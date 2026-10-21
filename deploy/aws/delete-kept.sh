#!/bin/sh
# Delete what a deleted stack of deploy/aws/apiary.yaml kept: its key secrets (none when it
# took them under Keys of a deleted stack), its log groups, and the snapshots its database
# left: the final one, and one for each database an update replaced. For a test stack
# only: a real install keeps them to restore from.
#
#   deploy/aws/delete-kept.sh qory-test --region <region>         # lists them, deletes nothing
#   deploy/aws/delete-kept.sh qory-test --region <region> --yes   # deletes them
#   deploy/aws/delete-kept.sh <stack ID> --yes                    # when another stack has or had that name
#
# The region is --region, else AWS_REGION, else AWS_DEFAULT_REGION; the aws command takes
# its credentials and AWS_PROFILE from the environment as it always does.
#
# It reads only what CloudFormation recorded for the stack, never a name it makes up: the
# resources the delete skipped, which are the ones the template keeps, and from the stack's
# events each ID its database instance had, with the times of that instance's delete. An
# instance's snapshot is the manual snapshot of it taken between those two times, whose name
# starts with the stack's name and "-snapshot-" as CloudFormation names one. CloudFormation
# answers for a deleted stack for 90 days after its delete.
#
# It refuses a stack that is not deleted, a name another stack has or had, and
# anything a stack that is not deleted still uses: a stack given these keys under Keys of a
# deleted stack, or this snapshot under Database snapshot to restore. After a delete it
# looks again, says what is left, and exits 1 if anything is.
set -eu

usage() {
	cat <<'EOF'
usage: delete-kept.sh <stack name or stack ID> [--region <region>] [--yes]

Lists what the deleted stack kept: its key secrets, its log groups and its database's
snapshots from the delete and from any replacement. With --yes, deletes them, which
cannot be undone.
EOF
}

stack=
region=${AWS_REGION:-${AWS_DEFAULT_REGION:-}}
yes=
while [ "$#" -gt 0 ]; do
	case "$1" in
	--yes) yes=1 ;;
	--region) [ "$#" -gt 1 ] || { usage >&2; exit 2; }; region=$2; shift ;;
	--region=*) region=${1#--region=} ;;
	-h | --help) usage; exit 0 ;;
	-*) echo "delete-kept: unknown option $1" >&2; usage >&2; exit 2 ;;
	*) [ -z "$stack" ] || { usage >&2; exit 2; }; stack=$1 ;;
	esac
	shift
done
[ -n "$stack" ] || { usage >&2; exit 2; }
[ -n "$region" ] || { echo "delete-kept: no region: pass --region, or set AWS_REGION" >&2; exit 2; }

tab=$(printf '\t')
err=$(mktemp)
trap 'rm -f "$err"' EXIT

# The aws command in the region, its output as text, its times in UTC. Its error goes to
# $err, and is printed when the call fails, unless the caller reads it first.
aws_() {
	TZ=UTC aws --region "$region" --output text "$@" 2>"$err"
}

fail() {
	echo "delete-kept: $*" >&2
	exit 1
}

# Called when an aws call failed for a reason the caller does not expect.
aws_failed() {
	cat "$err" >&2
	fail "the aws command failed: $*"
}

# Whether the failed call's error is that the item is not there: only the error code, as
# the aws command prints it, counts, never the word elsewhere in a message.
gone_error() {
	grep -q -e '^An error occurred (ResourceNotFoundException) ' -e '^An error occurred (DBSnapshotNotFound) ' \
		-e '^An error occurred (DBSnapshotNotFoundFault) ' "$err"
}

# --- The stack ---------------------------------------------------------------------------
# A stack name is letters, digits and hyphens; a stack ID is its ARN. Only these go into
# the queries below.
case "$stack" in
arn:*:cloudformation:*:stack/*/*) stack_id=$stack ;;
*[!A-Za-z0-9-]* | [!A-Za-z]*) fail "$stack is neither a stack name nor a stack ID" ;;
*) stack_id= ;;
esac

if [ -z "$stack_id" ]; then
	# Every stack of that name, deleted or not, newest first; the aws command reads every page.
	stacks=$(aws_ cloudformation list-stacks \
		--query "StackSummaries[?StackName=='$stack'].[StackId,StackStatus]") || aws_failed list-stacks
	[ -n "$stacks" ] || fail "no stack named $stack in $region, deleted or not, in the last 90 days"
	live=$(printf '%s\n' "$stacks" | awk -F "$tab" '$2 != "DELETE_COMPLETE"')
	deleted=$(printf '%s\n' "$stacks" | awk -F "$tab" '$2 == "DELETE_COMPLETE" { print $1 }')
	if [ -n "$live" ] && [ -z "$deleted" ]; then
		fail "stack $stack is not deleted ($(printf '%s\n' "$live" | cut -f2 | head -n 1)): delete it first"
	fi
	if [ -n "$live" ] || [ "$(printf '%s\n' "$deleted" | wc -l)" -gt 1 ]; then
		echo "delete-kept: another stack has or had the name $stack; pass the stack ID of the deleted one:" >&2
		printf '%s\n' "$stacks" | awk -F "$tab" '{ print "  " $1 "  " $2 }' >&2
		exit 1
	fi
	stack_id=$deleted
fi

status=$(aws_ cloudformation describe-stacks --stack-name "$stack_id" \
	--query 'Stacks[0].[StackStatus,StackName,DeletionTime]') || aws_failed describe-stacks
IFS=$tab read -r status name deleted_at <<EOF
$status
EOF
[ "$status" = DELETE_COMPLETE ] || fail "stack $stack_id is not deleted ($status)"
# The four key secrets are named <stack name>-<the stack ID's UUID>/..., the name a stack
# given these keys has under KeysFromStack.
keys_name=$name-${stack_id##*/}
echo "Stack $name, deleted $deleted_at"
echo "  $stack_id"

# --- What it kept ------------------------------------------------------------------------
# One line per item: its kind, then its ID. A kept resource of a type this script does not
# delete is listed as "other" and left alone, and so is a secret or log group not named for
# this stack's keys, or one with no ID.
items=
add() {
	items="$items$1$tab$2
"
}

skipped=$(aws_ cloudformation list-stack-resources --stack-name "$stack_id" \
	--query 'StackResourceSummaries[?ResourceStatus==`DELETE_SKIPPED`].[ResourceType,PhysicalResourceId]') ||
	aws_failed list-stack-resources
while IFS=$tab read -r type id; do
	case "$type" in
	'') ;;
	AWS::SecretsManager::Secret)
		case "$id" in
		*:secret:"$keys_name"/*) add secret "$id" ;;
		*) add other "$type $id" ;;
		esac ;;
	AWS::Logs::LogGroup)
		case "$id" in
		/qory/"$keys_name" | /qory/"$keys_name"/*) add log-group "$id" ;;
		*) add other "$type $id" ;;
		esac ;;
	*) add other "$type $id, a type this script does not delete" ;;
	esac
done <<EOF
$skipped
EOF

# The database's snapshots. Every ID the stack's database instance had is in the stack's
# events: the last one, deleted with the stack, and each one an update replaced, deleted
# in the update's clean-up. Each instance's snapshot is a manual snapshot of it taken after
# the newest delete began on it and before that delete completed. A snapshot taken by hand
# while the stack ran is older, and is left alone. A snapshot from the delete whose name
# CloudFormation did not give is listed and left alone too.
logical=$(aws_ cloudformation list-stack-resources --stack-name "$stack_id" \
	--query 'StackResourceSummaries[?ResourceType==`AWS::RDS::DBInstance`].LogicalResourceId') ||
	aws_failed list-stack-resources
prefix=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')-snapshot-
for resource in $logical; do
	case "$resource" in *[!A-Za-z0-9]*) fail "unexpected logical ID $resource" ;; esac
	# Newest first: an instance's first DELETE_IN_PROGRESS and first DELETE_COMPLETE here
	# are its newest. Each line: the instance's ID, then the two times, or None.
	events=$(aws_ cloudformation describe-stack-events --stack-name "$stack_id" \
		--query "StackEvents[?LogicalResourceId=='$resource' && ResourceType=='AWS::RDS::DBInstance'].[PhysicalResourceId,ResourceStatus,Timestamp]") ||
		aws_failed describe-stack-events
	windows=$(printf '%s\n' "$events" | awk -F "$tab" '
			$1 == "" || $1 == "None" { next }
			!($1 in seen) { seen[$1] = 1; order[++n] = $1; began[$1] = "None"; ended[$1] = "None" }
			$2 == "DELETE_IN_PROGRESS" && began[$1] == "None" { began[$1] = $3 }
			$2 == "DELETE_COMPLETE" && ended[$1] == "None" { ended[$1] = $3 }
			END { for (i = 1; i <= n; i++) print order[i] "\t" began[order[i]] "\t" ended[order[i]] }')
	while IFS=$tab read -r db began ended; do
		[ -n "$db" ] || continue
		case "$db" in *[!a-z0-9-]*) fail "unexpected database instance ID $db" ;; esac
		if [ "$began" = None ] || [ "$ended" = None ]; then
			echo "Database instance $db: the stack records no completed delete of it, so no snapshot from one."
			continue
		fi
		snapshots=$(aws_ rds describe-db-snapshots --db-instance-identifier "$db" --snapshot-type manual \
			--query 'DBSnapshots[].[DBSnapshotIdentifier,SnapshotCreateTime]') || aws_failed describe-db-snapshots
		# The times are ISO 8601 in UTC; their first 19 characters, to the second, compare as
		# text. Each line: "ok" or "name", then the snapshot's ID.
		found=$(printf '%s\n' "$snapshots" | awk -F "$tab" -v from="$(printf '%.19s' "$began")" \
			-v to="$(printf '%.19s' "$ended")" -v prefix="$prefix" '
			$1 != "" { t = substr($2, 1, 19); if (t >= from && t <= to) print (index($1, prefix) == 1 ? "ok" : "name") "\t" $1 }')
		named=$(printf '%s\n' "$found" | awk -F "$tab" '$1 == "ok" { print $2 }')
		while IFS=$tab read -r check id; do
			if [ "$check" = name ]; then add other "snapshot $id, taken during the delete of $db, but its name does not start with $prefix"; fi
		done <<EOF
$found
EOF
		case "$(printf '%s' "$named" | grep -c .)" in
		0) [ -n "$found" ] || echo "Database instance $db: no snapshot of $db from the stack's delete." ;;
		1) add snapshot "$named" ;;
		*) add other "more than one snapshot of $db from the stack's delete: $(printf '%s\n' "$named" | tr '\n' ' ')" ;;
		esac
	done <<EOF
$windows
EOF
done

# --- What a stack that is not deleted still uses -------------------------------------------
uses=$(aws_ cloudformation describe-stacks \
	--query 'Stacks[].[StackName, Parameters[?ParameterKey==`KeysFromStack`].ParameterValue | [0], Parameters[?ParameterKey==`DatabaseSnapshot`].ParameterValue | [0]]') ||
	aws_failed describe-stacks
# The aws command prints a parameter given "" as an empty field, and read takes a run of
# tabs as one, which would shift the fields after it: each empty field becomes None first.
uses=$(printf '%s\n' "$uses" | awk -F "$tab" -v OFS="$tab" '{ for (i = 1; i <= NF; i++) if ($i == "") $i = "None"; print }')
in_use=
while IFS=$tab read -r user keys snapshot; do
	[ -n "$user" ] || continue
	if [ "$keys" = "$keys_name" ]; then
		in_use="$in_use  $user uses the key secrets $keys_name
"
	fi
	# A snapshot's identifier is the same in any case.
	used=$(printf '%s' "${snapshot##*:}" | tr '[:upper:]' '[:lower:]')
	while IFS=$tab read -r kind id; do
		if [ "$kind" = snapshot ] && [ -n "$snapshot" ] &&
			[ "$used" = "$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')" ]; then
			in_use="$in_use  $user restored its database from the snapshot $id
"
		fi
	done <<EOF
$items
EOF
done <<EOF
$uses
EOF
if [ -n "$in_use" ]; then
	printf 'delete-kept: a stack that is not deleted still uses what %s kept; nothing deleted:\n%s' "$name" "$in_use" >&2
	exit 1
fi

# --- Exists, delete ------------------------------------------------------------------------
# The items this run deleted, and those whose delete failed. One line per item, as in $items.
removed=
failed=
# Whether the list $1 has the item of kind $2 and ID $3.
has() {
	case "
$1" in *"
$2$tab$3
"*) return 0 ;; esac
	return 1
}

# Succeeds when the item exists; fails when it is gone or being deleted. Any other error
# from the aws command stops the script, so an error never reads as gone.
exists() {
	case "$1" in
	secret)
		# A secret scheduled for deletion still answers, with its DeletedDate, and is there
		# until its window ends. Only this run's delete without recovery, which finishes a
		# little later, makes it gone while it answers.
		out=$(aws_ secretsmanager describe-secret --secret-id "$2" --query DeletedDate) ||
			{ gone_error && return 1; aws_failed describe-secret; }
		[ "$out" = None ] || ! has "$removed" secret "$2" ;;
	log-group)
		out=$(aws_ logs describe-log-groups --log-group-name-prefix "$2" \
			--query "logGroups[?logGroupName=='$2'].logGroupName") || aws_failed describe-log-groups
		[ -n "$out" ] ;;
	snapshot)
		out=$(aws_ rds describe-db-snapshots --db-snapshot-identifier "$2" --query 'DBSnapshots[0].Status') ||
			{ gone_error && return 1; aws_failed describe-db-snapshots; }
		[ "$out" != deleting ] ;;
	other) return 0 ;;
	esac
}

delete() {
	case "$1" in
	secret) aws_ secretsmanager delete-secret --secret-id "$2" --force-delete-without-recovery >/dev/null ;;
	log-group) aws_ logs delete-log-group --log-group-name "$2" ;;
	snapshot) aws_ rds delete-db-snapshot --db-snapshot-identifier "$2" >/dev/null ;;
	esac
}

if [ -z "$items" ]; then
	echo "It kept nothing this script finds."
	exit 0
fi

echo "What it kept:"
count=0
while IFS=$tab read -r kind id; do
	[ -n "$kind" ] || continue
	if [ "$kind" = other ]; then
		printf '  %-10s %s  (left alone)\n' "$kind" "$id"
	elif exists "$kind" "$id"; then
		printf '  %-10s %s\n' "$kind" "$id"
		count=$((count + 1))
	else
		printf '  %-10s %s  (already gone)\n' "$kind" "$id"
	fi
done <<EOF
$items
EOF

if [ -z "$yes" ]; then
	echo "Nothing deleted. To delete these $count, which cannot be undone, run again with --yes."
	exit 0
fi

while IFS=$tab read -r kind id; do
	case "$kind" in '' | other) continue ;; esac
	exists "$kind" "$id" || continue
	if delete "$kind" "$id"; then
		echo "Deleted $kind $id"
		removed="$removed$kind$tab$id
"
	elif gone_error; then
		echo "Already gone: $kind $id"
	else
		echo "Could not delete $kind $id:" >&2
		cat "$err" >&2
		failed="$failed$kind$tab$id
"
	fi
done <<EOF
$items
EOF

left=0
echo "Left:"
while IFS=$tab read -r kind id; do
	[ -n "$kind" ] || continue
	# An item whose delete failed is left, whatever the look says.
	if has "$failed" "$kind" "$id" || exists "$kind" "$id"; then
		printf '  %-10s %s\n' "$kind" "$id"
		left=$((left + 1))
	fi
done <<EOF
$items
EOF
if [ "$left" -gt 0 ]; then
	echo "$left left."
	exit 1
fi
echo "  nothing"
