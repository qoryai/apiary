defmodule ApiaryWeb.InstanceLive.MailTest do
  @moduledoc """
  Instance settings › Mail (`ApiaryWeb.InstanceLive.Mail`) and its test link
  (`ApiaryWeb.InstanceMailController`): the form for the instance's admins, which never
  shows a password; the test link that turns mail on for the admin who saved; the page
  read only where the server's environment sets mail, and on an instance of any features;
  and a path that does not exist for anyone else.
  """
  # Not async: hiding the instance's organisation acts on the row every test shares, and
  # the mailer's environment is the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]
  import Phoenix.LiveViewTest
  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures, only: [member_fixture: 1, member_fixture: 2]

  alias Apiary.Mail

  @password "correct horse battery staple"

  # An adapter whose relay refuses every email, as `Swoosh.Adapters.SMTP` returns it.
  defmodule Refusing do
    @moduledoc false
    use Swoosh.Adapter

    def deliver(_email, _config),
      do:
        {:error,
         {:send,
          {:permanent_failure, ~c"smtp.example.com", "550 5.7.1 Refused for 192.0.2.7\r\n"}}}
  end

  # An adapter that answers what the test put in the application's environment, as
  # `Swoosh.Adapters.SMTP` answers for gen_smtp, after calling the trace function with each
  # format there, as gen_smtp does. The page's process sends, so the answer is the node's.
  defmodule Answering do
    @moduledoc false
    use Swoosh.Adapter

    def deliver(_email, config) do
      {answer, traces} = Application.fetch_env!(:apiary, :mail_test_answer)
      for format <- traces, do: config[:trace_fun].(format, ["the relay's reply"])
      answer
    end
  end

  # An adapter that hands the test what it was asked to send, and how.
  defmodule Capture do
    @moduledoc false
    use Swoosh.Adapter

    def deliver(email, config) do
      for pid <- Enum.uniq([self() | List.wrap(Process.get(:"$callers"))]),
          do: send(pid, {:sent, email, config})

      {:ok, %{}}
    end
  end

  # The fields of the mail settings that hold a password, given or saved.
  @sealed Apiary.Mail.Settings.__schema__(:redact_fields)

  # The page's state, and its form's (`ApiaryWeb.InstanceLive.MailForm`), hold no byte of
  # the saved password's ciphertext; no settings, form data or changeset in them holds a
  # password, given or saved; and the form's changeset none in its data or its changes.
  defp refute_sealed_state(view, ciphertext) do
    state = :sys.get_state(view.pid)
    form_assigns = form_assigns(state)

    for assigns <- [state.socket.assigns, form_assigns] do
      assert :binary.match(:erlang.term_to_binary(assigns), ciphertext) == :nomatch
      refute_sealed(assigns)
    end

    %Phoenix.HTML.Form{data: data, source: %Ecto.Changeset{} = changeset} = form_assigns.form

    for field <- @sealed do
      assert Map.get(data, field) == nil
      assert Map.get(changeset.data, field) == nil
      refute Map.has_key?(changeset.changes, field)
    end
  end

  # The assigns of the page's form, the live component `ApiaryWeb.InstanceLive.MailForm`,
  # as the page's process holds them.
  defp form_assigns(%{components: {by_cid, _by_id, _uuids}}) do
    Enum.find_value(by_cid, fn
      {_cid, {ApiaryWeb.InstanceLive.MailForm, "mail", assigns, _private, _prints}} -> assigns
      _other -> nil
    end)
  end

  # Walks a term: wherever a map or a struct has one of the sealed fields, it is empty. A
  # changeset's types name each field with its type, not its value.
  defp refute_sealed(%Ecto.Changeset{} = changeset),
    do: changeset |> Map.from_struct() |> Map.delete(:types) |> refute_sealed()

  defp refute_sealed(%_{} = struct), do: struct |> Map.from_struct() |> refute_sealed()

  defp refute_sealed(map) when is_map(map) do
    for {key, value} <- map do
      if key in @sealed, do: assert(value == nil, "#{key} held")
      refute_sealed(value)
    end
  end

  defp refute_sealed([head | tail]) do
    refute_sealed(head)
    refute_sealed(tail)
  end

  defp refute_sealed(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> refute_sealed()
  defp refute_sealed(_term), do: :ok

  @attrs %{
    "smtp_relay" => "smtp.example.com",
    "smtp_port" => "587",
    "smtp_tls" => "always",
    "smtp_username" => "qory",
    "smtp_password" => @password,
    "mail_from" => "qory@example.com"
  }

  defp text(view, selector),
    do:
      view
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.split()
      |> Enum.join(" ")

  # Puts the mailer's environment for the test, and back after it.
  defp put_mailer_env(config) do
    before = Application.get_env(:apiary, Apiary.Mailer)
    Application.put_env(:apiary, Apiary.Mailer, config)
    on_exit(fn -> Application.put_env(:apiary, Apiary.Mailer, before) end)
  end

  # The path of the test link in the email the admin was sent.
  @subject "Turn on mail for Qory Apiary"

  defp sent_path do
    assert_received {:email, %{subject: @subject} = email}
    [path] = Regex.run(~r{/instance/mail/confirm/[A-Za-z0-9_-]+}, email.text_body)
    path
  end

  # Saves, a minute or more after the last test send.
  defp save(view, attrs \\ @attrs) do
    unthrottle!()
    view |> form("#mail_form", mail: attrs) |> render_submit()
  end

  # The last test send, a minute and a second ago: the next one is allowed.
  defp unthrottle!,
    do:
      Apiary.Repo.update_all(
        from(s in Apiary.Mail.Settings, where: not is_nil(s.mail_test_sent_at)),
        set: [mail_test_sent_at: DateTime.add(DateTime.utc_now(), -61, :second)]
      )

  # Puts the adapter of the saved settings' sends for the test, and back after it.
  defp put_adapter(adapter) do
    before = Application.get_env(:apiary, Mail)
    Application.put_env(:apiary, Mail, smtp_adapter: adapter)
    on_exit(fn -> Application.put_env(:apiary, Mail, before) end)
  end

  # Has the adapter answer `answer` to each send, as gen_smtp's adapter, with `traces`.
  defp answer(answer, traces \\ []) do
    put_adapter(Answering)
    Application.put_env(:apiary, :mail_test_answer, {answer, traces})
    on_exit(fn -> Application.delete_env(:apiary, :mail_test_answer) end)
  end

  # A time as the page shows it, with the seconds, and until when a link sent then works.
  defp at(time), do: ApiaryWeb.Format.datetime(time, seconds: true, zone: true)

  defp until(time),
    do: time |> DateTime.add(60, :minute) |> ApiaryWeb.Format.datetime(zone: true)

  defp sent_at, do: Mail.settings().mail_test_sent_at

  # The mail form in `html` is sent with POST, and its password's field has no value.
  defp assert_posts_without_password(html) do
    form = LazyHTML.query(html, "#mail_form")
    assert LazyHTML.attribute(form, "method") == ["post"]
    assert LazyHTML.attribute(form, "action") == []

    password = LazyHTML.query(form, ~s{input[type="password"]})
    assert LazyHTML.attribute(password, "name") == ["mail[smtp_password]"]
    assert LazyHTML.attribute(password, "value") == []
  end

  # Nothing of mail is saved: no row of the instance's settings, or one that holds none of
  # the mail's columns, as the instance's set-up leaves it (`Apiary.Setup`).
  defp no_mail_saved? do
    case Mail.settings() do
      nil ->
        true

      settings ->
        settings
        |> Map.take(Apiary.Mail.Settings.__schema__(:fields) -- [:id, :updated_at])
        |> Map.values()
        |> Enum.all?(&is_nil/1)
    end
  end

  describe "for an instance admin" do
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

    test "is a section after the edition's and before Configuration, with the form, mail off",
         %{conn: conn, scope: scope} do
      assert [:mail, :configuration] =
               scope
               |> ApiaryWeb.Layouts.instance_sections()
               |> Enum.map(& &1.key)
               |> Enum.take(-2)

      {:ok, view, html} = live(conn, ~p"/instance/mail")

      assert html =~ ~r{<title[^>]*>\s*Mail · Instance settings · Qory Apiary\s*</title>}
      assert text(view, "h1#settings-section-title") =~ "Mail"

      assert text(view, "#mail-status") ==
               "Off: invitations and password links are copied by hand."

      assert has_element?(view, "#mail_form input[name='mail[smtp_relay]']")
      assert has_element?(view, "#mail_form input[name='mail[smtp_port]'][value='587']")

      assert has_element?(
               view,
               "#mail_form select[name='mail[smtp_tls]'] option[selected]",
               "Always"
             )

      assert has_element?(
               view,
               "#mail_form input[name='mail[smtp_password]'][type='password'][autocomplete='new-password']:not([value])"
             )

      assert text(view, "#mail-save") =~
               "Saving sends a test link to #{scope.user.email}. Mail is off until you follow it."

      refute has_element?(view, "#mail-pending")
    end

    test "saving sends the test link, and neither the page nor its process holds the password",
         %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/instance/mail")
      html = save(view)

      refute html =~ @password
      refute render(view) =~ @password

      refute inspect(:sys.get_state(view.pid), limit: :infinity, printable_limit: :infinity) =~
               @password

      assert has_element?(view, "#mail_form input[name='mail[smtp_password]']:not([value])")

      assert has_element?(
               view,
               "#mail_form input[name='mail[smtp_relay]'][value='smtp.example.com']"
             )

      assert text(view, "#mail_form") =~
               "Saved, and never shown. Leave it empty to keep it, unless you change the relay, port, TLS or username."

      assert text(view, "#mail-status") ==
               "Off: invitations and password links are copied by hand."

      sent_at = sent_at()

      assert text(view, "#mail-pending") ==
               "Mail turns on when you follow the link we sent to #{scope.user.email} at #{at(sent_at)}, signed in as you. The link works until #{until(sent_at)}."

      assert text(view, "#mail-arrive") ==
               "If the email does not arrive within 5 minutes, check your spam folder and the relay's log, then send the link again."

      assert has_element?(view, "#mail-resend", "Send the test link again")
      refute has_element?(view, "#mail-result")

      # The same after a reload.
      {:ok, view, _html} = live(conn, ~p"/instance/mail")
      assert text(view, "#mail-pending") =~ "at #{at(sent_at)}, signed in as you."
      assert has_element?(view, "#mail-resend")

      assert_received {:email, %{subject: @subject} = email}
      assert email.to == [{"", scope.user.email}]
      assert email.text_body =~ "/instance/mail/confirm/"
    end

    test "following the test link turns mail on, and says so", %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/instance/mail")
      save(view)
      path = sent_path()

      conn = get(conn, path)
      assert redirected_to(conn) == ~p"/instance/mail"

      assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
               "Mail is on, and your email address is confirmed."

      assert Mail.state(Mail.settings()) == :on
      assert %DateTime{} = Apiary.Repo.get!(Apiary.Accounts.User, scope.user.id).confirmed_at

      {:ok, view, _html} = live(conn, ~p"/instance/mail")
      assert text(view, "#mail-status") =~ ~r/\AOn since \d{1,2} \w+( \d{4})?\.\z/
      refute has_element?(view, "#mail-pending")

      # Once.
      conn = get(conn, path)
      assert redirected_to(conn) == ~p"/instance/mail"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "This link no longer turns mail on."
    end

    test "for another instance admin, the link does nothing, and the page says who it waits for",
         %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/instance/mail")
      save(view)
      path = sent_path()

      # The invitation goes out by the tests' mail.
      Mail.put_test_source(:env)
      other = member_fixture(scope, :owner)
      Mail.put_test_source(:none)
      conn = log_in_user(build_conn(), other.user)

      conn = get(conn, path)
      assert redirected_to(conn) == ~p"/instance/mail"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "This link no longer turns mail on."
      assert Mail.state(Mail.settings()) == :pending

      {:ok, view, _html} = live(conn, ~p"/instance/mail")

      assert text(view, "#mail-pending") ==
               "Mail turns on when the admin who saved these settings follows the link we sent them."

      assert text(view, "#mail-other-admin") ==
               "To get a test link at your address, save the settings."

      refute has_element?(view, "#mail-no-link")
      refute has_element?(view, "#mail-resend")
      refute has_element?(view, "#mail-arrive")
      refute has_element?(view, "#mail-result")
      assert text(view, "#mail-save") =~ "Saving sends a test link to #{other.user.email}."
    end

    test "asks for a recent sign-in, as Account settings does", %{conn: conn, user: user} do
      stale = DateTime.add(DateTime.utc_now(:second), -16, :minute)
      stale_conn = log_in_user(build_conn(), user, token_authenticated_at: stale)

      assert {:error, {:redirect, %{to: "/users/log-in", flash: flash}}} =
               live(stale_conn, ~p"/instance/mail")

      assert flash == %{"error" => "You must re-authenticate to access this page."}

      # Opened in time, and saved once the sign-in has grown old, as Account settings
      # counts it for a change, 20 minutes: nothing is saved, and the page leads to the
      # log-in page the same way.
      {:ok, view, _html} = live(conn, ~p"/instance/mail")
      old = DateTime.add(DateTime.utc_now(:second), -21, :minute)

      # The page's scope, and its form's, which the page gave it.
      :sys.replace_state(view.pid, fn state ->
        state = put_in(state.socket.assigns.current_scope.user.authenticated_at, old)
        {by_cid, by_id, uuids} = state.components

        by_cid =
          Map.new(by_cid, fn {cid, {module, id, assigns, private, prints}} ->
            assigns = put_in(assigns.current_scope.user.authenticated_at, old)
            {cid, {module, id, assigns, private, prints}}
          end)

        %{state | components: {by_cid, by_id, uuids}}
      end)

      assert {:error, {:redirect, %{to: "/users/log-in"}}} = save(view)

      assert assert_redirect(view, ~p"/users/log-in") ==
               %{"error" => "You must re-authenticate to access this page."}

      assert no_mail_saved?()
      refute_received {:email, %{subject: @subject}}
    end

    test "the test link asks for a recent sign-in, and works once the admin has signed in again",
         %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/instance/mail")
      save(view)
      path = sent_path()

      stale = DateTime.add(DateTime.utc_now(:second), -21, :minute)
      stale_conn = log_in_user(build_conn(), user, token_authenticated_at: stale) |> get(path)

      assert redirected_to(stale_conn) == ~p"/users/log-in"

      assert Phoenix.Flash.get(stale_conn.assigns.flash, :error) ==
               "You must re-authenticate to access this page."

      # Back to the link once signed in again.
      assert get_session(stale_conn, :user_return_to) == path
      assert Mail.state(Mail.settings()) == :pending

      assert conn |> get(path) |> redirected_to() == ~p"/instance/mail"
      assert Mail.state(Mail.settings()) == :on
    end

    test "a save and the test link followed are entries of the instance's activity",
         %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/instance/mail")
      save(view)
      get(conn, sent_path())

      entries =
        Apiary.Repo.all(
          from e in Apiary.Audit.Entry,
            where: e.organisation_id == ^Apiary.Edition.instance_organisation_id(),
            where: e.action in ["instance.mail_save", "instance.mail_on"],
            order_by: [asc: e.inserted_at, asc: e.id],
            select: {e.action, e.actor_id}
        )

      assert Enum.sort(entries) ==
               [{"instance.mail_on", scope.user.id}, {"instance.mail_save", scope.user.id}]
    end

    test "TLS other than Always with a username is refused, saying so", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/instance/mail")

      for tls <- ["never", "if_available"] do
        html = save(view, %{@attrs | "smtp_tls" => tls})
        assert html =~ "must be Always with a username"
        refute html =~ @password
      end

      assert no_mail_saved?()
    end

    test "a username of one character over 320 bytes is refused, not a crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/instance/mail")
      long = "a" <> String.duplicate("\u0301", 40_000)

      html = save(view, %{@attrs | "smtp_username" => long})
      assert html =~ "should be at most 320 byte(s)"
      refute html =~ @password
      assert Process.alive?(view.pid)
      assert no_mail_saved?()
    end

    test "posts its form, and the password's field has no value", %{conn: conn} do
      # The page before it connects: a submit there is the browser's, with the form's method.
      html = conn |> get(~p"/instance/mail") |> html_response(200)
      assert_posts_without_password(LazyHTML.from_document(html))

      {:ok, view, _html} = live(conn, ~p"/instance/mail")
      html = save(view)
      refute html =~ @password
      assert_posts_without_password(LazyHTML.from_fragment(html))

      # With settings saved, a form of their changeset is `method="put"` unless it says
      # otherwise, and a browser sends that as a GET.
      html = conn |> get(~p"/instance/mail") |> html_response(200)
      assert_posts_without_password(LazyHTML.from_document(html))

      html = save(view, %{@attrs | "smtp_port" => "0", "smtp_password" => "s3cret-example"})

      assert html =~ "aria-invalid"
      refute html =~ "s3cret-example"
      assert_posts_without_password(LazyHTML.from_fragment(html))
    end

    test "a refused save shows what to change, and keeps no password", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/instance/mail")
      html = save(view, %{@attrs | "smtp_relay" => "smtp example com"})

      assert html =~ "must be a host name, such as smtp.example.com"
      refute html =~ @password

      refute inspect(:sys.get_state(view.pid), limit: :infinity, printable_limit: :infinity) =~
               @password

      assert no_mail_saved?()
      refute_received {:email, %{subject: @subject}}

      html = save(view, %{@attrs | "smtp_password" => ""})
      assert html =~ "can&#39;t be blank"
    end

    test "the page's state holds nothing of the saved password: opened, saved, or refused, and a save keeps it",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/instance/mail")
      save(view)
      ciphertext = Mail.settings().smtp_password_ciphertext
      assert is_binary(ciphertext)
      refute_sealed_state(view, ciphertext)

      # Opened with the password saved: said to be there.
      {:ok, view, _html} = live(conn, ~p"/instance/mail")
      refute_sealed_state(view, ciphertext)
      assert text(view, "#mail_form") =~ "Saved, and never shown."

      # Refused with a password given, and refused for the saved one, none given.
      html = save(view, %{@attrs | "smtp_relay" => "smtp example com"})
      assert html =~ "must be a host name, such as smtp.example.com"
      refute_sealed_state(view, ciphertext)

      html = save(view, %{@attrs | "smtp_password" => "", "smtp_port" => "2525"})
      assert html =~ "enter it again: the relay, port, TLS or username changed"
      assert has_element?(view, "#mail_form input[name='mail[smtp_port]'][value='2525']")
      refute_sealed_state(view, ciphertext)

      # Saved with the field empty: the saved password is kept, and sends.
      put_adapter(Capture)

      save(view, %{@attrs | "smtp_password" => "", "mail_from" => "mail@example.com"})
      assert_received {:sent, %{subject: @subject}, config}
      assert config[:password] == @password
      assert Mail.settings().smtp_password_ciphertext == ciphertext
      refute_sealed_state(view, ciphertext)
      assert text(view, "#mail_form") =~ "Saved, and never shown."

      assert has_element?(
               view,
               "#mail_form input[name='mail[mail_from]'][value='mail@example.com']"
             )
    end

    test "a test link that could not be sent: saved, and the page says what to check, after a reload too",
         %{conn: conn} do
      put_adapter(Refusing)

      {:ok, view, _html} = live(conn, ~p"/instance/mail")
      {html, _log} = with_log(fn -> save(view) end)

      line =
        "Check the sender address, and that the relay allows this server's IP address, then send the test link again. The relay refused the email at #{at(sent_at())} (reply code 550 5.7.1)."

      assert text(view, "#mail-result") == line
      assert has_element?(view, "#mail-resend", "Send the test link again")
      refute html =~ "192.0.2.7"
      refute has_element?(view, "#mail-pending")
      refute has_element?(view, "#mail-arrive")
      assert Mail.state(Mail.settings()) == :pending

      {:ok, view, html} = live(conn, ~p"/instance/mail")
      assert text(view, "#mail-result") == line
      assert has_element?(view, "#mail-resend")
      refute html =~ "192.0.2.7"
    end

    test "each result of a failed send has its line, starting with what to check",
         %{conn: conn} do
      host = ~c"smtp.example.com"
      sender = ~c"Mail FROM rejected: ~p~n"

      for {answer, traces, line} <- [
            {{:error, {:no_more_hosts, {:permanent_failure, host, :auth_failed}}}, [],
             "Check the username and password, and that the relay allows this server's IP address, then send the test link again. The log-in to the relay failed at %{time}."},
            {{:error, {:send, {:permanent_failure, host, "550 5.7.1 Unverified sender\r\n"}}},
             [sender],
             "Set Sender to an address the relay accepts, such as one verified with your mail provider, then send the test link again. The relay refused the sender address at %{time} (reply code 550 5.7.1)."},
            {{:error, {:send, {:permanent_failure, host, "554 5.7.1 No\r\n"}}}, [],
             "Check the sender address, and that the relay allows this server's IP address, then send the test link again. The relay refused the email at %{time} (reply code 554 5.7.1)."},
            {{:error, {:send, {:temporary_failure, host, "451 4.3.0 Later\r\n"}}}, [],
             "Send the test link again in a few minutes. The relay returned a temporary error at %{time} (reply code 451 4.3.0)."},
            {{:error, {:retries_exceeded, {:network_failure, host, {:error, :econnrefused}}}}, [],
             "Check the SMTP relay and port, and that this server can reach them, then send the test link again. The connection to the relay failed at %{time} (econnrefused)."},
            {{:error, {:retries_exceeded, {:temporary_failure, host, :tls_failed}}}, [],
             "Check the TLS setting and port, such as 587 with Always, or 465, then send the test link again. The TLS handshake with the relay failed at %{time}."},
            {{:error, {:retries_exceeded, {:unexpected_response, host, ["no"]}}}, [],
             "Check the settings, then send the test link again. The send failed at %{time}."}
          ] do
        answer(answer, traces)
        {:ok, view, _html} = live(conn, ~p"/instance/mail")
        {_html, _log} = with_log(fn -> save(view) end)
        line = String.replace(line, "%{time}", at(sent_at()))

        assert text(view, "#mail-result") == line
        assert has_element?(view, "#mail-resend")
      end

      # After a reload, the reason a connection failed is not known: the line without it.
      {:ok, view, _html} = live(conn, ~p"/instance/mail")
      assert text(view, "#mail-result") =~ "The send failed at"
      answer({:error, {:retries_exceeded, {:network_failure, host, {:error, :timeout}}}})
      {:ok, view, _html} = live(conn, ~p"/instance/mail")
      {_html, _log} = with_log(fn -> save(view) end)
      assert text(view, "#mail-result") =~ "(timeout)."
      {:ok, view, _html} = live(conn, ~p"/instance/mail")

      assert text(view, "#mail-result") ==
               "Check the SMTP relay and port, and that this server can reach them, then send the test link again. The connection to the relay failed at #{at(sent_at())}."
    end

    test "Send the test link again sends a new link, and says so; within the minute, says until when",
         %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/instance/mail")
      save(view)
      first = sent_path()
      unthrottle!()

      view |> element("#mail-resend") |> render_click()
      second = sent_path()
      refute second == first
      sent_at = sent_at()

      assert text(view, "#mail-resent") ==
               "Test link sent to #{scope.user.email} at #{at(sent_at)}. It works until #{until(sent_at)}."

      refute has_element?(view, "#mail-pending")
      assert has_element?(view, "#mail-arrive")
      assert has_element?(view, "#mail-resend")

      # Within the minute: nothing sent, and when to try again.
      view |> element("#mail-resend") |> render_click()

      assert text(view, "#mail-wait") ==
               "Wait until #{at(DateTime.add(sent_at, 60, :second))}, then send the link again. Qory Apiary sends at most one test link a minute."

      refute_received {:email, %{subject: @subject}}

      # A save within the minute: nothing saved, the form as typed but the password.
      view
      |> form("#mail_form", mail: %{@attrs | "mail_from" => "mail@example.com"})
      |> render_submit()

      assert text(view, "#mail-wait") =~ "Wait until #{at(DateTime.add(sent_at, 60, :second))}"
      assert Mail.settings().mail_from == "qory@example.com"

      assert has_element?(
               view,
               "#mail_form input[name='mail[mail_from]'][value='mail@example.com']"
             )

      assert has_element?(view, "#mail_form input[name='mail[smtp_password]']:not([value])")
      refute_received {:email, %{subject: @subject}}

      # The second link turns mail on.
      assert redirected_to(get(conn, second)) == ~p"/instance/mail"
      assert Mail.state(Mail.settings()) == :on
    end

    test "Send the test link again that the relay refuses shows the result's line",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/instance/mail")
      save(view)
      _first = sent_path()
      unthrottle!()
      put_adapter(Refusing)

      {_html, _log} = with_log(fn -> view |> element("#mail-resend") |> render_click() end)

      assert text(view, "#mail-result") =~
               "The relay refused the email at #{at(sent_at())} (reply code 550 5.7.1)."

      refute has_element?(view, "#mail-resent")
      refute has_element?(view, "#mail-pending")
    end

    test "for another instance admin, a failed send's line without the button",
         %{conn: conn, scope: scope} do
      put_adapter(Refusing)
      {:ok, view, _html} = live(conn, ~p"/instance/mail")
      {_html, _log} = with_log(fn -> save(view) end)

      Mail.put_test_source(:env)
      other = member_fixture(scope, :owner)
      Mail.put_test_source(:none)
      {:ok, view, _html} = live(log_in_user(build_conn(), other.user), ~p"/instance/mail")

      # No link went out: none waits.
      refute has_element?(view, "#mail-pending")

      assert text(view, "#mail-no-link") ==
               "No test link is waiting for the admin who saved these settings."

      assert text(view, "#mail-result") =~ "The relay refused the email at"

      assert text(view, "#mail-other-admin") ==
               "To get a test link at your address, save the settings."

      refute has_element?(view, "#mail-resend")
    end

    test "once the test link no longer works, the admin who saved has the button alone",
         %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/instance/mail")
      save(view)
      assert has_element?(view, "#mail-pending")

      Apiary.Repo.update_all(
        from(t in Apiary.Accounts.UserToken, where: t.context == "instance_mail"),
        set: [inserted_at: DateTime.add(DateTime.utc_now(:second), -61, :minute)]
      )

      {:ok, view, _html} = live(conn, ~p"/instance/mail")
      refute has_element?(view, "#mail-pending")
      refute has_element?(view, "#mail-arrive")
      refute has_element?(view, "#mail-result")
      assert has_element?(view, "#mail-resend")

      # Another admin sees that no link waits, and how to get one.
      Mail.put_test_source(:env)
      other = member_fixture(scope, :owner)
      Mail.put_test_source(:none)
      {:ok, view, _html} = live(log_in_user(build_conn(), other.user), ~p"/instance/mail")
      refute has_element?(view, "#mail-pending")

      assert text(view, "#mail-no-link") ==
               "No test link is waiting for the admin who saved these settings."

      assert text(view, "#mail-other-admin") ==
               "To get a test link at your address, save the settings."

      refute has_element?(view, "#mail-resend")
    end

    test "with mail on, there is no button", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/instance/mail")
      save(view)
      get(conn, sent_path())

      {:ok, view, _html} = live(conn, ~p"/instance/mail")
      refute has_element?(view, "#mail-test")
      refute has_element?(view, "#mail-resend")
    end

    test "says when the saved password cannot be read", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/instance/mail")
      save(view)

      # A row changed outside the application: its key id names no key the instance holds.
      Apiary.Repo.update_all(Apiary.Mail.Settings, set: [mail_key_id: "0000000000000000"])

      {:ok, view, _html} = live(conn, ~p"/instance/mail")

      assert text(view, "#mail-status") ==
               "Off: the saved password cannot be read. Enter it again and save."

      refute text(view, "#mail_form") =~ "Saved, and never shown."
    end

    test "with SMTP_RELAY set, shows the environment's settings, read only", %{conn: conn} do
      Mail.put_test_source(:env)

      put_mailer_env(
        adapter: Swoosh.Adapters.SMTP,
        relay: "smtp.example.com",
        port: 465,
        username: "qory",
        password: @password,
        auth: :always,
        ssl: true,
        tls: :never
      )

      {:ok, view, html} = live(conn, ~p"/instance/mail")

      assert text(view, "#mail-status") ==
               "Set by the server's environment (SMTP_RELAY); change it there."

      refute has_element?(view, "#mail_form")
      refute html =~ @password

      refute inspect(:sys.get_state(view.pid), limit: :infinity, printable_limit: :infinity) =~
               @password

      assert text(view, "#mail-env-relay-value") == "smtp.example.com"
      assert text(view, "#mail-env-port-value") == "465"
      assert text(view, "#mail-env-tls-value") == "From the start (port 465)"
      assert text(view, "#mail-env-username-value") == "qory"
      assert text(view, "#mail-env-sender-value") == Apiary.Mailer.default_address()
    end
  end

  describe "for anyone else" do
    setup do
      Apiary.EditionKit.hide_instance_organisation()
      :ok
    end

    setup :register_and_log_in_user

    test "the page and the test link are paths that do not exist", %{conn: conn, scope: scope} do
      member = member_fixture(scope)
      Mail.put_test_source(:none)
      {:ok, view, _html} = live(conn, ~p"/instance/mail")
      save(view)
      path = sent_path()

      member_conn = log_in_user(build_conn(), member.user)
      assert_raise ApiaryWeb.NotFound, fn -> live(member_conn, ~p"/instance/mail") end
      assert_error_sent :not_found, fn -> get(member_conn, path) end

      refute Enum.any?(
               ApiaryWeb.Layouts.instance_sections(member.scope),
               &(&1.key == :mail)
             )

      # Signed out: sent to log in, and nothing changes.
      assert build_conn() |> get(path) |> redirected_to() == ~p"/users/log-in"

      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               live(build_conn(), ~p"/instance/mail")

      assert Mail.state(Mail.settings()) == :pending
    end
  end

  describe "on an instance with the record alone" do
    setup do
      Apiary.EditionKit.hide_instance_organisation()
      :ok
    end

    setup :register_and_log_in_user

    @tag with_features: [:observability]
    test "an instance admin has the Mail section", %{conn: conn, scope: scope} do
      assert Apiary.Access.instance_admin?(scope)
      assert Enum.any?(ApiaryWeb.Layouts.instance_sections(scope), &(&1.key == :mail))

      {:ok, _view, html} = live(conn, ~p"/instance/mail")
      assert html =~ "Mail"
    end
  end
end
