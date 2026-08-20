# WNUT — Wrapped NUT

1:1 ERC-20 wrapper over NUT (18 decimals, matching underlying).

## Design

- OpenZeppelin `ERC20Wrapper` — deposit N NUT, receive N wNUT
- Immutable deployment — no governance, no pausing, no upgradeability
- Owner-only `recover()` for accidentally sent ERC-20s (never NUT or wNUT)
- Direct NUT transfers to the wrapper do not mint wNUT

## Functions

```solidity
function depositFor(address account, uint256 amount) external returns (bool);
function withdrawTo(address account, uint256 amount) external returns (bool);
function recover(address token) external onlyOwner returns (uint256);
function underlyingNUT() external view returns (address);
```

## Tests

9 tests — wrap/unwrap 1:1, surplus handling, recover RBAC + guards, metadata. Run: `forge test --match-contract WNUTTest`
