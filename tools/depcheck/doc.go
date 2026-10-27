// SPDX-License-Identifier: Apache-2.0

// Package depcheck holds the dependency checks of the root module (docs/BUILD.md, Continuous integration): the
// CLI, rhobound, is built from the standard library and this module only, and the module requires nothing. The nested
// mcp module checks its own dependencies (mcp/internal/schematest). It has no Go API.
package depcheck
