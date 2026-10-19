# Building and testing

rhobound is one Go program with no dependency outside the Go standard library. This page shows how to build it, how
to run its tests, and what to do when something goes wrong. The commands and outputs below were run on Linux
(arm64) with Go 1.27.2, from the repository root.

## Requirements

- **Go 1.23 or later** (`go.mod` says `go 1.23`). Get it from <https://go.dev/dl/>.
- Nothing else to build: no C compiler, no other module, no network access during the build.
- Any operating system and architecture Go supports. It has been built and run on linux/arm64, and cross-built for
  linux/amd64, darwin/arm64, darwin/amd64 and windows/amd64 (those were built, not run).
- The tests have been run only with Go 1.27.2 on linux/arm64. `go vet` (whose `stdversion` check reports standard
  library calls newer than the `go 1.23` line) passes, but no Go 1.23 toolchain and no amd64 machine has run them;
  the CI below is the first to do so.
- For the race detector only: cgo, which means a C compiler (`gcc` or `clang`) and `CGO_ENABLED=1`.
- For the Kubernetes end-to-end test only: `docker`, `kind` and `kubectl`.

Check your Go:

```
$ go version
go version go1.27.2 linux/arm64
```

## Get the source

```
git clone https://github.com/Sharvil2704/rhobound-cli.git
cd rhobound-cli
```

(Not run here: this machine had no network access when this page was written.)

## Build

```
$ go build -o bin/rhobound ./cmd/rhobound
$ bin/rhobound version
rhobound 0.1.0-dev
```

The binary is `bin/rhobound` (`bin/` is ignored by git). It does not need cgo, so it is a static binary:

```
$ file bin/rhobound
bin/rhobound: ELF 64-bit LSB executable, ARM aarch64, version 1 (SYSV), statically linked, Go BuildID=YKRsD4ejlNC18DW2GKIz/hHePPiyAbelv929FPHD-/ua7Xmiwc06LxTRZIIKvU/VP9gUijI5zTguE7XElZX, BuildID[sha1]=d4a0e98c935c914e43999416f1666e5054f42ff5, with debug_info, not stripped
```

### With version information

The version string is a variable set at link time:

```
$ go build -ldflags "-X main.Version=0.1.0" -o bin/rhobound ./cmd/rhobound
$ bin/rhobound version
rhobound 0.1.0
```

For a release, `-trimpath` removes local paths from the binary, and `-s -w` drops the symbol table and debug
information (here 3.3 MB instead of about 5 MB):

```
go build -trimpath -ldflags "-s -w -X main.Version=0.1.0" -o bin/rhobound ./cmd/rhobound
```

### Cross-compiling

Set `GOOS` and `GOARCH`. `CGO_ENABLED=0` makes sure the binary is static:

```
$ CGO_ENABLED=0 GOOS=linux   GOARCH=amd64 go build -trimpath -ldflags "-s -w -X main.Version=0.1.0" -o dist/rhobound-linux-amd64 ./cmd/rhobound
$ CGO_ENABLED=0 GOOS=linux   GOARCH=arm64 go build -trimpath -ldflags "-s -w -X main.Version=0.1.0" -o dist/rhobound-linux-arm64 ./cmd/rhobound
$ CGO_ENABLED=0 GOOS=darwin  GOARCH=arm64 go build -trimpath -ldflags "-s -w -X main.Version=0.1.0" -o dist/rhobound-darwin-arm64 ./cmd/rhobound
$ CGO_ENABLED=0 GOOS=darwin  GOARCH=amd64 go build -trimpath -ldflags "-s -w -X main.Version=0.1.0" -o dist/rhobound-darwin-amd64 ./cmd/rhobound
$ CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -trimpath -ldflags "-s -w -X main.Version=0.1.0" -o dist/rhobound-windows-amd64.exe ./cmd/rhobound
$ file dist/*
dist/rhobound-darwin-amd64:      Mach-O 64-bit x86_64 executable, flags:<|DYLDLINK|PIE>
dist/rhobound-darwin-arm64:      Mach-O 64-bit arm64 executable, flags:<|DYLDLINK|PIE>
dist/rhobound-linux-amd64:       ELF 64-bit LSB executable, x86-64, version 1 (SYSV), statically linked, Go BuildID=l70P39FvX0JLL_Eism0x/cjOyFMZJPSKrwBxw0Wmf/6dn4AdFYf4HJDHyanJM-/MzZDwlPCQwRSU1H2eOOp, BuildID[sha1]=d3becd1b4e9aa3bab0bb52408a7d8defd3131173, stripped
dist/rhobound-linux-arm64:       ELF 64-bit LSB executable, ARM aarch64, version 1 (SYSV), statically linked, Go BuildID=o1Y08pfokQh0eN2-zuER/wzKTBYAyd6NqPS3UkvfO/bChK14g4MnncA52maCVJ/O0xnaqWah0r4p4jgOPFs, BuildID[sha1]=3da4fb286b9229768b3177b54f8a64e8e71de61a, stripped
dist/rhobound-windows-amd64.exe: PE32+ executable for MS Windows 10.00 (console), x86-64, 8 sections
$ dist/rhobound-linux-arm64 version
rhobound 0.1.0
```

(`dist/` is ignored by git. On macOS a binary always links the system library, which is what `DYLDLINK` says; it
needs nothing else.)

### Install with `go install`

From a clone, `go install ./cmd/rhobound` puts the binary in `$(go env GOPATH)/bin`, or in `GOBIN` when that is set
(here a folder of the repository, to show it):

```
$ GOBIN=$PWD/dist go install ./cmd/rhobound
$ dist/rhobound version
rhobound 0.1.0-dev
```

Without a clone, once the repository is public:

```
go install github.com/Sharvil2704/rhobound-cli/cmd/rhobound@latest
```

(Not run here: it needs network access. It builds without `-ldflags`, so `rhobound version` prints `0.1.0-dev`.)

## The Makefile

The Makefile is a shortcut for the `go` commands. `make` is not needed; every target has a plain equivalent:

| target | the go command | what it does |
|---|---|---|
| `make build` | `go build -o bin/rhobound ./cmd/rhobound` | builds the binary |
| `make test` | `go test ./...` | unit, golden, simulator and CLI tests (about 12 s) |
| `make race` | `go test -race ./...` | the same with the race detector (about 2 minutes) |
| `make vet` | `go vet ./... && go vet -tags e2e ./... && go vet -tags accuracy ./...` | static checks, with each build tag |
| `make cover` | `go test -cover ./...` | the tests with coverage per package |
| `make fmt` | `gofmt -l -w .` | formats the code in place |
| `make accuracy` | `go test -tags accuracy -v -count=1 -timeout 60m ./internal/infer` | every accuracy study (prints tables, does not assert) |
| `make e2e` | `RHOBOUND_E2E=1 go test -tags e2e -v -count=1 -timeout 40m ./e2e` | the Kubernetes end-to-end test (needs docker, kind, kubectl) |

## Running the tests

The times below are from an 8-core arm64 machine with the tests limited to 3 cores (`GOMAXPROCS=3`) and a 2.5 GB
memory cap. On more cores they are shorter.

### Unit tests

```
$ go test -count=1 ./...
ok  	github.com/Sharvil2704/rhobound-cli/cmd/rhobound	0.558s
?   	github.com/Sharvil2704/rhobound-cli/e2e/demoapp	[no test files]
?   	github.com/Sharvil2704/rhobound-cli/e2e/loadgen	[no test files]
ok  	github.com/Sharvil2704/rhobound-cli/internal/infer	10.836s
ok  	github.com/Sharvil2704/rhobound-cli/internal/mathx	6.638s
ok  	github.com/Sharvil2704/rhobound-cli/internal/model	0.073s
ok  	github.com/Sharvil2704/rhobound-cli/internal/otlp	0.005s
?   	github.com/Sharvil2704/rhobound-cli/internal/report	[no test files]
```

`-count=1` makes Go run them again instead of printing a cached result. They cover: the CLI on the example capture
and on hand-made captures; the inference against a queue simulator whose truth is known; the model against closed
forms (M/M/1, M/G/1, M/M/2, Burke) and against golden files; the numerical kernels against high-precision reference
values; and the OTLP reader.

- `testdata/golden/golden.json` holds results of the reference implementation (an unpublished Python prototype)
  that the basic model must match: 7 hand-written and 60 random layered topologies at utilizations 0.3, 0.6 and
  0.85, each with a random service-time change (the basic model, Poisson arrivals). The script that made them needs
  the reference implementation and is not published.
- `testdata/numerics/` holds reference values for the numerical kernels (`internal/mathx` and Erlang C), from decimal
  arithmetic, scipy, adaptive quadrature and Monte Carlo. `gen_reference.py` (needs numpy and scipy) shows how.
- `internal/infer/testdata/` holds the reference implementation's outputs for the queue rebuild (on inputs that
  `TestDumpFIFOInputs` writes from simulated captures) and for the stage template. The scripts that made them are
  not published.
- Comments in the regression tests say how earlier code behaved, by short commit hash ("each failed at 29a7ed9").
  Those hashes name commits of the development history, which is not published; this repository starts with one
  commit that holds the final code.

With coverage:

```
$ go test -count=1 -cover ./...
ok  	github.com/Sharvil2704/rhobound-cli/cmd/rhobound	0.584s	coverage: 90.0% of statements
	github.com/Sharvil2704/rhobound-cli/e2e/demoapp		coverage: 0.0% of statements
	github.com/Sharvil2704/rhobound-cli/e2e/loadgen		coverage: 0.0% of statements
ok  	github.com/Sharvil2704/rhobound-cli/internal/infer	11.495s	coverage: 96.4% of statements
ok  	github.com/Sharvil2704/rhobound-cli/internal/mathx	6.722s	coverage: 99.0% of statements
ok  	github.com/Sharvil2704/rhobound-cli/internal/model	0.074s	coverage: 91.6% of statements
ok  	github.com/Sharvil2704/rhobound-cli/internal/otlp	0.005s	coverage: 90.5% of statements
	github.com/Sharvil2704/rhobound-cli/internal/report		coverage: 0.0% of statements
```

(`internal/report` has no tests of its own; the CLI tests in `cmd/rhobound` exercise it. The demo services are
tested by the end-to-end tests below.)

### The race detector

```
$ go test -race -count=1 ./...
ok  	github.com/Sharvil2704/rhobound-cli/cmd/rhobound	7.411s
?   	github.com/Sharvil2704/rhobound-cli/e2e/demoapp	[no test files]
?   	github.com/Sharvil2704/rhobound-cli/e2e/loadgen	[no test files]
ok  	github.com/Sharvil2704/rhobound-cli/internal/infer	113.836s
ok  	github.com/Sharvil2704/rhobound-cli/internal/mathx	17.165s
ok  	github.com/Sharvil2704/rhobound-cli/internal/model	1.362s
ok  	github.com/Sharvil2704/rhobound-cli/internal/otlp	1.018s
?   	github.com/Sharvil2704/rhobound-cli/internal/report	[no test files]
```

It took 1 minute 54 seconds in all.

### Formatting and vet

```
$ gofmt -l .
$ go vet ./... && go vet -tags e2e ./... && go vet -tags accuracy ./...
```

Both print nothing when all is well.

### The accuracy studies

The accuracy studies are behind the `accuracy` build tag because they take seconds to minutes each and print tables
instead of asserting (except `TestHarnessPlumbing`, which checks the harness's own arithmetic). Run one at a time
with `-run`:

```
$ go test -tags accuracy -count=1 -run TestHarnessPlumbing -v ./internal/infer
=== RUN   TestHarnessPlumbing
--- PASS: TestHarnessPlumbing (0.47s)
PASS
ok  	github.com/Sharvil2704/rhobound-cli/internal/infer	0.469s
```

```
$ go test -tags accuracy -count=1 -run TestGlueEndToEnd -v ./internal/infer
=== RUN   TestGlueEndToEnd
GLUE post 0 chg@a truth L 103.06 dL 1.84 (se 0.01) | true parameters L 102.12 (-0.9%) dL 1.81 (-1.5%)
GLUE   spans include the wait false a S 12.01 glue 0.00 cap 1 | L 106.13 (+3.0%) dL 1.78 (-3.1% of dL, -0.06% of L)
GLUE   spans include the wait true  a S 12.01 glue 0.00 cap 1 | L 106.13 (+3.0%) dL 1.78 (-3.1% of dL, -0.06% of L)
GLUE post 0 chg@b truth L 102.35 dL 27.23 (se 0.46) | true parameters L 102.12 (-0.2%) dL 27.12 (-0.4%)
GLUE   spans include the wait false a S 11.99 glue 0.00 cap 1 | L 105.42 (+3.0%) dL 29.17 (+7.1% of dL, +1.89% of L)
GLUE   spans include the wait true  a S 11.99 glue 0.00 cap 1 | L 105.44 (+3.0%) dL 29.19 (+7.2% of dL, +1.91% of L)
GLUE post 3 chg@a truth L 104.98 dL 1.83 (se 0.01) | true parameters L 105.12 (+0.1%) dL 1.81 (-0.9%)
GLUE   spans include the wait false a S 11.84 glue 3.00 cap 1 | L 110.92 (+5.7%) dL 1.72 (-5.8% of dL, -0.10% of L)
GLUE   spans include the wait true  a S 11.84 glue 3.00 cap 1 | L 110.92 (+5.7%) dL 1.72 (-5.8% of dL, -0.10% of L)
GLUE post 3 chg@b truth L 105.11 dL 26.92 (se 0.56) | true parameters L 105.12 (+0.0%) dL 27.12 (+0.7%)
GLUE   spans include the wait false a S 11.91 glue 3.00 cap 1 | L 106.25 (+1.1%) dL 27.49 (+2.1% of dL, +0.55% of L)
GLUE   spans include the wait true  a S 11.91 glue 3.00 cap 1 | L 106.25 (+1.1%) dL 27.49 (+2.1% of dL, +0.55% of L)
--- PASS: TestGlueEndToEnd (1.55s)
PASS
ok  	github.com/Sharvil2704/rhobound-cli/internal/infer	1.552s
```

Each `GLUE` row compares the truth of a simulation with the model, first given the true parameters, then given what
it read from one simulated capture. `TestAccuracy` (32 scenarios against 64 simulated replications each) took 18.3 s
here. [ACCURACY.md section 10](ACCURACY.md#10-re-running) lists every study, its run time (from about 1 s to about
2 minutes) and the switches that pick seeds and modes. `make accuracy` runs them all in one go, with a 60-minute
timeout; it was not run as a whole for this page.

### The demo without a cluster (loopback smoke test)

`TestLoopbackSmoke` runs the Kubernetes demo's services and load generator as local processes on loopback ports, then
runs the CLI on their traces. It needs no docker and no cluster (about 35 s):

```
$ go test -tags e2e -count=1 -run TestLoopbackSmoke -v ./e2e
=== RUN   TestLoopbackSmoke
=== RUN   TestLoopbackSmoke/keepalive=false
    smoke_test.go:119: load generator: sent 433, 297 measured, 0 errors, mean 44.91 ms, lag 1.1 ms, 5 windows; traces: entry 44.72 ms over 433 spans; api api-a 51.0% wait 7.62 ms, api-b 49.0% wait 5.26 ms
    smoke_test.go:150: rhobound: own ms frontend 3.41 (3), api 20.27 (20), db 8.14 (8), cache 5.51 (5); entry model 43.68 ms, load generator 44.91 ms; change api +8ms: +14.07 ms
    smoke_test.go:160: db down: sent 65, errors 65, measured 0; {"errors":65,"max_lag_ms":1.04427,"mean_ms":null,"requests":0,"rps":30,"sent":65,"windows":[{"mean_ms":0,"n":0,"start_s":0}]}
=== RUN   TestLoopbackSmoke/keepalive=true
    smoke_test.go:119: load generator: sent 447, 288 measured, 0 errors, mean 38.06 ms, lag 1.1 ms, 5 windows; traces: entry 37.88 ms over 447 spans; api api-a 60.2% wait 7.91 ms, api-b 39.8% wait 3.37 ms
--- PASS: TestLoopbackSmoke (33.74s)
    --- PASS: TestLoopbackSmoke/keepalive=false (17.47s)
    --- PASS: TestLoopbackSmoke/keepalive=true (15.48s)
PASS
ok  	github.com/Sharvil2704/rhobound-cli/e2e	33.739s
```

It is a plumbing check, with only about 15 s of load: its numbers are noisy and it is not an accuracy test. The
numbers in brackets are the true service times.

### The Kubernetes end-to-end test (kind)

`TestClusterEndToEnd` builds the demo services into an image, creates a kind cluster named `rb-oss-e2e` with its own
kubeconfig file (it never touches your default one), deploys four services, drives a Poisson load, rolls out a change
with `kubectl set env`, and compares the CLI's prediction with the latency the load generator measured. It needs
`docker`, `kind` and `kubectl` on the PATH, and takes about 13 minutes with the default two rounds. It deletes the
cluster at the end.

```
RHOBOUND_E2E=1 go test -tags e2e -v -count=1 -timeout 40m ./e2e
```

It was not run for this page; [DEMO.md](DEMO.md#demo-2-kubernetes-kind) shows the result of its last passing run.
Without `RHOBOUND_E2E=1` it skips:

```
$ go test -tags e2e -count=1 -run TestClusterEndToEnd -v ./e2e
=== RUN   TestClusterEndToEnd
    e2e_test.go:913: set RHOBOUND_E2E=1 (needs docker, kind and kubectl)
--- SKIP: TestClusterEndToEnd (0.00s)
PASS
ok  	github.com/Sharvil2704/rhobound-cli/e2e	0.003s
```

Its settings are environment variables, described at the top of `e2e/e2e_test.go`:

| variable | effect |
|---|---|
| `RHOBOUND_E2E_ROUNDS=N` | before/after pairs (default 2) |
| `RHOBOUND_E2E_STRICT=1` | fail instead of skip when the measurement was not steady |
| `RHOBOUND_E2E_KEEPALIVE=1` | the services reuse connections (a robustness run; expect the share gate to mark it unsteady) |
| `RHOBOUND_E2E_WORK=DIR` | the work folder (default: a new folder under `$HOME/.cache/rb-e2e-work`, kept when the test fails or skips) |
| `RHOBOUND_E2E_KEEP=1` | keep the cluster afterwards; a later run reuses it |
| `RHOBOUND_E2E_CAPTURE=DIR` | read one kept capture offline (`TestAnalyzeCapture`) |

## Continuous integration

`.github/workflows/ci.yml` runs on every push and pull request, on `ubuntu-latest` with the Go version that `go.mod`
names:

1. `gofmt -l .` must print nothing;
2. `go vet ./... && go vet -tags e2e ./...` (the `accuracy` tag is not vetted in CI; `make vet` does it);
3. `go test -race -count=1 ./...`.

It does not run the accuracy studies or either end-to-end test.

## Troubleshooting

**`make: command not found`.** `make` is optional. Without it, bash prints a message like this one (the wording
depends on your shell and system). Use the go command from the table above instead:

```
$ make build
bash: make: command not found
$ go build -o bin/rhobound ./cmd/rhobound
```

**Your Go is too old.** With Go 1.21 or later and the default `GOTOOLCHAIN=auto`, an older `go` downloads a newer
toolchain by itself (that needs network access). Offline, or with `GOTOOLCHAIN=local`, it stops with a message like
this one (reproduced by raising the `go` line of `go.mod` in a scratch copy, since this machine has Go 1.27.2):

```
$ GOTOOLCHAIN=local go build ./cmd/rhobound
go: go.mod requires go >= 1.99 (running go 1.27.2; GOTOOLCHAIN=local)
```

Install Go 1.23 or later from <https://go.dev/dl/>.

**Commands run outside the repository.** `go build` and `go test` must run inside the repository (the folder with
`go.mod`, or below it):

```
$ go test ./...
# ./...
pattern ./...: directory prefix . does not contain main module or its selected dependencies
FAIL	./... [setup failed]
FAIL
```

**`-race requires cgo`.** The race detector needs cgo and a C compiler:

```
$ CGO_ENABLED=0 go test -race ./internal/otlp
go: -race requires cgo; enable cgo by setting CGO_ENABLED=1
```

Install `gcc` (or `clang`) and set `CGO_ENABLED=1`, or run the tests without `-race`.

**`build constraints exclude all Go files` in `e2e`.** The end-to-end tests need the `e2e` build tag (the path is
shortened here):

```
$ go test ./e2e
# github.com/Sharvil2704/rhobound-cli/e2e
package github.com/Sharvil2704/rhobound-cli/e2e: build constraints exclude all Go files in .../e2e
FAIL	github.com/Sharvil2704/rhobound-cli/e2e [setup failed]
FAIL
```

Add `-tags e2e`.

**`no tests to run` for an accuracy study.** The studies need the `accuracy` build tag:

```
$ go test -count=1 -run 'TestAccuracy$' -v ./internal/infer
testing: warning: no tests to run
PASS
ok  	github.com/Sharvil2704/rhobound-cli/internal/infer	0.001s [no tests to run]
```

Add `-tags accuracy`. For several studies at once also add `-timeout 60m`: by default `go test` stops a test binary
after 10 minutes.

**The kind test skips with `UNSTABLE measurement`.** The test checks that each measured window was steady (even load
split, no stalls, no lost spans, windows of the same kind that agree). If one was not, it logs why and skips instead
of judging the model, and keeps its work folder. Look at the `UNSTABLE:` lines and `result.json` in that folder.
`RHOBOUND_E2E_STRICT=1` makes it fail instead.

**The CLI refuses a capture.** That is not a build problem: [USAGE.md](USAGE.md#9-exit-codes-and-refusals) lists the
refusals and what to do about each.
