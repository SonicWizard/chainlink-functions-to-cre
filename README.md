# Chainlink Functions → CRE

A worked migration of a Chainlink Functions consumer to the **Chainlink Runtime
Environment (CRE)**, on Ethereum Sepolia.

This started as the consumer contract from
[Cyfrin Updraft's **Chainlink Fundamentals**](https://updraft.cyfrin.io/courses/chainlink-fundamentals)
course — Section 7, lesson 4:
[*Building a Chainlink Functions Consumer Smart Contract*](https://updraft.cyfrin.io/courses/chainlink-fundamentals/chainlink-functions/building-a-functions-smart-contract). Partway through, it
turned out the lesson can no longer be completed as written:

> **Chainlink Functions sunset on 2026-06-15 (testnet) and 2026-06-30 (mainnet).**
> New subscriptions can't be created — the "Create Subscription" button 404s —
> and the DON no longer fulfils requests.

So this repo keeps the original Functions contract as the *before*, and adds a
working CRE replacement as the *after*. If you're partway through that course, or
have an existing Functions consumer to port, the diff between the two is the point.

## How the two models differ

Functions was **request/callback**, driven by the contract:

```
contract --_sendRequest()--> Router --> DON runs inline JS --> fulfillRequest() callback
```

CRE is **trigger/report**, driven by an off-chain workflow:

```
contract emits event --> CRE workflow (log trigger) --> HTTP fetch under consensus
                     --> signed report --> KeystoneForwarder --> onReport()
```

Practical consequences:

| | Chainlink Functions | CRE |
| --- | --- | --- |
| Off-chain code | JavaScript in a Solidity string | TypeScript/Go compiled to WASM |
| Billing | LINK subscription | Workflow pays for its own writes |
| Entry point | `fulfillRequest()` | `onReport()` via `IReceiver` |
| Consensus | Implicit in response bytes | Explicit `ConsensusAggregationByFields` |
| Concurrency | One request slot | Keyed by `requestId` |

## Layout

| Path | What |
| --- | --- |
| [`src/FunctionsConsumer.sol`](src/FunctionsConsumer.sol) | The original Functions consumer. Deployed, but permanently unfulfillable. Kept as reference. |
| [`src/TemperatureConsumer.sol`](src/TemperatureConsumer.sol) | The CRE replacement, built on Chainlink's `ReceiverTemplate`. |
| [`cre/weather/workflow.ts`](cre/weather/workflow.ts) | The CRE workflow: log trigger → Open-Meteo → signed report. |
| [`test/`](test/) | Foundry tests for both contracts (24 passing). |
| [`script/`](script/) | Deployment scripts. |

## Build and test

```sh
forge build
forge test -vv
```

## Run the workflow

Needs the [CRE CLI](https://docs.chain.link/cre/getting-started/cli-installation),
Bun, and a CRE account (`cre login`).

```sh
cd cre
bun install --cwd ./weather

# replay a real TemperatureRequested log through the workflow
cre workflow simulate weather --target staging-settings \
  --evm-tx-hash <TX_THAT_CALLED_requestTemperature> \
  --evm-event-index 0
```

Expected output:

```
[USER LOG] TemperatureRequested: city="London" requestId=0xd9cb010a…
[USER LOG] Consensus reading: 17C at 1789510500
✓ "London: 17C — tx: 0x0000…0000"
```

The zero tx hash is expected: the simulator runs the write path without
broadcasting. Real writes require a deployed workflow, which needs CRE deploy
access (`cre account access`).

## Deployed on Sepolia

| Contract | Address |
| --- | --- |
| `FunctionsConsumer` (dead) | [`0x2968e237d04126b5A35ff62f34020079A0D1A0Ee`](https://sepolia.etherscan.io/address/0x2968e237d04126b5A35ff62f34020079A0D1A0Ee) |
| `TemperatureConsumer` (CRE) | [`0xd70e7756435B0ad0496259f80Ff06aADBf10b5F1`](https://sepolia.etherscan.io/address/0xd70e7756435B0ad0496259f80Ff06aADBf10b5F1) |

## Things that cost us time

**Solidity has no multi-line or backtick string literals.** The Functions JS was
stored as adjacent string literals, which the compiler concatenates with *nothing*
between them — so every line needed its own `\n`. Miss one and the script silently
collapses onto a single line, where a `//` comment swallows the rest.

**Report encoding must be flat ABI parameters.** viem's
`encodeAbiParameters(parseAbiParameters('bytes32 a, string b, …'))` produces a flat
tuple. Decoding it into a Solidity *struct* fails — `abi.encode` of a struct with
dynamic members prepends an offset word. Use `abi.decode(report, (bytes32, string, …))`.
`test_Report_StructEncodingIsRejected` pins this.

**Workflow names in report metadata aren't plaintext.** They're the first 10
characters of the hex-encoded SHA-256 of the name. Comparing against
`bytes10("my-workflow")` will never match.

**The data source matters for consensus.** Every DON node runs the fetch
independently and the results must agree. The original lesson used `wttr.in`, whose
live-rendered output can differ between nodes (and whose TLS cert had expired).
Open-Meteo buckets readings into 15-minute intervals (`interval: 900`), so nodes
querying the same window see identical values.

## Credit

Original contract and lesson: [Cyfrin Updraft — Chainlink Fundamentals](https://updraft.cyfrin.io/courses/chainlink-fundamentals),
lesson [*Building a Chainlink Functions Consumer Smart Contract*](https://updraft.cyfrin.io/courses/chainlink-fundamentals/chainlink-functions/building-a-functions-smart-contract).
CRE migration, tests, and workflow: this repo.
