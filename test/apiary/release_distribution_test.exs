defmodule Apiary.ReleaseDistributionTest do
  # How the release runs Erlang distribution: rel/env.sh.eex, the release's env.sh, which
  # sources rel/overlays/releases/distribution.sh, and rel/overlays/bin/server, which
  # sources it too. Each test lays out a release in a separate temporary directory: those
  # files as the release holds them, the release script bin/apiary rendered from the
  # template `mix release` renders it from, and the elixir and iex scripts of this Elixir
  # installation, run with ELIXIR_CLI_DRY_RUN=1 so they print the Erlang command line they
  # would run instead of running it. getent, uname and od are stubs first on PATH where a
  # test needs them: this host is node-a, at 10.0.1.5.
  #
  # The cookie reaches the node through a file, never a command line: each run that goes on,
  # but version, writes it to tmp/apiary-cookie.<random>/.erlang.cookie in the release, and
  # the command line holds the word below where the cookie was.
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

  # What the release script passes as the cookie once distribution.sh has written it.
  @word "-release_cookie_in_home"

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
  # Returns the output, stderr included, and the exit status. `opts` are System.cmd's, :cd
  # among them.
  defp run(dir, program, args, env \\ [], opts \\ []) do
    base = [
      {"PATH", Path.join(dir, "stubs") <> ":" <> System.get_env("PATH")},
      {"ELIXIR_CLI_DRY_RUN", "1"},
      {"DNS_CLUSTER_QUERY", nil},
      {"RELEASE_COOKIE", nil},
      {"RELEASE_NODE", nil},
      {"RELEASE_DISTRIBUTION", nil},
      {"RELEASE_NAME", nil},
      {"RELEASE_TMP", nil},
      {"ELIXIR_ERL_OPTIONS", nil}
    ]

    System.cmd(
      Path.join(dir, "bin/#{program}"),
      args,
      [env: base ++ env, stderr_to_stdout: true] ++ opts
    )
  end

  # The node name flag of the Erlang command line a run printed and the cookie the node
  # gets, or the output and the status when it stopped. daemon and daemon_iex print it
  # escaped for run_erl, a backslash before each character other than letters, digits, _, /
  # and -.
  #
  # A run that goes on writes exactly one cookie file, and its cookie is the file's: the
  # command line holds the word, not the cookie, and the directory and the file are for
  # the release user alone. A run that writes no file, or two, fails the test.
  defp erl(dir, program, args, env \\ []) do
    before = cookie_homes(dir)

    case run(dir, program, args, env) do
      {output, 0} ->
        words = output |> String.replace("\\", "") |> String.split()

        assert [home] = cookie_homes(dir) -- before,
               "bin/#{program} #{Enum.join(args, " ")} did not write exactly one cookie file"

        written = written_cookie(home)
        assert cookie(words) == @word
        refute output =~ written
        refute Enum.join(words, " ") =~ written
        %{name: flag(words, ["-name", "-sname"]), cookie: written}

      stopped ->
        stopped
    end
  end

  # The node name flag and the cookie of the command line a run printed, for a release
  # whose env.sh does not source distribution.sh: it writes no cookie file.
  defp erl_without_file(dir, program, args) do
    before = cookie_homes(dir)
    assert {output, 0} = run(dir, program, args)
    assert cookie_homes(dir) == before
    words = String.split(output)
    %{name: flag(words, ["-name", "-sname"]), cookie: cookie(words)}
  end

  defp cookie_homes(dir), do: Path.wildcard(Path.join(dir, "tmp/apiary-cookie.*"))

  # The cookie in `home`, once the modes of the directory and the file are checked.
  defp written_cookie(home) do
    file = Path.join(home, ".erlang.cookie")
    assert mode(home) == 0o700
    assert mode(file) == 0o400
    assert File.ls!(home) == [".erlang.cookie"]
    File.read!(file)
  end

  defp mode(path), do: Bitwise.band(File.lstat!(path).mode, 0o7777)

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

    assert erl_without_file(dir, "apiary", ["start"]) ==
             %{name: {"-sname", "apiary"}, cookie: @baked}

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

  @tag :tmp_dir
  test "with DNS_CLUSTER_QUERY and RELEASE_COOKIE, the cookie is on no command line",
       %{tmp_dir: dir} do
    release(dir)
    env = clustering([{"RELEASE_COOKIE", "a-shared-secret"}])

    for command <- @starting ++ ["eval"] do
      assert %{cookie: "a-shared-secret"} = erl(dir, "apiary", [command, "IO.puts(1)"], env)
    end

    assert %{cookie: "a-shared-secret"} = erl(dir, "server", [], env)

    homes = cookie_homes(dir)
    assert run(dir, "apiary", ["version"], env) == {"apiary 0.1.0\n", 0}
    assert cookie_homes(dir) == homes
  end

  @tag :tmp_dir
  test "the Erlang command runs with HOME at the directory that holds the cookie",
       %{tmp_dir: dir} do
    release(dir)
    # erl itself, which the elixir script runs when it is not a dry run.
    script(Path.join(dir, "stubs/erl"), ~s(#!/bin/sh\nprintf '%s\\n' "$HOME" "$RELEASE_COOKIE"\n))
    env = clustering([{"RELEASE_COOKIE", "a-shared-secret"}, {"ELIXIR_CLI_DRY_RUN", nil}])

    for {program, args} <- [{"apiary", ["start"]}, {"apiary", ["remote"]}, {"server", []}] do
      before = cookie_homes(dir)
      assert {output, 0} = run(dir, program, args, env)
      assert [home, @word] = String.split(output, "\n", trim: true)
      assert cookie_homes(dir) -- before == [home]
      assert written_cookie(home) == "a-shared-secret"
    end
  end

  @tag :tmp_dir
  test "the Erlang VM ignores -setcookie with the word and reads the cookie from HOME",
       %{tmp_dir: dir} do
    release(dir)

    {output, 0} =
      run(dir, "apiary", ["start"], clustering([{"RELEASE_COOKIE", "a-shared-secret"}]))

    [home] = cookie_homes(dir)

    words = String.split(output)
    setcookie = Enum.slice(words, Enum.find_index(words, &(&1 == "-setcookie")), 2)
    assert setcookie == ["-setcookie", @word]

    # The kernel's auth server, which holds the node's cookie, in a VM with no distribution.
    eval = "{ok, _} = auth:start_link(), io:put_chars(atom_to_list(auth:get_cookie())), halt()."
    erl = Path.join(:code.root_dir(), "bin/erl")

    # No ERL_*FLAGS from the caller's environment, so nothing can start distribution.
    env = [{"HOME", home}, {"ERL_FLAGS", nil}, {"ERL_AFLAGS", nil}, {"ERL_ZFLAGS", nil}]

    assert System.cmd(erl, ["-noshell" | setcookie] ++ ["-eval", eval], env: env) ==
             {"a-shared-secret", 0}
  end

  @tag :tmp_dir
  test "RELEASE_COOKIE set to the word counts as unset, unless distribution.sh wrote the file",
       %{tmp_dir: dir} do
    release(dir)

    assert run(dir, "apiary", ["start"], clustering([{"RELEASE_COOKIE", @word}])) ==
             {@cookie_stop, 1}

    assert %{cookie: cookie} = erl(dir, "apiary", ["start"], [{"RELEASE_COOKIE", @word}])
    assert random?(cookie)

    # A HOME named as distribution.sh names its directories, without the file.
    home = Path.join(dir, "elsewhere/apiary-cookie.AAAAAAAA")
    File.mkdir_p!(home)

    assert run(dir, "apiary", ["start"], clustering([{"RELEASE_COOKIE", @word}, {"HOME", home}])) ==
             {@cookie_stop, 1}
  end

  # The line a command stops with when the cookie cannot be written to `dir`: the reason is
  # what the failed command said, which differs between systems.
  defp write_stop(dir) do
    ~r/\ACannot write the Erlang cookie to #{Regex.escape(dir)}: [^:\n]+\. RELEASE_TMP has to be writable by the release user\.\n\z/
  end

  @tag :tmp_dir
  test "the command stops when the file for the cookie cannot be written", %{tmp_dir: dir} do
    release(dir)
    tmp = Path.join(dir, "tmp")
    env = clustering([{"RELEASE_COOKIE", "a-shared-secret"}])

    commands = [
      {"apiary", ["start"]},
      {"apiary", ["eval", "IO.puts(1)"]},
      {"server", []}
    ]

    # RELEASE_TMP is a file: mkdir fails.
    File.write!(tmp, "")

    for {program, args} <- commands do
      assert {output, 1} = run(dir, program, args, env)
      assert output =~ write_stop(tmp)
      refute output =~ "a-shared-secret"
    end

    # RELEASE_TMP no one may write to: mktemp fails.
    File.rm!(tmp)
    File.mkdir!(tmp)
    File.chmod!(tmp, 0o500)

    try do
      for {program, args} <- commands do
        assert {output, 1} = run(dir, program, args, env)
        assert output =~ write_stop(tmp)
        refute output =~ "a-shared-secret"
      end
    after
      File.chmod!(tmp, 0o700)
    end

    assert cookie_homes(dir) == []

    # chmod fails once the directory is made: the line names that directory.
    script(
      Path.join(dir, "stubs/chmod"),
      "#!/bin/sh\necho \"chmod: $2: Operation not permitted\" >&2\nexit 1\n"
    )

    for {program, args} <- commands do
      before = cookie_homes(dir)
      assert {output, 1} = run(dir, program, args, env)
      assert [home] = cookie_homes(dir) -- before
      assert output =~ write_stop(home)
      assert output =~ ": Operation not permitted. "
      refute output =~ "a-shared-secret"
    end

    File.rm!(Path.join(dir, "stubs/chmod"))
    other = Path.join(dir, "other")
    assert {_, 0} = run(dir, "apiary", ["start"], [{"RELEASE_TMP", other} | env])
    assert [home] = Path.wildcard(Path.join(other, "apiary-cookie.*"))
    assert written_cookie(home) == "a-shared-secret"
  end

  @tag :tmp_dir
  test "RELEASE_TMP and the cookie's directory are made under umask 077", %{tmp_dir: dir} do
    release(dir)
    tmp = Path.join(dir, "tmp")
    refute File.exists?(tmp)

    # bin/apiary start under umask 000.
    {output, 0} =
      System.cmd(
        "/bin/sh",
        ["-c", ~s(umask 000 && exec "$0" "$@"), Path.join(dir, "bin/apiary"), "start"],
        env: [
          {"PATH", Path.join(dir, "stubs") <> ":" <> System.get_env("PATH")},
          {"ELIXIR_CLI_DRY_RUN", "1"},
          {"DNS_CLUSTER_QUERY", "apiary.internal"},
          {"RELEASE_COOKIE", "a-shared-secret"},
          {"RELEASE_NODE", nil},
          {"RELEASE_TMP", nil}
        ],
        stderr_to_stdout: true
      )

    refute output =~ "a-shared-secret"
    assert mode(tmp) == 0o700
    assert [home] = cookie_homes(dir)
    assert written_cookie(home) == "a-shared-secret"
  end

  @tag :tmp_dir
  test "the word counts as written only with HOME a directory this user owns, directly in RELEASE_TMP",
       %{tmp_dir: dir} do
    release(dir)
    env = clustering([{"RELEASE_COOKIE", @word}])

    home = fn path ->
      File.mkdir_p!(path)
      File.chmod!(path, 0o700)
      file = Path.join(path, ".erlang.cookie")
      File.write!(file, "a-planted-cookie")
      File.chmod!(file, 0o400)
      path
    end

    tmp = Path.join(dir, "tmp")
    File.mkdir_p!(tmp)

    # Elsewhere; nested in RELEASE_TMP, above the name or below it; named otherwise; a file
    # in place of the directory; a symbolic link to a directory this user owns that holds a
    # valid file; and a valid directory whose .erlang.cookie is a symbolic link to a valid
    # file.
    file_home = Path.join(tmp, "apiary-cookie.FFFFFFFF")
    File.write!(file_home, "")

    link_home = Path.join(tmp, "apiary-cookie.LLLLLLLL")
    File.ln_s!(home.(Path.join(dir, "linked/apiary-cookie.GGGGGGGG")), link_home)

    link_file_home = Path.join(tmp, "apiary-cookie.MMMMMMMM")
    File.mkdir!(link_file_home)
    File.chmod!(link_file_home, 0o700)

    File.ln_s!(
      Path.join(home.(Path.join(dir, "linked/apiary-cookie.HHHHHHHH")), ".erlang.cookie"),
      Path.join(link_file_home, ".erlang.cookie")
    )

    for untrusted <- [
          home.(Path.join(dir, "elsewhere/apiary-cookie.AAAAAAAA")),
          home.(Path.join(tmp, "nested/apiary-cookie.BBBBBBBB")),
          home.(Path.join(tmp, "apiary-cookie.EEEEEEEE/inner")),
          home.(Path.join(tmp, "other.CCCCCCCC")),
          file_home,
          link_home,
          link_file_home
        ] do
      before = cookie_homes(dir)

      assert run(dir, "apiary", ["start"], [{"HOME", untrusted} | env]) == {@cookie_stop, 1}
      assert cookie_homes(dir) == before

      assert %{cookie: cookie} =
               erl(dir, "apiary", ["start"], [{"HOME", untrusted}, {"RELEASE_COOKIE", @word}])

      assert random?(cookie)
    end

    # A directory of RELEASE_TMP that this user owns, with a file this user owns, is the
    # cookie written already: the run writes no other.
    trusted = home.(Path.join(tmp, "apiary-cookie.DDDDDDDD"))
    before = cookie_homes(dir)
    assert {output, 0} = run(dir, "apiary", ["start"], [{"HOME", trusted} | env])
    assert output =~ "-setcookie #{@word} "
    assert cookie_homes(dir) == before

    # The same directory, once RELEASE_TMP names another: not trusted.
    other = Path.join(dir, "other")

    assert run(dir, "apiary", ["start"], [{"HOME", trusted}, {"RELEASE_TMP", other} | env]) ==
             {@cookie_stop, 1}
  end

  @tag :tmp_dir
  test "a relative RELEASE_TMP is the directory it names, and HOME is absolute",
       %{tmp_dir: dir} do
    release(dir)
    script(Path.join(dir, "stubs/erl"), ~s(#!/bin/sh\nprintf '%s\\n' "$HOME" "$RELEASE_COOKIE"\n))

    env =
      clustering([
        {"RELEASE_COOKIE", "a-shared-secret"},
        {"ELIXIR_CLI_DRY_RUN", nil},
        {"RELEASE_TMP", "relative/tmp"}
      ])

    # bin/apiary, run from the release's root; bin/server, which runs from bin/, and its
    # second pass.
    for {program, root} <- [{"apiary", dir}, {"server", Path.join(dir, "bin")}] do
      assert {output, 0} = run(dir, program, ["start"], env, cd: dir)
      assert [home, @word] = String.split(output, "\n", trim: true)
      assert Path.type(home) == :absolute
      assert Path.basename(Path.dirname(home)) == "tmp"
      assert [^home] = Path.wildcard(Path.join(root, "relative/tmp/apiary-cookie.*"))
      assert written_cookie(home) == "a-shared-secret"
    end
  end
end
