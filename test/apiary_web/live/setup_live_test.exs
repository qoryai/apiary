defmodule ApiaryWeb.SetupLiveTest do
  @moduledoc """
  The set-up page, `/setup/<code>` (`ApiaryWeb.SetupLive`): the form for the stored code,
  the set-up that signs the person in, "already set up" for any code after it, and a path
  that does not exist for a wrong code before it. The suite's instance is set up; a test
  before set-up hides its organisation inside its sandbox (`Apiary.EditionKit`).
  """
  # Not async: the tests hide the suite's instance organisation, a row every test shares.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.AccountsFixtures

  alias Apiary.Setup

  @password "a long pass phrase"

  defp fields(lv) do
    lv
    |> element("#setup_form")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("input:not([type=hidden]), select, textarea")
    |> LazyHTML.attribute("name")
  end

  defp params(extra \\ %{}) do
    Enum.into(extra, %{
      "email" => unique_user_email(),
      "organisation_name" => "Acme Ltd",
      "password" => @password,
      "password_confirmation" => @password
    })
  end

  describe "before set-up" do
    setup do
      Apiary.EditionKit.hide_instance_organisation()
      %{code: Setup.code!()}
    end

    test "asks for the address, a password and its confirmation, and the organisation's name",
         %{conn: conn, code: code} do
      {:ok, lv, html} = live(conn, ~p"/setup/#{code}")

      assert html =~ "Set up Qory Apiary"

      # The edition's line, exactly as it gives it, and the admin sentence on its own line.
      assert lv
             |> element("main h1 + p")
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.text()
             |> String.trim() ==
               Apiary.Edition.first_sign_up_line()

      assert has_element?(lv, "#setup-admin", "You become this instance's admin.")

      assert fields(lv) == [
               "user[email]",
               "user[password]",
               "user[password_confirmation]",
               "user[organisation_name]"
             ]

      assert has_element?(lv, "#setup_form button", "Set up")
      assert page_title(lv) =~ "Set up"

      # The code is in the address alone: never drawn on the page.
      refute render(lv) =~ code
    end

    test "makes the organisation with no workspace", %{conn: conn, code: code} do
      {:ok, lv, _html} = live(conn, ~p"/setup/#{code}")
      email = unique_user_email()

      lv
      |> form("#setup_form", user: params(%{"email" => email}))
      |> render_submit()

      user = Apiary.Accounts.get_user_by_email(email)
      [membership] = Apiary.Organisations.list_memberships(user)
      refute Apiary.Organisations.has_workspace?(membership.organisation)
    end

    test "sets the instance up and signs the person in", %{conn: conn, code: code} do
      Apiary.Mail.put_test_source(:none)
      {:ok, lv, _html} = live(conn, ~p"/setup/#{code}")
      email = unique_user_email()

      form = form(lv, "#setup_form", user: params(%{"email" => email}))
      render_submit(form)
      conn = follow_trigger_action(form, conn)

      # Signed in, and at the instance's connections, its admin's first step.
      assert redirected_to(conn) == ~p"/instance/set-up"
      assert get_session(conn, :user_token)

      user = Apiary.Accounts.get_user_by_email(email)
      assert Apiary.Accounts.get_user_by_email_and_password(email, @password)
      assert Apiary.Access.instance_admin?(Apiary.Accounts.Scope.for_user(user))
      [membership] = Apiary.Organisations.list_memberships(user)
      assert membership.organisation.name == "Acme Ltd"

      refute Setup.valid_code?(code)
      assert Setup.set_up?()
    end

    test "with mail too, keeps the password and signs the person in with it",
         %{conn: conn, code: code} do
      Apiary.Mail.put_test_source(:env)
      {:ok, lv, _html} = live(conn, ~p"/setup/#{code}")
      email = unique_user_email()

      form = form(lv, "#setup_form", user: params(%{"email" => email}))
      render_submit(form)
      conn = follow_trigger_action(form, conn)

      assert get_session(conn, :user_token)
      assert Apiary.Accounts.get_user_by_email_and_password(email, @password)
    end

    test "asks for a password with mail too, and refuses what the sign-up refuses",
         %{conn: conn, code: code} do
      Apiary.Mail.put_test_source(:env)
      {:ok, lv, _html} = live(conn, ~p"/setup/#{code}")
      email = unique_user_email()

      lv
      |> form("#setup_form",
        user: %{"email" => email, "organisation_name" => "", "password" => ""}
      )
      |> render_submit()

      assert has_element?(lv, "#setup_form [name='user[organisation_name]'][aria-invalid]")
      assert has_element?(lv, "#user_password-error")
      refute Apiary.Accounts.get_user_by_email(email)
      assert Setup.valid_code?(code)

      lv
      |> form("#setup_form", user: params(%{"email" => email, "password_confirmation" => "no"}))
      |> render_submit()

      assert has_element?(lv, "#user_password_confirmation-error")
      refute Apiary.Accounts.get_user_by_email(email)
      refute Setup.set_up?()
    end

    test "a wrong code is a path that does not exist", %{conn: conn, code: code} do
      for wrong <- ["nope", String.duplicate("A", 43), code <> "A"] do
        assert_error_sent(:not_found, fn -> get(conn, ~p"/setup/#{wrong}") end)
      end

      assert Setup.valid_code?(code)
    end

    test "the full stop after the link in the log is no part of the code",
         %{conn: conn, code: code} do
      {:ok, lv, _html} = live(conn, "/setup/#{code}.")
      assert has_element?(lv, "#setup_form")
    end

    test "of two pages open, the second to send finds the instance set up",
         %{conn: conn, code: code} do
      {:ok, first, _html} = live(conn, ~p"/setup/#{code}")
      {:ok, second, _html} = live(build_conn(), ~p"/setup/#{code}")

      first |> form("#setup_form", user: params()) |> render_submit()

      email = unique_user_email()
      html = second |> form("#setup_form", user: params(%{"email" => email})) |> render_submit()

      assert html =~ "This Qory Apiary is already set up."
      refute Apiary.Accounts.get_user_by_email(email)
    end

    test "the page holds the code where an inspection does not print it",
         %{conn: conn, code: code} do
      {:ok, lv, _html} = live(conn, ~p"/setup/#{code}")
      assert render(lv) =~ "Set up Qory Apiary"

      refute inspect(%ApiaryWeb.SetupLive.HeldCode{value: code}) =~ code
      # The page's process as a crash report would print it.
      state = :sys.get_state(lv.pid)
      refute inspect(state, limit: :infinity, printable_limit: :infinity) =~ code
    end
  end

  describe "with a preset code, before set-up" do
    setup do
      Apiary.EditionKit.hide_instance_organisation()
      # The code of a link that a start without the preset logged.
      earlier = Setup.code!()
      code = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      previous = Application.get_env(:apiary, Setup, [])
      hex = Base.encode16(:crypto.hash(:sha256, code), case: :lower)
      Application.put_env(:apiary, Setup, Keyword.put(previous, :preset_code_sha256_setting, hex))
      on_exit(fn -> Application.put_env(:apiary, Setup, previous) end)
      :ok = Setup.boot()
      %{code: code, hex: hex, earlier: earlier}
    end

    test "the code opens the form and sets the instance up, once", %{conn: conn, code: code} do
      Apiary.Mail.put_test_source(:none)
      {:ok, lv, _html} = live(conn, ~p"/setup/#{code}")
      email = unique_user_email()

      form = form(lv, "#setup_form", user: params(%{"email" => email}))
      render_submit(form)
      conn = follow_trigger_action(form, conn)

      assert redirected_to(conn) == ~p"/instance/set-up"
      user = Apiary.Accounts.get_user_by_email(email)
      assert Apiary.Access.instance_admin?(Apiary.Accounts.Scope.for_user(user))
      assert Setup.set_up?()

      {:ok, _lv, html} = live(build_conn(), ~p"/setup/#{code}")
      assert html =~ "This Qory Apiary is already set up."
    end

    test "any other code is a path that does not exist", %{conn: conn, code: code, hex: hex} do
      other = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      for wrong <- ["nope", other, code <> "A", hex] do
        assert_error_sent(:not_found, fn -> get(conn, ~p"/setup/#{wrong}") end)
      end

      assert Setup.valid_code?(code)
    end

    test "the link a start logged before the preset is a path that does not exist",
         %{conn: conn, earlier: earlier} do
      assert_error_sent(:not_found, fn -> get(conn, ~p"/setup/#{earlier}") end)
      refute Setup.valid_code?(earlier)
    end

    test "after a purge, the same code is a path that does not exist",
         %{conn: conn, code: code} do
      assert {:ok, _signed_up} =
               Setup.set_up(code, %{
                 email: unique_user_email(),
                 organisation_name: "Acme Ltd",
                 password: @password,
                 password_confirmation: @password
               })

      Apiary.EditionKit.hide_instance_organisation()

      assert_error_sent(:not_found, fn -> get(conn, ~p"/setup/#{code}") end)
    end
  end

  describe "once set up" do
    test "any code says so and leads to the log-in page", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/setup/any-code")

      assert html =~ "This Qory Apiary is already set up."
      refute has_element?(lv, "#setup_form")

      assert {:ok, _login, _html} =
               lv
               |> element("#setup-done a", "Log in")
               |> render_click()
               |> follow_redirect(conn, ~p"/users/log-in")
    end

    test "a signed-in person is led to their workspace", %{conn: conn} do
      %{conn: conn} = register_and_log_in_user(%{conn: conn})
      {:ok, lv, _html} = live(conn, ~p"/setup/any-code")
      assert has_element?(lv, "#setup-done a[href='/']", "Go to your workspace")
    end
  end
end
