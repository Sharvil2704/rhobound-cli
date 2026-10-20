# rbfast: a parallel Rust accelerator for rhobound-cli

rbfast reads OpenTelemetry trace captures, infers the service call graph and predicts mean latency exactly as
rhobound-cli (the Go code in this repository) does, only faster. It is **optional**: the Go binary `rhobound` stays
the reference and the specification. Every rbfast output was checked against it (see [Parity](#parity)), and when
the two ever disagree, the Go binary is right. Byte-identity with the Go binary was verified on linux/arm64 only
(see [Architectures](#architectures)).

What it is made of (a Cargo workspace; each crate is a port of one Go package, line by line where it matters):

| crate | ports | what runs in parallel |
|---|---|---|
| `crates/otlp` (rbfast-otlp) | `internal/otlp`: the OTLP/JSON capture reader (`.jsonl`, `.json` streams, both gzipped) | plain files cut at line ends and read with pread into per-thread buffers, decoded on all cores by a hand-written JSON decoder; each `.gz` file inflated by its own task that hands batches to the pool; `.json` streams cut into batches scanned and decoded in parallel; tables interned with a fast hash |
| `crates/infer` (rbfast-infer) | `internal/infer`: topology inference, FIFO queue rebuild, glue, stages, async calls, uneven split, branch correlation | the span sort (Go's own pdqsort, run in parallel: Go's order of tied spans), the per-trace passes (in Go's chunks, merged in Go's order), the queue rebuild per pod, per-service sorts |
| `crates/math` (rbfast-math) | `internal/mathx` and `internal/model`: GammaP, normal, matched/correlated gamma maxima, Erlang C, QNA, AnalyticWith, ChangePatchWith, topology JSON | the matched maximum's quadrature for one what-if; many what-ifs at once (`batch`, `sweep`) |
| `crates/gostr` (rbfast-gostr) | Go's `strconv.Quote`/`QuoteRune`/`IsPrint` (with Go 1.27's own tables), `unicode.IsSpace`, `strings.TrimSpace`, `utf8.DecodeRune`, the JSON encoder's replacement of invalid UTF-8 | (shared by the others: every `%q` in an error is Go's) |
| `crates/cli` (rbfast) | `cmd/rhobound`, `internal/report` and `text/tabwriter` | (drives the above) |

Parts of these crates are ports of the Go standard library (BSD-3-Clause, [LICENSE-GO](LICENSE-GO)); each such
file says in its header which Go file it is derived from. The rest is Apache-2.0, as the repository. The
third-party crates and their licences are in [THIRD-PARTY.md](THIRD-PARTY.md).

## Commands

```
rbfast predict CAPTURE [--patch svc=+3ms,other=+10%] [--workers svc=N] [--kept-share F]
                       [--max-rho 0.85] [--out DIR] [--json] [--plain] [--threads N]
rbfast infer   CAPTURE [--workers svc=N] [--threads N]
rbfast model   TOPOLOGY.json --rps N [--patch ...] [--max-rho 0.85] [--out DIR] [--json] [--plain]
rbfast sweep   TOPOLOGY.json --rps A:B:STEP[,R,...] [--patch-grid GRID] [--plain | --both] [--max-rho R] [--threads N]
rbfast sweep   CAPTURE --capture [--rps ...] [--patch-grid GRID] [--workers svc=N] [--kept-share F] ...
rbfast read    CAPTURE [--threads N] [--reps R] [--json]
rbfast version
```

`predict`, `infer` and `model` take rhobound's arguments, with Go's flag rules (`-x` or `--x`, `--x=v`, flags
before or after the positional argument), and print rhobound's output: the same JSON report (`--json`), the
same text report, the same topology JSON, the same warnings, refusal texts and exit codes (0; 1 for any error;
2 for no or an unknown command). Arguments are taken as bytes, as Go takes them: a capture, topology or `--out`
path that is not UTF-8 opens, and an error prints or quotes it as Go does. They are drop-in replacements:

```
rbfast predict /path/to/capture --json --patch pricing=+5%,recommend=+1ms > report.json
rbfast infer /path/to/capture > topology.json
rbfast model topology.json --rps 120 --patch pricing=+2ms
```

The new commands:

* **`sweep`**: many what-ifs on one topology in parallel, one JSON line each (the Go binary has no such command;
  there, each point is one `rhobound model` process). `--rps` takes ranges and lists (`50:150:10,200`); each
  value is `A + k*STEP`. `--patch-grid` is `ALT[;ALT...]`, each `ALT` a list `svc=VALUES[,svc=VALUES...]`
  evaluated at every combination of its services' values; `VALUES` is `V[|V...]`, each `V` a `--patch` value
  (`+3ms`, `-10%`) or a range with a unit (`0:10:2%`, `0:5:0.5ms`). At most 1,000,000 loads and 100,000 changes
  per sweep (counted before anything is built; more is refused with an error). Example:

  ```
  rbfast sweep topology.json --rps 50:150:10 --patch-grid 'pricing=0:20:5%;recommend=+1ms|+2ms' --both
  ```

  Each line has the load (`rps`), the model (`refined` or `basic`), the change as a `--patch` spec (`patch`,
  `null` for the base), `status` (`ok`, `refused` with rhobound's refusal text, or `error`), the busiest service
  and its utilization, and per service `utilization`, `model_ms` (the latency the caller sees, as in the report)
  and, for a change, `after_utilization`, `after_ms`, `change_ms`, `change_pct`. Every line is what
  `rhobound model TOPOLOGY --rps R --patch SPEC --json` reports for that point, bit for bit, in rhobound's order of
  checks (a base that fails or is refused at a load is what every change at that load reports, before a change
  that does not parse) (checked; see Parity). The base of each (load, model) is solved once and shared by its
  changes, and matched-maximum results are reused across lines by their input bits; neither changes a bit.
  `--capture` infers the topology from a capture first; at the observed load (no `--rps`) a refusal is worded as
  `rhobound predict` words it ("refusing to predict: at the observed load ..."); at another load rbfast says
  "refusing to predict: at R requests/s" (predict has no such case).
* **`read`**: reads the capture only and prints its counts (files, bytes, spans, skipped, probes, resources,
  peers, addresses) and the read time (`--reps R`: the median of R reads).

Differences from rhobound, all deliberate:

* Error lines start with `rbfast: ` where rhobound prints `rhobound: `; the text after it is rhobound's.
* `help`, `version` and the usage text are rbfast's own (they list the extra commands).
* `--threads N` (or `RBFAST_THREADS=N`) sets the worker threads; 0 or unset means one per core, as Go's default
  GOMAXPROCS. rhobound would refuse this flag. When the OS refuses the threads, every command fails with
  `thread pool: resource temporarily unavailable` (exit 1).
* Environment switches: `RBFAST_TIMES=1` prints the read, inference, model and report times to stderr;
  `RBFAST_STAGES=1` and `RBFAST_OTLP_STAGES=1` print the inference's and the reader's own stage timings;
  `RHOBOUND_ESTIMATOR` is read as rhobound reads it (any bytes; an unknown value is refused with Go's text). Two
  audit switches for the span sort: `RBFAST_SORT=go-exact` runs the step-for-step serial port of Go's
  `slices.SortFunc` (the same order as the default, so the same bytes); `RBFAST_SORT=stable` runs a parallel stable
  sort, which is *not* Go's order of spans with an equal trace and start and can change a result (the pairing of
  parallel calls to one callee: on the `ties/shuffled` input the branch correlation differs by 2%).

## Build

```
cd rust
cargo build --release            # target/release/rbfast (or $CARGO_TARGET_DIR/release/rbfast)
cargo test --release --workspace # see Tests: without the Go-made data, the parity tests skip
cargo clippy --workspace --all-targets -- -D warnings
```

Rust 1.83 or later (every crate declares it; built and tested with 1.99.1 on linux/arm64). No C code is
compiled; the dependencies are listed with their licences in [THIRD-PARTY.md](THIRD-PARTY.md): rayon (with
crossbeam and either), memchr, flate2 and its inflate backend, nothing else in the binary. The default build
inflates `.gz` captures with zlib-rs (licence Zlib, the faster backend; flate2's `runtime_detection` feature gives
it the hardware CRC-32); for an MIT/Apache-2.0-only build:

```
cargo build --release -p rbfast --no-default-features --features miniz
```

The release profile keeps line tables (`debug = 1`), so the binary embeds the paths it was built from (the
workspace and `~/.cargo/registry`): the SHA-256 of the benchmarked binary quoted below (546fdb7f22f5bcf2...) was
reproducible only from the same workspace and target paths, by `cargo build --release --locked -p rbfast` (checked:
rebuilding there gave the same hash); the edits for publication (comments, the version text) change it too. `cargo test --workspace` builds the CLI with the workspace's unified features
(the tests' second inflate backend), a different binary. For a binary that does not depend on the paths, build with
`RUSTFLAGS="--remap-path-prefix=$PWD=. --remap-path-prefix=$HOME/.cargo/registry=/cargo"` (not done here).

Other targets were not built here (only the `aarch64-unknown-linux-gnu` standard library was installed). For
x86_64 it should be:

```
rustup target add x86_64-unknown-linux-musl
RUSTFLAGS="-C target-cpu=x86-64-v3 -C linker=rust-lld" cargo build --release -p rbfast --target x86_64-unknown-linux-musl
```

(untested). `x86-64-v3` gives the CPU's fused multiply-add: the model and the inference call `mul_add` where Go's
arm64 build fuses `x*y + z`, and without hardware FMA that is a correct but slow software call.

## Architectures

The Go binary's results depend on the architecture: Go's arm64 build fuses `x*y + z` into fused multiply-adds and
its amd64 build does not, so the two differ in the last bits; and Go converts out-of-range float timestamps
differently on amd64. rbfast computes **what Go computes on linux/arm64**: the ports carry Go's own math functions
and Go's arm64 fusions (as `mul_add`, which Rust defines as fused on every target), and Rust's float-to-integer
conversion saturates as arm64's does. So an x86_64 rbfast is expected to give the arm64 bits too, but that is
unverified: **byte-identity was verified on linux/arm64 only**. Compare an x86_64 rbfast with an arm64 rhobound
output, or with a tolerance; Go's own amd64 output will differ in the last bits.

The tests follow the same rule: every comparison with Go's linux/arm64 values is bit for bit on aarch64. On other
architectures a float within 1e-9 relative of Go's passes, and the tests print how many floats were not
bit-identical (none is expected); texts (error messages, JSON bytes of parsed input) stay exact, and the end-to-end
oracle test of the CLI (byte comparison of whole outputs) is skipped there with a message. `RBFAST_PARITY=tolerant`
selects the tolerant comparison on aarch64 too, to exercise it.

## Tests

`cargo test --release --workspace` runs everything that needs no data from outside the repository: Go's
`otlp_test.go` ported test for test, 406 small captures with Go 1.27.2's outcome frozen (each read at five
chunkings), the nesting limit, 2,000 random inputs per math kernel against Go's bits, Go's edge cases and edited
topologies, the Go tests' own reference sets (golden.json, reference.json) at their tolerances, the reference
implementation's FIFO and stage golden files (from `internal/infer/testdata`), Go's quoting on every code point,
the CLI's flag rules, tabwriter and parsers. The tests that compare with Go-made data not in the repository skip,
printing why, unless the data is given:

| variable | what | tests |
|---|---|---|
| `RBFAST_ORACLE` | the oracle: the Go binary's outputs on 24 captures (below) | `crates/cli/tests/oracle.rs` (every command line of the oracle), `crates/infer/tests/oracle.rs` (the whole inference and every pod's queue rebuild, at 1, 2, 3 and 8 threads), `crates/infer/tests/mathx.rs`, `crates/math/tests/parity_oracle.rs` (321,040 model floats, the numerics grids, MarshalTopology's bytes) |
| `RBFAST_REPLAY` | the recorded runs of the Go unit tests that build spans | `crates/infer/tests/replay.rs` (110 runs from 40 tests, byte for byte) |
| `RBFAST_FIXTURES` | Go's inputs and answers for the unit tests that draw from `math/rand` | `crates/infer/tests/units.rs` (worker search, uneven split, rise estimator, `fmt` verbs) |
| `RBFAST_GO_TESTDATA` | Go's `internal/infer/testdata` (default: this repository's) | `crates/infer/tests/units.rs` (FIFO and stage golden files) |
| `RBFAST_GO_KERNELS` | a larger kernel file in the form of `crates/math/testdata/go_kernels.txt` | `crates/math/tests/parity_kernels.rs` |

The results of the full runs, with every variable set, are recorded in [results/](results/) (see Parity). The
oracle, the recordings and the fixtures were made with Go 1.27.2 on linux/arm64 from the Go tree of this repository,
by Go programs written for the comparison that are not published. To make your own:

* **The oracle** (a folder with a `README.md`, which the tests look for):
  * `captures/NAME/traces/...`: the inputs: `testdata/capture-chain`; simulated captures from the accuracy harness
    (`ACC_SEED=31337 ACC_STRUCT=1 ACC_TRUTH_REPS=2 ACC_ROWS=0,30,36,37,38,39,40,41,42,43 ACC_DUMP=DIR go test
    -tags accuracy -run 'TestEndToEndAccuracy$' ./internal/infer`, both span modes); and hand-built captures made
    with the unit tests' span builders (async calls, an external peer, remote-parent entries with broken traces,
    PRODUCER/CONSUMER spans, kubelet probes, a refused capture with 8% broken traces, no CLIENT spans with a
    skewed clock, a fan-out over two pods). The recorded oracle also had the five test-bed captures of a
    10-service Python demo shop on a single-node test bed (not published; their sources are named in their
    `commands.txt`).
  * `NAME/` for each capture: the unmodified `rhobound` binary's outputs (`infer.json`, `infer.stderr`,
    `predict.json` and `predict.txt`, with `--plain`, `--patch P` and both (P: the busiest service `+5%` and the
    internal service with the largest own time `+1ms`), `--workers svc=N`, `--max-rho 0.3`, and `GOMAXPROCS=1`),
    each command line in `commands.txt` as `[GOMAXPROCS=1] PATH/rhobound ARGS > OUTFILE 2> ERRFILE # exit N`, with
    the comment lines `# capture: PATH` and `# workers override: svc=N`; a dump of what `otlp.ReadDir` returns
    (`spans.tsv.gz`: every span sorted by trace, id, start and capture index, with its resolved names;
    `resources.tsv`, `peers.tsv`, `addrs.tsv`; `counters.json` with the span count), `infer.Run`'s whole result as
    `inferred_full.json` (or `inferred_error.txt`), and every pod's queue rebuild (`fifo_pods.jsonl.gz`, through a
    hook in `internal/infer`). The exact formats are what `crates/otlp/src/dump.rs`, `crates/infer/src/dump.rs`
    and the tests read.
  * `model/`: `AnalyticWith` and `ChangePatchWith` (basic and refined, scaled and shifted changes) on manifests of
    the golden cases, the examples and every inferred topology, in 17-digit JSON (`model_*.json`); GammaP,
    NormCDF, NormQuantile, ErlangC, Residence, EmaxExp and the gamma maxima on reference.json's inputs and on grids
    (`mathx_go.json`); Go's `math.Exp`, `Log`, `Lgamma`, `Erfc`, `Erfinv`, `Sqrt` on a grid (`gomath.json`).
  * `bench/` and `bench-out/` (only for the `big` group of `scripts/parity.sh`): large captures and Go's
    `predict --json` on them. The recorded oracle had `big8-run3`, eight copies of test-bed run 3's capture with
    every trace and span id XORed with a key per copy and every time shifted by 610 s per copy (4.63 GB,
    5,575,592 spans), the same gzipped (`big8-run3-gz`), and run 3 gzipped (`run3-gz`).
  * Optionally `tools/src/*-files.sha256`: the sha256 of the Go files the oracle was made from (`sha256sum` lines
    for `cmd/`, `internal/`, `go.mod`, `testdata/`), which `scripts/parity.sh` checks the Go tree against.
* **The replay recording** (`RBFAST_REPLAY`): a hook at the end of `infer.Run` in a copy of the Go tree that
  writes, for every call the `internal/infer` unit tests make, a folder with `options.json` (the test's name and
  the options), the input in the oracle's dump format, and `inferred_full.json` or `inferred_error.txt`.
* **The fixtures** (`RBFAST_FIXTURES`): `fifo_cases.json.gz`, `split_cases.json.gz`, `byk_cases.json.gz` and
  `gofmt_cases.jsonl.gz`, written by a test added to a copy of the Go tree: the inputs the randomized unit tests
  draw and Go's answers on them.

## Parity

`scripts/parity.sh` builds the Go CLI from this repository (or takes `RBFAST_GO`; when the oracle has the list of
its Go files, it first checks, without git, that `cmd/`, `internal/`, `go.mod` and `testdata/` are the same
bytes), records the Go CLI tests' command lines and the simulated tie captures (`scripts/go/`), writes the edge
inputs (`scripts/edge_inputs.py`), builds rbfast, and compares the two on every input there is. Each command line
runs through both binaries with the same arguments; a comparison is *identical* when stdout, stderr (after the
`rbfast:`/`rhobound:` prefix) and the exit status are the same bytes, *equal* when the JSON is structurally the
same with every number within 1e-9 relative, and a *DIFF* otherwise. `--quick` skips the large captures.

```
RBFAST_ORACLE=/path/to/oracle scripts/parity.sh [--quick] [--only oracle,cli,fail,model,sweep,edge,big]
```

Result of the last full run before publication (2026-10-20, 16:23-16:26 UTC, linux/arm64, on the benchmarked
binary, sha256 546fdb7f22f5bcf2...; log and every verdict in `results/parity/`). The same run on this tree as
published (whose edits for publication changed only comments, tests, scripts and the version text) gave the same
2,677 identical comparisons and 0 DIFF:

| group | what was compared | comparisons | identical | DIFF |
|---|---|---|---|---|
| oracle | all 24 oracle captures (capture-chain, the five test-bed captures of 347k-697k spans, 10 accuracy-harness rows in both span modes, 8 hand-built captures): every `rhobound` line of their `commands.txt` (infer, infer --workers, predict --json and text, --plain, --patch, --plain --patch, --workers, --max-rho 0.3 refusals, the >5%-broken-traces refusal, GOMAXPROCS=1 as `--threads 1`), each rbfast vs the oracle file, the fresh Go build vs the oracle file, and rbfast vs the fresh Go build; plus predict --json at 3 threads and with Go's serial sort | 855 | 855 | 0 |
| cli | the 57 command lines the Go tests in `cmd/rhobound` run (recorded from the tests, inputs copied out), replayed: the Go binary vs the Go test's own output, and rbfast vs the Go binary, including the `--out` files | 116 | 116 | 0 |
| fail | 102 failing and edge inputs: usage errors, unknown and malformed flags, NaN/Inf/out-of-range values, bad `--patch`/`--workers`/`--kept-share`, missing, empty, broken and non-OTLP captures, a corrupt `.gz`, missing, malformed and invalid topology files (syntax errors, type errors, unknown children and entries, cycles, held workers), utilization refusals, stdout on `/dev/full` | 102 | 102 | 0 |
| model | `model` on all 23 inferred topologies at the observed load, half of it, 1.3x and 3x (a refusal), with and without `--plain` and the capture's `--patch`, JSON and text | 736 | 736 | 0 |
| sweep | every line of a 6-topology grid (60 lines each: 5 loads x 2 models x the base and 5 changes) against `rhobound model --rps R [--patch P] [--plain] --json` (numbers bit-equal; refusals word for word); `sweep --capture` against predict; sweep at 1 thread vs all | 512 | 512 | 0 |
| edge | the cases found when the first version was checked: 14 captures with spans tied on (trace, start) (10 written by the tie-case generators of `edge_inputs.py`, 4 recorded by Go's own simulator with parallel calls [b, b, b]) through predict --json, predict and infer, each rbfast at all threads, 1, 3 and with Go's serial sort (168); 19 `.json`/`.json.gz` streams (pretty, adjacent values, cut inside a value, late syntax errors, truncation, a bad rune at the end, a top-level number, a corrupt gzip) (76); service names with `\v`, `\f`, a tab, invalid UTF-8, a lone surrogate, CJK, NBSP (26); topologies named with `\v`/`\f` (`model` text and JSON); paths that are not UTF-8 (capture, trace file, topology, `--out`), `%q` of NBSP, U+0085, U+00AD, U+0378, U+0600, U+10FFFF and invalid bytes in `--patch`/`--workers`, 9 `RHOBOUND_ESTIMATOR` values, unknown commands (28); `--out` over a file, below a file, under a read-only folder, through a symlink loop, with a trailing slash (17); sweep's order of checks and its `--capture` wording against rhobound model and predict (18); an invalid UTF-8 port, 100,000 8-byte peer names (8) | 349 | 349 | 0 |
| big | predict --json on big8-run3 (4.63 GB, 5.58M spans; also against the oracle), run3-gz, big8-run3-gz, and the same bytes as `.json` streams: test-bed run 3 as one `.json` and one `.json.gz`, big8-run3's 8 gzipped files as `.json.gz` | 7 | 7 | 0 |

The largest relative difference of any number compared was 0: no comparison needed the tolerance. Besides, every
case file of the checks of the first version was replayed through both binaries on the benchmarked binary (their
differential batteries, not published, 16:18-16:23 UTC: 6,478 command lines on fuzzed captures and topologies,
`.json` captures, OS paths, the rise estimator, thread counts; summary in `results/batteries-2026-10-20/`): all
identical except one shared defect (below).

Notes:

* **Byte-identical, not just within tolerance** (on linux/arm64). Every predict and infer output, text and JSON, on
  every capture is the same bytes as Go's at every thread count tried (1, 2, 3, 8), and with Go's serial sort: every
  float is bit-equal. The 1e-9 tolerance is never used. This holds because each crate reproduces Go's summation
  order (the inference sums in Go's chunks, merged in Go's order; the reader merges in capture order), Go's arm64
  fused multiply-adds and Go's own `math` functions, and, since the fixes to the first version, Go's order of spans
  that tie on (trace, start).
* **The span sort is Go's pdqsort.** Go sorts the span table with `slices.SortFunc` (pattern-defeating
  quicksort, not stable): spans with an equal trace and start time end in an order that depends on the whole
  array, and that order reaches the result when a service calls one callee several times in parallel at the same
  nanosecond (which branch is paired with which). rbfast runs Go's algorithm itself, ported step for step, on
  compact keys (trace, start, index: pdqsort's moves depend only on its comparisons, so the keys move exactly as
  Go's spans do), with the two ranges each partition leaves sorted at the same time (they are independent: each
  reads only itself and the element bounding it, and pattern breaking is seeded by the range's length); a test
  checks it against the serial port on 8 shapes at 1, 3 and 8 threads. The parallel stable sort used before gave
  a different pairing on the tie captures (branch correlation 2% off, latencies off in the 5th digit).
* The oracle files are the outputs of the Go binary built from the Go tree of this repository; the fresh Go build
  reproduced every one of them byte for byte as well.

Known differences that remain (none is reached by any input above except the first):

* `--workers svc=9223372036854775807` crashes both binaries (Go: `makeslice: cap out of range`, exit 2; rbfast:
  `capacity overflow`, exit 101). A shared defect of the specification, left as it is.
* OS error texts come from the C library (they match Go's table for the common errors); one request line or
  `.json` value may be at most 1 GiB (Go has no limit); when stdout is a closed pipe rbfast exits 1 with an error
  where Go dies of SIGPIPE.
* Go's own non-determinism cannot be matched byte for byte: a topology whose entry map holds two unknown services
  makes Go name either one (map order); rbfast always names the first. Float timestamps out of the uint64 range
  follow arm64's conversion (saturating), as the oracle; Go on amd64 converts them differently.
* Inside the math kernels, a NaN result can carry other payload bits than Go's (`math.NaN()` is
  0x7ff8000000000001); no output can show it (JSON refuses NaN, the text report prints `-`).
* `Data::files` (the reader's list of file names) holds names that are not UTF-8 with U+FFFD per invalid byte, and
  addresses (`peer:port`) whose port text is not UTF-8 the same way; nothing prints them, and they are interned on
  their bytes, so their count (all the inference uses) is Go's.
* Not covered by any capture here (the oracle shares these gaps): `container.image.tag`, `http.url` routes and the
  `rise` estimator on a real capture. The reader's and the inference's own tests cover them on small inputs (406
  frozen Go outcomes, each also read at 4 tiny chunk sizes; 110 replayed Go unit-test runs), and a differential
  battery covered `rise` on 312 command lines.

## Speed

`scripts/bench.sh` times `rhobound predict CAPTURE --json` against `rbfast predict CAPTURE --json`, the whole
process (read, inference, model, report), at 1, 2, 4 and 8 threads (Go: GOMAXPROCS; rbfast: `--threads`). Each
cell is the median of 3 timed runs after one warm-up, with a warm page cache, in a memory-capped scope (4 GB cap,
nice 10), on an 8-core linux/arm64 machine (15 GB, Go 1.27.2, rustc 1.99.1). The script waits for a
quiet machine first (1-minute load below 1.5, under 0.4 busy cores) and logs how many cores other processes used
during each cell; every run's output was also hashed, and Go's and rbfast's were the same bytes in every cell.

The captures: test-bed run 3's before capture (one of the five test-bed captures of a 10-service Python demo shop
on a single-node test bed: one 579 MB `.jsonl`, 696,949 spans), and big8-run3, eight time-shifted copies of it with
remapped ids (4.63 GB in 8 files, 5,575,592 spans, synthetic). Neither is published.

Run of 2026-10-20, 15:31-16:08 UTC (`scripts/bench.sh OUTDIR RUN3 BIG RUN3GZ BIGGZ RUN3JSON RUN3JSONGZ BIGJSONGZ`;
summary and logs in `results/bench-2026-10-20/`). At the start: 1-minute load 0.41 after a 2-minute wait,
0.15 busy cores; during the cells, other processes kept 0.07-0.22 cores busy (none above the 0.3 flag).
Benchmarked binary: sha256 546fdb7f22f5bcf2... (built from this code before the edits for publication, which
changed only comments, tests, scripts and the version text; see Build for why the hash depends on the build path);
Go binary 6e9743f281024bec... (built from the Go tree of this repository by parity.sh).

| capture | threads | rhobound (s) | rbfast (s) | speedup | CPU user+sys, Go / rbfast (s) | peak RSS, Go / rbfast (MiB) |
|---|---|---|---|---|---|---|
| test-bed run 3, one 579 MB `.jsonl`, 696,949 spans | 1 | 5.138 | 0.862 | **6.0x** | 5.13 / 0.86 | 227 / 99 |
| | 2 | 2.764 | 0.461 | **6.0x** | 5.26 / 0.88 | 211 / 113 |
| | 4 | 1.535 | 0.255 | **6.0x** | 5.28 / 0.90 | 212 / 111 |
| | 8 | 0.999 | 0.147 | **6.8x** | 5.49 / 0.93 | 253 / 112 |
| big8-run3, 4.63 GB in 8 `.jsonl` files, 5,575,592 spans | 1 | 40.279 | 6.720 | **6.0x** | 40.3 / 6.7 | 1700 / 736 |
| | 2 | 21.626 | 3.549 | **6.1x** | 41.1 / 7.0 | 1574 / 895 |
| | 4 | 12.079 | 1.839 | **6.6x** | 41.3 / 7.0 | 1534 / 896 |
| | 8 | 7.674 | 1.035 | **7.4x** | 42.5 / 7.1 | 1640 / 920 |
| test-bed run 3 gzipped, one 36 MB `.jsonl.gz` | 1 | 5.724 | 1.065 | **5.4x** | 5.73 / 1.06 | 222 / 155 |
| | 2 | 3.056 | 0.549 | **5.6x** | 5.85 / 1.08 | 212 / 150 |
| | 4 | 1.693 | 0.401 | **4.2x** | 5.89 / 1.11 | 213 / 129 |
| | 8 | 1.182 | 0.376 | **3.1x** | 6.11 / 1.16 | 250 / 134 |
| big8-run3 gzipped, 8 `.jsonl.gz` files | 1 | 45.286 | 8.461 | **5.4x** | 45.4 / 8.4 | 1591 / 930 |
| | 2 | 24.070 | 4.365 | **5.5x** | 46.0 / 8.6 | 1566 / 966 |
| | 4 | 13.351 | 2.273 | **5.9x** | 46.4 / 8.8 | 1603 / 949 |
| | 8 | 9.089 | 1.250 | **7.3x** | 47.1 / 9.1 | 1541 / 1074 |

The same bytes read as `.json` streams (a file of one value per line is a stream of values; links named `*.json`
and `*.json.gz`), same run:

| capture | threads | rhobound (s) | rbfast (s) | speedup | CPU user+sys, Go / rbfast (s) | peak RSS, Go / rbfast (MiB) |
|---|---|---|---|---|---|---|
| test-bed run 3 as one `.json` | 1 | 7.084 | 1.299 | **5.5x** | 7.09 / 1.30 | 226 / 106 |
| | 2 | 3.719 | 0.673 | **5.5x** | 7.15 / 1.32 | 219 / 148 |
| | 4 | 2.535 | 0.357 | **7.1x** | 7.19 / 1.35 | 213 / 159 |
| | 8 | 2.498 | 0.219 | **11.4x** | 7.29 / 1.38 | 244 / 117 |
| test-bed run 3 as one `.json.gz` | 1 | 7.690 | 1.500 | **5.1x** | 7.69 / 1.50 | 222 / 120 |
| | 2 | 4.041 | 0.772 | **5.2x** | 7.73 / 1.52 | 218 / 160 |
| | 4 | 3.134 | 0.429 | **7.3x** | 7.75 / 1.54 | 212 / 121 |
| | 8 | 3.095 | 0.416 | **7.4x** | 7.88 / 1.57 | 232 / 124 |
| big8-run3's 8 gzipped files as `.json.gz` | 1 | 61.010 | 12.043 | **5.1x** | 61.1 / 12.0 | 1754 / 976 |
| | 2 | 32.199 | 6.229 | **5.2x** | 61.5 / 12.4 | 1592 / 1152 |
| | 4 | 25.026 | 3.163 | **7.9x** | 61.6 / 12.3 | 1623 / 985 |
| | 8 | 24.598 | 1.721 | **14.3x** | 61.8 / 12.7 | 1632 / 1012 |

(Go reads one `.json` stream on one goroutine with json.Decoder, so its own time stops falling past 2-4 threads;
that, not rbfast, makes the 8-thread ratios of these rows large.)

Inside rbfast (`RBFAST_TIMES=1`, median of 3; 8 threads from the run above, 1 thread from a separate quiet run at
16:16-16:18 UTC, 1-minute load 0.98 at its start):

| capture | threads | read | inference | model | report |
|---|---|---|---|---|---|
| test-bed run 3 | 1 | 0.682 s | 0.171 s | 0.0030 s | 0.0001 s |
| test-bed run 3 | 8 | 0.104 s | 0.037 s | 0.0007 s | 0.0002 s |
| big8-run3 | 1 | 5.268 s | 1.405 s | 0.0030 s | 0.0001 s |
| big8-run3 | 8 | 0.728 s | 0.275 s | 0.0082 s | 0.0001 s |
| test-bed run 3 gzipped | 8 | 0.329 s | 0.037 s | 0.0007 s | 0.0002 s |
| big8-run3 gzipped | 8 | 0.956 s | 0.288 s | 0.0028 s | 0.0001 s |
| test-bed run 3 as `.json` | 8 | 0.173 s | 0.035 s | 0.0007 s | 0.0001 s |
| test-bed run 3 as `.json.gz` | 8 | 0.364 s | 0.035 s | 0.0007 s | 0.0001 s |
| big8-run3 as `.json.gz` | 8 | 1.393 s | 0.313 s | 0.0048 s | 0.0002 s |

The rest of each wall time is process start, the thread pools and writing the report. Most of the gain is per
core, not from parallelism: at 1 thread rbfast is already 5.1-6.0x faster on every format (its decoder allocates
nothing per span and borrows strings from the input; in a profile of Go at GOMAXPROCS=1 on
test-bed run 3, `decodeRequest` took 81% of the CPU, encoding/json about 60%, and the read stage 4.42 of 5.06 s),
and it uses 4.9-6.0x less CPU at every thread count. It scales a little better than Go from 1 to 8 threads on plain
captures (5.9x and 6.5x against Go's 5.1x and 5.2x). **Peak memory is 0.43-0.75 of Go's** on every capture,
format and thread count above (0.43-0.58 on plain `.jsonl`, 0.54-0.71 gzipped, 0.47-0.75 as `.json` streams).

What changed since the first version's run (the same script on the same machine, 11:26-11:45 UTC; its logs are in
`results/bench-run1/`): test-bed run 3 0.893 → 0.862 s at 1 thread and 0.151 → 0.147 s at 8; big8-run3 7.040 → 6.720
and 1.067 → 1.035 s; gzipped run 3 1.246 → 1.065 and 0.454 → 0.376 s; gzipped big8-run3 9.782 → 8.461 and 1.402 →
1.250 s; as `.json` streams a separate measurement of the first version gave 0.601 s (`.json`) and 0.962 s
(`.json.gz`) for run 3 at 8 threads, and big8-run3 as `.json.gz` was killed at the 4 GB cap (4,782 MiB peak at 8
threads); now 0.219 s, 0.416 s and 1,012 MiB. The gains: the hardware CRC-32 of the inflate backend, hex ids 8
digits at a time, an ASCII check before case-folding unknown keys, `.json` streams in parallel batches. Two fixes
cost time, measured on the same quiet run as the 1-thread stages (16:16-16:18 UTC; `results/extra-2026-10-20/`):

* **Go's order of tied spans.** The span sort is Go's pdqsort, in parallel on keys: 14.0 ms at 8 threads and 58.5
  ms at 1 thread on test-bed run 3, against 5.5 and 25.7 ms for the parallel stable sort it replaces
  (`RBFAST_SORT=stable`); on big8-run3 105 against 42 ms at 8 threads, and 527 against 240 ms at 1 thread. That is
  +6% of the 8-thread wall time on big8-run3, +4% at 1 thread. (Each partition's two ranges are sorted in
  parallel; the partitions themselves are serial, Go's Hoare scan. A parallel version of that scan with the same
  result was tried: on these inputs it was slower, 0.160 against 0.105 s on big8-run3 at 8 threads, from its extra
  passes and buffers, and was dropped.)
* **pread instead of mmap.** Reading plain files with pread (so that a shrinking file cannot SIGBUS) costs a copy:
  the read stage of test-bed run 3, median of 9 reads, 0.671-0.674 s against 0.627 s with the mapped reader (+7%)
  at 1 thread, 0.097-0.098 s against 0.094 s (+3-4%) at 8 threads (the mapped variant was built from the same
  decoder).

Where it is not faster, or not by much:

* **One gzipped file at 4-8 threads: 3.1-4.2x, not 6-7x.** A single `.jsonl.gz` is one deflate stream, inflated
  by one task, so the read of run 3 gzipped stays at about 0.33 s however many threads there are; decoding runs
  in parallel behind it. A capture of several `.gz` files (the Collector rotates its files) scales: 7.3x on
  big8-run3 gzipped at 8 threads. Go is limited the same way (its gunzip is single-stream too) but at its slower
  decoding speed. The MIT/Apache-only `miniz` build inflates more slowly (a separate measurement: 0.601 s against
  0.357 s for run 3 gzipped at 8 threads, both with the hardware CRC).
* **A cold page cache.** Not measured here. It was measured once on the first version (page cache evicted with
  fadvise, 579 MB read from a network disk per run): run 3 1.09x at 8 threads (Go 3.756 s, rbfast 3.461 s) and 1.38x
  at 1 thread; gzipped captures were unaffected (2.57x and 4.64x). On a network disk the first read of a plain
  capture is disk-bound for both binaries.
* **Small inputs and single model calls: a few milliseconds either way.** Median of 10 processes (the sweep run
  below): `model` on the run 3 topology 6 ms (Go) against 2 ms (rbfast), with `--patch` 15 ms against 2 ms;
  `predict` on capture-chain (15,495 spans, gzipped) 19 ms against 9 ms. Process start and file reading are much
  of it; nobody will notice the difference.
* **The model is not where the time goes.** rbfast's model stage (the base, plus the change with `--patch`) takes
  3.0 ms at 1 thread on run 3 and on big8-run3; at 8 threads 0.7 ms on run 3 and 2-8 ms on big8-run3, varying from
  run to run (a separate run saw the same rise with threads inside predict; standalone `rbfast model` on that
  topology scales normally; the cause is not isolated). Go's model was measured at 4.3 ms for the base and 8.6 ms
  more for a change on run 3 when the oracle was made. rbfast-math by itself is bit-for-bit Go and about Go's
  speed per kernel call (measured during development: Log 12% slower than Go's, Lgamma, Erfc, Erfinv, GammaP,
  NormCDF and NormQuantile within 1-4%); its gains come from skipping provably redundant work, two-lane SIMD in the
  copula's quadrature, and running what-ifs in parallel.
* **Peak memory is lower, not small:** 0.7-1.2 GB on the 4.63 GB captures (Go 1.5-1.8 GB), because the span table of
  5.6M spans is held in memory, as in Go. With tens of thousands of distinct service or peer names the inference's
  per-chunk accumulators take about 7 KB per name (Go about 1.2 KB; measured: 764 MB against 134 MB for 100,000
  peers); not changed.

**Many what-ifs (`sweep`)** (`scripts/bench_sweep.sh`, 2026-10-20 16:13-16:16 UTC, after a 2-minute wait: load
0.18 at the start; logs in `results/sweep-2026-10-20/`): 2,244 points on the run 3 topology (51 loads x 2
models x the base and 21 changes). The Go binary has no sweep; its way is one `rhobound model ... --json` process
per point, and the like-for-like comparison of per-call speed is the same evaluations inside one Go process (a Go
driver written for the comparison, not published, that calls `model.AnalyticWith` and `ChangePatchWith` in a loop):

| how | wall time | per point |
|---|---|---|
| rhobound, one process per point, one at a time | 17.45 s | 7.8 ms |
| rhobound, one process per point, 8 at a time | 2.60 s | 1.16 ms |
| Go in one process (the Go driver, GOMAXPROCS=1, median of 3 repetitions in the process) | 9.363 s | 4.17 ms |
| `rbfast sweep --threads 1` (median of 3) | 1.583 s | 0.71 ms |
| `rbfast sweep --threads 8` (median of 3) | 0.299 s | 0.13 ms |

So per call, in one process and on one thread, rbfast is 5.9x faster than Go here (56 of the points are changes
refused at their load; both evaluate them). Part of that is per-call speed (1.5x per AnalyticWith call, measured
during development) and most is reuse: the base of each (load, model) is solved once for its 22 lines, and
matched-maximum results are reused across lines by their input bits. The 11x against one process per point adds
Go's process starts. Every one of the 2,244 Go results equalled rbfast's line (utilization, model_ms, after_ms,
change_ms, change_pct; refusals word for word).

## Fixes after the first version

The first version was checked for parity, performance and safety; every finding, and what became of it
(each fix is checked by the edge group of `parity.sh` and by unit tests, as noted):

| finding | severity | done |
|---|---|---|
| Tied spans sorted differently from Go's pdqsort (branch pairing, 2% on branch_corr) | major | fixed: the default sort is Go's pdqsort, in parallel on keys (see Parity); `RBFAST_SORT=stable` keeps the old sort as an audit switch |
| tabwriter treated `\v`, `\f` as text | minor | fixed: Go's text/tabwriter ported whole, on bytes (`\v` ends a cell, `\f` a line and flushes, the Escape byte, rune widths of invalid UTF-8); 16 cases checked against Go's own output (`scripts/go/tabwriter_cases`) |
| Paths and arguments that are not UTF-8 | minor (x2) | fixed: argv is taken as bytes; paths open as given; errors print paths raw (`%v`) and quote them with `\x` escapes (`%q`); the report's `capture` is raw in text and U+FFFD per invalid byte in JSON, as Go's encoder does |
| A non-UTF-8 `RHOBOUND_ESTIMATOR` read as fifo | minor | fixed: read as bytes, refused with Go's text |
| `%q` approximated (945,928 code points differed) | minor | fixed: rbfast-gostr ports strconv's IsPrint with Go 1.27.2's tables (generated by `scripts/gen_isprint.py`); every code point and every invalid lead byte gives Go's `Quote` and `QuoteRune` (hash-checked in `crates/gostr/tests`); used by all crates |
| `--out` error texts differ from os.MkdirAll | minor (x2) | fixed: MkdirAll ported (ENOTDIR on an existing non-folder, the parent first, the failing component named, mode 0755) |
| sweep reported a parse error before the base refusal | minor | fixed: rhobound's order (base error, base refusal, then the change) |
| sweep --capture refusal said "at N requests/s" | minor | fixed at the observed load ("at the observed load"); at other loads the wording stays and is documented |
| `max_moments_gamma_corr_par(.., NaN)` returned the independent moments | info | fixed (`!(r <= 1e-3)`, Go's test); 21 NaN cases checked against Go (`crates/math/tests/nan_corr.rs`) |
| `--workers svc=i64::MAX` crashes both binaries | info | left: a shared defect of the specification |
| NaN payload bits in kernels | info | documented (no output can show it) |
| `.json.gz` inflated whole; `.json` mapped whole (OOM-killed at 4 GB on big8-run3 as `.json.gz`) | major | fixed: `.json` streams are read in batches (parallel cut-and-check, serial fallback); memory stays near the batches in flight (see Speed) |
| Software CRC-32 (flate2's runtime detection off) | major | fixed: `runtime_detection` on (both backends) |
| Serial validating pre-scan of `.json` streams | minor | fixed: the batches are scanned in parallel; the serial scan runs only when a batch is not clean |
| Sweep table compared in-process rbfast with one Go process per point | minor | fixed: an in-process Go row (the Go driver's sweep) added to `bench_sweep.sh` and the table |
| README wording (memory "about half", model stage, Go's decode share, cold cache) | minor | fixed in Speed |
| SWAR hex ids, ASCII length check before case folding | info | applied (with the CRC change: -8% to -20% in a separate measurement; see Speed for this binary) |
| Panic on an invalid-UTF-8 port (`intValue`) | major | fixed: such addresses become strings per byte (their count is Go's); a parity edge case |
| FxHasher without a finaliser: quadratic interning of 8-byte names (13.7 s for 200k) | major | fixed: the high bits folded into the low ones; 100,000 8-byte peer names are a parity edge case |
| SIGBUS when a capture shrinks while read | minor | fixed: plain files are read with pread into per-thread buffers, not mapped (memmap2 and libc dropped); costs about 5% of the read stage at one thread (measured in Speed) |
| Unbounded sweep grids (wrap in release, OOM) | minor | fixed: counted with `checked_mul` before anything is built; at most 100,000 changes and 1,000,000 loads |
| Timestamp arithmetic relied on release-mode wrapping | minor | fixed: `wrapping_add`/`wrapping_sub` at the three sites (Go's uint64 semantics in every profile) |
| ErlangC looped once per server (hangs at 1e15 servers, shared with Go) | minor | fixed: stops once the term is 0 (no bit changes; servers 1e15 and i64::MAX finish in milliseconds) |
| Thread pool failure panicked in model and sweep | minor | fixed: every command fails with `thread pool: resource temporarily unavailable` (exit 1); `--threads` is not capped |
| ~7 KB per distinct name of per-chunk accumulators | info | not done: needs a sparse accumulator layout in the inference; it matters only with tens of thousands of distinct service or peer names (1.5 GB at 200k) |
| Builds not reproducible across paths; rust-version undeclared | info | rust-version 1.83 declared in every crate; the path dependence is documented (Build) |
| serde_json in the binary for an unused fallback | info | fixed: optional (rbfast-math's `oracle` feature); four crates fewer in the binary |
| Go's non-determinism (map order, amd64 float conversion) | info | documented (Parity) |
| SAFETY comments on NEON, a u32 truncation in fifo.rs | info | added; the visit index is checked to fit in u32 |
| Clippy pedantic | info | default lints clean with `-D warnings`; pedantic not adopted |

## Scripts

| script | what |
|---|---|
| `scripts/parity.sh [--quick] [--only GROUPS]` | builds both binaries and runs every comparison (needs `RBFAST_ORACLE`; driver: `parity.py`; recorders for the Go side: `scripts/go/record/zz_record_test.go`, the CLI tests' command lines, and `scripts/go/ties/zz_tie_captures_test.go`, the simulated tie captures; edge inputs: `edge_inputs.py`) |
| `scripts/bench.sh OUTDIR [RUN3 BIG RUN3GZ BIGGZ RUN3JSON RUN3JSONGZ BIGJSONGZ]` | the end-to-end benchmark above (summary: `bench_summary.py`; timer: `timer.py`) |
| `scripts/bench_sweep.sh OUTDIR [TOPOLOGY] [CAPTURE]` | sweep throughput against one `rhobound model` process per point and, with `RBFAST_GO_SWEEP`, against Go in one process, and single-call costs |
| `scripts/timer.py` | runs a command N times and prints wall, user, sys and peak RSS per run and the median (the recorded runs used a Go program with the same output) |
| `scripts/third_party.py` | regenerates THIRD-PARTY.md from `cargo tree` and `cargo metadata` |
| `scripts/gen_isprint.py` | regenerates `crates/gostr/src/isprint.rs` from Go's `strconv/isprint.go` |
| `scripts/go/quote_dump/` | Go's strconv.Quote/QuoteRune/IsPrint/IsSpace on every code point (the hash in `crates/gostr/tests/all_code_points.rs`) |
| `scripts/go/tabwriter_cases/` | Go's text/tabwriter output for the cases in `crates/cli/src/tabwriter_cases.rs` |

The scripts take their inputs from the environment: `RBFAST_ORACLE` (the oracle), `RBFAST_GO` (a rhobound binary;
parity.sh builds one from this repository when it is unset), `RBFAST_BIN` (rbfast, default
`$CARGO_TARGET_DIR/release/rbfast` or `target/release/rbfast`), `RBFAST_SCRATCH` (parity.sh's work folder),
`RBFAST_WRAP` (a command prefix for the measured runs, such as a memory-capped systemd scope), `RBFAST_TIMER`, and
for the benchmarks `RBFAST_BENCH_RUN3`, `RBFAST_BENCH_BIG`, `RBFAST_BENCH_RUN3GZ`, `RBFAST_BENCH_BIGGZ` (the
captures) and `RBFAST_GO_SWEEP`, `RBFAST_SWEEP_GRID`; each script's header lists its own. The raw outputs behind
the numbers in this README are in [results/](results/): the parity run's per-comparison verdicts and log
(`results/parity/`), the benchmark summaries and logs (`results/bench-2026-10-20/`,
`results/sweep-2026-10-20/`, and the extra stage, sort and read measurements in
`results/extra-2026-10-20/`). `results/bench-run1/`, `bench-run2-final/` and `bench-sweep1/` are the first
version's runs, kept for the comparison above. For publication the logs were edited, and no number in them was
changed: machine paths became `<repo>`, `<scratch>`, `<target>` and `$RBFAST_ORACLE`; the captures carry the names
used here and in the repository's docs (the five test-bed captures are `testbed-aa-before` and `testbed-run1-before`
to `testbed-run4-before`, the A/A run and runs 1 to 4 of [ACCURACY.md](../docs/ACCURACY.md) section 8; test-bed run
3 is also `RUN3` and `run3-gz`; big8-run3 is `BIG`); a field of the quiet-machine check that was always empty or 0
was dropped from the WAIT and STATE lines; the MACHINE lines give the kernel as `Linux 6.12` instead of its full
release string; the logged version text of the binaries names rhobound-cli 0.1.0 instead of a development commit,
and parity.sh's log line on the Go tree says "the oracle's Go tree" instead of that commit; the memory-capped
wrapper and the in-process Go driver are named in words (its two files in `results/sweep-2026-10-20/` are
`go-sweep-manifest.json` and `go-sweep.json`); and `results/extra-2026-10-20/run.sh` takes its paths from variables
and names the wrapper `WRAP`. `results/parity/parity-full.log` names the tie recorder at its path at the time,
`scripts/go/zz_tie_captures_test.go` (now `scripts/go/ties/`).
