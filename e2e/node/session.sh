#!/bin/sh
# One session on the node: qory run, behind the wall the Forager file names, reporting to
# the server the Forager file names, signed with the access key whose secret is beside it,
# in the node's own copy of the configuration that prepare.sh made. qory keeps the run's
# record in its state directory on the node, root's ~/.local/state/qory/runs, outside the
# checkout, and names the run's folder when the run ends. The status is the session's.
set -eu
export XDG_CONFIG_HOME=/node-config
cd /work/checkout
exec qory run --headless
