# kshop images. One build per service (SERVICE names the image; the binary is shared code),
# LIB selects the shared library version: "kshop_v11" builds library 1.1 (production in this demo);
# CMD=kshop-load builds the load generator. Build context: kshop/ (CI uses the kit's copy of this file, never a PR's):
#   docker build -f kshop/Dockerfile --build-arg LIB=kshop_v11 --build-arg SERVICE=auth kshop
# Base pinned by digest: golang:1.26.9-bookworm, its linux/amd64 manifest. Source (2026-10-30):
#   https://registry-1.docker.io/v2/library/golang/manifests/1.26.9-bookworm
#   index sha256:d9c68c2c51161e12fd77e4c6320687c9cd86e1af1e3ad6e6cd63ff970641453c -> linux/amd64 below
# No RUN --mount cache: the file builds with BuildKit and with the classic builder (docker.io without buildx).
FROM golang:1.26.9-bookworm@sha256:bcef992b77b1e2031aaaa51da75cebc32da8e9c182e12e633ea79023c79d9eff AS build
WORKDIR /src
ENV GOTOOLCHAIN=local GOFLAGS=-mod=readonly
COPY app/go.mod app/go.sum ./
RUN go mod download
COPY app/ ./
ARG LIB=""
ARG CMD=kshop-svc
# -buildvcs=false: no VCS stamping, so go build never runs git/hg/svn/bzr/fossil on a .hg (or other) folder in the tree
RUN CGO_ENABLED=0 go build -trimpath -buildvcs=false -tags "$LIB" -o /out/app ./cmd/$CMD

FROM scratch
ARG SERVICE=svc
LABEL org.opencontainers.image.title="kshop-${SERVICE}"
COPY --from=build /out/app /app
USER 65532:65532
ENTRYPOINT ["/app"]
