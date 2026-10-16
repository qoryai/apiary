defmodule ApiaryWeb.LiveViewLogTest do
  @moduledoc """
  The lines a page logs at debug as it mounts, handles its parameters and handles an
  event keep the keys, the event's name and the page, and write every value as
  `[FILTERED]` (`ApiaryWeb.LiveViewLog`).
  """
  # Not async: the tests set Logger's level to debug.
  use ApiaryWeb.ConnCase, async: false

  # The other lines logged at debug are kept out of the test's output.
  @moduletag :capture_log

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias ApiaryWeb.LiveViewLog

  # What a client sends: no log line may hold it.
  @marker "plaintext-marker-5e1c"

  @events [
    [:phoenix, :live_view, :mount, :start],
    [:phoenix, :live_view, :handle_params, :start],
    [:phoenix, :live_view, :handle_event, :start],
    [:phoenix, :live_component, :handle_event, :start]
  ]

  setup do
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)
  end

  describe "a signed-in person's page" do
    setup :register_and_log_in_user

    test "logs its mount, its parameters and an event with the keys and no value",
         %{conn: conn, user: _user, scope: scope} do
      token = get_session(conn, :user_token)
      socket_id = "users_sessions:" <> Base.url_encode64(token)
      conn = put_session(conn, :live_socket_id, socket_id)
      path = "/#{scope.organisation.slug}/audit-log"

      # The page is rendered before the level counts: the request's line is Phoenix's
      # request log, which this does not change.
      Logger.put_process_level(self(), :warning)
      conn = get(conn, "#{path}?note=#{@marker}")
      Logger.delete_process_level(self())

      log =
        capture_log([level: :debug], fn ->
          {:ok, view, _html} = live(conn)
          render_async(view)

          render_patch(view, "#{path}?note=#{@marker}-patched")
          render_async(view)

          render_hook(view, "narrow", %{
            "_filter" => "action",
            "q" => @marker,
            "nested" => %{"list" => [@marker, 7]}
          })
        end)

      [mount] = entries(log, "MOUNT ")
      assert mount =~ "MOUNT ApiaryWeb.ActivityLive\n  Parameters: %{"
      assert mount =~ ~s("note" => "[FILTERED]")
      assert mount =~ "\n  Session: %{"
      assert mount =~ ~s("user_token" => "[FILTERED]")
      assert mount =~ ~s("live_socket_id" => "[FILTERED]")

      # The connected mount's, and the patch's.
      [_first, patched] = params = entries(log, "HANDLE PARAMS ")
      assert patched =~ "HANDLE PARAMS in ApiaryWeb.ActivityLive\n  Parameters: %{"
      assert patched =~ ~s("note" => "[FILTERED]")

      [event] = entries(log, "HANDLE EVENT ")
      assert event =~ ~s(HANDLE EVENT "narrow" in ApiaryWeb.ActivityLive\n  Parameters: %{)
      assert event =~ ~s("_filter" => "[FILTERED]")
      assert event =~ ~s("q" => "[FILTERED]")
      assert event =~ ~s("nested" => %{"list" => ["[FILTERED]", "[FILTERED]"]})

      # Each is still followed by LiveView's line of its timing.
      assert length(entries(log, "Replied in ")) == 4

      # The token is in the lines of the queries that read it, Ecto's, which this does not
      # change: the page's lines hold none of it.
      for line <- [mount, event | params] do
        refute line =~ token
        refute line =~ inspect(token)
        refute line =~ Base.url_encode64(token)
        refute line =~ Base.encode64(token)
        refute line =~ socket_id
      end

      refute log =~ @marker
    end
  end

  # The entries of a captured log that `text` starts, after the level.
  defp entries(log, text) do
    ~r/(?=^\d\d:\d\d:\d\d\.\d{3} )/m
    |> Regex.split(log)
    |> Enum.filter(&String.contains?(&1, "[debug] " <> text))
  end

  test "a component's event keeps its name, the page and the component, and no value" do
    socket = %Phoenix.LiveView.Socket{view: ApiaryWeb.ActivityLive}

    log =
      capture_log([level: :debug], fn ->
        :telemetry.execute(
          [:phoenix, :live_component, :handle_event, :start],
          %{system_time: System.system_time()},
          %{
            socket: socket,
            component: ApiaryWeb.LiveViewLogTest,
            event: "save",
            params: %{"form" => %{"name" => @marker}}
          }
        )
      end)

    assert log =~ ~s(HANDLE EVENT "save" in ApiaryWeb.ActivityLive)
    assert log =~ "Component: ApiaryWeb.LiveViewLogTest"
    assert log =~ ~s(Parameters: %{"form" => %{"name" => "[FILTERED]"}})
    refute log =~ @marker
  end

  test "at boot, LiveView's handlers of these lines are detached and this module's attached" do
    handlers = fn ->
      for event <- @events do
        event
        |> :telemetry.list_handlers()
        |> Enum.filter(&(&1.event_name == event))
        |> Enum.map(& &1.id)
      end
    end

    assert handlers.() == List.duplicate(["apiary-live-view-log"], length(@events))

    # Attaching again changes nothing.
    assert LiveViewLog.attach() == :ok
    assert handlers.() == List.duplicate(["apiary-live-view-log"], length(@events))

    # The `Replied in` lines are still LiveView's.
    assert Enum.any?(
             :telemetry.list_handlers([:phoenix, :live_view, :mount, :stop]),
             &match?(%{id: {Phoenix.LiveView.Logger, _event}}, &1)
           )
  end

  test "an event it cannot read is passed by, and the handler stays attached" do
    log =
      capture_log([level: :debug], fn ->
        assert LiveViewLog.handle_event(@events |> hd(), %{}, %{socket: :not_a_socket}, nil) ==
                 :ok

        assert LiveViewLog.handle_event(@events |> hd(), %{}, %{}, nil) == :ok
      end)

    refute log =~ "MOUNT"

    assert [%{id: "apiary-live-view-log"}] =
             :telemetry.list_handlers([:phoenix, :live_view, :mount, :start])
  end

  test "mask/1 keeps a map's keys and the nesting, and writes every value as [FILTERED]" do
    assert LiveViewLog.mask(%{"a" => [1, %{"b" => @marker}], :c => {1, 2}}) ==
             %{"a" => ["[FILTERED]", %{"b" => "[FILTERED]"}], :c => "[FILTERED]"}

    assert LiveViewLog.mask([1 | @marker]) == ["[FILTERED]" | "[FILTERED]"]
    assert LiveViewLog.mask(~D[2026-10-16]) == "[FILTERED]"
    assert LiveViewLog.mask(:not_mounted_at_router) == "[FILTERED]"
  end
end
