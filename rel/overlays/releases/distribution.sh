# How the release runs Erlang distribution. Sourced, never run: by releases/<version>/env.sh
# (rel/env.sh.eex), which the release script bin/apiary sources before every command, and
# by bin/server before it starts the release. POSIX sh. It only sets variables, or stops a
# command that would start distribution.
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
