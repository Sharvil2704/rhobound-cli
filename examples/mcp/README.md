# Running rhobound-mcp locally

Examples for the MCP server in stdio mode, the way a coding agent on a developer machine uses it: no AWS, no network,
no credentials (docs/mcp/DEPLOY_AWS.md, 14).

| file | what it is |
|---|---|
| `policy.example.json` | a gate policy (`rhobound.policy/v1`): the 5% entry threshold of the examples, every other key at its default (ARCHITECTURE.md 6.2) |
| `config.example.json` | the server's configuration (`rhobound-mcp.config/v1`): the repository's test fixtures as captures, and the policy above as `default` |
| `.mcp.json` | the server registered with Claude Code, for a project's root folder |
| `codex-config.toml` | the same for Codex |
| `muse-settings.json` | the same for Muse Code (`~/.config/muse/settings.json`), with `"mode": "optional"`; `rhobound-mcp init` writes it with real paths, and the Muse plugin is in `integrations/muse-code` |

## Steps

```
go build -o bin/rhobound ./cmd/rhobound
(cd mcp && go build -o ../bin/rhobound-mcp ./cmd/rhobound-mcp)     # Go 1.25 or later
sha256sum bin/rhobound
```

In `config.example.json`, set `engine.path` to the absolute path of `bin/rhobound` and `engine.sha256` to the sum
printed above. The placeholder of zeros is refused on purpose: the server checks the engine's sha256 at start and
refuses to run another binary (`server.engine_mismatch`). Paths in the configuration are relative to its own folder;
`state_dir` holds the server's handles, jobs and preview log, and under `engine/` the CLI's own record store (the A/B
records `diff-fit` mints).

Then register the server with the agent (with `bin/` on `PATH`, or the absolute path of `rhobound-mcp` as `command`),
or try it by hand:

```
bin/rhobound-mcp stdio --config examples/mcp/config.example.json
```

The configured names are the fixtures of `testdata/mcp` (see its README): `loop` is the scripted agent's capture,
`loop-a` and `loop-b` its A/B pair, `hostile` the hostile-names capture. An agent starts with
`fit_start({"capture": "loop", "workers": {"a": 1, "b": 2, "c": 1}})`, then `job_status`, `context`, `budget` and
`predict`. The loop capture's window ended on 2023-11-14, more than `max_fit_age_h` ago, so rule 3 (`fit_stale`)
holds every preview on it that does not block at `inconclusive`; the server's tests pin their clock instead. A recent
capture of your own, named in `captures`, has no such problem.
