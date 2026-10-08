defmodule ApiaryWeb.SecretLive.LogTest do
  # Not async: the level of the LiveView's own log lines is the node's, lowered for a test
  # and put back after it.
  use ApiaryWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  @moduletag needs: :secrets

  @value "ghp_exampleTokenValue0123456789"

  setup :register_and_log_in_user

  setup do
    Logger.put_module_level(Phoenix.LiveView.Logger, :debug)
    on_exit(fn -> Logger.delete_module_level(Phoenix.LiveView.Logger) end)
  end

  test "a value is filtered out of the parameters a log line holds" do
    filtered =
      Phoenix.Logger.filter_values(%{
        "secret" => %{"name" => "FORGE_TOKEN", "value" => @value},
        "secret_value" => %{"value" => @value},
        "variable" => %{"name" => "NPM_REGISTRY", "value" => "https://registry.example.com"}
      })

    refute inspect(filtered) =~ @value
    refute inspect(filtered) =~ "registry.example.com"
  end

  test "a LiveView event's line names the event, never the value", %{conn: conn, scope: scope} do
    log =
      capture_log([level: :debug], fn ->
        {:ok, lv, _html} =
          live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings/secrets/new")

        lv
        |> form("#secret-form", secret: %{name: "FORGE_TOKEN", value: @value})
        |> render_submit()
      end)

    assert log =~ "HANDLE EVENT \"create_secret\""
    assert log =~ "[FILTERED]"
    refute log =~ @value
  end
end
