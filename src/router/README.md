# FeeRouter

Deploys incoming USDC revenue across two legs, emitting an EAS attestation per leg.

## Configuration

- Split ratio: admin-settable in basis points (default 80/20)
- PIPS leg: purchases PIPS via an `IPipsBuyer` adapter, **balance-delta verified** (return value never trusted)
- LP leg: swaps USDC -> NUT, wraps half to wNUT, adds wNUT/NUT liquidity with exact per-run amounts
- Attestations: EAS (Base predeploy `0x4200000000000000000000000000000000000021`), schema existence validated at construction and on update
- All slippage bounds, min-outputs, and deadline are **caller-supplied** and enforced on-chain; zero bounds revert

## Security

- Single authority: `DEFAULT_ADMIN_ROLE` via `AccessControlDefaultAdminRules` (2-step + delayed admin transfer). No `Ownable`.
- `OPERATOR_ROLE` RBAC on `splitAndDeploy`
- Chain-ID guard at construction — wrong-chain deploy reverts
- Constructor validates all dependencies (nonzero + code + wNUT.underlyingNUT() == NUT + schemas exist)
- Allowance hygiene: `forceApprove` exact amounts, reset to 0 after every external call
- LP position is protocol-owned; LP token is on the protected-token denylist and cannot be swept by any function
- USDC rescue requires admin **and** paused state (blacklist/emergency only)
- Reentrancy guard, pausable, no upgradeability

## Events

- `FeesSplitAndDeployed` — full accounting per run
- `PipsBpsUpdated`, `SchemaUIDsUpdated`, `PipsRecovered`, `DustRecovered`, `UsdcRescued`

## Tests

26 tests — happy path, slippage reverts (swap + deadline + zero-bound), lying-adapter rejection, protected-token sweep denial (USDC/NUT/wNUT/PIPS/LP), paused-only USDC rescue, 2-step delayed admin transfer with former-admin lockout, constructor validation (zero-addr/EOA/chain/schema/wrong-underlying), allowance reset, no cross-run balance sweeps, RBAC, pause, admin setters. Run: `forge test --match-contract FeeRouterTest`
