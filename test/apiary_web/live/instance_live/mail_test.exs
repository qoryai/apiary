defmodule ApiaryWeb.InstanceLive.MailTest do
  @moduledoc """
  Instance settings › Mail (`ApiaryWeb.InstanceLive.Mail`) and its test link
  (`ApiaryWeb.InstanceMailController`): the form for the instance's admins, which never
  shows a password; the test link that turns mail on for the admin who saved; the page
  read only where the server's environment sets mail; and a path that does not exist for
  anyone else, and without the `instance_mail` feature.
  """
  # Not async: hiding the instance's organisation acts on the row every test shares, and
  # the mailer's environment is the whole node's.
  use ApiaryWeb.ConnCase, async: false

  @moduletag needs: :instance_mail

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

  # What the instance's row keeps of the mail settings: nil where there is no row, or where
  # the row, which the set-up makes, holds none of them.
  defp kept_mail do
    with %Apiary.Mail.Settings{} = settings <- Mail.settings(),
         kept when kept != %{} <-
           settings
           |> Map.take(Apiary.Mail.Settings.__schema__(:fields) -- [:id, :updated_at])
           |> Map.reject(fn {_field, value} -> is_nil(value) end) do
      kept
    else
      _nothing -> nil
    end
  end

  defp sent_path do
    assert_received {:email, %{subject: @subject} = email}
    [path] = Regex.run(~r{/instance/mail/confirm/[A-Za-z0-9_-]+}, email.text_body)
    path
  end

  defp save(view, attrs \\ @attrs),
    do: view |> form("#mail_form", mail: attrs) |> render_submit()

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
               "#mail_form input[name='mail[smtp_password]'][type='password'][value=''][autocomplete='new-password']"
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

      assert has_element?(view, "#mail_form input[name='mail[smtp_password]'][value='']")

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

    test "a refused save shows what to change, and keeps no password", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/instance/mail")
      html = save(view, %{@attrs | "smtp_relay" => "smtp example com"})

      assert html =~ "must be a host name, such as smtp.example.com"
      refute html =~ @password

      refute inspect(:sys.get_state(view.pid), limit: :infinity, printable_limit: :infinity) =~
               @password

      assert kept_mail() == nil
      refute_received {:email, %{subject: @subject}}

      html = save(view, %{@attrs | "smtp_password" => ""})
      assert html =~ "can&#39;t be blank"
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

  describe "without the instance_mail feature" do
    setup do
      Apiary.EditionKit.hide_instance_organisation()
      :ok
    end

    setup :register_and_log_in_user

    @tag with_features: [:observability, :security]
    test "there is no Mail section, and its paths do not exist", %{conn: conn, scope: scope} do
      assert Apiary.Access.instance_admin?(scope)
      refute Enum.any?(ApiaryWeb.Layouts.instance_sections(scope), &(&1.key == :mail))

      assert conn |> get(~p"/instance/mail") |> response(404)

      assert conn
             |> get(~p"/instance/mail/confirm/#{Base.url_encode64("x", padding: false)}")
             |> response(404)
    end
  end
end
