# The Linux node of the end to end job: a machine with a container engine of its own
# (Docker in Docker), git, and a forwarder for the one loopback port the apiary is
# reached on. qory itself is mounted in, built from the pinned source by run.sh.
FROM ghcr.io/qoryai/ci-images:docker-29-dind@sha256:0b6d18a4a222e71c88be6034926b4f6cde2fc33c2218643d03ccfddc65995470
RUN apk add --no-cache git socat
