defmodule ApiaryWeb.InstanceLive.MailEventsTest do
  @moduledoc """
  Instance settings › Mail (`ApiaryWeb.InstanceLive.Mail`): an event its form never sends,
  with a plaintext password in it, is refused in silence, by the form
  (`ApiaryWeb.InstanceLive.MailForm`) and by the page. The page's process stays up, so no
  crash report prints the event, and no log line holds the password.
  """
  # Not async: hiding the instance's organisation acts on the row every test shares.
  use ApiaryWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Apiary.Mail

  # What a client might send as the relay's password: no log line may hold it.
  @marker "plaintext-marker-9c3a"

  # The fields the form sends under `mail`.
  @fields ~w(smtp_relay smtp_port smtp_tls smtp_username smtp_password mail_from)

  # A save the page takes, its password the marker.
  @valid %{
    "smtp_relay" => "smtp.example.com",
    "smtp_port" => "587",
    "smtp_tls" => "always",
    "smtp_username" => "qory",
    "smtp_password" => @marker,
    "mail_from" => "qory@example.com"
  }

  setup do
    Apiary.EditionKit.hide_instance_organisation()
    :ok
  end

  setup :register_and_log_in_user

  setup do
    # No mail from the environment: in production, SMTP_RELAY not set.
    Mail.put_test_source(:none)
    :ok
  end

  # What stands where text is expected: each holds the marker.
  defp wrong do
    m = @marker

    [
      [m],
      [[m]],
      %{"0" => m},
      %{"x" => %{"y" => m}},
      [%{"x" => m}],
      42,
      -1,
      1.5,
      true,
      nil,
      m <> <<0xFF>>,
      <<0xC3>> <> m
    ]
  end

  # The payloads of an event: wrong at the top, wrong under `mail`, each field wrong in
  # turn with the others holding the marker, each field missing, a name that is not text,
  # and, last, text as the form sends it: the marker under each name the form uses, a name
  # no form sends, the `_unused_` names a form adds, and a save the page takes.
  defp payloads do
    m = @marker
    full = Map.new(@fields, &{&1, m})
    wrap = &%{"mail" => &1, "value" => m}

    top = [m, 42, nil, true, [m], [%{"mail" => m}], %{}, %{"smtp_password" => m}, %{"x" => m}]
    under = for w <- [m | wrong()], do: %{"mail" => w}

    per_field =
      for field <- @fields,
          payload <- [
            wrap.(Map.delete(full, field)) | for(w <- wrong(), do: wrap.(Map.put(full, field, w)))
          ],
          do: payload

    names = [
      wrap.(Map.put(full, 42, m)),
      wrap.(Map.put(full, [m], m)),
      wrap.(Map.put(full, :smtp_password, m)),
      wrap.(Map.put(full, "smtp" <> <<0xFF>>, m))
    ]

    unused = Map.new(@fields, &{"_unused_" <> &1, ""})

    strings =
      [wrap.(full), wrap.(Map.put(full, "extra", m)), wrap.(Map.merge(full, unused))] ++
        for(field <- @fields, do: wrap.(%{field => m})) ++
        [wrap.(@valid), %{"mail" => Map.merge(@valid, unused), "_target" => ["mail", m]}]

    top ++ under ++ per_field ++ names ++ strings
  end

  # The event as a client sends it on the page's channel, to the form's component, `cid`,
  # or to the page, nil: a hook's value as it comes, a form's encoded as a form encodes it.
  # The page's state, read after it, says it was answered.
  defp push({view, cid}, type, event, value) do
    {_ref, topic, _proxy} = view.proxy
    value = if type == "form", do: Plug.Conn.Query.encode(value), else: value
    payload = %{"type" => type, "event" => event, "value" => value}

    send(view.pid, %Phoenix.Socket.Message{
      topic: topic,
      event: "event",
      ref: "events-test",
      payload: if(cid, do: Map.put(payload, "cid", cid), else: payload)
    })

    :sys.get_state(view.pid)
    :ok
  catch
    :exit, _down -> :down
  end

  # A form's encoding takes a map whose names and values are text, and no map of more than
  # one key inside a list; the page's channel decodes text only.
  defp types(value) when is_map(value) do
    value |> Plug.Conn.Query.encode() |> Plug.Conn.Query.decode()
    ["hook", "form"]
  rescue
    _not_a_form -> ["hook"]
  end

  defp types(_value), do: ["hook"]

  # Each event sent each payload, to the form or, with `to: :page`, to the page: the
  # events that took the page down.
  defp sweep(conn, events, payloads, to \\ :form) do
    for event <- events, payload <- payloads, type <- types(payload), reduce: {nil, []} do
      {view, downs} ->
        view = view || mount(conn, to)

        case push(view, type, event, payload) do
          :ok -> {view, downs}
          :down -> {nil, [{event, type, payload} | downs]}
        end
    end
    |> elem(1)
    |> Enum.reverse()
  end

  # The page, and where its events go: the form's component, by its id, or the page.
  defp mount(conn, to \\ :form) do
    {:ok, view, _html} = live(conn, ~p"/instance/mail")

    cid =
      if to == :form,
        do:
          view
          |> element("#mail")
          |> render()
          |> LazyHTML.from_fragment()
          |> LazyHTML.attribute("data-phx-component")
          |> List.first()
          |> String.to_integer()

    {view, cid}
  end

  test "a save no form sends leaves the page up, and no password in a log line",
       %{conn: conn} do
    Process.flag(:trap_exit, true)

    {downs, log} = with_log([level: :error], fn -> sweep(conn, ["save"], payloads()) end)

    refute log =~ @marker
    assert downs == []
  end

  test "an event the page has no control for leaves the page up, and no password in a log line",
       %{conn: conn} do
    Process.flag(:trap_exit, true)
    events = ["validate", "change", "no_such_event", "", "SAVE", "save ", "RESEND", "resend "]

    {downs, log} = with_log([level: :error], fn -> sweep(conn, events, payloads()) end)

    refute log =~ @marker
    assert downs == []
  end

  # Send the test link again: the form reads none of its payload. With nothing saved, it
  # sends nothing.
  test "a resend with any payload leaves the page up, sends nothing, and no password in a log line",
       %{conn: conn} do
    Process.flag(:trap_exit, true)

    {downs, log} =
      with_log([level: :error], fn -> sweep(conn, ["resend"], Enum.take(payloads(), 40)) end)

    refute log =~ @marker
    assert downs == []
    refute_received {:email, %{subject: "Turn on mail for Qory Apiary"}}
  end

  test "an event sent to the page, not its form, leaves the page up, and no password in a log line",
       %{conn: conn} do
    Process.flag(:trap_exit, true)
    events = ["save", "resend", "validate", "no_such_event"]

    {downs, log} =
      with_log([level: :error], fn -> sweep(conn, events, Enum.take(payloads(), 12), :page) end)

    refute log =~ @marker
    assert downs == []
  end

  # The shape that took the page down before: a save without `mail`, its password at the
  # top. Refused, it leaves the page as it was.
  test "a save without mail is refused, and the page is as it was", %{conn: conn} do
    Process.flag(:trap_exit, true)
    {view, _cid} = target = mount(conn)
    html = render(view)

    {result, log} =
      with_log([level: :error], fn ->
        for type <- ["hook", "form"],
            do: push(target, type, "save", %{"smtp_password" => @marker})
      end)

    refute log =~ @marker
    assert result == [:ok, :ok]
    assert render(view) == html
    assert Mail.settings() == nil or is_nil(Mail.settings().smtp_relay)
  end

  # A NUL byte in the username or the sender reaches the database, which refuses it, and
  # the page's process ends. The report of it names the database's error and the event,
  # whose value Phoenix filters, and holds no password.
  test "a save the database refuses logs no password", %{conn: conn} do
    Process.flag(:trap_exit, true)

    payloads =
      for field <- ~w(smtp_username mail_from),
          do: %{"mail" => Map.update!(@valid, field, &(&1 <> <<0>>))}

    {_downs, log} =
      with_log([level: :error], fn -> sweep(conn, ["save"], payloads) end)

    refute log =~ @marker
  end

  # The form still saves, as the Mail page's suite shows; this test shows that a save the
  # form sends with the `_unused_` names a browser adds is taken.
  test "a save the form sends, with the names a form adds, is taken", %{conn: conn} do
    target = mount(conn)
    unused = Map.new(@fields, &{"_unused_" <> &1, ""})

    assert push(target, "form", "save", %{"mail" => Map.merge(@valid, unused)}) == :ok
    assert %{smtp_relay: "smtp.example.com", smtp_username: "qory"} = Mail.settings()
    assert_received {:email, %{subject: "Turn on mail for Qory Apiary"}}
  end

  # The checks above see what a crash report prints: a process that fails on a term
  # holding the marker logs the marker.
  test "a crash report prints the arguments a process failed on" do
    Process.flag(:trap_exit, true)

    log =
      capture_log([level: :error], fn ->
        {:ok, pid} = Agent.start_link(fn -> nil end)
        ref = Process.monitor(pid)
        term = Process.get(:never_set, %{"smtp_password" => @marker})
        Agent.cast(pid, fn _state -> String.trim(term) end)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
      end)

    assert log =~ @marker
  end
end
