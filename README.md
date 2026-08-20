# sol-contracts

Smart contracts for BASED NUT protocol infrastructure on Base.

## Contracts

| Contract | Directory | Description |
|---|---|---|
| WNUT | `src/wnut/` | 1:1 ERC-20 wrapper over NUT |
| FeeRouter | `src/router/` | Revenue deployment router with EAS attestations |

See each directory's README for contract details.

## Interfaces

| Interface | File | Purpose |
|---|---|---|
| EAS | `src/interfaces/EAS.sol` | Minimal EAS Core + Schema Registry |
| IPipsBuyer | `src/interfaces/IPipsBuyer.sol` | PIPS purchase adapter |
| ISwapRouter | `src/interfaces/ISwapRouter.sol` | Swap + liquidity router |

## Dependencies

- [Foundry](https://getfoundry.sh) — build, test, local chain
- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) 5.x
- [forge-std](https://github.com/foundry-rs/forge-std) — test utilities
- [EAS contracts](https://github.com/ethereum-attestation-service/eas-contracts) — reference

Installed as git submodules in `lib/`.

## Build

```bash
forge build
forge test
```

## License

MIT
