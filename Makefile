# SPDX-License-Identifier: Apache-2.0
GO ?= go

.PHONY: build test race vet cover e2e accuracy fmt mcp mcp-build mcp-test contract
build:
	$(GO) build -o bin/rhobound ./cmd/rhobound

# rhobound-mcp, the MCP server: the nested module mcp/ (Go 1.25 or later; the root module stays Go 1.23).
mcp-build:
	cd mcp && $(GO) build -o ../bin/rhobound-mcp ./cmd/rhobound-mcp

mcp-test:
	cd mcp && $(GO) vet ./... && $(GO) test ./...

mcp: build mcp-build

# The files generated from the data contract's registry (internal/contract): the code tables of docs/mcp/DATA.md and
# docs/mcp/data-contract.json. `go test ./tools/gencontract` fails when they are not current.
contract:
	$(GO) run ./tools/gencontract docs

test:
	$(GO) test ./...

race:
	$(GO) test -race -timeout 30m ./...

vet:
	$(GO) vet ./... && $(GO) vet -tags e2e ./... && $(GO) vet -tags accuracy ./...

cover:
	$(GO) test -cover ./...

fmt:
	gofmt -l -w .

# Needs docker, kind and kubectl. Creates and deletes a kind cluster with its own kubeconfig.
e2e:
	RHOBOUND_E2E=1 $(GO) test -tags e2e -v -count=1 -timeout 40m ./e2e

# The accuracy studies (minutes): they print tables instead of asserting. See docs/ACCURACY.md.
accuracy:
	$(GO) test -tags accuracy -v -count=1 -timeout 60m ./internal/infer
