defmodule ApiaryWeb.NodeLive.AccessKeyLogTest do
  # Not async: the level of the log lines is lowered for a test and put back after it.
  use ApiaryWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures

  alias Apiary.AccessKeys

  # What a test logs besides what it captures is shown only if it fails.
  @moduletag :capture_log

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

  describe "a key generated in the browser" do
    @secret "qak_AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA"

    defp generate_path(scope, node),
      do: ~p"/#{scope.organisation}/#{scope.workspace}/nodes/#{node}/access-key/generate"

    test "an event that carries a secret is refused, and the secret is in no log line", %{
      conn: conn,
      scope: scope
    } do
      node = node_fixture(scope)

      key = %{
        "label" => "ci",
        "allow_secrets" => "false",
        "public_key" => ed25519_key_pair().encoded
      }

      for event <- [
            %{"key" => Map.put(key, "secret", @secret)},
            %{"key" => %{key | "label" => @secret}},
            %{"key" => %{key | "public_key" => String.upcase(@secret)}},
            %{"key" => key, "secret" => @secret}
          ] do
        {:ok, lv, _html} = live(conn, generate_path(scope, node))

        log =
          capture_log([level: :debug], fn ->
            render_hook(lv, "generate_key", event)
            render(lv)
          end)

        assert log =~ ~s(HANDLE EVENT "generate_key")
        assert log =~ "[FILTERED]"
        refute log =~ ~r/qak_/i
        refute log =~ "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA"
      end

      assert AccessKeys.list_for_node(scope, node) == []
    end

    test "the page writes no line of its own, and the debug line holds the public half alone",
         %{conn: conn, scope: scope} do
      node = node_fixture(scope)
      pair = ed25519_key_pair()
      {:ok, lv, _html} = live(conn, generate_path(scope, node))

      info =
        capture_log([level: :info], fn ->
          render_hook(lv, "generate_key", %{
            "key" => %{"label" => "ci", "allow_secrets" => "true", "public_key" => pair.encoded}
          })

          render(lv)
        end)

      refute info =~ "generate"
      refute info =~ pair.encoded
      assert [_key] = AccessKeys.list_for_node(scope, node)

      {:ok, lv, _html} = live(conn, generate_path(scope, node))

      debug =
        capture_log([level: :debug], fn ->
          render_hook(lv, "generate_key", %{
            "key" => %{"label" => "qak_x", "allow_secrets" => "true", "public_key" => "x"}
          })
        end)

      assert debug =~ ~s(HANDLE EVENT "generate_key")
      # Phoenix's name filter: the flag's name holds "secret".
      assert debug =~ ~s("allow_secrets" => "[FILTERED]")
      refute debug =~ ~r/qak_/i
    end
  end
end
