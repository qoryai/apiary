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

  import Phoenix.LiveViewTest
  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures, only: [member_fixture: 1, member_fixture: 2]

  alias Apiary.Mail

  @password "correct horse battery staple"

  # An adapter whose relay refuses every email.
  defmodule Refusing do
    @moduledoc false
    use Swoosh.Adapter

    def deliver(_email, _config), do: {:error, {:permanent_failure, "550 refused"}}
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

  @no_link "No test link is waiting: save the settings again to send one."

  defp sent_path do
    assert_received {:email, %{subject: @subject} = email}
    [path] = Regex.run(~r{/instance/mail/confirm/[A-Za-z0-9_-]+}, email.text_body)
    path
  end

  defp save(view, attrs \\ @attrs),
    do: view |> form("#mail_form", mail: attrs) |> render_submit()

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

      assert text(view, "#mail-pending") ==
               "Mail turns on when you follow the link we sent to #{scope.user.email}, signed in as you."

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

      assert text(view, "#mail-save") =~ "Saving sends a test link to #{other.user.email}."
    end

    test "asks for a recent sign-in, as Account settings does", %{conn: conn, user: user} do
      stale = DateTime.add(DateTime.utc_now(:second), -11, :minute)
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
      before = Application.get_env(:apiary, Mail)
      Application.put_env(:apiary, Mail, smtp_adapter: Capture)
      on_exit(fn -> Application.put_env(:apiary, Mail, before) end)

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

    test "a test link that could not be sent: saved, and the page says so", %{conn: conn} do
      before = Application.get_env(:apiary, Mail)
      Application.put_env(:apiary, Mail, smtp_adapter: Refusing)
      on_exit(fn -> Application.put_env(:apiary, Mail, before) end)

      {:ok, view, _html} = live(conn, ~p"/instance/mail")
      save(view)

      assert text(view, "#mail-not-sent") ==
               "Saved, but the test link could not be sent through these settings. Check them and save again."

      refute has_element?(view, "#mail-pending")
      refute has_element?(view, "#mail-no-link")
      assert Mail.state(Mail.settings()) == :pending

      # Opened again: no link waits, and the page says what to do.
      {:ok, view, _html} = live(conn, ~p"/instance/mail")
      refute has_element?(view, "#mail-pending")
      assert text(view, "#mail-no-link") == @no_link
    end

    test "once the test link no longer works, says so in place of who it waits for",
         %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/instance/mail")
      save(view)
      assert has_element?(view, "#mail-pending")
      refute has_element?(view, "#mail-no-link")

      Apiary.Repo.update_all(
        from(t in Apiary.Accounts.UserToken, where: t.context == "instance_mail"),
        set: [inserted_at: DateTime.add(DateTime.utc_now(:second), -61, :minute)]
      )

      {:ok, view, _html} = live(conn, ~p"/instance/mail")
      refute has_element?(view, "#mail-pending")
      assert text(view, "#mail-no-link") == @no_link

      # Another admin sees the same.
      Mail.put_test_source(:env)
      other = member_fixture(scope, :owner)
      Mail.put_test_source(:none)
      {:ok, view, _html} = live(log_in_user(build_conn(), other.user), ~p"/instance/mail")
      refute has_element?(view, "#mail-pending")
      assert text(view, "#mail-no-link") == @no_link
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
