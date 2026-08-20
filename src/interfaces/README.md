# Interfaces

- **EAS.sol** — minimal EAS Core (`attest`, `getAttestation`) and Schema Registry (`register`, `getSchema`) interfaces for Base predeploys
- **IPipsBuyer.sol** — adapter interface for PIPS purchases: `buyPips(usdcAmount) -> pipsMinted`
- **ISwapRouter.sol** — generic V2-style `swapExactTokensForTokens` and `addLiquidity` seams
