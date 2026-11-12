defmodule ApiaryPro.RuntimeConfigTest do
  # config/runtime.exs configures the core's settings and the edition's in one file: what the core
  # configures at runtime, and the edition's sign-up settings beside it. The documentation an
  # instance serves is this application's, the default of `ApiaryWeb.DocsController`, so
  # the file sets no `:docs_root`. (`Apiary.RuntimeConfigTest` reads the same file.)
  # Not async: reads config/runtime.exs under a changed system environment.
  use ExUnit.Case, async: false

  @env %{
    "DATABASE_URL" => "ecto://apiary:apiary@localhost/apiary",
    "SECRET_KEY_BASE" => String.duplicate("s", 64),
    "APIARY_ENCRYPTION_SECRET" => Base.encode64(String.duplicate("k", 32)),
    "APIARY_SIGNING_SECRET" => Base.encode64(String.duplicate("g", 32)),
    "PUBLIC_URL" => "https://qory.example",
    "SMTP_RELAY" => "smtp.example.com",
    "SIGNUP_ORGANISATIONS" => "open",
    "SIGNUP_OPERATORS" => "closed"
  }

  setup do
    previous = Map.new(@env, fn {name, _} -> {name, System.get_env(name)} end)
    System.put_env(@env)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  defp runtime(env), do: Config.Reader.read!("config/runtime.exs", env: env, target: :host)

  test "the core's runtime configuration is read, and the edition's settings" do
    config = runtime(:prod)

    # The core's: the database, the address and the mail, from the core's file.
    assert get_in(config, [:apiary, Apiary.Repo, :url]) == @env["DATABASE_URL"]
    assert get_in(config, [:apiary, ApiaryWeb.Endpoint, :url])[:host] == "qory.example"
    assert get_in(config, [:apiary, Apiary.Mailer, :adapter]) == Swoosh.Adapters.SMTP
    assert get_in(config, [:apiary, Apiary.Mailer, :relay]) == "smtp.example.com"

    # The edition's: the sign-up settings. The documentation is this application's, by default.
    assert get_in(config, [:apiary, :sign_up_organisations_setting]) == "open"
    assert get_in(config, [:apiary, :sign_up_operators_setting]) == "closed"
    refute Keyword.has_key?(config[:apiary], :docs_root)
  end

  test "the sign-up settings are not read under test" do
    config = runtime(:test)
    refute Keyword.has_key?(config[:apiary], :sign_up_organisations_setting)
    refute Keyword.has_key?(config[:apiary], :docs_root)
  end

  test "development reloads the page for the edition's files as for the core's" do
    patterns = get_in(runtime(:dev), [:apiary, ApiaryWeb.Endpoint, :live_reload, :patterns])

    assert Enum.any?(patterns, &Regex.match?(&1, "lib/apiary_pro_web/live/client_live/index.ex"))

    assert Enum.any?(
             patterns,
             &Regex.match?(&1, "priv/gettext/en@software/LC_MESSAGES/default.po")
           )

    assert Enum.any?(
             patterns,
             &Regex.match?(&1, "priv/gettext_pro/en@software/LC_MESSAGES/default.po")
           )

    assert Enum.any?(patterns, &Regex.match?(&1, "lib/apiary_web/router.ex"))
  end
end
