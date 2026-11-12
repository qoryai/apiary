defmodule ApiaryWeb.ModelChoiceUncheckedTest do
  # Workspace settings › Model with a provider whose settings check ran out of time or
  # crashed (`Apiary.Connections.provider/1`): the provider serves nothing on that read,
  # and the page shows no "Add … again" line for it. The test sets the check for every
  # process (`SettingsFit.put_test_check/1`), so it is not async.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Apiary.Connections
  alias Apiary.Connections.SettingsFit

  @moduletag needs: [:factory, :secrets]

  setup :register_and_log_in_user

  setup %{scope: scope} do
    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "anthropic",
        keys: [%{value_id: "key-1", value: "sk-ant-model-unchecked-0123456789"}]
      })

    SettingsFit.put_test_check(fn _entry, _settings -> :unchecked end)
    SettingsFit.clear()

    on_exit(fn ->
      SettingsFit.put_test_check(nil)
      SettingsFit.clear()
    end)

    %{provider: provider}
  end

  test "shows no line to add the provider again", %{conn: conn, scope: scope, provider: provider} do
    {:ok, lv, html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings/model")

    refute has_element?(lv, "#model-changed-#{provider.public_id}")
    refute has_element?(lv, "#model-unknown-#{provider.public_id}")
    refute html =~ "again in"
    refute has_element?(lv, "#model-submit")
  end
end
