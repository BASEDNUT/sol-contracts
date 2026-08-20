# WNUT — Wrapped NUT

1:1 ERC-20 wrapper over NUT (18 decimals, matching underlying).

## Design

- OpenZeppelin `ERC20Wrapper` — deposit N NUT, receive N wNUT
- Immutable deployment — no governance, no pausing, no upgradeability
- `Ownable2Step` — two-step ownership transfer
- Constructor validates NUT is a deployed contract (rejects EOAs)
- Owner-only `recover()` for accidentally sent ERC-20s (never NUT or wNUT), uses SafeERC20
- Owner-only `recoverSurplus()` mints wNUT covering direct NUT transfers / rebasing surplus (no stranded collateral)
- Direct NUT transfers do not mint wNUT

## Functions

```solidity
function depositFor(address account, uint256 amount) external returns (bool);
function withdrawTo(address account, uint256 amount) external returns (bool);
function recover(address token) external onlyOwner returns (uint256);
function recoverSurplus() external onlyOwner returns (uint256);
function underlyingNUT() external view returns (address);
```

## Tests

15 tests — wrap/unwrap 1:1, direct-transfer no-mint, surplus recovery (amounts + RBAC + empty-revert), junk recovery (SafeERC20 + guards + RBAC), constructor validation, 2-step ownership. Run: `forge test --match-contract WNUTTest`
