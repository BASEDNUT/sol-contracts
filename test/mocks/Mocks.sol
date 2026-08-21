// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {FeeRouter} from "../../src/router/FeeRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AttestationRequest, MultiAttestationRequest} from "@eas/contracts/IEAS.sol";
import {ISchemaRegistry, SchemaRecord} from "@eas/contracts/ISchemaRegistry.sol";
import {ISchemaResolver} from "@eas/contracts/resolver/ISchemaResolver.sol";

// ── 6-decimal USDC (Base-native shape) ──
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

// ── ERC20 pair with token0/token1 (canonical sorted order) ──
contract MockPair is ERC20 {
    address public immutable token0;
    address public immutable token1;

    // ── Canonical Aerodrome Pool.fee claim semantics ──
    // Fees accrue to LP holders; claimFees() pays the CALLING holder and
    // resets their claimable. Test harness sets pending fees directly.
    mapping(address => uint256) public claimable0;
    mapping(address => uint256) public claimable1;

    constructor(address a, address b) ERC20("Mock LP", "MLP") {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    /// @dev Test helper: accrue pending fees for an LP holder.
    function accrueFees(address holder, uint256 amt0, uint256 amt1) external {
        claimable0[holder] += amt0;
        claimable1[holder] += amt1;
    }

    /// @dev Canonical shape: pays caller, returns claimed amounts, resets.
    function claimFees() external returns (uint256 claimed0, uint256 claimed1) {
        claimed0 = claimable0[msg.sender];
        claimed1 = claimable1[msg.sender];
        claimable0[msg.sender] = 0;
        claimable1[msg.sender] = 0;
        IERC20(token0).transfer(msg.sender, claimed0);
        IERC20(token1).transfer(msg.sender, claimed1);
    }
}

// ── Faithful SchemaRegistry: unknown UID returns ZERO record, never reverts ──
contract MockSchemaRegistry {
    mapping(bytes32 => SchemaRecord) private _records;
    event Registered(bytes32 indexed uid, address indexed registerer, SchemaRecord schema);

    function register(string calldata schema, ISchemaResolver resolver, bool revocable) external returns (bytes32 uid) {
        uid = keccak256(abi.encodePacked(schema, resolver, revocable));
        _records[uid] = SchemaRecord(uid, resolver, revocable, schema);
        emit Registered(uid, msg.sender, _records[uid]);
    }

    /// @dev Convenience for tests: returns the canonical EAS UID for a schema def.
    function uidFor(string calldata schema, ISchemaResolver resolver, bool revocable) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(schema, resolver, revocable));
    }

    function getSchema(bytes32 uid) external view returns (SchemaRecord memory) {
        return _records[uid]; // zero record (uid=0) when absent — mirrors real registry
    }
}

// ── Faithful EAS: reverts on unregistered schema ("NotFound"), mints UIDs ──
contract MockEAS {
    ISchemaRegistry public immutable registry;
    uint256 public attestCount;
    mapping(bytes32 => bool) public exists;

    error NotFound();

    constructor(address registry_) {
        registry = ISchemaRegistry(registry_);
    }

    function getSchemaRegistry() external view returns (ISchemaRegistry) {
        return registry;
    }

    function attest(AttestationRequest calldata request) external payable returns (bytes32 uid) {
        SchemaRecord memory rec = registry.getSchema(request.schema);
        if (rec.uid == bytes32(0)) revert NotFound(); // real EAS behavior
        attestCount++;
        uid = keccak256(abi.encodePacked(attestCount, request.schema, request.data.recipient));
        exists[uid] = true;
    }

    /// @dev Canonical EAS multiAttest: one UID per data entry, all-or-nothing.
    function multiAttest(MultiAttestationRequest[] calldata requests)
        external
        payable
        returns (bytes32[] memory uids)
    {
        uids = new bytes32[](requests.length);
        for (uint256 i; i < requests.length; ++i) {
            SchemaRecord memory rec = registry.getSchema(requests[i].schema);
            if (rec.uid == bytes32(0)) revert NotFound();
        }
        for (uint256 i; i < requests.length; ++i) {
            for (uint256 j; j < requests[i].data.length; ++j) {
                attestCount++;
                uids[i + j] =
                    keccak256(abi.encodePacked(attestCount, requests[i].schema, requests[i].data[j].recipient));
                exists[uids[i + j]] = true;
            }
        }
    }
}

// ── Resolver stub: address-only, never called. L-01 schema-semantics tests. ──
contract MockResolver {
    // Intentionally empty: the router only checks the schema RECORD's resolver
    // field is zero/nonzero; it never calls the resolver.
}

// ── PIPS adapters ──
contract MockPipsBuyer {
    MockUSDC public usdc;
    MockERC20 public pips;
    uint256 public rate = 2e12; // 1 USDC (6dp) -> 2e12 raw PIPS

    constructor(address usdc_, address pips_) {
        usdc = MockUSDC(usdc_);
        pips = MockERC20(pips_);
    }

    function buyPips(uint256 usdcAmount) external returns (uint256) {
        usdc.transferFrom(msg.sender, address(this), usdcAmount);
        uint256 out = usdcAmount * rate;
        pips.mint(msg.sender, out);
        return out;
    }
}

/// @dev Lying adapter: claims max output, delivers 1 raw PIPS. Catches return-value trust.
contract LyingPipsBuyer {
    MockUSDC public usdc;
    MockERC20 public pips;

    constructor(address usdc_, address pips_) {
        usdc = MockUSDC(usdc_);
        pips = MockERC20(pips_);
    }

    function buyPips(uint256 usdcAmount) external returns (uint256) {
        usdc.transferFrom(msg.sender, address(this), usdcAmount);
        pips.mint(msg.sender, 1);
        return type(uint256).max;
    }
}

/// @dev Stingy adapter: spends less than approved but delivers full PIPS from inventory.
///      Catches unverified USDC consumption (M-02).
contract StingyPipsBuyer {
    MockUSDC public usdc;
    MockERC20 public pips;

    constructor(address usdc_, address pips_) {
        usdc = MockUSDC(usdc_);
        pips = MockERC20(pips_);
    }

    function buyPips(uint256) external returns (uint256) {
        // pulls only half of the approval
        uint256 allowance = usdc.allowance(msg.sender, address(this));
        usdc.transferFrom(msg.sender, address(this), allowance / 2);
        pips.mint(msg.sender, 1_000_000e18); // plenty of PIPS from inventory
        return 1_000_000e18;
    }
}

// ── Swap routers ──
contract MockSwapRouter {
    MockUSDC public usdc;
    MockERC20 public nut;
    uint256 public rate = 3e12; // 1 USDC (6dp) -> 3e12 raw NUT

    constructor(address usdc_, address nut_) {
        usdc = MockUSDC(usdc_);
        nut = MockERC20(nut_);
    }

    function setRate(uint256 r) external {
        rate = r;
    }

    function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata, address to, uint256)
        external
        returns (uint256[] memory amounts)
    {
        usdc.transferFrom(msg.sender, address(this), amountIn);
        uint256 out = amountIn * rate;
        nut.mint(to, out);
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = out;
    }
}

/// @dev Lying swap router: reports inflated output, delivers little. Catches return-array trust.
contract LyingSwapRouter {
    MockUSDC public usdc;
    MockERC20 public nut;

    constructor(address usdc_, address nut_) {
        usdc = MockUSDC(usdc_);
        nut = MockERC20(nut_);
    }

    function swapExactTokensForTokens(uint256 amountIn, uint256, address[] calldata, address to, uint256)
        external
        returns (uint256[] memory amounts)
    {
        usdc.transferFrom(msg.sender, address(this), amountIn);
        nut.mint(to, amountIn / 10); // deliver 10% of honest output
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn * 1e6; // lie: claim huge
    }
}

// ── LP routers ──

/// @dev Faithful LP router: pulls tokens, enforces minima, mints LP to `to`.
contract MockLpRouter {
    MockPair public pair;

    constructor(MockPair pair_) {
        pair = pair_;
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        require(amountADesired >= amountAMin && amountBDesired >= amountBMin, "MIN_AMOUNTS");
        MockERC20(tokenA).transferFrom(msg.sender, address(this), amountADesired);
        MockERC20(tokenB).transferFrom(msg.sender, address(this), amountBDesired);
        amountA = amountADesired;
        amountB = amountBDesired;
        liquidity = (amountA * amountB) / 1e12; // synthetic sqrt-ish
        pair.mint(to, liquidity);
    }
}

/// @dev Sparing LP router: consumes only 90% of desired (real AMM ratio behavior).
///      Catches stranded-residual handling (M-03).
contract SparingLpRouter {
    MockPair public pair;

    constructor(MockPair pair_) {
        pair = pair_;
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        amountA = (amountADesired * 9) / 10;
        amountB = (amountBDesired * 9) / 10;
        require(amountA >= amountAMin && amountB >= amountBMin, "MIN_AMOUNTS");
        MockERC20(tokenA).transferFrom(msg.sender, address(this), amountA);
        MockERC20(tokenB).transferFrom(msg.sender, address(this), amountB);
        liquidity = (amountA * amountB) / 1e12;
        pair.mint(to, liquidity);
    }
}

/// @dev Lying LP router: consumes tokens, mints NO LP, reports huge liquidity.
contract LyingLpRouter {
    constructor() {}

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256,
        uint256,
        address,
        uint256
    ) external returns (uint256, uint256, uint256) {
        MockERC20(tokenA).transferFrom(msg.sender, address(this), amountADesired);
        MockERC20(tokenB).transferFrom(msg.sender, address(this), amountBDesired);
        return (amountADesired, amountBDesired, type(uint256).max); // lie
    }
}

/// @dev 6-decimal ERC20 — rejects WNUT 18dp underlying guard (I-01).
contract SixDecimalToken is ERC20 {
    constructor() ERC20("Six", "SIX") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

// ═══════════════ REENTRANCY HARNESS (round 6) ═══════════════

/// @dev Reenters FeeRouter.splitAndDeploy from inside buyPips.
contract ReentrantPipsBuyer {
    MockUSDC public immutable usdc;
    MockERC20 public immutable pips;
    address public target;

    constructor(address usdc_, address pips_) {
        usdc = MockUSDC(usdc_);
        pips = MockERC20(pips_);
    }

    function setTarget(address t) external {
        target = t;
    }

    function buyPips(uint256 usdcAmount) external returns (uint256) {
        usdc.transferFrom(msg.sender, address(this), usdcAmount);
        if (target != address(0)) {
            // Nested attempt — MUST hit ReentrancyGuard and bubble up.
            try FeeRouter(target).splitAndDeploy(
                usdcAmount, 1, 1, 1, 1, 1, block.timestamp + 600
            ) {
                revert("REENTRANCY NOT BLOCKED");
            } catch {
                revert("NESTED REVERT EXPECTED");
            }
        }
        pips.mint(msg.sender, usdcAmount * 2e12);
        return usdcAmount * 2e12;
    }
}

/// @dev Malicious LP pair: reenters deployResiduals (via mint) or claimLpFees
///      (via claimFees) depending on mode.
contract MaliciousPair is ERC20 {
    enum Mode { OFF, REENTER_DEPLOY, REENTER_CLAIM }
    address public immutable token0;
    address public immutable token1;
    Mode public mode = Mode.OFF;
    address public target;
    mapping(address => uint256) public claimable0;
    mapping(address => uint256) public claimable1;

    constructor(address a, address b) ERC20("Evil LP", "ELP") {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function setTarget(address t) external {
        target = t;
    }

    function accrueFees(address holder, uint256 amt0, uint256 amt1) external {
        claimable0[holder] += amt0;
        claimable1[holder] += amt1;
    }

    function mint(address, uint256) external {
        if (mode == Mode.REENTER_DEPLOY && target != address(0)) {
            FeeRouter(target).deployResiduals(1, 1, 1, block.timestamp + 600); // must revert
        }
        // then reverts itself via failed nested call bubbling
    }

    function claimFees() external returns (uint256, uint256) {
        if (mode == Mode.REENTER_CLAIM && target != address(0)) {
            FeeRouter(target).claimLpFees(); // must revert
        }
        revert("NESTED REVERT EXPECTED");
    }
}

/// @dev LpRouter bound to MaliciousPair (type-correct ctor).
contract EvilLpRouter {
    MaliciousPair public pair;
    constructor(MaliciousPair pair_) { pair = pair_; }
    function addLiquidity(
        address tokenA, address tokenB,
        uint256 amountADesired, uint256 amountBDesired,
        uint256 amountAMin, uint256 amountBMin,
        address to, uint256
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        require(amountADesired >= amountAMin && amountBDesired >= amountBMin, "MIN_AMOUNTS");
        MockERC20(tokenA).transferFrom(msg.sender, address(this), amountADesired);
        MockERC20(tokenB).transferFrom(msg.sender, address(this), amountBDesired);
        amountA = amountADesired;
        amountB = amountBDesired;
        liquidity = (amountA * amountB) / 1e12;
        pair.mint(to, liquidity);
    }
}
