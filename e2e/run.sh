#!/usr/bin/env bash
# The end to end job of live reload, and of a deny that holds under observe, on an instance
# without mail; then, on Linux, of the mailed way in, on an instance whose mail goes to the
# job's SMTP sink. Each instance is set up with the set-up link its start logged. See
# e2e/README.md for what it proves.
#
#   e2e/run.sh            one run
#   e2e/run.sh 3          three runs, each on a fresh database and a fresh node
#
# What it needs: docker with compose, openssl, the toolchain of mise.toml (mix on PATH, or
# mise), a Postgres it may create and drop one database on, and the source of qory, with
# Go to build it. Everything it writes is under E2E_WORK, and nothing of it is this
# user's own qory configuration: the node has its own, under XDG_CONFIG_HOME.
#
#   QORY_SRC            the checkout of qoryai/qory to build          (default ../../qory/main)
#   FORAGER_SRC         a checkout of qoryai/forager to build it with, when the module it
#                       names cannot be fetched                       (default none)
#   E2E_QORY            a static Linux build of qory, instead of building one
#   E2E_DATABASE_URL    (default ecto://postgres:postgres@localhost:5432/apiary_e2e)
#   E2E_PORT            the test instance's port                      (default 4180)
#   E2E_WORK            (default tmp/e2e under the repository)
#   E2E_RETRY_SECONDS   how often the session asks for the host       (default 3)
#   E2E_LEVEL           target or workspace: where the row's rule goes (default target)
#   E2E_BUDGET_SECONDS  (default 35)
set -euo pipefail

runs="${1:-1}"
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
cd "$root"

export E2E_WORK="${E2E_WORK:-$root/tmp/e2e}"
export E2E_PORT="${E2E_PORT:-4180}"
export E2E_UPSTREAM_HOST="${E2E_UPSTREAM_HOST:-files.e2e.test}"
export E2E_FORGE="${E2E_FORGE:-git.e2e.test}"
export E2E_REPOSITORY="${E2E_REPOSITORY:-acme/shop}"
export E2E_RETRY_SECONDS="${E2E_RETRY_SECONDS:-3}"
export E2E_BUDGET_SECONDS="${E2E_BUDGET_SECONDS:-35}"
export E2E_LEVEL="${E2E_LEVEL:-target}"
database_url="${E2E_DATABASE_URL:-ecto://postgres:postgres@localhost:5432/apiary_e2e}"
wall_image="${E2E_WALL_IMAGE:-curlimages/curl:8.16.0}"

# The job drops its database before and after. It is never somebody's.
case "$database_url" in
  *_e2e) ;;
  *) echo "E2E_DATABASE_URL must name a database ending in _e2e; the job drops it" >&2; exit 2 ;;
esac

if command -v mix >/dev/null 2>&1; then mix=(mix); else mix=(mise x -- mix); fi
compose=(docker compose -f "$here/compose.yaml")

say() { printf '\n== %s\n' "$*"; }

# How long the job waits for each of its machines before it gives up on that one, and the
# waits between the attempts of a pull: four attempts, 5, 15 and 45 seconds apart.
node_engine_seconds=120
sink_seconds=60
retry_waits=(5 15 45)

# Runs a command until it succeeds, once more after each of retry_waits. Each failure is
# logged, with the command's own error above it; after the last, it fails with that one's status.
retry() {
  local attempt=1 attempts=$((${#retry_waits[@]} + 1)) status
  while true; do
    status=0
    "$@" || status=$?
    [ "$status" -eq 0 ] && return 0
    if [ "$attempt" -ge "$attempts" ]; then
      echo "attempt $attempt of $attempts failed (exit $status), giving up: $*" >&2
      return "$status"
    fi
    echo "attempt $attempt of $attempts failed (exit $status), again in ${retry_waits[$((attempt - 1))]}s: $*" >&2
    sleep "${retry_waits[$((attempt - 1))]}"
    attempt=$((attempt + 1))
  done
}

# Asks a command every half second until it succeeds, for at most the given seconds; then
# says what it waited for, and fails.
wait_for() {
  local seconds="$1" what="$2"
  shift 2
  local deadline=$((SECONDS + seconds))
  until "$@" >/dev/null 2>&1; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "gave up after ${seconds}s waiting for $what" >&2
      return 1
    fi
    sleep 0.5
  done
}

# What the job's machines are and what they printed, for the job's log when one of them
# did not come up: all of them, or the ones named.
show_machines() {
  echo "-- docker compose ps"
  "${compose[@]}" ps --all || true
  echo "-- docker compose logs ${*:-(all)}"
  "${compose[@]}" logs --no-color --tail 200 "$@" || true
}

# --- qory, built for the node: Linux, the engine's architecture, static -----------------
mkdir -p "$E2E_WORK"
if [ -z "${E2E_QORY:-}" ]; then
  qory_src="${QORY_SRC:-$root/../../qory/main}"
  [ -f "$qory_src/go.mod" ] || { echo "no qory source at $qory_src; set QORY_SRC or E2E_QORY" >&2; exit 2; }
  arch="$(docker version --format '{{.Server.Arch}}')"
  say "building qory for linux/$arch from $(git -C "$qory_src" rev-parse --short HEAD)"
  if command -v go >/dev/null 2>&1; then go=(go); else go=(mise x -- go); fi
  modfile=()
  if [ -n "${FORAGER_SRC:-}" ]; then
    # The module file is copied and the copy edited: the checkout stays as it is.
    mkdir -p "$E2E_WORK/mod"
    cp "$qory_src/go.mod" "$qory_src/go.sum" "$E2E_WORK/mod/"
    (cd "$qory_src" && GOWORK=off "${go[@]}" mod edit -modfile="$E2E_WORK/mod/go.mod" -replace "github.com/qoryai/forager=$(cd "$FORAGER_SRC" && pwd)")
    modfile=(-modfile="$E2E_WORK/mod/go.mod")
    echo "   with Forager at $(git -C "$FORAGER_SRC" rev-parse --short HEAD)"
  fi
  (cd "$qory_src" && GOWORK=off CGO_ENABLED=0 GOOS=linux GOARCH="$arch" "${go[@]}" build ${modfile[@]+"${modfile[@]}"} -o "$E2E_WORK/qory" .)
  export E2E_QORY="$E2E_WORK/qory"
fi

# --- the test instance's own settings: production's, on a database and a port of its own
export MIX_ENV=prod
export DATABASE_URL="$database_url"
export PORT="$E2E_PORT"
export PUBLIC_URL="http://127.0.0.1:$E2E_PORT"
export PHX_SERVER=true
# No mail of this shell's: the first instance has none, and the mailed one is given the
# sink's below.
unset SMTP_RELAY SMTP_PORT SMTP_USERNAME SMTP_PASSWORD SMTP_TLS MAIL_FROM
# Each secret is a fresh random value of its own, never derived from another. The signing
# secret is the seed of the key the instance signs its answers with, the key the node pins
# as apiary_public_key; the instance refuses at boot the Forager contract's fixture seeds,
# whose keys qory refuses as a pin.
SECRET_KEY_BASE="$(openssl rand -base64 48)"
APIARY_ENCRYPTION_SECRET="$(openssl rand -base64 32)"
APIARY_SIGNING_SECRET="$(openssl rand -base64 32)"
export SECRET_KEY_BASE APIARY_ENCRYPTION_SECRET APIARY_SIGNING_SECRET

say "compiling the test instance"
"${mix[@]}" compile

cleanup() {
  "${compose[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
  "${mix[@]}" ecto.drop --force --force-drop --quiet </dev/null >/dev/null 2>&1 || true
  rm -rf "$E2E_WORK/config" "$E2E_WORK/tls" "$E2E_WORK/forager-tail.yaml"
}
trap cleanup EXIT

# The job's images are pulled here, each pull tried again after a wait when it fails, as a
# registry that limits pulls without a login answers at times, so that starting the
# machines need not pull. The node's base image is pulled by its build.
if ! docker image inspect "$wall_image" >/dev/null 2>&1; then
  retry docker pull --quiet "$wall_image" || { echo "could not pull the wall's image $wall_image" >&2; exit 1; }
fi
retry "${compose[@]}" pull --quiet --ignore-buildable || { echo "could not pull the images of the job's machines" >&2; exit 1; }
retry "${compose[@]}" build --quiet || { echo "could not build the node" >&2; exit 1; }

one_run() {
  local n="$1" log="$E2E_WORK/run-$1.log" mail_log="$E2E_WORK/run-$1-mail.log"
  say "run $n of $runs"
  rm -f "$E2E_WORK/session-$n.log" "$log" "$mail_log"
  cleanup

  mkdir -p "$E2E_WORK/config/qory" "$E2E_WORK/tls"
  # The node's qory configuration: how the runtime is started, and the part of the Forager
  # file that is not the gateway's. The scenario writes the file, the gateway's server
  # section first, and the access key's secret beside it, access-key-secret, in this
  # directory, mode 0700; node/prepare.sh copies the three into the node.
  cat >"$E2E_WORK/config/qory/qory.yaml" <<YAML
apiVersion: qory.dev/v1alpha1
harness:
  launch:
    claude:
      command: /work/checkout/bin/fake-runtime
YAML
  cat >"$E2E_WORK/forager-tail.yaml" <<YAML
wall:
  adapter: docker
  image: $wall_image
  user: "1000:1000"
  env: [E2E_UPSTREAM_URL, E2E_RETRY_SECONDS, E2E_THEN_DENIED]
YAML
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$E2E_UPSTREAM_HOST" \
    -keyout "$E2E_WORK/tls/upstream.key" -out "$E2E_WORK/tls/upstream.crt" >/dev/null 2>&1
  chmod 644 "$E2E_WORK/tls/upstream.key"

  "${mix[@]}" ecto.create --quiet

  # one_run is called as the left side of ||, where set -e does not stop the script, so
  # the start of the machines, and each wait for one of them, is checked here.
  if ! "${compose[@]}" up --detach --build --quiet-pull; then
    echo "the job's machines did not start" >&2
    show_machines
    return 1
  fi
  wait_for "$node_engine_seconds" "the node's container engine" \
    "${compose[@]}" exec -T node docker info || { show_machines node; return 1; }
  wait_for "$sink_seconds" "the SMTP sink" \
    "${compose[@]}" exec -T sink /mailpit readyz || { show_machines sink; return 1; }
  docker save "$wall_image" | "${compose[@]}" exec -T node docker load >/dev/null
  # The server contract lets the gateway speak plain http to a loopback address only, so
  # the node reaches the test instance as 127.0.0.1, the way a tunnel would bring it.
  # The host behind the tunnel: on Linux the host's own address on the node's network,
  # since host.docker.internal there is the default bridge, whose traffic the engine
  # keeps apart from this one; on a Mac the engine's name for the host.
  case "$(uname -s)" in
    Linux) host_from_node="$(docker network inspect apiary-e2e_outside --format '{{(index .IPAM.Config 0).Gateway}}')" ;;
    *) host_from_node=host.docker.internal ;;
  esac
  "${compose[@]}" exec --detach node socat "TCP-LISTEN:$E2E_PORT,bind=127.0.0.1,fork,reuseaddr" "TCP:$host_from_node:$E2E_PORT"

  export E2E_FORAGER_FILE="$E2E_WORK/config/qory/forager.yaml"
  export E2E_FORAGER_TAIL="$E2E_WORK/forager-tail.yaml"
  export E2E_SESSION_LOG="$E2E_WORK/session-$n.log"
  export E2E_PREPARE_COMMAND="${compose[*]} exec -T -e E2E_PORT -e E2E_FORGE -e E2E_REPOSITORY node /e2e/prepare.sh"
  export E2E_SESSION_COMMAND="${compose[*]} exec -T -e E2E_UPSTREAM_URL=https://$E2E_UPSTREAM_HOST/ -e E2E_RETRY_SECONDS -e E2E_THEN_DENIED=1 node /e2e/session.sh"

  # The instance's output, its log, goes to the file the scenario reads the set-up link
  # from, as a person reads it from `docker compose logs apiary`.
  local status=0
  E2E_MAIL=none E2E_INSTANCE_LOG="$log" "${mix[@]}" run e2e/scenario.exs 2>&1 | tee "$log" || status=$?

  echo
  echo "-- the session's own output"
  sed 's/^/   /' "$E2E_SESSION_LOG" 2>/dev/null || true

  # The mailed way in, on a fresh database: the instance's mail goes over SMTP to the
  # sink, which publishes no port, so the instance reaches it at its address on the job's
  # network. A Linux host routes to that address; a Mac's engine does not, and there this
  # part is left out, and says so.
  say "run $n of $runs: with mail, through the sink"
  if [ "$(uname -s)" = Linux ]; then
    local sink_address
    sink_address="$(docker inspect --format '{{(index .NetworkSettings.Networks "apiary-e2e_outside").IPAddress}}' "$("${compose[@]}" ps -q sink)")"
    "${mix[@]}" ecto.drop --force --force-drop --quiet
    "${mix[@]}" ecto.create --quiet
    SMTP_RELAY="$sink_address" SMTP_PORT=1025 SMTP_TLS=never \
      E2E_MAIL=sink E2E_INSTANCE_LOG="$mail_log" \
      E2E_SINK_COMMAND="${compose[*]} exec -T sink wget -qO- http://127.0.0.1:8025/api/v1/" \
      "${mix[@]}" run e2e/scenario.exs 2>&1 | tee "$mail_log" || status=$?
  else
    echo "   left out: on $(uname -s) the host does not reach the sink's address on the job's network"
  fi
  return "$status"
}

failed=0
for n in $(seq 1 "$runs"); do
  one_run "$n" || failed=$((failed + 1))
done

say "summary"
grep -h '^E2E ' "$E2E_WORK"/run-*.log || true
[ "$failed" -eq 0 ] || { echo "$failed of $runs runs failed"; exit 1; }
