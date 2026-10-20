// Not a module to build: scripts/parity.sh copies zz_record_test.go into a copy of the Go tree's cmd/rhobound.
// This file keeps it out of the repository's root module (go vet ./..., go test ./...).
module rbfastrecord

go 1.23
