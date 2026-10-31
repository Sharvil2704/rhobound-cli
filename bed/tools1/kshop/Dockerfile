# kshop images, the KIT's Dockerfile (/opt/rbd/kshop/Dockerfile; build.sh uses it, never a PR's). Context: CHECKOUT/kshop.
# One build per service (SERVICE names the image; the binary is shared code); LIB selects the library version
# ("kshop_v11" = library 1.1, production on demo1); CMD=kshop-load builds the load generator.
# Base pinned by digest: golang:1.26.9-bookworm, index sha256:d9c68c2c... (Docker Hub, last updated 2026-10-08).
# GO_IMAGE (rbd-bench T4) swaps the builder for a change whose rhobound-change.json names a "base": build.sh passes
# --build-arg GO_IMAGE=<that key's value in the kit's bases.json> (an allowlist of images by digest; a PR never
# carries a Dockerfile). The default is bases.json's "go1269", today's builder.
# No BuildKit cache mounts: it builds with the classic builder and with BuildKit alike.
ARG GO_IMAGE=golang:1.26.9-bookworm@sha256:d9c68c2c51161e12fd77e4c6320687c9cd86e1af1e3ad6e6cd63ff970641453c
FROM ${GO_IMAGE} AS build
WORKDIR /src
# no toolchain download (go.mod says go 1.26.0, the base is 1.26.9 or a newer allowlisted Go), go.mod/go.sum as committed
ENV GOTOOLCHAIN=local GOFLAGS=-mod=readonly
COPY app/go.mod app/go.sum ./
RUN go mod download
COPY app/ ./
ARG LIB=""
ARG CMD=kshop-svc
# -buildvcs=false: no VCS stamping, so go build never runs git/hg/svn/bzr/fossil on a .hg (or other) folder in the tree
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -buildvcs=false -tags "$LIB" -o /out/app ./cmd/$CMD

FROM scratch
ARG SERVICE=svc
LABEL org.opencontainers.image.title="kshop-${SERVICE}"
COPY --from=build /out/app /app
USER 65532:65532
ENTRYPOINT ["/app"]
