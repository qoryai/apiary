defmodule Apiary.RuntimeConfigTest do
  # Not async: reads config/runtime.exs under a changed system environment.
  use ExUnit.Case, async: false

  @base %{
    "DATABASE_URL" => "ecto://apiary:apiary@localhost/apiary",
    "SECRET_KEY_BASE" => String.duplicate("s", 64),
    "CLOAK_KEY" => Base.encode64(String.duplicate("k", 32)),
    "PUBLIC_URL" => "https://apiary.example.com"
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
