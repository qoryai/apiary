defmodule Apiary.ReleaseDistributionTest do
  # How the release runs Erlang distribution: rel/env.sh.eex, the release's env.sh, which
  # sources rel/overlays/releases/distribution.sh, and rel/overlays/bin/server, which
  # sources it too. Each test lays out a release in a separate temporary directory: those
  # files as the release holds them, the release script bin/apiary rendered from the
  # template `mix release` renders it from, and the elixir and iex scripts of this Elixir
  # installation, run with ELIXIR_CLI_DRY_RUN=1 so they print the Erlang command line they
  # would run instead of running it. getent, uname and od are stubs first on PATH where a
  # test needs them: this host is node-a, at 10.0.1.5.
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @template Path.join(@root, "rel/env.sh.eex")
  @shared Path.join(@root, "rel/overlays/releases/distribution.sh")
  @server Path.join(@root, "rel/overlays/bin/server")

  # What releases/COOKIE holds: the cookie every copy of the image holds.
  @baked "baked-cookie-of-the-image"

  @cookie_stop "DNS_CLUSTER_QUERY is set, so RELEASE_COOKIE must be set too: one secret value, the same on every node. Set it, or unset DNS_CLUSTER_QUERY to run one node.\n"

  @starting ~w(start start_iex daemon daemon_iex remote rpc restart stop pid)

  @mode_tag ~s[<%= release_mode(@release, "$RELEASE_MODE") %>]

  # The release script, as `mix release` renders it for a release named apiary.
  defp release_script do
    template = Mix.Tasks.Release.Init.cli_text()
    assert template =~ @mode_tag
    template = String.replace(template, @mode_tag, "-mode $RELEASE_MODE")
    EEx.eval_string(template, assigns: [release: %{name: :apiary}])
  end

  # Lays the release out in `dir`, with `env_sh` as its env.sh: the template rendered as
  # `mix release` renders it, unless a test gives another.
  defp release(dir, env_sh \\ nil) do
    env_sh = env_sh || EEx.eval_file(@template, assigns: [release: %{name: :apiary}])
    elixir_bin = Path.expand("../../bin", :code.lib_dir(:elixir))
    version = Path.join(dir, "releases/0.1.0")

    File.mkdir_p!(Path.join(dir, "bin"))
    File.mkdir_p!(version)
    File.mkdir_p!(Path.join(dir, "stubs"))
    File.write!(Path.join(dir, "releases/COOKIE"), @baked)
    File.write!(Path.join(dir, "releases/start_erl.data"), "16.0 0.1.0")
    File.cp!(@shared, Path.join(dir, "releases/distribution.sh"))
    File.write!(Path.join(version, "env.sh"), env_sh)
    File.write!(Path.join(version, "sys.config"), "[].\n")
    File.cp!(@server, Path.join(dir, "bin/server"))
    script(Path.join(dir, "bin/apiary"), release_script())

    for name <- ["elixir", "iex"] do
      script(Path.join(version, name), File.read!(Path.join(elixir_bin, name)))
    end

    script(Path.join(dir, "stubs/uname"), "#!/bin/sh\necho node-a\n")
    addresses(dir, ["10.0.1.5"])
    dir
  end

  # getent's answer for node-a: one line for each address, as `getent ahostsv4` prints it.
  defp addresses(dir, addresses) do
    lines =
      Enum.map_join(addresses, fn address ->
        "#{address}        STREAM node-a\\n#{address}        DGRAM\\n"
      end)

    script(Path.join(dir, "stubs/getent"), """
    #!/bin/sh
    [ "$1" = ahostsv4 ] && [ "$2" = node-a ] || exit 2
    printf '#{lines}'
    """)
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
      {"ELIXIR_CLI_DRY_RUN", "1"},
      {"DNS_CLUSTER_QUERY", nil},
      {"RELEASE_COOKIE", nil},
      {"RELEASE_NODE", nil},
      {"RELEASE_DISTRIBUTION", nil},
      {"RELEASE_NAME", nil},
      {"ELIXIR_ERL_OPTIONS", nil}
    ]

    System.cmd(Path.join(dir, "bin/#{program}"), args, env: base ++ env, stderr_to_stdout: true)
  end

  # The node name flag and the cookie of the Erlang command line a run printed, or the
  # output and the status when it stopped. daemon and daemon_iex print it escaped for
  # run_erl, a backslash before each character other than letters, digits, _, / and -.
  defp erl(dir, program, args, env \\ []) do
    case run(dir, program, args, env) do
      {output, 0} ->
        words = output |> String.replace("\\", "") |> String.split()
        %{name: flag(words, ["-name", "-sname"]), cookie: cookie(words)}

      stopped ->
        stopped
    end
  end

  defp flag(words, flags) do
    case Enum.find_index(words, &(&1 in flags)) do
      nil -> nil
      index -> {Enum.at(words, index), Enum.at(words, index + 1)}
    end
  end

  defp cookie(words) do
    case flag(words, ["-setcookie"]) do
      {_, cookie} -> cookie
      nil -> nil
    end
  end

  defp random?(cookie), do: is_binary(cookie) and cookie =~ ~r/\A[0-9a-f]{64}\z/

  defp clustering(env \\ []), do: [{"DNS_CLUSTER_QUERY", "apiary.internal"} | env]

  test "the template renders to the file that sources distribution.sh" do
    rendered = EEx.eval_file(@template, assigns: [release: %{name: :apiary}])
    assert rendered == File.read!(@template)
    assert rendered =~ ~s(. "$RELEASE_ROOT/releases/distribution.sh")
  end

  @tag :tmp_dir
  test "without DNS_CLUSTER_QUERY, distribution is off and the cookie is a new random one",
       %{tmp_dir: dir} do
    release(dir)

    for command <- ["start", "start_iex", "daemon", "daemon_iex", "remote", "rpc", "eval"] do
      assert %{name: nil, cookie: cookie} = erl(dir, "apiary", [command, "IO.puts(1)"])
      assert random?(cookie), "#{command} does not run with a random cookie"
    end

    assert %{name: nil, cookie: cookie} =
             erl(dir, "apiary", ["start"], [{"RELEASE_DISTRIBUTION", "sname"}])

    assert random?(cookie)

    assert %{name: nil} = erl(dir, "apiary", ["start"], [{"DNS_CLUSTER_QUERY", ""}])
    assert run(dir, "apiary", ["version"]) == {"apiary 0.1.0\n", 0}
  end

  @tag :tmp_dir
  test "the cookie in releases/COOKIE is never used, and each run makes another",
       %{tmp_dir: dir} do
    release(dir)

    %{cookie: first} = erl(dir, "apiary", ["start"])
    %{cookie: second} = erl(dir, "apiary", ["start"])
    %{cookie: third} = erl(dir, "apiary", ["eval", "IO.puts(1)"], clustering())

    assert Enum.all?([first, second, third], &random?/1)
    refute @baked in [first, second, third]
    assert first != second

    assert %{cookie: "a-shared-secret"} =
             erl(dir, "apiary", ["start"], [{"RELEASE_COOKIE", "a-shared-secret"}])
  end

  @tag :tmp_dir
  test "a node an Erlang option starts has the random cookie, not the image's",
       %{tmp_dir: dir} do
    release(dir)

    assert %{name: {"-sname", "x"}, cookie: cookie} =
             erl(dir, "server", [], [{"ELIXIR_ERL_OPTIONS", "-sname x"}])

    assert random?(cookie)

    assert %{name: {"-name", "x"}, cookie: cookie} =
             erl(dir, "apiary", ["start"], [{"ELIXIR_ERL_OPTIONS", "-name x"}])

    assert random?(cookie)
  end

  @tag :tmp_dir
  test "the command stops when no random cookie can be made", %{tmp_dir: dir} do
    release(dir)

    stop =
      "No random Erlang cookie could be made from /dev/urandom. Set RELEASE_COOKIE to a long random value.\n"

    script(Path.join(dir, "stubs/od"), "#!/bin/sh\nexit 1\n")
    assert run(dir, "apiary", ["start"]) == {stop, 1}
    assert run(dir, "server", []) == {stop, 1}

    script(Path.join(dir, "stubs/od"), "#!/bin/sh\necho ' 0a 1b'\n")
    assert run(dir, "apiary", ["eval", "IO.puts(1)"]) == {stop, 1}

    assert %{cookie: "a-shared-secret"} =
             erl(dir, "apiary", ["start"], [{"RELEASE_COOKIE", "a-shared-secret"}])
  end

  @tag :tmp_dir
  test "with DNS_CLUSTER_QUERY and no RELEASE_COOKIE, a command that starts distribution stops",
       %{tmp_dir: dir} do
    release(dir)

    for command <- @starting do
      assert run(dir, "apiary", [command, "IO.puts(1)"], clustering()) == {@cookie_stop, 1}
    end

    assert run(dir, "apiary", ["start"], clustering([{"RELEASE_COOKIE", ""}])) ==
             {@cookie_stop, 1}
  end

  @tag :tmp_dir
  test "with DNS_CLUSTER_QUERY and no RELEASE_COOKIE, eval and version run", %{tmp_dir: dir} do
    release(dir)

    assert %{name: nil, cookie: cookie} =
             erl(dir, "apiary", ["eval", "IO.puts(1)"], clustering())

    assert random?(cookie)
    assert run(dir, "apiary", ["version"], clustering()) == {"apiary 0.1.0\n", 0}
  end

  @tag :tmp_dir
  test "with DNS_CLUSTER_QUERY and RELEASE_COOKIE, the node has a long name at this host's address",
       %{tmp_dir: dir} do
    release(dir)
    env = clustering([{"RELEASE_COOKIE", "a-shared-secret"}])

    for command <- ["start", "start_iex", "daemon", "daemon_iex"] do
      assert erl(dir, "apiary", [command], env) ==
               %{name: {"-name", "apiary@10.0.1.5"}, cookie: "a-shared-secret"}
    end

    assert %{name: {"-name", "rem-" <> remote}, cookie: "a-shared-secret"} =
             erl(dir, "apiary", ["remote"], env)

    assert remote =~ ~r/-apiary@10\.0\.1\.5\z/

    assert erl(dir, "apiary", ["start"], [{"RELEASE_NODE", "apiary@192.0.2.7"} | env]) ==
             %{name: {"-name", "apiary@192.0.2.7"}, cookie: "a-shared-secret"}
  end

  @tag :tmp_dir
  test "with DNS_CLUSTER_QUERY, the node's address is the first that is not a loopback one",
       %{tmp_dir: dir} do
    release(dir)
    env = clustering([{"RELEASE_COOKIE", "a-shared-secret"}])

    addresses(dir, ["127.0.1.1", "10.0.1.6", "10.0.1.5"])
    assert %{name: {"-name", "apiary@10.0.1.6"}} = erl(dir, "apiary", ["start"], env)

    addresses(dir, ["127.0.1.1", "127.0.0.1"])

    assert run(dir, "apiary", ["start"], env) ==
             {"DNS_CLUSTER_QUERY is set, and this host's name resolves only to a loopback address. Set RELEASE_NODE to apiary@<address>, with the address the other nodes reach this one at.\n",
              1}

    assert %{name: {"-name", "apiary@192.0.2.7"}} =
             erl(dir, "apiary", ["start"], [{"RELEASE_NODE", "apiary@192.0.2.7"} | env])
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

    assert erl(dir, "apiary", ["start"]) == %{name: {"-sname", "apiary"}, cookie: @baked}

    assert %{name: nil, cookie: cookie} = erl(dir, "server", [])
    assert random?(cookie)

    assert run(dir, "server", [], clustering()) == {@cookie_stop, 1}

    assert erl(dir, "server", [], clustering([{"RELEASE_COOKIE", "a-shared-secret"}])) ==
             %{name: {"-name", "apiary@10.0.1.5"}, cookie: "a-shared-secret"}
  end

  @tag :tmp_dir
  test "bin/server, with the release's env.sh", %{tmp_dir: dir} do
    release(dir)

    assert %{name: nil, cookie: cookie} = erl(dir, "server", [])
    assert random?(cookie)

    assert run(dir, "server", [], clustering()) == {@cookie_stop, 1}

    assert erl(dir, "server", [], clustering([{"RELEASE_COOKIE", "a-shared-secret"}])) ==
             %{name: {"-name", "apiary@10.0.1.5"}, cookie: "a-shared-secret"}
  end
end
