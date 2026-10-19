# SPDX-License-Identifier: Apache-2.0
GO ?= go

.PHONY: build test race vet cover e2e accuracy fmt
build:
	$(GO) build -o bin/rhobound ./cmd/rhobound

test:
	$(GO) test ./...

race:
	$(GO) test -race ./...

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
