# rbfast-otlp

A parallel Rust port of rhobound-cli's trace reader (`internal/otlp`, `otlp.ReadDir`). Go stays the reference: this
crate returns the same `Data` (the span table, the resource, peer and address tables, the counters and the file
list) for the same capture, byte for byte, and fails where Go fails, with Go's error text.

## API

```rust
let d: rbfast_otlp::Data = rbfast_otlp::read_dir("CAPTURE")?;          // every core, like Go's GOMAXPROCS default
let d = rbfast_otlp::read_dir_with("CAPTURE", &rbfast_otlp::ReadOptions { threads: 4, chunk_bytes: 0 })?;
let d = rbfast_otlp::read_file("spans.jsonl.gz")?;                      // Go's ReadDir given a file path
```

* `Data`, `Span`, `Resource` and the `KIND_*` constants are the shared types in `lib.rs` (unchanged).
* `ReadError { kind, message }`: `message` (and `Display`) is Go's `err.Error()`; `kind` is `Path`, `NoFiles`, `File`
  (open, read, gzip, or a `.json` stream that is not JSON) or `BadJson` (a request `json.Unmarshal` refuses).
* `is_probe(route)`: Go's `otlp.IsProbe`.
* `dump::write_dump(&data, dir, gz)`: the rbfast oracle's canonical dump (`spans.tsv[.gz]`, `resources.tsv`,
  `peers.tsv`, `addrs.tsv`, `counters.json` with the SHA-256 of `spans.tsv`), for diffing against the oracle's Go dumps.
* `RBFAST_OTLP_STAGES=1` prints stage times to stderr (diagnostics only).
* Binary `rbfast-otlp`: `dump CAPTURE OUTDIR [--threads N] [--gz]`, `bench CAPTURE [--threads N] [--reps R]`,
  `batch LIST OUT` (one hash or error per capture, for differential testing), `inflate FILE` (gzip code alone).

## What is kept from Go

Files: a file path as given; else `CAPTURE/traces/` if it is a folder, else the folder itself; `*.jsonl`, `*.json`,
`*.jsonl.gz`, `*.json.gz` (case-sensitive), byte-sorted; directory entries skipped by their own type (a symlink to a
folder named `x.jsonl` is opened and fails as Go fails); paths cleaned as `filepath.Join` does. A name containing
`.jsonl` is read as lines (every line that is not Unicode white space, with its newline, is one request), any other as
a stream of JSON values (adjacent values allowed, as Go's `json.Decoder`); `.gz` is gzip, multistream.

JSON, as Go 1.27's `encoding/json` (v1 API over v2 with the v1 options) reads it into the reader's structs: full
syntax validation including skipped members (Go's error texts), nesting limit 10000, member names matched exactly or
by `strings.EqualFold` (so `KIND`, `kind`, U+212A Kelvin sign + `ind` all match `kind`), duplicate members
merged with Go's legacy rules (struct fields merge; scalars replaced; null leaves scalars and structs alone and
empties slices; a repeated array decodes element by element into the old backing array, whose tail survives),
escapes resolved, invalid UTF-8 replaced by U+FFFD byte by byte, lone surrogates replaced, `kind` as Go's `int`
(fractions, exponents, overflow and non-numbers refused; stored truncated to `uint8` while the comparisons with 2
and 3 use the full value), timestamps by Go's `nanos.UnmarshalJSON` (raw value with `"` trimmed, `ParseUint`, else
`ParseFloat` with Go's syntax: signs, `_`, hex floats, `Inf`, `NaN`; converted as `uint64(f)` on arm64), `intValue`
as the raw JSON text with `"` trimmed. A syntax error anywhere beats a type error; type errors report Go's path.

Spans: Go's skip rule (ids, service, start, end), probe rule (route from the first present path attribute, the span
name, query/fragment cut, `http(s)://host` cut, method, `strings.TrimSpace`, the `IsProbe` regexp), probe children
made roots, peer and address rules (peer keys in order, first non-empty; first `server.port`/`net.peer.port` with
text). Tables are first-seen in capture order (every resource, including those whose spans were all skipped).

Errors: a file's read error (the first failing file in order) wins over any request error; then the first request
error in capture order. gzip framing is ours, with Go's rules and texts (`EOF`, `unexpected EOF`,
`gzip: invalid header`, `gzip: invalid checksum`, trailing bytes after a member); a `.json.gz` stream reports a JSON
syntax error in the bytes inflated before a gzip failure first, as Go does.

## How it is parallel

Every file is read at once. A plain `.jsonl` file is cut at line ends into chunks (about input / (8 x threads),
256 KiB to 8 MiB; the cuts are found with small reads), and each chunk is read with pread(2), 512 KiB at a time,
into its worker thread's buffer and decoded there, in parallel: the resident set stays near the chunks in flight.
Files are not memory-mapped, so a capture that shrinks while it is read (a Collector still writing it, a log
rotation with copytruncate) gives a short read and some result or a JSON error, never a SIGBUS (as in Go, such a
read has no defined result). A gzipped `.jsonl.gz` file is inflated by one task (members are sequential) that
hands batches of whole lines (about 8 MiB) to the pool; at most 2 x threads batches wait over all files, beyond
that the inflating task decodes the batch itself (no blocking, so one thread works).

A `.json` or `.json.gz` file (a stream of JSON values) is read by one task (pread or inflate) that cuts it, without
scanning it, into batches of about 4 MiB just after a newline that a `{` follows; the batches are scanned (Go's
syntax rules) and decoded in parallel, under the same bound. Batch 0 starts at the stream's start, and a batch that
is clean (whole values to its end) ends where the next value starts, so when every batch is clean the values are
exactly those of a serial scan. When one is not (a syntax error, a cut inside a value, a read or gzip error, no
place to cut within 64 MiB) the file is read again serially: one task scans the stream in a window (a value is
taken as complete only when a byte follows it or the stream has ended, an error near the window's end is confirmed
with more input) and hands batches of whole values to the pool; its values and errors are those of a scan of the
whole stream, Go's. Either way memory stays near the batches in flight; nothing is inflated or held whole.

Each chunk decodes with a hand-written, allocation-free (after warm-up) decoder that borrows strings from the input,
and keeps first-seen tables with an Fx hash (with a final fold of the high bits into the low ones: hashbrown picks
buckets from the low bits, and without it 8-byte names collided). Parts merge in capture order: tables serially
(they are small), spans copied into the final table in parallel (each part freed as it is copied), probe children
fixed in parallel.

## Limits and approximations

* One request (a line, or a value of a `.json` stream) may be at most 1 GiB - 1 byte (offsets are 32-bit); a larger
  one is refused with a clear error. Go has no such limit.
* Error texts are Go's on every form tested (syntax, type, depth, timestamps, gzip, paths), except: OS error texts
  are the C library's message with a lower-case first letter (Go uses its own table; they agree for the common
  ones); with the `miniz` backend some corrupt deflate streams fail as `gzip: invalid checksum` instead of Go's
  `flate: corrupt input before offset N` (with the default zlib-rs backend the texts and offsets matched Go on every
  case found). Characters are quoted with Go's own `strconv.Quote` and `IsPrint` tables (rbfast-gostr).
* `ReadError::raw` is the error text as Go prints it (a path that is not UTF-8 keeps its bytes); `message` is the
  same text as valid UTF-8 (each invalid byte replaced by U+FFFD, as Go's encoders do). `Data::files` holds
  `String`s: a file name that is not UTF-8 is replaced the same way (Go keeps the bytes; no output prints it).
* Addresses (`peer:port`) whose port text is not UTF-8 become `String`s the same way; they are interned on their
  bytes, so their number (all the inference uses) is Go's.
* `uint64(f)` of a float timestamp out of range follows arm64 (saturating, NaN to 0), as the oracle (Go on amd64
  gives other values for out-of-range floats).

## Crates and licences

rayon (MIT OR Apache-2.0), memchr (MIT OR Unlicense), flate2 (MIT OR Apache-2.0) with its `runtime_detection`
feature (the hardware CRC-32), and rbfast-gostr (this workspace). Inflate backend: by default zlib-rs (licence Zlib),
the Rust port of zlib-ng; `--no-default-features --features miniz` gives miniz_oxide (MIT OR Zlib OR Apache-2.0)
with crc32fast (MIT OR Apache-2.0) for an MIT/Apache-only build (slower on gzipped captures, and see the error-text
note above).

## Tests

* `tests/go_ported.rs`: Go's `otlp_test.go`, test for test, plus a thread-count/chunk-size invariance test for
  lines files and one for `.json` streams (one value per line, pretty-printed, adjacent, cut inside a value, a
  late syntax error, a truncation, a bad rune at the end; plain and gzipped).
* `tests/go_golden.rs` + `tests/data/go_golden.txt`: 406 small captures with Go 1.27.2's outcome frozen (canonical
  hash of the whole `Data`, or the exact error text): crafted cases on every rule above and fuzzed captures. Each is
  read 5 times: default chunks, and chunk sizes and read steps of 1, 7, 64 and 4096 bytes (so every lines chunk,
  `.json` batch, serial fallback and window boundary is exercised); the outcome must be Go's every time.
* `tests/depth.rs`: the nesting limit through every path of the decoder, at the boundary and one past it.
* Unit tests: Go's `ParseFloat` cases, quoting, UTF-8 replacement, routes and probes, `filepath.Clean`, SHA-256.

## Measured speed

(A measurement made during development, of the reader as it was then: memory-mapped plain files, `.json` streams
scanned serially. The workspace README has the current end-to-end figures; reading plain files with pread costs
about 5% of the read stage at one thread, and `.json` streams now read in parallel.)

`read_dir` against Go's `otlp.ReadDir` alone (Go: a program made for the comparison, not published, timing
`ReadDir` in process; Rust: `rbfast-otlp bench`), on the same binary as the parity runs. Each number is the median
of 3 processes, all run in a memory-capped scope (4 GB, nice 10), with a warm page cache. Go's thread count was set with GOMAXPROCS and
Rust's with `--threads`. Machine: 8-core aarch64, 15 GiB, 2026-10-20 09:49-10:02 UTC. Conditions: no test
cluster running. The run started after a 24-minute wait for the box to go quiet (between 09:25 and 09:49 the 1-minute load
reached 3.8); at the start the 1-minute load was 0.62. Before every configuration the run also waited until other
processes used under 0.4 cores. During the runs, other processes used 0.03-0.19 cores, except while Rust read run 3 at
8 threads: 0.33 cores, flagged noisy. Its three samples were 0.121, 0.117 and 0.116 s, so the noise did not move the
median. MB/s is uncompressed JSON per second (run 3: 579,251,255 bytes; big8-run3: 8 times that). The Go times agree with
the oracle's own method: the read stage of `rhobound predict`, timed by stage timers in an instrumented copy of the
Go binary (not published) when the oracle was made, at 07:39-08:02. They differ by -0.1% to +1.2% on every cell
except run 3 plain at 8 threads, where the in-process timing was 2.9% slower (0.692 s against 0.6725 s), so the run 3
8-thread speedup is 5.7x against the oracle's time rather than 5.9x.

| capture | threads | Go s | Rust s | Go MB/s | Rust MB/s | speedup |
|---|---|---|---|---|---|---|
| test-bed run 3 plain, 579 MB, 1 file | 1 / 2 / 4 / 8 | 4.481 / 2.298 / 1.169 / 0.692 | 0.752 / 0.388 / 0.208 / 0.117 | 129 / 252 / 496 / 838 | 770 / 1493 / 2780 / 4938 | 6.0 / 5.9 / 5.6 / 5.9x |
| run 3 gzipped, 37.7 MB, 1 file | 1 / 2 / 4 / 8 | 5.079 / 2.574 / 1.319 / 0.865 | 1.087 / 0.548 / 0.427 / 0.419 | 114 / 225 / 439 / 670 | 533 / 1056 / 1357 / 1383 | 4.7 / 4.7 / 3.1 / 2.1x |
| big8-run3 plain, 4.63 GB, 8 files | 1 / 2 / 4 / 8 | 34.55 / 17.55 / 8.915 / 4.902 | 5.886 / 2.982 / 1.519 / 0.823 | 134 / 264 / 520 / 945 | 787 / 1554 / 3051 / 5629 | 5.9 / 5.9 / 5.9 / 6.0x |
| big8-run3 gzipped, 302 MB, 8 files | 1 / 2 / 4 / 8 | 39.37 / 19.98 / 10.14 / 6.378 | 8.625 / 4.338 / 2.194 / 1.149 | 118 / 232 / 457 / 727 | 537 / 1068 / 2112 / 4034 | 4.6 / 4.6 / 4.6 / 5.6x |

Peak RSS (whole process): run 3 plain, Go 194-245 MiB, Rust 57-118 MiB; big8-run3 plain, Go 1325-1376 MiB, Rust
366-415 MiB; big8-run3 gzipped, Go about 1330 MiB, Rust 740-840 MiB.

Where Rust stops scaling: a gzipped file is one stream. Inflating run 3's `.gz` alone takes 0.367 s (1575 MB/s out, zlib-rs),
so with one gzipped file Rust is limited to about 0.42 s from 4 threads up, 2.1x Go at 8 threads. Gzipped captures
with several files scale, because each file inflates on its own thread. At 8 threads on plain input, 95% of the
wall time is decoding (stage timer `RBFAST_OTLP_STAGES=1`). Merging the tables takes under 1 ms and copying the
spans 4 ms (run 3) or 35 ms (big8-run3).
