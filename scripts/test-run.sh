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
# value (config/test.exs), for example apiary_testrun1763200000p4242. Each run also gets a
# new TMPDIR under the current one, removed when the run ends: two runs that share a
# TMPDIR collide in test/support/public_git_server.ex.
#
# The suite drops the database as the VM exits, whether it passed or failed
# (Apiary.TestDatabase). This script drops it again, if it is still there, when mix test
# exits. On INT, TERM or HUP the script sends TERM to mix test, waits up to 60 seconds for
# it to stop (then sends KILL), drops the database, and exits with 128 plus the signal's
# number. Otherwise it exits with mix test's exit code.
#
# SIGKILL cannot be trapped. If SIGKILL stops the script, mix test keeps running and the
# suite drops the database at its end. If SIGKILL stops mix test, its database stays. At
# start the script drops each database left so: a name of the form
# apiary_testrun<digits>p<digits> whose start time is more than 24 hours old and which has
# no connection in pg_stat_activity. The script drops no database with another name.
#
# Limits, so that a test run leaves the machine usable for other work:
#   - mix test runs with --max-cases 4, and ERL_FLAGS gets "+S 4" (4 schedulers) and
#     "+Bi" (INT goes to the script, which stops mix test with TERM). The script refuses
#     --max-cases and --listen-on-stdin.
#   - A run with no test file is a full suite. Full suites run one at a time on the
#     machine: a run waits until it can create the lock directory APIARY_TEST_LOCK
#     (default /tmp/apiary-test-full-suite.lock), and removes it when it ends. The lock's
#     owner file lists the process ids of the script and of mix test, one per line. A lock
#     whose processes no longer run is removed. A lock with an empty or missing owner file
#     is being taken; it is removed once it is more than 60 seconds old.
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
	--listen-on-stdin)
		say "leave out --listen-on-stdin: the script runs mix test once, with no input"
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
	*) repeat=${repeat#"${repeat%%[!0]*}"} repeat=${repeat:-0} ;;
	esac
	case "$repeat" in
	*[!0-9]*) ;;
	???*)
		say "repeat at most 20 times: --repeat-until-failure is $repeat"
		exit 2
		;;
	*)
		if [ "$repeat" -gt 20 ]; then
			say "repeat at most 20 times: --repeat-until-failure is $repeat"
			exit 2
		fi
		;;
	esac
fi

lock_dir=${APIARY_TEST_LOCK:-/tmp/apiary-test-full-suite.lock}
break_dir="$lock_dir.break"
tmp_base=${TMPDIR:-/tmp}
tmp_base=${tmp_base%/}

database=""
child=""
lock=""
breaking=0
sleeper=""
run_tmp=""

# Drops this run's database if it is still there. A failed drop writes one warning line.
drop_database() {
	[[ "$database" =~ $pattern ]] || return 0
	if ! sql "DROP DATABASE IF EXISTS \"$database\" WITH (FORCE)" >/dev/null; then
		say "warning: drop the test database $database with psql: the drop at the end of the run failed"
	fi
}

cleanup() {
	if [ -n "$sleeper" ]; then
		kill "$sleeper" 2>/dev/null
	fi
	if [ "$breaking" -eq 1 ]; then
		rmdir "$break_dir" 2>/dev/null
	fi
	drop_database
	if [ -n "$run_tmp" ]; then
		rm -rf "$run_tmp"
	fi
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
	if sql "DROP DATABASE IF EXISTS \"$name\"" >/dev/null; then
		say "dropped $name, left by a run that started more than 24 hours ago"
	else
		say "warning: $name, left by a run that started more than 24 hours ago, was not dropped"
	fi
done

# The process ids in the lock's owner file, on one line: the lines that are only digits.
lock_pids() { grep -E '^[0-9]+$' "$lock_dir/owner" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }

# Whether a path was last changed more than 60 seconds ago.
older_than_a_minute() { [ -n "$(find "$1" -maxdepth 0 -mmin +1 2>/dev/null)" ]; }

# Removes a lock that a run stopped by SIGKILL left: one whose processes no longer run, or
# one with no process id in its owner file that is more than 60 seconds old (the run was
# stopped between taking the lock and writing the file). Returns:
#   0  it removed the lock;
#   1  a process of the lock runs;
#   2  another run is removing the lock;
#   3  the lock has no process id yet and is less than 60 seconds old: it is being taken;
#   4  the lock is stale but this user cannot remove it.
# The directory $break_dir lets one run at a time remove the lock: without it, a run could
# remove the lock that another run has just taken. A $break_dir older than 60 seconds was
# left by a killed run, and is removed. /tmp is shared by every user of the machine, so a
# process is checked with ps, which also finds another user's process.
break_stale_lock() {
	local pids pid removed=1
	pids=$(lock_pids)
	if [ -n "$pids" ]; then
		for pid in $pids; do
			ps -p "$pid" >/dev/null 2>&1 && return 1
		done
	elif ! older_than_a_minute "$lock_dir"; then
		return 3
	fi
	if ! mkdir "$break_dir" 2>/dev/null; then
		[ -d "$break_dir" ] || return 4
		if older_than_a_minute "$break_dir"; then
			rmdir "$break_dir" 2>/dev/null || return 4
		fi
		return 2
	fi
	breaking=1
	if [ "$(lock_pids)" = "$pids" ] && { [ -n "$pids" ] || older_than_a_minute "$lock_dir"; }; then
		rm -f "$lock_dir/owner" 2>/dev/null
		if rmdir "$lock_dir" 2>/dev/null; then
			if [ -n "$pids" ]; then
				say "removed the full-suite lock $lock_dir of processes $pids, which no longer run"
			else
				say "removed the full-suite lock $lock_dir, which had no owner for more than 60 seconds"
			fi
			removed=0
		else
			# Put the process ids back, so the next check finds the same stale lock.
			if [ -n "$pids" ]; then
				{ printf '%s\n' $pids >"$lock_dir/owner"; } 2>/dev/null
			fi
			removed=4
		fi
	fi
	rmdir "$break_dir" 2>/dev/null
	breaking=0
	return "$removed"
}

if [ "$targeted" -eq 0 ]; then
	said_fix=0
	until mkdir "$lock_dir" 2>/dev/null; do
		lock_parent=$(dirname "$lock_dir")
		if [ ! -d "$lock_parent" ] || [ ! -w "$lock_parent" ]; then
			say "create the directory $lock_parent or set APIARY_TEST_LOCK: the lock cannot be made"
			exit 2
		fi
		break_stale_lock
		case $? in
		0) continue ;;
		2) wait_seconds=1 ;;
		3)
			wait_seconds=30
			say "waiting for the full-suite lock $lock_dir, which has no owner yet: remove $lock_dir if no full suite runs"
			;;
		4)
			wait_seconds=30
			if [ "$said_fix" -eq 0 ]; then
				say "remove $lock_dir and $break_dir if no full suite runs: the lock is stale, and this user cannot remove it"
				said_fix=1
			fi
			;;
		*)
			wait_seconds=30
			say "waiting for the full-suite lock $lock_dir, taken by: $(grep -vE '^[0-9]+$' "$lock_dir/owner" 2>/dev/null)"
			;;
		esac
		# In the background, so that a signal reaches the trap at once; cleanup stops it.
		sleep "$wait_seconds" >/dev/null 2>&1 &
		sleeper=$!
		wait "$sleeper"
		sleeper=""
	done
	if ! { printf '%s\nscripts/test-run.sh, pid %s, in %s, since %s\n' "$$" "$$" "$(pwd)" \
		"$(date '+%Y-%m-%d %H:%M:%S')" >"$lock_dir/owner"; } 2>/dev/null; then
		rm -f "$lock_dir/owner" 2>/dev/null
		rmdir "$lock_dir" 2>/dev/null
		say "make $lock_dir writable or set APIARY_TEST_LOCK: the lock's owner file cannot be written"
		exit 2
	fi
	lock=$lock_dir
fi

partition="run$(date +%s)p$$"
database="apiary_test$partition"
run_tmp=$(mktemp -d "$tmp_base/apiary-test-run.XXXXXX") || {
	say "create a writable TMPDIR: mktemp -d under $tmp_base failed"
	exit 2
}

export MIX_ENV=test MIX_TEST_PARTITION="$partition" TMPDIR="$run_tmp/"
export ERL_FLAGS="${ERL_FLAGS:+$ERL_FLAGS }+S 4 +Bi"
say "database $database"

# mix test runs as a child the script waits for, so that a signal reaches the trap at once.
mix test --max-cases 4 "$@" </dev/null &
child=$!
# The lock stays live while mix test runs, also if SIGKILL stops the script.
if [ -n "$lock" ]; then
	echo "$child" >>"$lock/owner"
fi
wait "$child"
status=$?
child=""
exit "$status"
