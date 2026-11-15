#!/usr/bin/env bash
# Run the tests on a database that only this run uses, and drop the database when the run
# ends: passed, failed, or stopped by INT, TERM or HUP.
#
#   scripts/test-run.sh                                   # the whole suite
#   scripts/test-run.sh test/apiary/secrets_test.exs:42   # files, as mix test takes them
#   scripts/test-run.sh --only feature_sets               # any other option of mix test
#
# Each run sets MIX_TEST_PARTITION to run<start>p<pid>: the start time in seconds since
# 1970 and the script's process id. The run's database is apiary_test followed by that
# value (config/test.exs), for example apiary_testrun1763200000p4242.
#
# The suite drops the database as the VM exits, whether it passed or failed
# (Apiary.TestDatabase). This script drops it again, if it is still there, when mix test
# exits. On INT, TERM or HUP the script sends TERM to mix test, waits up to 60 seconds for
# it to stop (then sends KILL), drops the database, and exits with 128 plus the signal's
# number. Otherwise it exits with mix test's exit code.
#
# SIGKILL cannot be trapped. A script killed so leaves mix test running, and the suite
# drops the database when it ends; a mix test killed so leaves its database behind. At
# start the script drops each database left so: a name of the form
# apiary_testrun<digits>p<digits> whose start time is more than 24 hours old and which has
# no connection in pg_stat_activity. The script drops no database with another name.
#
# Limits, so that a test run leaves the machine usable for other work:
#   - mix test runs with --max-cases 4, and ERL_FLAGS gets "+S 4" (4 schedulers) and
#     "+Bi" (INT goes to the script, which stops mix test with TERM).
#   - A run with no test file is a full suite. Full suites run one at a time: a run waits
#     until it can create the lock directory APIARY_TEST_LOCK (default
#     $TMPDIR/apiary-test-full-suite.lock), and removes it when it ends.
#   - --repeat-until-failure takes test files and at most 20 repeats.
#   - Run the script in the foreground, one run at a time.
#
# Needs psql and the Postgres of config/test.exs: localhost:5432, user postgres, password
# postgres (or PGPASSWORD).
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2

say() { printf 'test-run: %s\n' "$*" >&2; }

# One statement, on the maintenance database, without notices such as "does not exist,
# skipping". DROP DATABASE cannot run inside a transaction, so each call sends one.
sql() {
	PGPASSWORD="${PGPASSWORD:-postgres}" PGOPTIONS="-c client_min_messages=warning" \
		psql -h localhost -p 5432 -U postgres -d postgres -X -q -A -t -v ON_ERROR_STOP=1 -c "$1"
}

pattern='^apiary_testrun[0-9]+p[0-9]+$'

if ! command -v psql >/dev/null 2>&1; then
	say "install psql, the Postgres client: the script drops the run's database with it"
	exit 2
fi

# The arguments: a test file makes the run targeted; --max-cases is the script's.
targeted=0
repeat=""
previous=""
for arg in "$@"; do
	case "$arg" in
	--max-cases | --max-cases=*)
		say "leave out --max-cases: the script runs mix test with --max-cases 4"
		exit 2
		;;
	--repeat-until-failure=*) repeat=${arg#*=} ;;
	esac
	[ "$previous" = "--repeat-until-failure" ] && repeat=$arg
	[ -f "${arg%%:*}" ] && targeted=1
	previous=$arg
done

if [ -n "$repeat" ]; then
	if [ "$targeted" -eq 0 ]; then
		say "give test files with --repeat-until-failure: repeats run on test files only"
		exit 2
	fi
	case "$repeat" in
	*[!0-9]*) ;;
	*)
		if [ "$repeat" -gt 20 ]; then
			say "repeat at most 20 times: --repeat-until-failure is $repeat"
			exit 2
		fi
		;;
	esac
fi

partition="run$(date +%s)p$$"
database="apiary_test$partition"
child=""
lock=""

# Drops this run's database if it is still there. A failed drop writes one warning line.
drop_database() {
	[[ "$database" =~ $pattern ]] || return 0
	if ! sql "DROP DATABASE IF EXISTS \"$database\" WITH (FORCE)" >/dev/null; then
		say "warning: drop the test database $database with psql: the drop at the end of the run failed"
	fi
}

cleanup() {
	drop_database
	if [ -n "$lock" ]; then
		rm -f "$lock/owner"
		rmdir "$lock" 2>/dev/null
	fi
}

stop() {
	trap '' INT TERM HUP
	say "SIG$1: stopping mix test"
	if [ -n "$child" ] && kill -0 "$child" 2>/dev/null; then
		kill -TERM "$child" 2>/dev/null
		for _ in $(seq 60); do
			kill -0 "$child" 2>/dev/null || break
			sleep 1
		done
		if kill -0 "$child" 2>/dev/null; then
			say "mix test still runs 60 seconds after TERM: sending KILL"
			kill -KILL "$child" 2>/dev/null
		fi
		wait "$child" 2>/dev/null
	fi
	exit $((128 + $2))
}

trap cleanup EXIT
trap 'stop INT 2' INT
trap 'stop TERM 15' TERM
trap 'stop HUP 1' HUP

# The databases of runs killed more than 24 hours ago, which nothing is connected to.
stale=$(sql "SELECT d.datname FROM pg_database d
	WHERE d.datname ~ '$pattern'
	AND substring(d.datname FROM '^apiary_testrun([0-9]+)p')::numeric
		< extract(epoch FROM now()) - 86400
	AND NOT EXISTS (SELECT 1 FROM pg_stat_activity a WHERE a.datname = d.datname)") ||
	say "warning: the list of test databases older than 24 hours failed; none dropped"
for name in $stale; do
	[[ "$name" =~ $pattern ]] || continue
	if sql "DROP DATABASE \"$name\"" >/dev/null; then
		say "dropped $name, left by a run that started more than 24 hours ago"
	else
		say "warning: $name, left by a run that started more than 24 hours ago, was not dropped"
	fi
done

if [ "$targeted" -eq 0 ]; then
	lock_dir=${APIARY_TEST_LOCK:-${TMPDIR:-/tmp}/apiary-test-full-suite.lock}
	until mkdir "$lock_dir" 2>/dev/null; do
		say "waiting for the full-suite lock $lock_dir, taken by: $(cat "$lock_dir/owner" 2>/dev/null)"
		sleep 30
	done
	lock=$lock_dir
	echo "scripts/test-run.sh, pid $$, in $(pwd), since $(date '+%Y-%m-%d %H:%M:%S')" >"$lock/owner"
fi

export MIX_ENV=test MIX_TEST_PARTITION="$partition"
export ERL_FLAGS="${ERL_FLAGS:+$ERL_FLAGS }+S 4 +Bi"
say "database $database"

# mix test runs as a child the script waits for, so that a signal reaches the trap at once.
mix test --max-cases 4 "$@" </dev/null &
child=$!
wait "$child"
status=$?
child=""
exit "$status"
