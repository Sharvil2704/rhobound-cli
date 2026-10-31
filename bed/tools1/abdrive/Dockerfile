# abdrive's image (SPEC 5): busybox (sh, tar for kubectl cp, sleep) + the static linux/amd64 binary from build.sh.
# Built on rbd-tools1 from this folder:  docker build -t "$RBD_ECR:abdrive-<sha12 of bin/abdrive>" .
# busybox:1.36.1, the linux/amd64 platform manifest, pinned by digest (looked up 2026-10-30 through the registry API:
#   GET https://registry-1.docker.io/v2/library/busybox/manifests/1.36.1 -> OCI index
#       sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662, linux/amd64 entry below;
#   the amd64 manifest's own bytes hash to it; config sha256:b116e155074440ffd9e449559433feb4cd2341eb3554b1da1c638c976e56451d,
#   created 2023-05-18T22:34:17Z, User unset = root).
FROM busybox@sha256:b7f3d86d6e84fc17718c48bcde1450807faa2d56704205c697b4bd5df7b9e29f
COPY bin/abdrive /abdrive
ENTRYPOINT ["/abdrive"]
