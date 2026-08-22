# WNUT — Wrapped NUT

Standard WETH9-model wrapper over NUT. Bare OpenZeppelin `ERC20Wrapper` — **18 lines, zero custom logic**.

## Properties
- **No admin surface**: no owner, no rescue, no upgrade path, no mint role. Nothing to hack, nothing to hand over.
- **Mint discipline**: `depositFor()` pulls NUT before minting — unbacked mint impossible.
- **Burn discipline**: `withdrawTo()` burns before release.
- **Permissionless**: anyone wraps/unwraps for anyone.
- **1:1 raw-unit backing**, decimals mirror underlying (NUT = verified immutable 18dp).
- **WETH parity**: accidentally-sent tokens are permanently stranded. Accepted market-wide cost of zero attack surface.

## Audit posture
No custom code to audit — inherits audited OZ library (thousands of deployments). WETH9 model has secured billions for 6+ years without admin functions.
