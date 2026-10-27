# Golden sweep of commit 1a2df09

What `rhobound predict` printed at commit 1a2df09 (rhobound-cli before rhobound-mcp) on every capture in the
repository's test data, in the three forms its readers use:

| form | arguments |
|---|---|
| text report | `predict CAPTURE` |
| JSON report | `predict CAPTURE --json` |
| JSON report of a change | `predict CAPTURE --patch P --json`, one patch per capture naming one of its services |

The captures are `testdata/capture-chain` and the seven under `internal/infer/testdata/` (`counts/`, `hops/`,
`nested/`). The four `nested/` sets are too small for the CLI: their golden is the refusal (exit status 1, the message
on standard error, nothing on standard output).

`cmd/rhobound/golden_test.go` runs the current tree's CLI on the same arguments, from the repository root, and compares
standard output, standard error and the exit status byte for byte. It is the check that report v1 stays byte-identical
to 1a2df09's on the repository's test captures, and on every capture without a platform pod identity, while rhobound-mcp
is built. One planned change is allowed: a refusal printed with `--json` may instead print the coded refusal object
(`{"error": {"code", "reason", "fix", ...}}`) on standard output, with the same exit status; the text form of each
refusal must keep its message. Three other changes, on bad input only, are not in the sweep. `--workers` naming a
service the capture does not have is refused (`change.unknown_service`, exit 1), where 1a2df09 ignored it and printed
the report ([docs/USAGE.md](../../docs/USAGE.md#7-the-other-flags), section 7). And on a file that is JSON but not in
OTLP's shape, the decoder's own text after `rhobound: bad OTLP/JSON: ` may differ from 1a2df09's: it names the Go type
the file is decoded into, which has gained fields since. The prefix and the exit status are the same, and with `--json`
the coded refusal's `reason` carries the new text. And `--fit`, `--changes` or `--report`, flags 1a2df09 did not have,
given with a capture are refused with this build's usage message on standard error, where 1a2df09 printed its own usage
line; the exit status (1) and the empty standard output are the same (`cmd/rhobound/main_test.go`,
`TestPredictFlagsGivenEmpty`). Report v1 reads a capture whole, as 1a2df09 did: the reader's caps bound `check` and
`fit` only, and `cmd/rhobound/readercaps_test.go` pins captures past them (a kept attribute value of 4097 bytes, a 65
MiB line, a file that inflates past 1 GiB) to the bytes 1a2df09 printed. A last change is on captures the sweep does not
hold, those that name their pods only by a platform identity: a resource with `k8s.pod.uid` or `aws.ecs.task.arn` but no
`k8s.pod.name` is keyed by that identity (an ECS task by the last element of its ARN, its id), where 1a2df09 used
`service.instance.id` or `host.name` or, with neither, read all of a service's spans as one pod. On such a capture the
predictions can change, since the pod count and the per-pod queues follow the identity, and the split warning names pods
by it ([DATA.md](../../docs/mcp/DATA.md#34-resource-attributes), 3.4). `cmd/rhobound/podidentity_test.go` pins two.
`hops/cache-30s` with `k8s.pod.name` renamed to `k8s.pod.uid`, and replaced by a task ARN, prints the bytes 1a2df09
printed for the capture as it is (api at `2 x 1+`), where 1a2df09 itself read one pod for api on those variants (`1 x
2+`, the frontend's model 42.84 ms instead of 52.16 ms). And a capture whose pods take uneven shares, named by task ARNs
alone, prints the bytes of the same capture with the task ids as `k8s.pod.name`, its split warning naming the task ids
(`TestPodIdentitySplitWarning`).

## How the files were made

- A binary built from commit 1a2df09 (`git archive 1a2df09`, then `go build ./cmd/rhobound`) with Go 1.27.2 on
  linux/arm64. Its sha256 and version are in `arm64/manifest.json`.
- Each case run from the repository root with `RHOBOUND_ESTIMATOR` unset, four times: twice, then with `GOMAXPROCS=1`
  and `GOMAXPROCS=2`. All four gave the same bytes.
- `manifest.json` lists every case: the capture, the arguments, the exit status, the standard error, the file that
  holds the standard output (none when it is empty) and the sha256 of both.

**Only a binary built from 1a2df09 writes these files.** The test has no update flag: regenerating them from a later
tree would hide exactly the change they exist to catch.

## Other architectures

Floating point differs in the last bits between architectures (arm64 fuses multiply-adds where amd64 does not), so the
goldens are kept per `GOARCH`, in a folder of that name. On an architecture with no folder the test skips and says so.
To add one, build 1a2df09 on that architecture, run the same cases from the repository root with `RHOBOUND_ESTIMATOR`
unset, and write the outputs and a manifest of the same shape into `testdata/golden-1a2df09/<GOARCH>/`.

Without a folder, `tools/golden-live.sh` checks the same rule live on any architecture: it builds rhobound from 1a2df09
out of the repository's history (`git archive`, so the clone needs the commit: `fetch-depth: 0` in CI) and runs
`TestGoldenLive1a2df09`, which runs that binary and this tree's CLI on the arguments of every case of
`arm64/manifest.json` and compares them byte for byte, with the same allowance for a coded refusal. CI runs it on
linux/amd64 (the `golden-live` job).
