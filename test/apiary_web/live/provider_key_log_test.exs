defmodule ApiaryWeb.ProviderKeyLogTest do
  # New model provider key (`ApiaryWeb.ProviderLive.Index`) and Edit key
  # (`ApiaryWeb.ProviderLive.Key`) write no model key into a log line, when a save is
  # refused, dropped or crashes. Not async: the tests set Logger's level to debug.
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

  # New model provider key drops an event whose fields are not each a string, before it is
  # read: the page stays up, so no crash report prints the event, and the key in it.
  test "a save with a field that is not a string is dropped, and logs no key", ctx do
    %{conn: conn, scope: scope} = ctx
    key = key()
    {:ok, lv, _html} = live(conn, new_path(scope))

    log =
      capture_log([level: :debug], fn ->
        html =
          render_submit(lv, "create", %{
            "provider" => %{"provider" => "litellm", "key" => key, "address" => %{"a" => "b"}}
          })

        refute html =~ key
      end)

    assert Process.alive?(lv.pid)
    assert has_element?(lv, "#new-provider-form")
    refute log =~ key
    assert Apiary.Connections.list_providers(scope) == {:ok, []}
  end

  # `assign_form/4` keeps the key out of the HTML and the state; an event the page has no
  # use for is dropped with the key in it.
  test "a refused save keeps no key, and an unknown event after it logs none", ctx do
    %{conn: conn, scope: scope} = ctx
    key = key()
    {:ok, lv, _html} = live(conn, new_path(scope))

    html =
      render_submit(lv, "create", %{
        "provider" => %{"provider" => "litellm", "key" => key, "address" => "http://x.example"}
      })

    assert html =~ "https://"
    refute html =~ key
    refute inspect(:sys.get_state(lv.pid), limit: :infinity, printable_limit: :infinity) =~ key
    assert Apiary.Connections.list_providers(scope) == {:ok, []}

    log =
      capture_log([level: :debug], fn ->
        render_submit(lv, "unknown", %{"provider" => %{"provider" => "anthropic", "key" => key}})
      end)

    assert Process.alive?(lv.pid)
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

    row =
      Apiary.Repo.get_by!(Apiary.Secrets.Value, secret_id: provider.secret_id, value_id: "main")

    path = "#{models_path(scope)}/#{provider.public_id}/keys/#{row.id}/edit"
    key = key()
    {:ok, lv, _html} = live(conn, path)

    log =
      capture_log([level: :debug], fn ->
        html =
          render_submit(lv, "save", %{"key" => %{"name" => "main", "key" => key <> <<0>>}})

        assert html =~ "must not contain a NUL byte"
        refute html =~ key
      end)

    refute log =~ key
    refute inspect(:sys.get_state(lv.pid), limit: :infinity, printable_limit: :infinity) =~ key

    log =
      capture_log([level: :debug], fn ->
        assert {:error, {:live_redirect, _to}} =
                 render_submit(lv, "save", %{"key" => %{"name" => "main", "key" => key}})
      end)

    refute log =~ key

    {:ok, lv, _html} = live(conn, path)

    log =
      crash_log(lv, fn ->
        render_submit(lv, "unknown", %{"key" => %{"key" => key}})
      end)

    assert log =~ "FunctionClauseError"
    refute log =~ key
  end
end
