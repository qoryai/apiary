defmodule ApiaryWeb.ProviderKeyLogTest do
  # New model provider (`ApiaryWeb.ProviderLive.Index`) and Edit key
  # (`ApiaryWeb.ProviderLive.Key`) write no model key into a log line, when a save is
  # refused or crashes. Not async: the tests set Logger's level to debug.
  use ApiaryWeb.ConnCase, async: false

  # The other lines logged at debug are kept out of the test's output.
  @moduletag :capture_log
  @moduletag needs: [:factory, :secrets]

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  setup do
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)
  end

  defp models_path(scope), do: ~p"/#{scope.organisation}/settings/model-providers"
  defp new_path(scope), do: "#{models_path(scope)}/new"

  defp key, do: "sk-probe-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  # The log of `submit`, which crashes the page's process, up to the process's end.
  defp crash_log(lv, submit) do
    Process.flag(:trap_exit, true)
    ref = Process.monitor(lv.pid)

    capture_log([level: :debug], fn ->
      catch_exit(submit.())
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 5_000
    end)
  end

  # Without `Apiary.SecretLogFilter` this test passes too: Phoenix prints the last message
  # with its payload's `value`, the encoded form with the key, as `[FILTERED]`, because
  # `value` is in `:filter_parameters`; and the page's state has no key (`assign_form/3`).
  test "a save that crashes the page logs no key", %{conn: conn, scope: scope} do
    key = key()
    {:ok, lv, _html} = live(conn, new_path(scope))

    # An address sent as a map passes the save's checks as refused, then fails to render.
    log =
      crash_log(lv, fn ->
        render_submit(lv, "create", %{
          "provider" => %{"provider" => "litellm", "key" => key, "address" => %{"a" => "b"}}
        })
      end)

    assert log =~ "terminating"
    assert log =~ ~s(Last message: %Phoenix.Socket.Message{)
    refute log =~ key
  end

  # `assign_form/3` keeps the key out of the HTML and the state. The crash's stacktrace has
  # the key among the arguments of `handle_event/3`, which `Apiary.SecretLogFilter`
  # replaces with the call's arity.
  test "a refused save keeps no key, and a crash after it logs none", %{conn: conn, scope: scope} do
    key = key()
    {:ok, lv, _html} = live(conn, new_path(scope))

    html =
      render_submit(lv, "create", %{
        "provider" => %{"provider" => "litellm", "key" => key, "address" => "http://x.example"}
      })

    assert html =~ "https://"
    refute html =~ key
    refute inspect(:sys.get_state(lv.pid), limit: :infinity, printable_limit: :infinity) =~ key

    # An event the page has no clause for fails with the key among the call's arguments.
    log =
      crash_log(lv, fn ->
        render_submit(lv, "unknown", %{"provider" => %{"provider" => "anthropic", "key" => key}})
      end)

    assert log =~ "FunctionClauseError"
    refute log =~ key
  end

  # A New value on Edit key that fails its checks stays out of the HTML, the state and
  # the log; so does one that is saved, and one in an event that crashes the page.
  test "Edit key keeps a New value out of the HTML, the state and the log", ctx do
    %{conn: conn, scope: scope} = ctx

    {:ok, provider} =
      Apiary.Connections.create_provider(scope, %{
        provider: "anthropic",
        keys: [%{value_id: "main", value: key()}]
      })

    path = "#{models_path(scope)}/#{provider.public_id}/keys/main/edit"
    key = key()
    {:ok, lv, _html} = live(conn, path)

    log =
      capture_log([level: :debug], fn ->
        html =
          render_submit(lv, "save", %{"key" => %{"value_id" => "main", "key" => key <> <<0>>}})

        assert html =~ "must not contain a NUL byte"
        refute html =~ key
      end)

    refute log =~ key
    refute inspect(:sys.get_state(lv.pid), limit: :infinity, printable_limit: :infinity) =~ key

    log =
      capture_log([level: :debug], fn ->
        assert {:error, {:live_redirect, _to}} =
                 render_submit(lv, "save", %{"key" => %{"value_id" => "main", "key" => key}})
      end)

    refute log =~ key

    {:ok, lv, _html} = live(conn, path)

    log =
      crash_log(lv, fn ->
        render_submit(lv, "unknown", %{"key" => %{"value_id" => "main", "key" => key}})
      end)

    assert log =~ "FunctionClauseError"
    refute log =~ key
  end
end
