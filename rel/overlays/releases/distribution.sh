# How the release runs Erlang distribution. Sourced, never run: by releases/<version>/env.sh
# (rel/env.sh.eex), which the release script bin/apiary sources before every command, and
# by bin/server before it starts the release, which sets RELEASE_ROOT first. POSIX sh. It
# sets variables and writes the cookie to a file, or stops the command.
#
# Without DNS_CLUSTER_QUERY, distribution is off (RELEASE_DISTRIBUTION=none): no epmd and
# no distribution port. `eval`, which bin/migrate and every Apiary.Release task use,
# starts no distribution in any case and works as before. `rpc`, `remote`, `stop`,
# `restart` and `pid` reach the running node over distribution, so with it off they
# cannot work.
#
# With DNS_CLUSTER_QUERY, the nodes cluster through DNSCluster, which needs long names:
# RELEASE_DISTRIBUTION=name, and the node is <release name>@<the first IPv4 address of this
# host's name that is not a loopback address> unless RELEASE_NODE names it. Every node
# needs the same RELEASE_COOKIE: a command that starts distribution stops without it.
# `eval` and `version` start none and run without it.
#
# The cookie in releases/COOKIE, which every copy of the image holds, is never used: when
# RELEASE_COOKIE is not set and the command goes on, it is set to a new random value for
# that command. A node that an Erlang option starts anyway (-sname or -name in
# ELIXIR_ERL_OPTIONS, ERL_FLAGS, ERL_AFLAGS, ERL_ZFLAGS or a RELEASE_VM_ARGS file) then has
# a cookie no one else knows.
#
# The cookie never reaches a command line, where anyone on the host who can list processes
# could read it. The release script passes RELEASE_COOKIE to the elixir script as
# --cookie, which becomes -setcookie on the command line of the Erlang VM, the beam. So for
# every command but `version`, the cookie is written to .erlang.cookie, mode 0400, in a new
# directory that mktemp makes under RELEASE_TMP (by default tmp/ of the release), mode 0700;
# HOME is set to that directory, and RELEASE_COOKIE to the word -release_cookie_in_home.
# RELEASE_TMP is made, when missing, under umask 077, and a relative RELEASE_TMP is taken
# as the absolute path it names, so HOME is absolute.
# The beam then gets "-setcookie -release_cookie_in_home": a -setcookie with no value,
# which the kernel's auth module ignores, and a flag nothing reads. With no -setcookie
# value, auth reads the cookie from $HOME/.erlang.cookie, which it accepts only when its
# mode gives no one but its owner any access, and only as printable ASCII on one line:
# openssl rand -hex 32 or openssl rand -base64 32 gives one (-base64 breaks its output into
# lines above 48 bytes). The value is written with printf, a shell builtin, so it is in no
# command's arguments, and the beam's environment holds only the word. The shell opens the
# file with noclobber set, which refuses a regular file that is there already, or a
# symbolic link to nothing; it does not refuse every file. What keeps other users from
# placing anything there is the directory: mktemp makes it new, mode 0700.
#
# bin/server sources this file and then starts bin/apiary, whose env.sh sources it again:
# RELEASE_COOKIE set to the word means the cookie was written already only when HOME is a
# directory named apiary-cookie.<random> directly in RELEASE_TMP, owned by this user, and
# holds .erlang.cookie, a file owned by this user, neither of them a symbolic link: what
# mktemp and printf made. The word set any other way counts as no RELEASE_COOKIE: with
# DNS_CLUSTER_QUERY a command that starts distribution stops, and any other command gets a
# random cookie.

distribution_marker=-release_cookie_in_home
distribution_written=
distribution_tmp=${RELEASE_TMP:-$RELEASE_ROOT/tmp}

if [ "${RELEASE_COOKIE:-}" = "$distribution_marker" ]; then
  distribution_resolved=$(CDPATH='' cd -P -- "$distribution_tmp" 2>/dev/null && pwd -P) ||
    distribution_resolved=

  case ${HOME:-} in
  "$distribution_resolved"/apiary-cookie.*)
    if [ -n "$distribution_resolved" ] && [ "${HOME%/*}" = "$distribution_resolved" ] &&
      [ ! -L "$HOME" ] && [ -d "$HOME" ] && [ -O "$HOME" ] &&
      [ ! -L "$HOME/.erlang.cookie" ] && [ -f "$HOME/.erlang.cookie" ] &&
      [ -O "$HOME/.erlang.cookie" ]; then
      distribution_written=yes
    fi
    ;;
  esac

  if [ -z "$distribution_written" ]; then
    RELEASE_COOKIE=
  fi
fi

if [ -z "${DNS_CLUSTER_QUERY:-}" ]; then
  RELEASE_DISTRIBUTION=none
  export RELEASE_DISTRIBUTION
else
  RELEASE_DISTRIBUTION=name
  export RELEASE_DISTRIBUTION

  case ${RELEASE_COMMAND:-} in
  start | start_iex | daemon | daemon_iex | remote | rpc | restart | stop | pid)
    if [ -z "${RELEASE_COOKIE:-}" ]; then
      echo "DNS_CLUSTER_QUERY is set, so RELEASE_COOKIE must be set too: one secret value, the same on every node. Set it, or unset DNS_CLUSTER_QUERY to run one node." >&2
      exit 1
    fi

    # bin/server starts bin/apiary, so the name is apiary when the release script has not
    # set it yet. getent prints one address a line, first; a loopback address names no
    # node the others can reach.
    if [ -z "${RELEASE_NODE:-}" ]; then
      distribution_lines=$(getent ahostsv4 "$(uname -n)" 2>/dev/null) || distribution_lines=
      distribution_address=
      distribution_loopback=

      while read -r distribution_word distribution_rest; do
        case $distribution_word in
        127.*) distribution_loopback=yes ;;
        ?*)
          distribution_address=$distribution_word
          break
          ;;
        esac
      done <<EOF
$distribution_lines
EOF

      if [ -z "$distribution_address" ] && [ -n "$distribution_loopback" ]; then
        echo "DNS_CLUSTER_QUERY is set, and this host's name resolves only to a loopback address. Set RELEASE_NODE to ${RELEASE_NAME:-apiary}@<address>, with the address the other nodes reach this one at." >&2
        exit 1
      fi

      if [ -z "$distribution_address" ]; then
        echo "DNS_CLUSTER_QUERY is set, and no IPv4 address of this host was found for the node's name. Set RELEASE_NODE to ${RELEASE_NAME:-apiary}@<address>, with the address the other nodes reach this one at." >&2
        exit 1
      fi

      RELEASE_NODE=${RELEASE_NAME:-apiary}@$distribution_address
      export RELEASE_NODE
    fi
    ;;
  esac
fi

# Any command that goes on without RELEASE_COOKIE: without DNS_CLUSTER_QUERY, every one;
# with it, eval and version. Two hex digits for each of 32 random bytes, or the command
# stops: it never goes on with an empty cookie, which would make the release script read
# releases/COOKIE.
if [ -z "${RELEASE_COOKIE:-}" ]; then
  RELEASE_COOKIE=$(od -An -N32 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') || RELEASE_COOKIE=

  if [ "${#RELEASE_COOKIE}" -ne 64 ]; then
    echo "No random Erlang cookie could be made from /dev/urandom. Set RELEASE_COOKIE to a long random value." >&2
    exit 1
  fi

  export RELEASE_COOKIE
fi

# The cookie out of every command line, as the head of this file says. A directory or file
# that cannot be made stops the command with one line: the directory, RELEASE_TMP or the
# one mktemp made, and the reason the failed command gave, what follows the last ": " of
# its first line, or the command's name when it printed none. That command is mkdir, cd,
# mktemp, the shell that opens the file, the printf builtin that writes it, or chmod. No
# external command is given the cookie. The printf builtin is, but its error, like the
# others', names a file or a reason and never the value written, so the reason cannot hold
# the cookie.
distribution_fail() {
  distribution_reason=${2%%"$distribution_newline"*}
  distribution_reason=${distribution_reason##*: }
  printf 'Cannot write the Erlang cookie to %s: %s. RELEASE_TMP has to be writable by the release user.\n' \
    "$1" "${distribution_reason:-$3}" >&2
  exit 1
}

distribution_newline='
'

# umask 077 and noclobber are set only in the subshells of the steps that need them, so the
# umask of the command is kept.
if [ -z "$distribution_written" ] && [ "${RELEASE_COMMAND:-}" != version ]; then
  distribution_output=$(umask 077 && mkdir -p "$distribution_tmp" 2>&1) ||
    distribution_fail "$distribution_tmp" "$distribution_output" mkdir

  distribution_output=$(CDPATH='' cd -P -- "$distribution_tmp" 2>&1 && pwd -P) ||
    distribution_fail "$distribution_tmp" "$distribution_output" cd
  distribution_tmp=$distribution_output

  # mktemp prints the directory it made, or only its error.
  distribution_output=$(umask 077 && mktemp -d "$distribution_tmp/apiary-cookie.XXXXXXXX" 2>&1) ||
    distribution_fail "$distribution_tmp" "$distribution_output" mktemp
  distribution_home=$distribution_output

  # printf writes to the file; only the shell's error reaches the output.
  distribution_output=$( (umask 077 && set -C && printf '%s' "$RELEASE_COOKIE" >"$distribution_home/.erlang.cookie") 2>&1) ||
    distribution_fail "$distribution_home" "$distribution_output" "the shell"
  distribution_output=$(chmod 0400 "$distribution_home/.erlang.cookie" 2>&1) ||
    distribution_fail "$distribution_home" "$distribution_output" chmod

  HOME=$distribution_home
  RELEASE_COOKIE=$distribution_marker
  export HOME RELEASE_COOKIE
fi
