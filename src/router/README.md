# FeeRouter

Deploys incoming USDC revenue across two legs, emitting an EAS attestation per leg.

## Configuration

- Split ratio: admin-settable in basis points (default 80/20)
- PIPS leg: purchases PIPS via an `IPipsBuyer` adapter, **balance-delta verified** (return values never trusted)
- LP leg: swaps USDC -> NUT, wraps half to wNUT, adds wNUT/NUT liquidity — **all outputs measured by balance deltas** (USDC spent, NUT received, LP received)
- Attestations: EAS (Base predeploy `0x4200000000000000000000000000000000000021`), registry-bound (`eas.getSchemaRegistry() == schemaRegistry` enforced) and **schema-definition-bound** (UID must match the canonical schema string), validated at construction and on update
- All slippage bounds, min-outputs, and deadline are caller-supplied and enforced on-chain; zero bounds revert
- Contract-level operator caps: `maxUsdcPerRun`, `maxDeadlineHorizon` — operator cannot bypass with `min=1` + far-future deadline

## Security

- Single authority: `DEFAULT_ADMIN_ROLE` via `AccessControlDefaultAdminRules` (2-step + delayed admin transfer). This is an ownership-transfer delay, **not** an execution timelock — admin parameter changes take effect immediately.
- `OPERATOR_ROLE` RBAC on `splitAndDeploy`, bounded by caps
- Chain-ID guard at construction — wrong-chain deploy reverts
- Constructor validates all dependencies (nonzero + code + wNUT.underlyingNUT() == NUT + registry binding + **LP token pair tokens == {wNUT, NUT}** + schema definitions)
- Allowance hygiene: `forceApprove` exact amounts, reset to 0 after every external call
- LP position is protocol-owned; LP token is pair-validated at construction and on the protected-token denylist — cannot be swept
- Unconsumed LP-side residuals are explicitly surfaced via `ResidualsCarried` event + `residuals()` view (not silently stranded)
- USDC rescue requires admin **and** paused state (blacklist/emergency only)
- Reentrancy guard, pausable, no upgradeability

## Events

- `FeesSplitAndDeployed` — full accounting per run
- `ResidualsCarried` — explicit residual surfacing per run
- `PipsBpsUpdated`, `CapsUpdated`, `SchemaUIDsUpdated`, `PipsRecovered`, `DustRecovered`, `UsdcRescued`

## Tests

- `test/router/FeeRouter.t.sol` — unit + adversarial adapters
- `test/integration/BaseFork.t.sol` — real Base EAS/SchemaRegistry fork gate
