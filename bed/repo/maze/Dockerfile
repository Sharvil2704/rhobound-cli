# maze images, the KIT's Dockerfile (/opt/rbd/maze/Dockerfile; build.sh uses it, never a PR's). Context: CHECKOUT/maze.
# One build per service: CMD names the image (spec.json services[SERVICE].image, i.e. cmd/<CMD>), SERVICE only labels it.
# The build stage compiles every cmd/ in one RUN (each image's binary carries -X maze/internal/rt.Image=<its name>), so
# Docker reuses that layer across the services of one commit and only the last stage differs. CMD=maze-load: the load
# generator. LIB is accepted and passed as build tags (maze has none today).
# Base pinned by digest: golang:1.26.9-bookworm, index sha256:d9c68c2c... (Docker Hub, last updated 2026-10-08).
# GO_IMAGE: the builder, swapped only through the kit's bases.json allowlist (build.sh --build-arg GO_IMAGE=...).
ARG GO_IMAGE=golang:1.26.9-bookworm@sha256:d9c68c2c51161e12fd77e4c6320687c9cd86e1af1e3ad6e6cd63ff970641453c
FROM ${GO_IMAGE} AS build
WORKDIR /src
# no toolchain download, go.mod/go.sum as committed
ENV GOTOOLCHAIN=local GOFLAGS=-mod=readonly
COPY app/go.mod app/go.sum ./
RUN go mod download
COPY app/ ./
ARG LIB=""
# -buildvcs=false: no VCS stamping (go build never runs a VCS tool on the tree, and unchanged images keep their bytes)
RUN mkdir -p /out && for c in $(ls cmd); do CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -buildvcs=false -tags "$LIB" -ldflags "-X maze/internal/rt.Image=$c" -o "/out/$c" "./cmd/$c" || exit 1; done

FROM scratch
ARG SERVICE=svc
ARG CMD=maze-load
LABEL org.opencontainers.image.title="maze-${SERVICE}"
COPY --from=build /out/${CMD} /app
USER 65532:65532
ENTRYPOINT ["/app"]
