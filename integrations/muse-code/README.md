# rhobound for Muse Code

**This plugin does nothing until `rhobound-mcp init --write` has registered the rhobound MCP server in Muse's settings
and a new Muse session has started.** It carries three skills and two hooks; the server itself is registered in Muse's
documented user settings with `"mode": "optional"`, not in the plugin, so a server that cannot start never aborts a
Muse run.

| file | what it is |
|---|---|
| `.muse-plugin/plugin.json` | the native manifest: three skills, two hooks, no MCP servers |
| `skills/rhobound-loop/SKILL.md` | the loop for the agent: context and budget before coding, predict after; only when the `mcp__rhobound__` tools are listed |
| `skills/rhobound-setup/SKILL.md` | install, check and repair, through `rhobound-mcp init` |
| `skills/rhobound-judge-review/SKILL.md` | off by default: the agent's own judge answer (client-asserted), checked by the CLI's judge-check; an independent judge is a CI step |
| `hooks/session-start.sh`, `hooks/stop.sh` | the opt-in Stop reminder (below); POSIX sh wrappers around `rhobound-mcp muse-hook` |

## Install

```
go build -o ~/.local/bin/rhobound ./cmd/rhobound
(cd mcp && go build -o ~/.local/bin/rhobound-mcp ./cmd/rhobound-mcp)
muse plugins install ./integrations/muse-code
muse plugins approve rhobound
rhobound-mcp init --engine ~/.local/bin/rhobound --capture NAME=FOLDER --policy default=POLICY.json
rhobound-mcp init --engine ~/.local/bin/rhobound --capture NAME=FOLDER --policy default=POLICY.json --write
rhobound-mcp init
```

The plugin goes in first: `muse plugins approve` may rewrite `settings.json`, so the server's entry is written after
it, and the last `init` (a dry run) must then report `muse_settings.action` `keep`. Run that check again after any
`muse plugins approve`, `update` or `disable`, and after `muse skills enable` or `disable`.

The first `init` is a dry run: it checks the configuration the way the server does at start (the configuration loads
and the engine's sha256 matches) and prints, as one JSON report, what the configuration makes the server run and read
(the engine's path and sha256, the state folder, the captures and the policies) and the settings entry it would
write. It refuses paths inside the git work tree of the current folder (a repository must not choose what rhobound
runs) unless `--allow-workspace-paths` is given, and it never prints the old entry (its `env` or `headers` may hold
credentials). `--write` writes `~/.config/rhobound-mcp/config.json` (0600, absolute paths), one entry in
`~/.config/muse/settings.json` (`$XDG_CONFIG_HOME` when set) and a registration record,
`~/.local/state/rhobound-mcp/muse-registration.json`, from which the hooks learn which settings file init wrote (their
environment may lack `XDG_CONFIG_HOME`). Every file it replaces is kept first as `FILE.rhobound-bak-<UTC time>`.

Only the entry changes: every other byte of the settings file stays as it was. An existing entry keeps the members init
does not set (`env`, `startup_timeout_sec`, `enabled_tools` and the like) and a `"enabled": false` you set; init sets
`transport`, `command`, `args`, `mode` and, unless you parked it, `enabled`. It drops `url` and `headers`, which
contradict a stdio entry, and lists them in `muse_settings.dropped` (they stay in the backup). init refuses a settings file that is not
plain JSON, has no `schema_version` or one other than 1, holds both `mcp_servers` and `mcpServers` (Muse then disables
MCP altogether), or has another entry that already runs rhobound-mcp.

The entry, as init writes it (the shape of Muse's documented example, with absolute paths):

```json
"rhobound": {
  "transport": "stdio",
  "command": "/path/to/home/.local/bin/rhobound-mcp",
  "args": ["stdio", "--config", "/path/to/home/.config/rhobound-mcp/config.json"],
  "enabled": true,
  "mode": "optional"
}
```

- Keep `"mode": "optional"`. Muse's default, `required`, aborts every run whose server fails to start, for example
  after the rhobound binary is rebuilt and its sha256 no longer matches (`server.engine_mismatch`; `rhobound-mcp init
  --repin`, then the same with `--write`, pins it again and changes nothing else in the configuration).
- The entry is user-level: the server's six tool definitions and its instructions load into every Muse session in every
  repository. Set `"enabled": false` to park it. init writes `false` itself while the configuration names no policy, or
  no capture or environment.
- `examples/mcp/muse-settings.json` is the same entry for pasting by hand.

After updating the plugin's files: `muse plugins update rhobound`, `muse plugins approve rhobound`, then `rhobound-mcp
init` (expect `keep`). The judge skill is off by default; `muse skills enable rhobound-judge-review` should turn it on
(not yet checked on a real Muse build). The repository also has a marketplace file, `.agents/plugins/marketplace.json`,
whose source path is relative to the repository's root; installing through it is not yet checked either.

## The Stop reminder (opt-in per repository)

A repository turns it on by committing `.rhobound/muse.json` holding exactly:

```json
{"schema": "rhobound.muse/v1", "remind_predict": true}
```

- On SessionStart, the hook arms the session when the repository opts in and the server is registered, enabled and
  passes its start checks. It records the session's start and a fingerprint of the repository's files: their names
  from `git ls-files` (no filters, diff drivers, hooks or fsmonitor run), their sizes and times from lstat.
- On Stop, when the files changed and the server's preview log has no row since the session started, it asks for one
  continuation with a fixed reason: call predict once and report its verdict, or say why the change cannot move a
  service's mean latency. It does this at most once per session, never while `stop_hook_active` is set, and never
  again after it reminded.
- The hooks never print to standard output (on SessionStart Muse would read it as context), never read a path, binary
  or setting from the workspace, and the wrappers exit 0 whatever fails: a missing or older binary, a crash, a signal,
  a missing `HOME` or `PATH`. Two cases are outside them, since a shell cannot catch them: if Muse could not open a
  wrapper (say it ran `/bin/sh hooks/stop.sh` in the workspace without resolving the path against the plugin's
  folder), and if the machine cannot start a process at all (`fork` fails), dash exits 2, which Muse reads as a block
  (bash retries for about 15 s, past the hook's 5 s). The reminder is a nudge, not the gate: CI's gate decides.
- What the hooks touch: they write only in `<data>/rhobound-sessions-v1/` (`<data>` is `MUSE_PLUGIN_DATA_DIR`, else
  `~/.cache/rhobound-mcp/muse`), and only once the server is registered, enabled and passes its start checks; that
  folder must be a real folder of the user's own that no one else can write, outside the repository, and the hooks
  remove only their own expired markers in it. A `HOME`, `XDG_CONFIG_HOME`, data folder or `PATH` entry that points
  into the repository is ignored, and the wrappers take the home folder from the user database and never run a
  `rhobound-mcp` under the current folder (so a session started in the home folder itself finds it only through
  `PATH`). Every file the hooks read is size-capped and must be a regular file, and a hook process ends shortly after
  its budget whatever it is doing.
- What it sees, and what not: any change to the repository's files since the session started counts, the user's own
  edits included, minus what git ignores (the repository's ignore files and `~/.config/git/ignore`; a
  `core.excludesFile` set in `~/.gitconfig` is not read). Edits inside a submodule or a nested repository are not seen
  from the superproject (start the session inside it). A preview from any session of the same server counts as a
  preview, and a refused predict does not.

The reason text and the skills are pinned in `mcp/MUSE-TEXT.sha256`; a test fails when they change without it.

## Status

Built and tested offline against the plugin contract as measured by the community (no official plugin page exists):
`go test ./cmd/rhobound-mcp` in `mcp/` checks the manifest against that contract, the hooks under `env -i`, init's
settings writer, and a scripted session. The fixtures in `mcp/cmd/rhobound-mcp/testdata/muse/` have the shape
`muse plugins hook test --fixture` takes. Not yet run against a real Muse build. The first checks on a machine that
has Muse, in order:

1. `muse plugins validate ./integrations/muse-code`: valid, no diagnostics.
2. `muse plugins hook test rhobound:rhobound-stop --fixture mcp/cmd/rhobound-mcp/testdata/muse/stop.json --json`, run
   from a folder other than the plugin's: the relative script path resolves to the plugin's folder, and the hook exits
   0.
3. After `muse plugins approve rhobound`, `rhobound-mcp init` reports `keep`: the `mcp_servers` entry survived Muse's
   own rewrite of `settings.json`. If it did not, move the entry to `mcpServers` and remove `mcp_servers` (with both,
   Muse disables MCP).
4. One live session in an opted-in repository: the session id is the same in the SessionStart and Stop payloads (the
   reminder fires once after an edit with no preview, and not after a preview), and a server that cannot start is
   skipped with a warning, not an abort.
