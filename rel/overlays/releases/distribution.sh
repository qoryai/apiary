# How the release runs Erlang distribution. Sourced, never run: by releases/<version>/env.sh
# (rel/env.sh.eex), which the release script bin/apiary sources before every command, and
# by bin/server before it starts the release. POSIX sh. It only sets variables, or stops a
# command that would start distribution.
#
# Without DNS_CLUSTER_QUERY, distribution is off (RELEASE_DISTRIBUTION=none): no epmd, no
# distribution port, and the cookie in releases/COOKIE, which every copy of the image
# holds, is never used. `eval`, which bin/migrate and every Apiary.Release task use,
# starts no distribution in any case and works as before. `rpc`, `remote`, `stop`,
# `restart` and `pid` reach the running node over distribution, so with it off they
# cannot work.
#
# With DNS_CLUSTER_QUERY, the nodes cluster through DNSCluster, which needs long names:
# RELEASE_DISTRIBUTION=name, and the node is <release name>@<this host's IPv4 address>
# unless RELEASE_NODE names it. Every node needs the same RELEASE_COOKIE: a command that
# starts distribution stops without it, so that no node uses the cookie in
# releases/COOKIE. `eval` and `version` start none and run without it.

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
    # set it yet.
    if [ -z "${RELEASE_NODE:-}" ]; then
      distribution_address=$(getent ahostsv4 "$(uname -n)" 2>/dev/null) || distribution_address=
      distribution_address=${distribution_address%%[[:space:]]*}

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
