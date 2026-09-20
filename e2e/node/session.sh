#!/bin/sh
# One session on the node: qory run, behind the wall the runner file names, reporting to
# the server the runner file names. The status is the session's.
set -eu
export XDG_CONFIG_HOME=/config
cd /work/checkout
exec qory run --headless
