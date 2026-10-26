# Cloud API read retries

Terraform deployment failed when `GetCVMInfo` returned HTTP 429 before an
environment update. The Go Cloud SDK already retried some writes, but its read
methods bypassed the retry loop. This model covers the automatic read retry
layer added to the SDK; it is separate from mesh signaling and CVM boot.

## Algorithm and correspondence

The SDK retries transient HTTP 409, 429, and 503 responses to replayable GET/HEAD
requests. Structured business conflicts, transport errors, response decoding,
and mutation policies stay outside this retry layer. `Retry-After` takes
precedence over exponential backoff, including values above the backoff cap.
Absent a usable header, waits start at one second, double, and cap at 20 seconds.
The default is 30 retries after the initial attempt. Cancellation and the
operation deadline apply to both requests and waits; the HTTP client timeout
applies to each exchange independently.

The client implementations are in the separate
[Cloud SDKs at `263896d`](https://github.com/Phala-Network/phala-cloud/tree/263896d8f2e0b4e22de822196372a154b81f4e94),
submitted in [Cloud PR #535](https://github.com/Phala-Network/phala-cloud/pull/535):
Go's `request.go` connects reads to `retry.go`; `errors.go` parses the delay.
JavaScript's `utils/read-retry.ts` and Python's `retry.py` implement the same
default read policy. A [shared fixture](https://github.com/Phala-Network/phala-cloud/blob/263896d8f2e0b4e22de822196372a154b81f4e94/go/testdata/read-retry.json)
checks 28 scenarios against Go, JS/TS, and both Python clients in CI. The
[SDK contract](https://github.com/Phala-Network/phala-cloud/blob/263896d8f2e0b4e22de822196372a154b81f4e94/docs/sdk-read-retries.md)
records each language's cancellation and transport timeout limits; in-flight
synchronous Python sockets use HTTPX timeouts.

SDK regressions exercise the public CVM reads with a 60-second `Retry-After`, a
30-second HTTP timeout, and a longer operation deadline using Go's virtual clock.
They also cover HTTP dates, capped backoff, exhaustion, cancellation, permanent
errors, and integer overflow. The model treats retryable responses as 429 and
assumes an already decoded delay. Parsing and status classification are checked
by conformance tests. No implementation refinement or full SDK equivalence is
claimed here.

## Checked properties and bounds

Run `python3 protocol/check.py --only deployment`.

The positive configurations check:

- At most the initial request plus `MaxRetries` retries are sent.
- A request never precedes its required retry time.
- Cancellation or the operation deadline prevents another request.
- The loop terminates through success, exhaustion, or cancellation/deadline.
- Transient throttling recovers when the retry and time budgets suffice.

The main scenario models two throttled responses, a six-tick quota wait, a
three-tick HTTP timeout, one-tick exchanges, and a twenty-tick operation budget.
The exponential scenario exercises the backoff cap through five retries.
`ProductionTiming` checks two 60-second quota waits with a 30-second HTTP
timeout, 30 allowed retries, and a 600-second operation deadline.
Separate scenarios cover cancellation, exhausted retries, and a short deadline.
These are exhaustive finite instances, not unbounded proofs of deployment.

Each modeled exchange takes exactly `RequestLatency` ticks, no longer than
`RequestTimeout`. Due local actions are urgent and execution is weakly fair.
The explicit completion budget is the sum of all exchanges and required waits;
it must be strictly less than the operation deadline. Cancellation may occur
between any actions. The model contains no VM creation or environment writes,
so it establishes no mutation or whole-deployment guarantee.

## Counterexamples

| Configuration | Expected result |
|---|---|
| `NoRetry` | A single transient 429 terminates the operation despite sufficient time and retry budget. |
| `RequestDeadline` | Applying the shorter HTTP timeout to the whole operation prevents recovery after the longer quota wait. |
| `IgnoreRetryAfter` | Retrying on the shorter exponential delay violates the server's retry time. |
| `IgnoreCancellation` | A request is issued after cancellation. |
| `Reachable` | Successful recovery is reachable. |

All counterexamples must identify the expected property; tool errors do not
count as passing controls. Permanent throttling cannot guarantee successful
completion with finite retry or time budgets. Server quota availability, VM
readiness, and the rest of Terraform's resource graph need their own assumptions
and models before claiming that a deployment always completes.
