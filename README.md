# BASEDNUT sol-contracts

Solidity contracts for the NUT Credit Protocol on Base.

## Architecture

USDC revenue in → 80% PIPS mint leg / 20% NUT LP leg, attested on EAS.

```
src/
├── wnut/WNUT.sol        # 1:1 ERC-20 wrapper over NUT (OZ ERC20Wrapper, 18dp)
├── router/FeeRouter.sol # 80/20 USDC splitter: PIPS mint + NUT/wNUT LP + EAS attestations
├── interfaces/
│   ├── EAS.sol          # Minimal EAS Core + Schema Registry (Base predeploys 0x4200...0020/21)
│   ├── IPipsBuyer.sol   # PIPS adapter seam (ACF calldata pending verification)
│   └── ISwapRouter.sol  # Generic V2-style swap + LP router seams
test/
├── wnut/WNUT.t.sol     # 9 tests
├── router/FeeRouter.t.sol # 8 tests
└── mocks/Mocks.sol      # Mock ERC20s, routers, EAS
```
## Status

| Component | State |
|---|---|
| WNUT wrapper | Written, 9/9 tests pass |
| FeeRouter 80/20 | Written, 8/8 tests pass (mocks) |
| EAS schemas | Not yet registered |
| PIPS buyer adapter | PENDING — see research note |
| Deployment | Not deployed |

## Critical research finding (2026-08-19)

PIPS (0x3f2327221dd4f0bae660172606d6b288a1cf8ad9) is **NOT on the classic Virtuals Fun bonding curve**. Token has no buy()/sell(). Curve/auction logic lives in Factory 0x488Db0978b34C6Fd901760b9024B565C1117c7c8 (impl UNVERIFIED on Basescan). ABI errors indicate ACF (Agent Capital Formation) auction model. Graduation → Uniswap V2 (not Aerodrome). Full research: `peanutoshi/research/virtuals-acp-pips-curve-2026-08-19.md`.

FeeRouter is built against the `IPipsBuyer` adapter seam — swap the adapter implementation when exact ACF entry points are verified. Router surface stays stable.

## Build

```bash
forge build
forge test
```

## Dependencies
- Foundry 1.7.1 (forge/cast/anvil) OpenZeppelin Contracts 5.x
- EAS contracts (reference)
- forge-std
