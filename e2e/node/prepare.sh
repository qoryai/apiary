#!/bin/sh
# Makes the node ready for a session: the engine up, the apiary answering on a loopback port, the
# checkout in place with an origin remote and its harness composed.
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

rm -rf /work
mkdir -p /work
cp -r /src/checkout /work/checkout
cd /work/checkout
git init --quiet --initial-branch main .
# The run's forge and repository labels come from the origin remote; nothing is fetched.
git remote add origin "https://${E2E_FORGE:?}/${E2E_REPOSITORY:?}.git"

export XDG_CONFIG_HOME=/config
qory harness compose
