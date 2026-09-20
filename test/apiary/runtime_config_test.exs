defmodule Apiary.RuntimeConfigTest do
  # Not async: reads config/runtime.exs under a changed system environment.
  use ExUnit.Case, async: false

  @base %{
    "DATABASE_URL" => "ecto://apiary:apiary@localhost/apiary",
    "SECRET_KEY_BASE" => String.duplicate("s", 64),
    "CLOAK_KEY" => Base.encode64(String.duplicate("k", 32)),
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

  test "M4: production without a relay refuses to boot, naming both variables" do
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

  test "M4: MAIL_TO_LOG=true is the explicit opt-in to the log adapter" do
    System.put_env("MAIL_TO_LOG", "true")
    assert prod_mailer()[:adapter] == Swoosh.Adapters.Logger
  end

  test "M4: a relay is used when set, whatever MAIL_TO_LOG says" do
    System.put_env("SMTP_RELAY", "smtp.example.com")
    System.put_env("MAIL_TO_LOG", "true")
    mailer = prod_mailer()
    assert mailer[:adapter] == Swoosh.Adapters.SMTP
    assert mailer[:relay] == "smtp.example.com"
  end

  defp prod_config, do: Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)

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
