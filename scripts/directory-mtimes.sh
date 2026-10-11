#!/usr/bin/env bash
# Give each directory of the checkout a modification time made from its contents, for CI's
# build cache.
#
#   scripts/directory-mtimes.sh
#
# Mix recompiles a module when one of its @external_resource files has a new modification
# time and new contents, and compares the digest it recorded to know. A directory has no
# digest: a module that names a directory, as Apiary.Kinds.Services names priv/services to
# see a definition added or removed, is recompiled whenever the directory's time changes,
# with every module that depends on it at compile time. A fresh checkout gives every
# directory the time of the checkout, so a restored build would recompile them on every
# run. Each directory tracked at HEAD instead takes a time made from its Git tree id, the
# id's first 32 bits modulo 10^9 seconds: the same contents give the same time, and other
# contents, all but certainly, another. The time is before 2002, as Mix resets a time in
# the future to the present.
set -euo pipefail

cd "$(dirname "$0")/.."

# The default -z output keeps a path as it is; a --format would quote one with a quote,
# a backslash, a newline or a character that is not ASCII.
git ls-tree -r -d -z HEAD |
	perl -0 -ne '
		chomp;
		my ($meta, $path) = split /\t/, $_, 2;
		my $tree = (split / /, $meta)[2];
		my $time = hex(substr($tree, 0, 8)) % 1_000_000_000;
		utime $time, $time, $path or die "$path: $!\n";
	'
