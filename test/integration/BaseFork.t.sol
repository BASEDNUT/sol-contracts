// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FeeRouter} from "../../src/router/FeeRouter.sol";
import {WNUT} from "../../src/wnut/WNUT.sol";
import {IEAS} from "@eas/contracts/IEAS.sol";
import {ISchemaRegistry, SchemaRecord} from "@eas/contracts/ISchemaRegistry.sol";
import {ISchemaResolver} from "@eas/contracts/resolver/ISchemaResolver.sol";
import {Attestation} from "@eas/contracts/Common.sol";

import {
    MockUSDC, MockERC20, MockPair,
    MockPipsBuyer, MockSwapRouter, MockLpRouter
} from "../mocks/Mocks.sol";

/**
 * @title BaseFork — C-01 regression gate
 * @notice Deploys FeeRouter against the REAL Base EAS + SchemaRegistry on a fork.
 *         Proves: (a) constructor ABI-decodes real getSchema() records,
 *         (b) schema registration flow works on the real registry,
 *         (c) real EAS.attest() round-trips with our payload encoding.
 *         Skips cleanly when no RPC URL is configured.
 */
contract BaseForkTest is Test {
    string constant RPC_ENV = "BASE_RPC_URL";
    string constant RPC_FALLBACK = "https://base.publicnode.com";

    // Predeployed system contracts on Base
    address constant EAS = 0x4200000000000000000000000000000000000021;
    address constant SCHEMA_REGISTRY = 0x4200000000000000000000000000000000000020;

    MockUSDC usdc;
    MockERC20 nut;
    WNUT wnut;
    MockERC20 pips;
    MockPipsBuyer pipsBuyer;
    MockSwapRouter swapRouter;
    MockLpRouter lpRouter;
    MockPair pair;
    FeeRouter router;

    function setUp() public {
        string memory rpc = vm.envOr(RPC_ENV, RPC_FALLBACK);
        vm.createSelectFork(rpc);

        usdc = new MockUSDC();
        nut = new MockERC20("NUT", "NUT");
        wnut = new WNUT(address(nut));
        pips = new MockERC20("PIPS", "PIPS");
        pipsBuyer = new MockPipsBuyer(address(usdc), address(pips));
        swapRouter = new MockSwapRouter(address(usdc), address(nut));
        pair = new MockPair(address(wnut), address(nut));
        lpRouter = new MockLpRouter(pair);

        // Register canonical schemas on the REAL registry (permissionless)
        string memory pipsDef = "string action,address caller,uint256 usdcTotal,uint256 usdcToPips,uint256 pipsMinted,uint256 timestamp";
        string memory lpDef = "string action,address caller,uint256 usdcTotal,uint256 usdcToLp,uint256 nutBought,uint256 liquidity,uint256 timestamp";
        bytes32 pipsUID = ISchemaRegistry(SCHEMA_REGISTRY).register(
            pipsDef, ISchemaResolver(address(0)), false
        );
        bytes32 lpUID = ISchemaRegistry(SCHEMA_REGISTRY).register(
            lpDef, ISchemaResolver(address(0)), false
        );

        router = new FeeRouter(
            address(usdc), address(nut), address(wnut), address(pips),
            address(pipsBuyer), address(swapRouter), address(lpRouter),
            EAS, SCHEMA_REGISTRY, address(pair),
            pipsUID, lpUID, 0, block.chainid, 1_000_000e6, 3600
        );

        usdc.mint(address(this), 1_000e6);
        usdc.approve(address(router), type(uint256).max);
    }

    function test_RealEas_ConstructorAndAttestation() public {
        // Registry binding verified against the real deployment
        assertEq(address(IEAS(EAS).getSchemaRegistry()), SCHEMA_REGISTRY);

        (bytes32 p, bytes32 l) = router.splitAndDeploy(
            100e6, 150e18, 55e18, 29e18, 29e18, 8e26, block.timestamp + 1800
        );

        // Real attestations exist and reference our schemas
        Attestation memory pAt = IEAS(EAS).getAttestation(p);
        assertEq(pAt.uid, p);
        assertEq(pAt.attester, address(router));
        assertEq(pAt.recipient, address(this));
        assertFalse(pAt.revocable);
        assertEq(pAt.revocationTime, 0);

        Attestation memory lAt = IEAS(EAS).getAttestation(l);
        assertEq(lAt.uid, l);
        assertEq(lAt.attester, address(router));

        // Payload ABI-decodes with the canonical schema fields
        (string memory action, address caller, uint256 usdcTotal, uint256 usdcToPips, uint256 pipsMinted, uint256 ts) =
            abi.decode(pAt.data, (string, address, uint256, uint256, uint256, uint256));
        assertEq(action, "PIPS_MINT");
        assertEq(caller, address(this));
        assertEq(usdcTotal, 100e6);
        assertEq(usdcToPips, 80e6);
        assertEq(pipsMinted, 160e18);
        assertEq(ts, block.timestamp);
    }

    function test_RealRegistry_UnknownUIDReturnsZeroRecord() public {
        // Documents real registry semantics: no revert, zero record
        SchemaRecord memory rec = ISchemaRegistry(SCHEMA_REGISTRY).getSchema(bytes32(uint256(0xdead)));
        assertEq(rec.uid, bytes32(0));
        assertEq(address(rec.resolver), address(0));
    }
}
