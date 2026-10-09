defmodule Apiary.RuntimeConfigTest do
  # Not async: reads config/runtime.exs under a changed system environment.
  use ExUnit.Case, async: false

  @base %{
    "DATABASE_URL" => "ecto://apiary:apiary@localhost/apiary",
    "SECRET_KEY_BASE" => String.duplicate("s", 64),
    "APIARY_ENCRYPTION_SECRET" => Base.encode64(String.duplicate("k", 32)),
    "APIARY_SIGNING_SECRET" => Base.encode64(String.duplicate("g", 32)),
    "PUBLIC_URL" => "https://qory.example"
  }
  @mail ~w(SMTP_RELAY SMTP_PORT SMTP_USERNAME SMTP_PASSWORD SMTP_TLS MAIL_TO_LOG MAIL_FROM)
  @unset ["APIARY_KEYS_DIR" | @mail]

  setup do
    names = Map.keys(@base) ++ @unset
    previous = Map.new(names, &{&1, System.get_env(&1)})
    Enum.each(@unset, &System.delete_env/1)
    System.put_env(@base)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  defp prod_mailer do
    "config/runtime.exs"
    |> Config.Reader.read!(env: :prod, target: :host)
    |> get_in([:apiary, Apiary.Mailer])
  end

  test "production without a relay refuses to boot, naming both variables" do
    error = assert_raise RuntimeError, fn -> prod_mailer() end
    assert error.message =~ "SMTP_RELAY"
    assert error.message =~ "MAIL_TO_LOG"

    # A blank line in .env is an unset relay, not a relay called "".
    System.put_env("SMTP_RELAY", "")
    assert_raise RuntimeError, ~r/MAIL_TO_LOG/, fn -> prod_mailer() end

    # Only the exact opt-in counts.
    System.put_env("MAIL_TO_LOG", "yes")
    assert_raise RuntimeError, ~r/MAIL_TO_LOG/, fn -> prod_mailer() end
  end

  test "MAIL_TO_LOG=true is the explicit opt-in to the log adapter" do
    System.put_env("MAIL_TO_LOG", "true")
    assert prod_mailer()[:adapter] == Swoosh.Adapters.Logger
  end

  test "a relay is used when set, whatever MAIL_TO_LOG says" do
    System.put_env("SMTP_RELAY", "smtp.example.com")
    System.put_env("MAIL_TO_LOG", "true")
    mailer = prod_mailer()
    assert mailer[:adapter] == Swoosh.Adapters.SMTP
    assert mailer[:relay] == "smtp.example.com"
  end

  defp prod_config, do: Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)

  describe "APIARY_ENCRYPTION_SECRET" do
    setup do
      System.put_env("MAIL_TO_LOG", "true")
    end

    test "its 32 bytes are what every key derives from, and key nothing themselves" do
      config = prod_config()

      assert get_in(config, [:apiary, Apiary.KeyDerivation, :secret]) ==
               String.duplicate("k", 32)
    end

    test "missing, or not 32 bytes in base64, it stops the boot, naming the variable" do
      System.delete_env("APIARY_ENCRYPTION_SECRET")
      assert_raise RuntimeError, ~r/APIARY_ENCRYPTION_SECRET is missing/, fn -> prod_config() end

      for value <- [Base.encode64(String.duplicate("k", 31)), "not base64!"] do
        System.put_env("APIARY_ENCRYPTION_SECRET", value)

        assert_raise RuntimeError, ~r/APIARY_ENCRYPTION_SECRET is not 32 bytes/, fn ->
          prod_config()
        end
      end
    end
  end

  describe "APIARY_SIGNING_SECRET" do
    setup do
      System.put_env("MAIL_TO_LOG", "true")
    end

    test "its 32 bytes are the signing key's seed, and nothing derives them" do
      config = prod_config()
      assert get_in(config, [:apiary, Apiary.SigningKey, :seed]) == String.duplicate("g", 32)

      # A secret of its own: the encryption secret is read as it was, and the seed is
      # not it.
      assert get_in(config, [:apiary, Apiary.KeyDerivation, :secret]) ==
               String.duplicate("k", 32)
    end

    test "missing or blank, it stops the boot, naming the variable: there is no fallback" do
      for set <- [&System.delete_env/1, &System.put_env(&1, "")] do
        set.("APIARY_SIGNING_SECRET")
        error = assert_raise RuntimeError, fn -> prod_config() end
        assert error.message =~ "APIARY_SIGNING_SECRET is missing"
        assert error.message =~ "openssl rand -base64 32"
      end
    end

    test "not 32 bytes in base64, it stops the boot, naming the variable and never the value" do
      for value <- [
            Base.encode64(String.duplicate("g", 31)),
            Base.encode64(String.duplicate("g", 33)),
            # The contract's fixture signing seed as the fixtures write it, base64url
            # without padding.
            "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVpbXF1eX2A",
            Base.url_encode64(<<0xFB>> <> String.duplicate("g", 31)),
            Base.encode64(String.duplicate("g", 32)) <> "\n",
            "not base64!"
          ] do
        System.put_env("APIARY_SIGNING_SECRET", value)
        error = assert_raise RuntimeError, fn -> prod_config() end
        assert error.message =~ "APIARY_SIGNING_SECRET is not 32 bytes in base64"
        refute error.message =~ String.trim(value)
      end
    end

    test "the same value as APIARY_ENCRYPTION_SECRET stops the boot, naming both, never the value" do
      value = Base.encode64(String.duplicate("k", 32))
      System.put_env("APIARY_SIGNING_SECRET", value)

      error = assert_raise RuntimeError, fn -> prod_config() end

      assert error.message =~
               "APIARY_SIGNING_SECRET is the same value as APIARY_ENCRYPTION_SECRET"

      assert error.message =~ "openssl rand -base64 32"
      refute error.message =~ value
      refute error.message =~ String.duplicate("k", 32)
    end

    test "the dev and test seeds this repository publishes stop the boot, never named by value" do
      # The core's files, which hold the seeds, wherever the suite runs from: an edition runs
      # these tests from its own checkout (its test_paths).
      for config_file <- ["config/dev.exs", "config/test.exs"] do
        seed =
          config_file
          |> Path.expand(Path.expand("../..", __DIR__))
          |> Config.Reader.read!(env: :test, target: :host, imports: :disabled)
          |> get_in([:apiary, Apiary.SigningKey, :seed])

        assert byte_size(seed) == 32
        value = Base.encode64(seed)
        System.put_env("APIARY_SIGNING_SECRET", value)

        error = assert_raise RuntimeError, fn -> prod_config() end

        assert error.message =~
                 "APIARY_SIGNING_SECRET is the development or test seed this repository publishes"

        assert error.message =~ "openssl rand -base64 32"
        refute error.message =~ value
        refute error.message =~ seed
      end
    end

    test "a value of its own, apart from the encryption secret and the published seeds, boots" do
      seed = :crypto.strong_rand_bytes(32)
      System.put_env("APIARY_SIGNING_SECRET", Base.encode64(seed))
      assert get_in(prod_config(), [:apiary, Apiary.SigningKey, :seed]) == seed
    end
  end

  describe "the two 32-byte keys in hex" do
    setup do
      System.put_env("MAIL_TO_LOG", "true")
    end

    defp configured_keys do
      config = prod_config()

      {get_in(config, [:apiary, Apiary.KeyDerivation, :secret]),
       get_in(config, [:apiary, Apiary.SigningKey, :seed])}
    end

    test "64 characters in lower, upper or mixed case are the same 32 bytes as base64" do
      encryption = :crypto.strong_rand_bytes(32)
      signing = :crypto.strong_rand_bytes(32)

      mixed = fn bytes ->
        bytes
        |> Base.encode16(case: :lower)
        |> String.graphemes()
        |> Enum.with_index()
        |> Enum.map_join(fn {char, i} ->
          if rem(i, 2) == 0, do: String.upcase(char), else: char
        end)
      end

      for encode <- [
            &Base.encode64/1,
            &Base.encode16(&1, case: :lower),
            &Base.encode16(&1, case: :upper),
            mixed
          ] do
        System.put_env("APIARY_ENCRYPTION_SECRET", encode.(encryption))
        System.put_env("APIARY_SIGNING_SECRET", encode.(signing))

        assert configured_keys() == {encryption, signing},
               "a form of the two keys was not decoded to their bytes"
      end

      # The mixed form above holds both cases, whatever the bytes.
      assert mixed.(<<0xAB, 0xCD>>) == "AbCd"
    end

    test "64 characters that are not hex are refused, naming the variable and never the value" do
      for variable <- ["APIARY_ENCRYPTION_SECRET", "APIARY_SIGNING_SECRET"],
          # Not hex; the first is base64 of 48 bytes, the second hex of 32 with one wrong
          # character.
          value <- [
            String.duplicate("g", 64),
            String.duplicate("a", 63) <> "x",
            String.duplicate("a", 62) <> " a"
          ] do
        System.put_env(@base)
        System.put_env(variable, value)

        error = assert_raise RuntimeError, fn -> prod_config() end

        assert error.message =~
                 "#{variable} is not 32 bytes in base64 (44 characters) or in hex (64 characters)."

        refute error.message =~ value
      end
    end

    test "the same key in hex and in base64 is the same value: the bytes are compared" do
      key = String.duplicate("k", 32)

      for {encryption, signing} <- [
            {Base.encode64(key), Base.encode16(key)},
            {Base.encode16(key, case: :lower), Base.encode64(key)},
            {Base.encode16(key, case: :lower), Base.encode16(key, case: :upper)}
          ] do
        System.put_env("APIARY_ENCRYPTION_SECRET", encryption)
        System.put_env("APIARY_SIGNING_SECRET", signing)

        error = assert_raise RuntimeError, fn -> prod_config() end

        assert error.message =~
                 "APIARY_SIGNING_SECRET is the same value as APIARY_ENCRYPTION_SECRET"

        refute error.message =~ encryption
        refute error.message =~ signing
      end
    end

    test "a published seed given in hex is refused" do
      for config_file <- ["config/dev.exs", "config/test.exs"],
          case <- [:lower, :upper] do
        seed =
          config_file
          |> Path.expand(Path.expand("../..", __DIR__))
          |> Config.Reader.read!(env: :test, target: :host, imports: :disabled)
          |> get_in([:apiary, Apiary.SigningKey, :seed])

        value = Base.encode16(seed, case: case)
        System.put_env("APIARY_SIGNING_SECRET", value)

        error = assert_raise RuntimeError, fn -> prod_config() end

        assert error.message =~
                 "APIARY_SIGNING_SECRET is the development or test seed this repository publishes"

        refute error.message =~ value
        refute error.message =~ seed
      end
    end
  end

  describe "the keys file" do
    setup do
      System.put_env("MAIL_TO_LOG", "true")
    end

    @file_keys %{
      "SECRET_KEY_BASE" => String.duplicate("f", 64),
      "APIARY_ENCRYPTION_SECRET" => Base.encode64(String.duplicate("e", 32)),
      "APIARY_SIGNING_SECRET" => Base.encode16(String.duplicate("i", 32))
    }

    defp write_keys_file(dir, keys) do
      File.write!(
        Path.join(dir, "apiary.env"),
        Enum.map_join(keys, fn {name, value} -> "#{name}=#{value}\n" end)
      )

      System.put_env("APIARY_KEYS_DIR", dir)
    end

    defp configured_secrets do
      config = prod_config()

      {get_in(config, [:apiary, ApiaryWeb.Endpoint, :secret_key_base]),
       get_in(config, [:apiary, Apiary.KeyDerivation, :secret]),
       get_in(config, [:apiary, Apiary.SigningKey, :seed])}
    end

    @tag :tmp_dir
    test "gives each key the environment does not set", %{tmp_dir: dir} do
      write_keys_file(dir, @file_keys)
      Enum.each(Map.keys(@file_keys), &System.delete_env/1)

      assert configured_secrets() ==
               {String.duplicate("f", 64), String.duplicate("e", 32), String.duplicate("i", 32)}

      # A blank line in .env is an unset value, so the file's is used.
      Enum.each(Map.keys(@file_keys), &System.put_env(&1, ""))

      assert configured_secrets() ==
               {String.duplicate("f", 64), String.duplicate("e", 32), String.duplicate("i", 32)}
    end

    @tag :tmp_dir
    test "the environment always wins", %{tmp_dir: dir} do
      write_keys_file(dir, @file_keys)

      assert configured_secrets() ==
               {String.duplicate("s", 64), String.duplicate("k", 32), String.duplicate("g", 32)}

      # One name from each: the environment's where it sets it, the file's where not.
      System.delete_env("APIARY_SIGNING_SECRET")

      assert configured_secrets() ==
               {String.duplicate("s", 64), String.duplicate("k", 32), String.duplicate("i", 32)}
    end

    @tag :tmp_dir
    test "a key neither sets stops the boot, saying where compose.yaml keeps it",
         %{tmp_dir: dir} do
      for name <- Map.keys(@file_keys) do
        System.put_env(@base)
        write_keys_file(dir, Map.delete(@file_keys, name))
        System.delete_env(name)

        error = assert_raise RuntimeError, fn -> prod_config() end
        assert error.message =~ "#{name} is missing."

        assert error.message =~
                 "With compose.yaml, the service keys generates it at first start, in /var/lib/apiary/keys/apiary.env."
      end
    end

    @tag :tmp_dir
    test "is read only from APIARY_KEYS_DIR", %{tmp_dir: dir} do
      write_keys_file(dir, @file_keys)
      System.delete_env("APIARY_KEYS_DIR")
      System.delete_env("APIARY_SIGNING_SECRET")

      assert_raise RuntimeError, ~r/APIARY_SIGNING_SECRET is missing/, fn -> prod_config() end
    end
  end

  describe "PUBLIC_URL" do
    setup do
      System.put_env("MAIL_TO_LOG", "true")
    end

    test "a scheme, a host and a port are what the endpoint is given" do
      System.put_env("PUBLIC_URL", "https://qory.example:8443/")
      url = get_in(prod_config(), [:apiary, ApiaryWeb.Endpoint, :url])
      assert url == [scheme: "https", host: "qory.example", port: 8443]
      assert get_in(prod_config(), [:apiary, :mail_from]) == "qory@qory.example"
    end

    test "a path, a query or a user is refused at boot: the gateway would refuse the server" do
      for url <- [
            "https://qory.example/console",
            "https://qory.example/?a=1",
            "https://qory.example#x",
            "https://ada@qory.example"
          ] do
        System.put_env("PUBLIC_URL", url)
        error = assert_raise RuntimeError, fn -> prod_config() end
        assert error.message =~ "PUBLIC_URL must be a scheme and a host"
        assert error.message =~ "https://qory.example"
      end
    end

    test "every refusal names Qory's example address, never another product name" do
      for url <- ["qory.example", "ftp://qory.example", "https://"] do
        System.put_env("PUBLIC_URL", url)
        error = assert_raise RuntimeError, fn -> prod_config() end
        assert error.message =~ "PUBLIC_URL"
        assert error.message =~ "https://qory.example"
        refute error.message =~ ~r/apiary/i
      end
    end
  end

  describe "Oban's crontab" do
    test "is the application's: the core's daily sweeps, then the edition's jobs" do
      oban = Application.get_env(:apiary, Oban)

      assert Enum.map(oban[:crontab], &elem(&1, 1)) ==
               [
                 Apiary.Audit.PruneSweep,
                 Apiary.Organisations.InvitationSweep,
                 Apiary.Deletion.PurgeSweep
               ] ++ Enum.map(Apiary.Edition.crontab(), &elem(&1, 1))

      for {expression, _worker} <- oban[:crontab] do
        assert {:ok, _} = Oban.Cron.Expression.parse(expression)
      end

      # The rest of Oban's configuration is the configuration's, the suite's manual testing
      # included.
      assert oban[:repo] == Apiary.Repo
      assert oban[:queues] == [default: 5]
      assert oban[:testing] == :manual
    end

    test "is not in the configuration, so an edition never restates Oban's" do
      config = Config.Reader.read!("config/config.exs", env: :prod, target: :host)
      assert get_in(config, [:apiary, Oban, :repo]) == Apiary.Repo
      refute Keyword.has_key?(get_in(config, [:apiary, Oban]), :crontab)
    end
  end

  test "a blank SMTP_USERNAME, as .env.example leaves it, is no authentication" do
    System.put_env("SMTP_RELAY", "smtp.example.com")
    System.put_env("SMTP_USERNAME", "")
    assert prod_mailer()[:auth] == :never

    System.put_env("SMTP_USERNAME", "relay-user")
    mailer = prod_mailer()
    assert mailer[:auth] == :always
    assert mailer[:username] == "relay-user"
  end
end
