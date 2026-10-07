defmodule ApiaryWeb.NodeLive.AccessKeyLogTest do
  # Not async: the level of the log lines is lowered for a test and put back after it.
  use ApiaryWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import Apiary.NodesFixtures

  setup :register_and_log_in_user

  setup do
    previous = Logger.level()
    Logger.configure(level: :debug)
    Logger.put_module_level(Phoenix.LiveView.Logger, :debug)

    on_exit(fn ->
      Logger.delete_module_level(Phoenix.LiveView.Logger)
      Logger.configure(level: previous)
    end)
  end

  test "an enrolment code is in no log line: not the event's, nor the query's", %{
    conn: conn,
    scope: scope
  } do
    node = node_fixture(scope)
    path = ~p"/#{scope.organisation}/#{scope.workspace}/nodes/#{node}/access-key/new-code"

    {code, log} =
      with_log([level: :debug], fn ->
        {:ok, lv, _html} = live(conn, path)
        lv |> form("#code-new-form", code: %{label_hint: "build-01"}) |> render_submit()
        html = lv |> element("#code-issued-value") |> render()
        [code] = Regex.run(~r/qec_[0-9A-Z]{26}/, html)
        render_click(element(lv, "#code-issued-done-button"))
        code
      end)

    assert log =~ "HANDLE EVENT \"create_code\""
    refute log =~ code
    refute log =~ String.slice(code, 4..-1//1)
  end
end
