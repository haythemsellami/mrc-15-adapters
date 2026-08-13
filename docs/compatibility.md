# Monad propAMM compatibility

This document records the current MRC-15 compatibility review of the supported Monad propAMMs. Compatibility was
revalidated against Monad mainnet block `90,990,000`; Hanji exact-execution controls additionally use block
`88,161,153`.

## Status

| Venue | Quote path | Exact-input execution | Adapter status |
| --- | --- | --- | --- |
| LFJ POE | Static-compatible pool quote | Callback settlement | Supported |
| Clober V2 | Static-compatible BookViewer | Supported when the complete requested base amount is executable | Supported |
| Metric legacy | State-changing legacy router quote | Router pulls exact input | Supported through rollback-isolated non-view quoting |
| Hanji | Static-compatible helper ladder | Proxy execution with exact-input verification | Operational exception requiring complete-swap simulation and winner pruning |
| Lunarbase | View pool quotes | Deployed execution path is caller-whitelisted | Blocked |

An unsupported venue is intentionally not represented by a contract that merely implements the ABI. A conforming
adapter must also satisfy MRC-15's exact-input funding, executable-quote, and recipient-settlement requirements. Hanji
is the explicitly documented exception: it is usable with a simulation-gated builder flow but is not claimed to
satisfy strict same-state quote fidelity.

## LFJ POE

`PoeAdapter` reads the pool's fixed token order, rejects quotes that do not consume the complete requested input, and
authenticates POE's settlement callback before paying the pool. POE sends output directly to the MRC-15 recipient, and
the shared base verifies the recipient's balance increase.

| Contract | Monad address |
| --- | --- |
| Factory | `0x78120F2C0EBF0cc8B7E7749e62D36e6523dD711D` |
| WMON/USDC pool | `0x02A8A16613a421EabaD6861fF6d8159f6D5EDB8f` |

## Clober V2

`CloberAdapter` validates its BookManager, BookViewer, Controller, and mirrored directional books at construction.
Quotes revert unless the viewer reports that the full exact input is executable. For native-MON books, the adapter
normalizes the MRC-15 endpoint to WMON and wraps or unwraps only during venue settlement.

| Contract | Monad address |
| --- | --- |
| BookManager | `0x6657d192273731C3cAc646cc82D5F28D0CBE8CCC` |
| BookViewer | `0xe424c211e2Ed8a5B6d1C57FA493C41715568D238` |
| Controller | `0x19b68a2b909D96c05B623050C276FBD457De8e83` |

| Adapter pair | token0-for-token1 book | token1-for-token0 book |
| --- | ---: | ---: |
| WMON/USDC | `5954885684956363054050231031211743946744177791604395877538` | `3875727077379471850923186002296331935053867847116966170720` |
| WBTC/USDC | `5310657737502833383554997860081619839164052597766524570606` | `3854396250455310695147789948131437079035726850548834252223` |
| WETH/USDC | `680091963353999958661303284433884846705699901928885914311` | `6215929461771924482215683498685754109371513948112281158916` |

## Metric legacy

`MetricAdapter` calls the legacy router's state-changing `quoteSwap` path. This is compatible with the current MRC-15
because quotes use ordinary `CALL` inside a child frame that always rolls back. The adapter reads the pool's price
provider for its bid and ask inputs, validates signed quote deltas, and requires both quoted and reported executed
input to equal the requested exact input.

| Contract | Monad address |
| --- | --- |
| Router | `0xaF9ADa6b6eC7993CE146f6c0bF98f7211CDfD3e5` |
| WMON/USDC pool | `0xFA32f9ec28787d1F9C5BA5c39e54e59984FEF3f0` |
| WBTC/USDC pool | `0x2D82AC42334b394A9a8d8f097d61DC1c6B065Fd8` |
| WETH/USDC pool | `0x354D92279cA0190fF275095fE6A2a6989BAa66Fb` |

Metric quotes fail under EVM `STATICCALL`. Integrations must use a rollback-isolated ordinary-call implementation.

## Hanji

`HanjiAdapter` walks the configured FastQuoterHelper ladder and executes against one fixed active market proxy.
Token-X inputs must be whole Hanji shares with sufficient visible depth. Token-Y inputs must equal an exact
helper-derived share boundary. Execution requires the proxy to consume the complete input and normalizes native MON
output to WMON where needed.

The helper ladder is not an enforced execution preview. A quote can win and then revert because the proxy consumes
less input or delivers less output. This is fund-safe because the complete transaction rolls back, but it is a
liveness and gas-cost risk. A builder must:

1. Quote the intended candidate set through the current router interface.
2. Simulate the exact complete swap with the intended calldata, caller, balances, allowances, gas limit, and state.
3. If a selected Hanji execution reverts, remove that winning adapter and repeat selection and complete-swap simulation.
4. Submit only a candidate set whose complete swap simulation succeeds.

A successful simulation is not a future-block guarantee, so the router and adapter retain atomic settlement checks.
The repository's pinned fork controls currently cover WMON/USDC.

| Deployment input | Monad address/value |
| --- | --- |
| WMON/USDC market | `0x1aeD222dda944a87703c918745b11bE13f8eEf10` |
| FastQuoterHelper | `0x237dB58fea34A35A8543b44C217d221606cE7788` |
| Recommended maximum price levels | `60` |

## Lunarbase blocker

The MON/USDC pool exposes view quote functions, but its deployed execution path is caller-whitelisted. A newly
deployed permissionless adapter is not currently authorized to execute, and the production execution ABI and native
settlement semantics are not sufficiently published to validate a conforming implementation.

Support requires a verified execution interface, authorization for the adapter deployment, and documented rules for
fee selection and native-MON settlement.
