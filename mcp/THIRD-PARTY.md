# Third-party Go modules of rhobound-mcp

The `mcp/` module (rhobound-mcp, a Go module of its own, Go 1.25) vendors no third-party code. Its binary,
`rhobound-mcp`, is built from the Go standard library, this module and the modules below, which `go build` downloads
through the module proxy and links in, at the versions `mcp/go.mod` pins. The licence column is what each module's own
`LICENSE` file states at that version. A binary of rhobound-mcp given to others carries those notices: its `LICENSE`,
`NOTICE` and each module's licence text, which `go mod download -json` locates in the module cache. The Lambda zip of
docs/mcp/DEPLOY_AWS.md 2.2 is for the operator's own account.
`go list -deps -f '{{with .Module}}{{.Path}} {{.Version}}{{end}}' ./cmd/rhobound-mcp | sort -u`, run in `mcp/`, lists
them, and `mcp/internal/schematest` fails when a package of this module, its tests included, is built from a module
this table does not list, and when `mcp/go.mod` holds a `replace`, `exclude` or `retract` directive.

| module | version | licence (its LICENSE file) | why |
|---|---|---|---|
| github.com/modelcontextprotocol/go-sdk | v1.8.0 | Apache-2.0 for new code and for contributions relicensed with their authors' consent; MIT for contributions not yet relicensed (its LICENSE describes this transition and carries both texts) | the official MCP Go SDK: the server, both protocol eras, the bearer-token middleware |
| github.com/google/jsonschema-go | v0.4.3 | MIT | JSON Schema: the tools' input schemas and their validation |
| github.com/segmentio/encoding | v0.5.4 | MIT; its `json/codec.go` includes code from the Go standard library under the Go Authors' BSD-style licence | the SDK's JSON codec |
| github.com/segmentio/asm | v1.1.3 | MIT | segmentio/encoding's base64, ASCII and CPU-feature helpers |
| github.com/yosida95/uritemplate/v3 | v3.0.2 | BSD-3-Clause | the SDK's resource templates |
| golang.org/x/oauth2 | v0.35.0 | BSD-3-Clause | the SDK's authorization packages |
| golang.org/x/sync | v0.20.0 | BSD-3-Clause | the SDK |
| golang.org/x/sys | v0.41.0 | BSD-3-Clause | segmentio/asm's CPU feature detection |
| golang.org/x/time | v0.15.0 | BSD-3-Clause | the SDK's rate limiter |
