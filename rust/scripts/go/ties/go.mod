// Not a module to build: scripts/parity.sh copies zz_tie_captures_test.go into a copy of the Go tree's
// internal/infer. This file keeps it out of the repository's root module (go vet ./..., go test ./...).
module rbfastties

go 1.23
