defmodule ApiaryWeb.CrashReportLogTest do
  @moduledoc """
  A frame a page's process fails on, sent on the page's channel as a client could send it:
  the crash report keeps what the frame carried out of every log line (the payload, the
  exception's terms, the arguments of the stacktrace's calls and, at debug, the state), and
  still names the exception, the function it was raised in and the page
  (`Apiary.SecretLogFilter`).
  """
  # Not async: the tests set Logger's level to debug, and the set-up page's test hides the
  # instance's organisation, a row every test shares.
  use ApiaryWeb.ConnCase, async: false

  # The lines the pages log as they mount, at debug, are kept out of the test's output.
  @moduletag :capture_log

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import Apiary.AccountsFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Accounts

  # What a client sends: no log line may hold it.
  @marker "plaintext-marker-7d2b"

  # A log handler that hands the test each event the page's process logs, as a handler is
  # given it: after the primary filters, Elixir's translator among them, so with its text
  # and its `:crash_reason` metadata.
  defmodule Sink do
    @moduledoc false
    def log(event, %{config: %{test: test, pid: pid}}) do
      if self() == pid, do: send(test, {:crash_report_event, event})
      :ok
    end
  end

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  # The page's process is sent a frame's event with `payload` (and the message's `fields`),
  # and fails on it: what it logged, as the captured text and as the events a handler is
  # given.
  #
  # The page's async tasks finish first (`render_async/1`). A task still reading when the
  # page fails is killed with it, holding the test's sandbox connection: the connection is
  # closed, and the test's next query finds no owner (`DBConnection.OwnershipError`).
  defp crash(view, payload, level \\ :error, fields \\ []) do
    render_async(view)
    {_ref, topic, _proxy} = view.proxy
    pid = view.pid
    ref = Process.monitor(pid)
    id = :"crash_report_sink_#{System.unique_integer([:positive])}"
    :ok = :logger.add_handler(id, Sink, %{level: :all, config: %{test: self(), pid: pid}})

    log =
      try do
        capture_log([level: level], fn ->
          message = %Phoenix.Socket.Message{
            topic: topic,
            event: "event",
            ref: "crash-test",
            payload: payload
          }

          send(pid, struct!(message, fields))

          assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
        end)
      after
        :logger.remove_handler(id)
      end

    {log, events()}
  end

  defp events do
    receive do
      {:crash_report_event, event} -> [event | events()]
    after
      0 -> []
    end
  end

  # An event as a handler would write it: its message's text and its metadata.
  defp text(%{msg: msg, meta: meta}) do
    message =
      case msg do
        {:string, chardata} -> IO.chardata_to_string(chardata)
        other -> inspect(other, limit: :infinity, printable_limit: :infinity)
      end

    message <> inspect(meta, limit: :infinity, printable_limit: :infinity)
  end

  # The crash is logged, names what it names, and holds none of the needles: in the text,
  # in the events, and in their `:crash_reason`.
  defp assert_stripped({log, events}, needles, names) do
    assert log =~ "terminating"
    assert Enum.any?(events, &match?(%{meta: %{crash_reason: {_, [_ | _]}}}, &1))

    for name <- names, do: assert(log =~ name)

    for needle <- needles do
      refute log =~ needle
      for event <- events, do: refute(text(event) =~ needle)
    end
  end

  describe "a frame the page's channel cannot read" do
    # Each payload, what the report names: the exception and the function it was raised in.
    defp unread do
      m = @marker

      [
        {%{"type" => "form", "event" => "submit", "value" => %{"user" => %{"password" => m}}},
         [
           "(FunctionClauseError) no function clause matching in Plug.Conn.Query.decode/4",
           "Plug.Conn.Query.decode/4",
           "Phoenix.LiveView.Channel.decode_event_type/3"
         ]},
        {%{"event" => "submit", "value" => %{"password" => m}},
         ["(MatchError)", "Phoenix.LiveView.Channel.handle_info/2"]},
        {%{"type" => "hook", "event" => "submit", "password" => m},
         ["(MatchError)", "Phoenix.LiveView.Channel.handle_info/2"]},
        {%{"type" => "form", "event" => "submit", "value" => "a=1", "meta" => m},
         ["(BadMapError)", "Phoenix.LiveView.Channel.maybe_merge_meta/2"]},
        {%{"type" => "form", "event" => "submit", "value" => "a=1", "meta" => [%{"x" => m}]},
         ["(BadMapError)", "Phoenix.LiveView.Channel.maybe_merge_meta/2"]},
        {m, ["(MatchError)", "Phoenix.LiveView.Channel.handle_info/2"]},
        {[m], ["(MatchError)", "Phoenix.LiveView.Channel.handle_info/2"]},
        {%{"type" => "hook", "event" => "submit", "value" => %{"x" => m}, "cid" => m},
         [
           "(FunctionClauseError) no function clause matching in " <>
             "Phoenix.LiveView.Diff.write_component/4",
           "Phoenix.LiveView.Channel.component_handle/4"
         ]}
      ]
    end

    test "keeps the payload out of the crash report, and names the exception", %{conn: conn} do
      for {payload, names} <- unread() do
        {:ok, view, _html} = live(conn, ~p"/users/log-in")

        view
        |> crash(payload)
        |> assert_stripped([@marker], [
          "Process Label: {Phoenix.LiveView, ApiaryWeb.UserLive.Login" | names
        ])
      end
    end

    test "writes the last message without its payload", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/log-in")
      {log, _events} = crash(view, %{"type" => "form", "event" => "submit", "meta" => @marker})

      assert log =~ ~s(event: "event", payload: "[FILTERED]")
      refute log =~ @marker
    end
  end

  describe "what a client chose in the message" do
    test "keeps its references out of the report", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/log-in")

      {log, events} =
        crash(view, %{"type" => "form", "event" => "x", "value" => "a=1", "meta" => 1}, :error,
          ref: @marker,
          join_ref: @marker
        )

      assert log =~ ~s(event: "event", payload: "[FILTERED]", ref: "[FILTERED]")
      assert_stripped({log, events}, [@marker], ["(BadMapError)"])
    end

    test "keeps a number it sent out of the report", %{conn: conn} do
      number = "987654321987"

      {:ok, view, _html} = live(conn, ~p"/users/log-in")

      view
      |> crash(%{"type" => "form", "event" => "x", "value" => "a=1", "meta" => 987_654_321_987})
      |> assert_stripped([number], ["(BadMapError)"])

      conn = log_in_user(conn, user_fixture())
      {:ok, view, _html} = live(conn, ~p"/users/settings")

      view
      |> crash(%{
        "type" => "hook",
        "event" => "update_password",
        "value" => %{"user" => 987_654_321_987}
      })
      |> assert_stripped([number], ["(Ecto.CastError)"])
    end
  end

  describe "the set-up page" do
    setup do
      Apiary.EditionKit.hide_instance_organisation()
      %{code: Apiary.Setup.code!()}
    end

    test "keeps the set-up code out of a save's crash report", %{conn: conn, code: code} do
      {:ok, view, _html} = live(conn, ~p"/setup/#{code}")

      view
      |> crash(%{"type" => "hook", "event" => "save", "value" => %{"user" => @marker}})
      |> assert_stripped([@marker, code], [
        "(FunctionClauseError) no function clause matching in Apiary.Setup.set_up/3",
        "ApiaryWeb.SetupLive.handle_event/3"
      ])
    end
  end

  describe "account settings" do
    setup %{conn: conn} do
      %{conn: log_in_user(conn, user_fixture())}
    end

    test "keeps a password out of a crash report", %{conn: conn} do
      m = @marker

      for {event, value, names} <- [
            {"update_password", %{"current_password" => m, "password" => m}, ["(MatchError)"]},
            {"validate_password", %{"password" => m}, ["(MatchError)"]},
            {"validate_email", %{"email" => m}, ["(MatchError)"]},
            {"update_email", %{"current_password" => m}, ["(MatchError)"]},
            {"update_password", %{"user" => m}, ["(Ecto.CastError)", "Ecto.Changeset.cast/7"]},
            {"validate_password", %{"user" => m}, ["(Ecto.CastError)", "Ecto.Changeset.cast/7"]}
          ] do
        {:ok, view, _html} = live(conn, ~p"/users/settings")

        view
        |> crash(%{"type" => "hook", "event" => event, "value" => value})
        |> assert_stripped([m], ["ApiaryWeb.UserLive.Settings.handle_event/3" | names])
      end
    end
  end

  describe "a page whose link carries a token" do
    test "the log-in page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/log-in")

      view
      |> crash(%{"type" => "hook", "event" => "change", "value" => %{"password" => @marker}})
      |> assert_stripped([@marker], [
        "no function clause matching in ApiaryWeb.UserLive.Login.handle_event/3"
      ])
    end

    test "the sign-up page of an invitation", %{conn: conn} do
      owner = sign_up_fixture()
      %{token: token} = invitation_fixture(owner.scope, %{"email" => "bee@example.com"})

      for {value, names} <- [
            {%{"password" => @marker},
             ["no function clause matching in ApiaryWeb.UserLive.Registration.handle_event/3"]},
            {%{"user" => @marker}, ["ApiaryWeb.UserLive.Registration.handle_event/3"]}
          ],
          event <- ["validate", "save"] do
        {:ok, view, _html} = live(conn, ~p"/users/register?invitation=#{token}")

        view
        |> crash(%{"type" => "hook", "event" => event, "value" => value})
        |> assert_stripped([@marker, token], names)
      end
    end

    test "the page of a log-in link", %{conn: conn} do
      user = unconfirmed_user_fixture()
      token = extract_user_token(&Accounts.deliver_login_instructions(user, &1))
      {:ok, view, _html} = live(conn, ~p"/users/log-in/#{token}")

      view
      |> crash(%{"type" => "hook", "event" => "submit", "value" => %{"password" => @marker}})
      |> assert_stripped([@marker, token], [
        "no function clause matching in ApiaryWeb.UserLive.Confirmation.handle_event/3"
      ])
    end

    test "the page of a password link", %{conn: conn} do
      user = user_fixture()
      {token, user_token} = Accounts.UserToken.build_password_link_token(user, "password")
      Apiary.Repo.insert!(user_token)

      for event <- ["validate", "save"] do
        {:ok, view, _html} = live(conn, ~p"/users/password/#{token}")

        view
        |> crash(%{"type" => "hook", "event" => event, "value" => %{"user" => @marker}})
        |> assert_stripped([@marker, token], ["ApiaryWeb.UserLive.Password.handle_event/3"])
      end
    end

    test "the page of an invitation", %{conn: conn} do
      owner = sign_up_fixture()
      %{token: token} = invitation_fixture(owner.scope, %{"email" => "bee@example.com"})
      {:ok, view, _html} = live(conn, ~p"/invitations/#{token}")

      view
      |> crash(%{"type" => "hook", "event" => "decline", "value" => %{"x" => @marker}})
      |> assert_stripped([@marker, token], [
        "no function clause matching in ApiaryWeb.InvitationLive.Accept.handle_event/3"
      ])
    end
  end

  describe "at debug" do
    setup do
      level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: level) end)
    end

    test "the state is written as [FILTERED]", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())
      {:ok, view, _html} = live(conn, ~p"/users/settings")

      # The password typed is kept in the page's form, in its state.
      view
      |> element("#password_form")
      |> render_change(%{"user" => %{"password" => @marker, "password_confirmation" => @marker}})

      assert inspect(:sys.get_state(view.pid), limit: :infinity, printable_limit: :infinity) =~
               @marker

      {log, events} =
        crash(view, %{"type" => "hook", "event" => "update_password", "value" => %{}}, :debug)

      assert log =~ ~s(State: "[FILTERED]")
      assert_stripped({log, events}, [@marker], ["(MatchError)"])
    end

    test "a message a page does not handle is logged without its terms", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/log-in")
      {_ref, topic, _proxy} = view.proxy

      log =
        capture_log([level: :debug], fn ->
          send(view.pid, %Phoenix.Socket.Message{
            topic: topic,
            event: @marker,
            ref: @marker,
            payload: %{"x" => @marker}
          })

          assert render(view) =~ "Log in"
        end)

      assert log =~ "[FILTERED]"
      refute log =~ @marker
    end

    test "a socket's assigns stay out of the arguments", %{conn: conn} do
      owner = sign_up_fixture()
      %{token: token} = invitation_fixture(owner.scope, %{"email" => "bee@example.com"})
      {:ok, view, _html} = live(conn, ~p"/invitations/#{token}")

      view
      |> crash(%{"type" => "hook", "event" => "x", "value" => %{}, "cid" => @marker}, :debug)
      |> assert_stripped([@marker, token], ["Phoenix.LiveView.Diff.write_component/4"])
    end
  end
end
