defmodule Apiary.RuntimeConfigTest do
  # Not async: reads config/runtime.exs under a changed system environment.
  use ExUnit.Case, async: false

  @base %{
    "DATABASE_URL" => "ecto://apiary:apiary@localhost/apiary",
    "SECRET_KEY_BASE" => String.duplicate("s", 64),
    "APIARY_ENCRYPTION_SECRET" => Base.encode64(String.duplicate("k", 32)),
    "PUBLIC_URL" => "https://qory.example"
  }
  @mail ~w(SMTP_RELAY SMTP_PORT SMTP_USERNAME SMTP_PASSWORD SMTP_TLS MAIL_TO_LOG MAIL_FROM)

  setup do
    names = Map.keys(@base) ++ @mail
    previous = Map.new(names, &{&1, System.get_env(&1)})
    Enum.each(@mail, &System.delete_env/1)
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

    test "its 32 bytes are the access key cipher's key and what the other keys derive from" do
      config = prod_config()
      secret = String.duplicate("k", 32)

      assert get_in(config, [:apiary, Apiary.KeyDerivation, :secret]) == secret

      assert [default: {Cloak.Ciphers.AES.GCM, cipher}] =
               get_in(config, [:apiary, Apiary.Vault, :ciphers])

      assert cipher[:key] == secret
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

    test "a path, a query or a user is refused at boot: a runner would refuse the server" do
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
