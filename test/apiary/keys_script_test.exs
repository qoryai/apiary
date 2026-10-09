defmodule Apiary.KeysScriptTest do
  # rel/overlays/bin/keys, the image's bin/keys, run as the service `keys` runs it, in a
  # directory of its own. Every assertion on a generated value says what failed in its
  # message and never shows the value: ExUnit prints only the message of assert/2.
  use ExUnit.Case, async: true

  alias Apiary.KeysFile

  @script Path.expand("../../rel/overlays/bin/keys", __DIR__)
  @names ~w(SECRET_KEY_BASE APIARY_ENCRYPTION_SECRET APIARY_SIGNING_SECRET DATABASE_PASSWORD)

  # Runs bin/keys with APIARY_KEYS_DIR=dir, none of the four names in its environment
  # unless `env` sets one, and `path` before PATH. Returns the output, stderr included,
  # and the exit status.
  defp run(dir, env \\ [], path \\ nil) do
    path_env = if path, do: [{"PATH", path <> ":" <> System.get_env("PATH")}], else: []
    env = [{"APIARY_KEYS_DIR", dir} | Enum.map(@names, &{&1, nil})] ++ path_env ++ env
    System.cmd(@script, [], env: env, stderr_to_stdout: true)
  end

  defp keys_path(dir), do: Path.join(dir, "apiary.env")
  defp password_path(dir), do: Path.join(dir, "postgres-password")
  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  defp generated(dir) do
    """
    Generated SECRET_KEY_BASE, APIARY_ENCRYPTION_SECRET, APIARY_SIGNING_SECRET and DATABASE_PASSWORD in #{keys_path(dir)}.
    Keep a copy apart from the database backups: without APIARY_ENCRYPTION_SECRET no access key is trusted. To print the file: docker compose exec apiary cat #{keys_path(dir)}
    """
  end

  defp file_state(path) do
    stat = File.stat!(path, time: :posix)
    {File.read!(path), stat.inode, stat.mode, stat.mtime}
  end

  defp refute_leaked(output, values) do
    leaked = Enum.filter(values, &String.contains?(output, &1))
    assert leaked == [], "#{length(leaked)} value(s) reached the output"
  end

  # A command, first on PATH, that kills bin/keys and itself where bin/keys runs it from
  # its write step: a crash at that point.
  defp crash_at(dir, command) do
    bin = Path.join(dir, "crash-bin")
    File.mkdir_p!(bin)

    File.write!(Path.join(bin, command), """
    #!/bin/sh
    script=$(ps -o ppid= -p "$PPID" | tr -d ' ')
    kill -9 "$script" "$PPID"
    """)

    File.chmod!(Path.join(bin, command), 0o755)
    bin
  end

  @tag :tmp_dir
  test "generates the four keys, each valid and the two 32-byte keys apart", %{tmp_dir: dir} do
    assert {output, 0} = run(dir)
    assert output == generated(dir)

    keys = KeysFile.read(dir)
    assert Map.keys(keys) |> Enum.sort() == Enum.sort(@names)

    contents = File.read!(keys_path(dir))

    assert String.split(contents, "\n") |> Enum.map(&(String.split(&1, "=") |> hd())) ==
             @names ++ [""]

    base = keys["SECRET_KEY_BASE"]
    assert byte_size(base) == 64, "SECRET_KEY_BASE is not 64 characters"

    assert match?({:ok, <<_::binary-size(48)>>}, Base.decode64(base)),
           "SECRET_KEY_BASE is not base64 of 48 bytes"

    for name <- ["APIARY_ENCRYPTION_SECRET", "APIARY_SIGNING_SECRET"] do
      assert byte_size(keys[name]) == 44, "#{name} is not 44 characters"

      assert match?({:ok, <<_::binary-size(32)>>}, Base.decode64(keys[name])),
             "#{name} is not base64 of 32 bytes"
    end

    assert keys["APIARY_SIGNING_SECRET"] != keys["APIARY_ENCRYPTION_SECRET"],
           "APIARY_SIGNING_SECRET is APIARY_ENCRYPTION_SECRET"

    assert keys["DATABASE_PASSWORD"] =~ ~r/\A[0-9a-f]{48}\z/,
           "DATABASE_PASSWORD is not 48 lowercase hex characters"

    assert File.read!(password_path(dir)) == keys["DATABASE_PASSWORD"] <> "\n",
           "postgres-password does not hold DATABASE_PASSWORD"

    refute_leaked(output, Map.values(keys))
    assert File.ls!(dir) |> Enum.sort() == ["apiary.env", "postgres-password"]
  end

  @tag :tmp_dir
  test "the keys file is 0600 and postgres-password 0644, whatever the umask", %{tmp_dir: dir} do
    assert {_output, 0} =
             System.cmd("sh", ["-c", "umask 000 && exec \"$0\"", @script],
               env: [{"APIARY_KEYS_DIR", dir} | Enum.map(@names, &{&1, nil})],
               stderr_to_stdout: true
             )

    assert mode(keys_path(dir)) == 0o600
    assert mode(password_path(dir)) == 0o644
  end

  @tag :tmp_dir
  test "a second run changes nothing", %{tmp_dir: dir} do
    assert {_output, 0} = run(dir)
    before = Enum.map([keys_path(dir), password_path(dir)], &file_state/1)

    assert {output, 0} = run(dir)
    assert output == "The keys in #{keys_path(dir)} are kept; none was generated.\n"

    # Same contents, same files: a rewrite would rename a new file into place.
    assert Enum.map([keys_path(dir), password_path(dir)], &file_state/1) == before,
           "a second run changed the keys or their files"

    refute_leaked(output, Map.values(KeysFile.read(dir)))
  end

  @tag :tmp_dir
  test "a name set in the environment is skipped, and the environment's value kept nowhere but postgres-password",
       %{tmp_dir: dir} do
    signing = Base.encode64(:crypto.strong_rand_bytes(32))
    password = "environment-password-0001"

    assert {output, 0} =
             run(dir, [{"APIARY_SIGNING_SECRET", signing}, {"DATABASE_PASSWORD", password}])

    assert output ==
             """
             APIARY_SIGNING_SECRET is set in the environment: not generated, not kept here.
             DATABASE_PASSWORD is set in the environment: not generated, not kept here.
             Generated SECRET_KEY_BASE and APIARY_ENCRYPTION_SECRET in #{keys_path(dir)}.
             Keep a copy apart from the database backups: without APIARY_ENCRYPTION_SECRET no access key is trusted. To print the file: docker compose exec apiary cat #{keys_path(dir)}
             """

    keys = KeysFile.read(dir)
    assert Map.keys(keys) |> Enum.sort() == ["APIARY_ENCRYPTION_SECRET", "SECRET_KEY_BASE"]
    refute File.read!(keys_path(dir)) =~ signing, "the environment's value was kept"

    # The bundled postgres reads its password from the volume, so it is the one Qory uses.
    assert File.read!(password_path(dir)) == password <> "\n",
           "postgres-password is not the environment's DATABASE_PASSWORD"

    refute_leaked(output, [signing, password | Map.values(keys)])
  end

  @tag :tmp_dir
  test "a name the file holds is kept, whatever the environment says", %{tmp_dir: dir} do
    assert {_output, 0} = run(dir)
    held = File.read!(keys_path(dir))

    # A value in the environment wins at boot; the file's stays, so removing the variable
    # brings the generated one back rather than a new one.
    signing = Base.encode64(:crypto.strong_rand_bytes(32))
    assert {output, 0} = run(dir, [{"APIARY_SIGNING_SECRET", signing}])

    assert output ==
             """
             APIARY_SIGNING_SECRET is set in the environment, which wins; the file keeps its own.
             The keys in #{keys_path(dir)} are kept; none was generated.
             """

    assert File.read!(keys_path(dir)) == held, "the file changed"
    refute_leaked(output, [signing | Map.values(KeysFile.read(dir))])
  end

  @tag :tmp_dir
  test "only the names missing from the file are generated, and the rest stay as they were",
       %{tmp_dir: dir} do
    encryption = Base.encode64(:crypto.strong_rand_bytes(32))
    base = Base.encode64(:crypto.strong_rand_bytes(48))

    # Read as Apiary.KeysFile reads it: these lines hold no key but the two valid ones.
    File.write!(keys_path(dir), """
    # SECRET_KEY_BASE=commented
    export APIARY_SIGNING_SECRET=exported
    DATABASE_PASSWORD=
    APIARY_ENCRYPTION_SECRET=#{encryption}
    SECRET_KEY_BASE=#{base}
    """)

    File.chmod!(keys_path(dir), 0o600)

    assert {output, 0} = run(dir)

    assert output ==
             """
             Generated APIARY_SIGNING_SECRET and DATABASE_PASSWORD in #{keys_path(dir)}.
             Keep a copy apart from the database backups: without APIARY_ENCRYPTION_SECRET no access key is trusted. To print the file: docker compose exec apiary cat #{keys_path(dir)}
             """

    keys = KeysFile.read(dir)
    assert keys["APIARY_ENCRYPTION_SECRET"] == encryption, "APIARY_ENCRYPTION_SECRET changed"
    assert keys["SECRET_KEY_BASE"] == base, "SECRET_KEY_BASE changed"
    assert Map.keys(keys) |> Enum.sort() == Enum.sort(@names)
    assert mode(keys_path(dir)) == 0o600
    refute_leaked(output, Map.values(keys))
  end

  @tag :tmp_dir
  test "a crash before the rename leaves no keys file, and its half-written temporary file never becomes one",
       %{tmp_dir: dir} do
    # Killed once the temporary file is written, before it is renamed.
    assert {_output, status} = run(dir, [], crash_at(dir, "chmod"))
    assert status != 0
    refute File.exists?(keys_path(dir))
    temporary = keys_path(dir) <> ".tmp"
    # Written under umask 077: never readable by others, even before its mode is set.
    assert mode(temporary) == 0o600

    # As a crash in the middle of writing would leave it.
    half = binary_part(File.read!(temporary), 0, 40)
    File.write!(temporary, half)

    assert {output, 0} = run(dir)
    assert output == generated(dir)
    keys = KeysFile.read(dir)
    assert Map.keys(keys) |> Enum.sort() == Enum.sort(@names)
    assert byte_size(keys["SECRET_KEY_BASE"]) == 64, "SECRET_KEY_BASE is not whole"

    refute String.contains?(File.read!(keys_path(dir)), half),
           "the half-written file became the keys file"

    assert File.ls!(dir) |> Enum.sort() == ["apiary.env", "crash-bin", "postgres-password"]
  end

  @tag :tmp_dir
  test "a crash while adding a key leaves the keys file as it was", %{tmp_dir: dir} do
    assert {_output, 0} = run(dir, [{"DATABASE_PASSWORD", "environment-password-0001"}])
    held = File.read!(keys_path(dir))

    assert {_output, status} = run(dir, [], crash_at(dir, "mv"))
    assert status != 0
    assert File.read!(keys_path(dir)) == held, "the keys file changed"
  end

  @tag :tmp_dir
  test "a failing openssl writes nothing and exits non-zero", %{tmp_dir: dir} do
    bin = Path.join(dir, "failing-bin")
    File.mkdir_p!(bin)
    openssl = System.find_executable("openssl")

    # The third key fails, after two were generated.
    File.write!(Path.join(bin, "openssl"), """
    #!/bin/sh
    echo x >> "#{bin}/calls"
    [ "$(wc -l < "#{bin}/calls")" -lt 3 ] || exit 1
    exec "#{openssl}" "$@"
    """)

    File.chmod!(Path.join(bin, "openssl"), 0o755)

    assert {_output, status} = run(dir, [], bin)
    assert status != 0
    assert File.ls!(dir) == ["failing-bin"]
  end

  @tag :tmp_dir
  test "a write step that fails without a word still names a reason", %{tmp_dir: dir} do
    bin = Path.join(dir, "silent-bin")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "sync"), "#!/bin/sh\nexit 1\n")
    File.chmod!(Path.join(bin, "sync"), 0o755)

    assert {output, 1} = run(dir, [], bin)

    assert output ==
             "Cannot write #{dir}: the write did not complete. The volume keys has to be writable by the user nobody.\n"

    assert File.ls!(dir) == ["silent-bin"]
  end

  @tag :tmp_dir
  test "a directory it cannot write to exits non-zero, naming it and the reason",
       %{tmp_dir: dir} do
    missing = Path.join(dir, "missing")
    assert {output, 1} = run(missing)

    assert output =~
             ~r/\ACannot write #{Regex.escape(missing)}: [^\n]+\. The volume keys has to be writable by the user nobody\.\n\z/

    # Under root every directory is writable.
    if System.cmd("id", ["-u"]) != {"0\n", 0} do
      read_only = Path.join(dir, "read-only")
      File.mkdir_p!(read_only)
      File.chmod!(read_only, 0o500)
      on_exit(fn -> File.chmod(read_only, 0o700) end)

      assert {output, 1} = run(read_only)

      assert output ==
               "Cannot write #{read_only}: Permission denied. The volume keys has to be writable by the user nobody.\n"
    end
  end
end
