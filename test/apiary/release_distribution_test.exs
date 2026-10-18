defmodule Apiary.ReleaseDistributionTest do
  # How the release runs Erlang distribution: rel/env.sh.eex, the release's env.sh, which
  # sources rel/overlays/releases/distribution.sh, and rel/overlays/bin/server, which
  # sources it too. Each test lays out a release in a directory of its own: the three
  # files as the release holds them, and a bin/apiary that sets what the release script
  # sets, sources env.sh as it does and prints the distribution and the node it would
  # start with. getent and uname are stubs first on PATH: this host is node-a, at
  # 10.0.1.5.
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @template Path.join(@root, "rel/env.sh.eex")
  @shared Path.join(@root, "rel/overlays/releases/distribution.sh")
  @server Path.join(@root, "rel/overlays/bin/server")

  @cookie_stop "DNS_CLUSTER_QUERY is set, so RELEASE_COOKIE must be set too: one secret value, the same on every node. Set it, or unset DNS_CLUSTER_QUERY to run one node.\n"

  @starting ~w(start start_iex daemon daemon_iex remote rpc restart stop pid)

  @release_script """
  #!/bin/sh
  set -e
  RELEASE_ROOT="$(CDPATH='' cd "$(dirname "$0")/.." && pwd -P)"
  export RELEASE_ROOT
  RELEASE_NAME="${RELEASE_NAME:-apiary}"
  export RELEASE_NAME
  RELEASE_COMMAND="$1"
  export RELEASE_COMMAND
  . "$RELEASE_ROOT/releases/0.1.0/env.sh"
  printf '%s|%s\\n' "${RELEASE_DISTRIBUTION:-}" "${RELEASE_NODE:-}"
  """

  # Lays the release out in `dir`, with `env_sh` as its env.sh: the template rendered as
  # `mix release` renders it, unless a test gives another.
  defp release(dir, env_sh \\ nil) do
    env_sh = env_sh || EEx.eval_file(@template, assigns: [release: %{name: :apiary}])

    File.mkdir_p!(Path.join(dir, "bin"))
    File.mkdir_p!(Path.join(dir, "releases/0.1.0"))
    File.mkdir_p!(Path.join(dir, "stubs"))
    File.cp!(@shared, Path.join(dir, "releases/distribution.sh"))
    File.cp!(@server, Path.join(dir, "bin/server"))
    File.write!(Path.join(dir, "releases/0.1.0/env.sh"), env_sh)
    script(Path.join(dir, "bin/apiary"), @release_script)

    script(Path.join(dir, "stubs/uname"), "#!/bin/sh\necho node-a\n")

    script(Path.join(dir, "stubs/getent"), """
    #!/bin/sh
    [ "$1" = ahostsv4 ] && [ "$2" = node-a ] || exit 2
    printf '10.0.1.5        STREAM node-a\\n10.0.1.5        DGRAM\\n'
    """)

    dir
  end

  defp script(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end

  # Runs bin/<program> with `args`, none of the variables below set unless `env` sets one.
  # Returns the output, stderr included, and the exit status.
  defp run(dir, program, args, env \\ []) do
    base = [
      {"PATH", Path.join(dir, "stubs") <> ":" <> System.get_env("PATH")},
      {"DNS_CLUSTER_QUERY", nil},
      {"RELEASE_COOKIE", nil},
      {"RELEASE_NODE", nil},
      {"RELEASE_DISTRIBUTION", nil},
      {"RELEASE_NAME", nil}
    ]

    System.cmd(Path.join(dir, "bin/#{program}"), args,
      env: base ++ env,
      stderr_to_stdout: true
    )
  end

  defp clustering(env \\ []), do: [{"DNS_CLUSTER_QUERY", "apiary.internal"} | env]

  test "the template renders to the file that sources distribution.sh" do
    rendered = EEx.eval_file(@template, assigns: [release: %{name: :apiary}])
    assert rendered == File.read!(@template)
    assert rendered =~ ~s(. "$RELEASE_ROOT/releases/distribution.sh")
  end

  @tag :tmp_dir
  test "without DNS_CLUSTER_QUERY, distribution is off for every command", %{tmp_dir: dir} do
    release(dir)

    for command <- ["eval", "version" | @starting] do
      assert run(dir, "apiary", [command]) == {"none|\n", 0}
    end

    assert run(dir, "apiary", ["start"], [{"RELEASE_DISTRIBUTION", "sname"}]) == {"none|\n", 0}
    assert run(dir, "apiary", ["start"], [{"DNS_CLUSTER_QUERY", ""}]) == {"none|\n", 0}
  end

  @tag :tmp_dir
  test "with DNS_CLUSTER_QUERY and no RELEASE_COOKIE, a command that starts distribution stops",
       %{tmp_dir: dir} do
    release(dir)

    for command <- @starting do
      assert run(dir, "apiary", [command], clustering()) == {@cookie_stop, 1}
    end

    assert run(dir, "apiary", ["start"], clustering([{"RELEASE_COOKIE", ""}])) ==
             {@cookie_stop, 1}
  end

  @tag :tmp_dir
  test "with DNS_CLUSTER_QUERY and no RELEASE_COOKIE, eval and version run", %{tmp_dir: dir} do
    release(dir)

    assert run(dir, "apiary", ["eval"], clustering()) == {"name|\n", 0}
    assert run(dir, "apiary", ["version"], clustering()) == {"name|\n", 0}
  end

  @tag :tmp_dir
  test "with DNS_CLUSTER_QUERY and RELEASE_COOKIE, the node has a long name at this host's address",
       %{tmp_dir: dir} do
    release(dir)
    env = clustering([{"RELEASE_COOKIE", "a-shared-secret"}])

    for command <- @starting do
      assert run(dir, "apiary", [command], env) == {"name|apiary@10.0.1.5\n", 0}
    end

    assert run(dir, "apiary", ["start"], [{"RELEASE_NODE", "apiary@192.0.2.7"} | env]) ==
             {"name|apiary@192.0.2.7\n", 0}
  end

  @tag :tmp_dir
  test "with DNS_CLUSTER_QUERY, a start stops when no IPv4 address of this host is found",
       %{tmp_dir: dir} do
    release(dir)
    script(Path.join(dir, "stubs/getent"), "#!/bin/sh\nexit 2\n")

    assert run(dir, "apiary", ["start"], clustering([{"RELEASE_COOKIE", "a-shared-secret"}])) ==
             {"DNS_CLUSTER_QUERY is set, and no IPv4 address of this host was found for the node's name. Set RELEASE_NODE to apiary@<address>, with the address the other nodes reach this one at.\n",
              1}
  end

  @tag :tmp_dir
  test "bin/server sets distribution also for a release whose env.sh does not", %{tmp_dir: dir} do
    release(dir, "#!/bin/sh\n")

    assert run(dir, "apiary", ["start"]) == {"|\n", 0}
    assert run(dir, "server", []) == {"none|\n", 0}
    assert run(dir, "server", [], clustering()) == {@cookie_stop, 1}

    assert run(dir, "server", [], clustering([{"RELEASE_COOKIE", "a-shared-secret"}])) ==
             {"name|apiary@10.0.1.5\n", 0}
  end

  @tag :tmp_dir
  test "bin/server, with the release's env.sh", %{tmp_dir: dir} do
    release(dir)

    assert run(dir, "server", []) == {"none|\n", 0}
    assert run(dir, "server", [], clustering()) == {@cookie_stop, 1}

    assert run(dir, "server", [], clustering([{"RELEASE_COOKIE", "a-shared-secret"}])) ==
             {"name|apiary@10.0.1.5\n", 0}
  end
end
