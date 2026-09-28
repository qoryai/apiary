# The Linux node of the end to end job: a machine with a container engine of its own
# (Docker in Docker), git, and a forwarder for the one loopback port the apiary is
# reached on. qory itself is mounted in, built from the pinned source by run.sh.
FROM docker:29-dind
RUN apk add --no-cache git socat
