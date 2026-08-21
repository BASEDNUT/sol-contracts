# sol-contracts

Smart contracts for BASED NUT protocol infrastructure on Base.

## Contracts

| Contract | Directory | Description |
|---|---|---|
| WNUT | `src/wnut/` | 1:1 ERC-20 wrapper over NUT |
| FeeRouter | `src/router/` | Revenue deployment router with EAS attestations |
| AerodromeAdapter | `src/adapters/` | Venue adapter: V2-style seams -> Aerodrome Router |

## Interfaces

| Interface | File | Purpose |
|---|---|---|
| IPipsBuyer | `src/interfaces/IPipsBuyer.sol` | PIPS purchase adapter seam |
| ISwapRouter | `src/interfaces/ISwapRouter.sol` | Swap + liquidity router seams |

EAS integration uses the official [ethereum-attestation-service/eas-contracts](https://github.com/ethereum-attestation-service/eas-contracts) interfaces directly (git submodule).

## Dependencies

- [Foundry](https://getfoundry.sh) — build, test, fork tests
- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) 5.x
- [forge-std](https://github.com/foundry-rs/forge-std) — test utilities
- [EAS contracts](https://github.com/ethereum-attestation-service/eas-contracts) — official interfaces (imported directly)

Installed as git submodules in `lib/`.

## Build & Test

```bash
forge build
forge test                              # unit + mock-adapter suites
forge test --match-contract BaseForkTest  # Base fork tests (requires RPC access)
```

## Test layers

1. **Unit (mocks)** — happy paths, reverts, adversarial adapters (lying/stingy/sparing routers), access control, hygiene
2. **Adapter** — Aerodrome call-shape translation, pull/refund flow, allowance resets
3. **Integration (Base fork)** — FeeRouter constructed against the real Base EAS + SchemaRegistry predeploys; real attestations round-trip and payload-decode

## License

MIT
