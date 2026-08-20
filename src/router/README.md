# FeeRouter

Deploys incoming USDC revenue across configured legs, emitting an EAS attestation per action.

## Configuration

- Split ratio: owner-settable in basis points (default 80/20)
- PIPS leg: purchases PIPS via an `IPipsBuyer` adapter
- LP leg: swaps USDC -> NUT, wraps half to wNUT, adds wNUT/NUT liquidity
- Attestations: EAS (Base predeploy `0x4200000000000000000000000000000000000021`)

## Security

- `OPERATOR_ROLE` RBAC on core entry — only operators call `splitAndDeploy`
- Owner can pause/unpause, set split, set schema UIDs, recover stuck tokens
- Reentrancy guard on state-changing functions
- Immutable — no upgradeability

## Events

- `FeesSplitAndDeployed` — full accounting per run (amounts, liquidity, attestation UIDs)
- `PipsBpsUpdated`, `SchemaUIDsUpdated`, `PipsRecovered`

## Tests

8 tests — happy path, split math, RBAC rejection, zero-amount, pause, admin setters, attestation count. Run: `forge test --match-contract FeeRouterTest`
