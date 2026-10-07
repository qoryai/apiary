#!/bin/sh
# Makes the node ready for a session: the engine up, the apiary answering on a loopback port, the
# node's own qory configuration in place, the checkout in place with an origin remote and its
# harness composed.
set -eu

port="${E2E_PORT:?}"

i=0
until docker info >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -gt 120 ] && { echo "the node's engine did not start" >&2; exit 1; }
  sleep 0.5
done

# run.sh has started the forwarder that brings the test instance to a loopback port of
# the node; the instance answers its health check through it, or the job stops here.
i=0
until wget -q -O /dev/null "http://127.0.0.1:${port}/health"; do
  i=$((i + 1))
  [ "$i" -gt 60 ] && { echo "the test instance does not answer on the node's 127.0.0.1:${port}" >&2; exit 1; }
  sleep 0.5
done

# qory reads the access key's secret only from a file the user running it owns, mode 0600,
# in a directory that is that user's alone, mode 0700, and keeps its instance id and locks
# beside it. /config is the host's, mounted read only and owned by the host's user, so the
# node takes its own copy of it, root's, the user qory runs as here.
rm -rf /node-config
(
  umask 077
  mkdir -p /node-config/qory
  cp /config/qory/qory.yaml /config/qory/runner.yaml /config/qory/access-key-secret /node-config/qory/
)

rm -rf /work
mkdir -p /work
cp -r /src/checkout /work/checkout
cd /work/checkout
git init --quiet --initial-branch main .
# The run's forge and repository labels come from the origin remote; nothing is fetched.
git remote add origin "https://${E2E_FORGE:?}/${E2E_REPOSITORY:?}.git"

export XDG_CONFIG_HOME=/node-config
qory harness compose
