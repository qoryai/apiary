#!/usr/bin/env bash
# The end to end job of live reload (F3), and of a deny that holds under observe. See
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
#   RUNNER_SRC          a checkout of qoryai/runner to build it with, when the module it
#                       names cannot be fetched                       (default none)
#   E2E_QORY            a static Linux build of qory, instead of building one
#   E2E_DATABASE_URL    (default ecto://postgres:postgres@localhost:5432/apiary_e2e)
#   E2E_PORT            the test instance's port                      (default 4180)
#   E2E_WORK            (default tmp/e2e under the repository)
#   E2E_RETRY_SECONDS   how often the session asks for the host       (default 3)
#   E2E_LEVEL           repository or hive: where the row's rule goes (default repository)
#   E2E_BUDGET_SECONDS  (default 35)
set -euo pipefail

runs="${1:-1}"
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
cd "$root"

export E2E_WORK="${E2E_WORK:-$root/tmp/e2e}"
export E2E_PORT="${E2E_PORT:-4180}"
export E2E_TARGET_HOST="${E2E_TARGET_HOST:-files.e2e.test}"
export E2E_FORGE="${E2E_FORGE:-git.e2e.test}"
export E2E_REPOSITORY="${E2E_REPOSITORY:-acme/shop}"
export E2E_RETRY_SECONDS="${E2E_RETRY_SECONDS:-3}"
export E2E_BUDGET_SECONDS="${E2E_BUDGET_SECONDS:-35}"
export E2E_LEVEL="${E2E_LEVEL:-repository}"
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

# --- qory, built for the node: Linux, the engine's architecture, static -----------------
mkdir -p "$E2E_WORK"
if [ -z "${E2E_QORY:-}" ]; then
  qory_src="${QORY_SRC:-$root/../../qory/main}"
  [ -f "$qory_src/go.mod" ] || { echo "no qory source at $qory_src; set QORY_SRC or E2E_QORY" >&2; exit 2; }
  arch="$(docker version --format '{{.Server.Arch}}')"
  say "building qory for linux/$arch from $(git -C "$qory_src" rev-parse --short HEAD)"
  if command -v go >/dev/null 2>&1; then go=(go); else go=(mise x -- go); fi
  modfile=()
  if [ -n "${RUNNER_SRC:-}" ]; then
    # The module file is copied and the copy edited: the checkout stays as it is.
    mkdir -p "$E2E_WORK/mod"
    cp "$qory_src/go.mod" "$qory_src/go.sum" "$E2E_WORK/mod/"
    (cd "$qory_src" && GOWORK=off "${go[@]}" mod edit -modfile="$E2E_WORK/mod/go.mod" -replace "github.com/qoryai/runner=$(cd "$RUNNER_SRC" && pwd)")
    modfile=(-modfile="$E2E_WORK/mod/go.mod")
    echo "   with the runner at $(git -C "$RUNNER_SRC" rev-parse --short HEAD)"
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
export MAIL_TO_LOG=true
SECRET_KEY_BASE="$(openssl rand -base64 48)"
CLOAK_KEY="$(openssl rand -base64 32)"
export SECRET_KEY_BASE CLOAK_KEY

say "compiling the test instance"
"${mix[@]}" compile

cleanup() {
  "${compose[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
  "${mix[@]}" ecto.drop --force --force-drop --quiet </dev/null >/dev/null 2>&1 || true
  rm -rf "$E2E_WORK/config" "$E2E_WORK/tls" "$E2E_WORK/runner-tail.yaml"
}
trap cleanup EXIT

docker image inspect "$wall_image" >/dev/null 2>&1 || docker pull --quiet "$wall_image"

one_run() {
  local n="$1" log="$E2E_WORK/run-$1.log"
  say "run $n of $runs"
  rm -f "$E2E_WORK/session-$n.log" "$log"
  cleanup

  mkdir -p "$E2E_WORK/config/qory" "$E2E_WORK/tls"
  # The node's own qory configuration: how the runtime is started, and the part of the
  # runner file that is not the server's. The scenario writes the file, server block first.
  cat >"$E2E_WORK/config/qory/qory.yaml" <<YAML
apiVersion: qory.dev/v1alpha1
harness:
  launch:
    claude:
      command: /work/checkout/bin/fake-runtime
YAML
  cat >"$E2E_WORK/runner-tail.yaml" <<YAML
wall:
  adapter: docker
  image: $wall_image
  user: "1000:1000"
  env: [E2E_TARGET_URL, E2E_RETRY_SECONDS, E2E_THEN_DENIED]
YAML
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$E2E_TARGET_HOST" \
    -keyout "$E2E_WORK/tls/target.key" -out "$E2E_WORK/tls/target.crt" >/dev/null 2>&1
  chmod 644 "$E2E_WORK/tls/target.key"

  "${mix[@]}" ecto.create --quiet

  "${compose[@]}" up --detach --build --quiet-pull
  "${compose[@]}" exec -T node sh -c 'until docker info >/dev/null 2>&1; do sleep 0.5; done'
  docker save "$wall_image" | "${compose[@]}" exec -T node docker load >/dev/null
  # The server contract lets a runner speak plain http to a loopback address only, so
  # the node reaches the test instance as 127.0.0.1, the way a tunnel would bring it.
  "${compose[@]}" exec --detach node socat "TCP-LISTEN:$E2E_PORT,bind=127.0.0.1,fork,reuseaddr" "TCP:host.docker.internal:$E2E_PORT"

  export E2E_RUNNER_FILE="$E2E_WORK/config/qory/runner.yaml"
  export E2E_RUNNER_TAIL="$E2E_WORK/runner-tail.yaml"
  export E2E_SESSION_LOG="$E2E_WORK/session-$n.log"
  export E2E_PREPARE_COMMAND="${compose[*]} exec -T -e E2E_PORT -e E2E_FORGE -e E2E_REPOSITORY node /e2e/prepare.sh"
  export E2E_SESSION_COMMAND="${compose[*]} exec -T -e E2E_TARGET_URL=https://$E2E_TARGET_HOST/ -e E2E_RETRY_SECONDS -e E2E_THEN_DENIED=1 node /e2e/session.sh"

  local status=0
  "${mix[@]}" run e2e/scenario.exs 2>&1 | tee "$log" || status=$?

  echo
  echo "-- the session's own output"
  sed 's/^/   /' "$E2E_SESSION_LOG" 2>/dev/null || true
  return "$status"
}

failed=0
for n in $(seq 1 "$runs"); do
  one_run "$n" || failed=$((failed + 1))
done

say "summary"
grep -h '^E2E ' "$E2E_WORK"/run-*.log || true
[ "$failed" -eq 0 ] || { echo "$failed of $runs runs failed"; exit 1; }
