defmodule ApiaryWeb.UserLive.SettingsTest do
  use ApiaryWeb.ConnCase, async: true

  alias Apiary.Accounts
  import Phoenix.LiveViewTest
  import Apiary.AccountsFixtures

  describe "Settings page" do
    test "renders settings page", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/settings")

      assert html =~ "Change email"
      assert html =~ "Save password"
    end

    test "is a settings page beside the workspace's sidebar, whose lists open whole",
         %{conn: conn} do
      %{user: user, scope: scope} = Apiary.OrganisationsFixtures.sign_up_fixture()
      conn = log_in_user(conn, user)
      workspace = "/#{scope.organisation.slug}/#{scope.workspace.slug}"

      for {path, key, title} <- [
            {~p"/users/settings", "user_settings", "Account"},
            {~p"/users/settings/preferences", "user_preferences", "Preferences"},
            {~p"/users/organisations", "user_organisations", "Organisations"}
          ] do
        {:ok, lv, _html} = live(conn, path)

        assert has_element?(lv, "#settings-section-#{key} h1#settings-section-title", title)
        assert has_element?(lv, "#nav-group-account #nav-#{key}[aria-current='page']")
        assert has_element?(lv, "aside#sidebar[aria-label='Workspace']")
        # Nothing carries a target here: Runs and Network access open the whole lists.
        assert has_element?(lv, "#nav-runs[href='#{workspace}/runs']")
        assert has_element?(lv, "#nav-network[href='#{workspace}/network']")
      end
    end

    test "redirects if user is not logged in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/users/settings")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end

    test "redirects if user is not in sudo mode", %{conn: conn} do
      {:ok, conn} =
        conn
        |> log_in_user(user_fixture(),
          token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
        )
        |> live(~p"/users/settings")
        |> follow_redirect(conn, ~p"/users/log-in")

      assert conn.resp_body =~ "You must re-authenticate to access this page."
    end

    test "asks for a recent sign-in for the account's deletion, not for Preferences",
         %{conn: conn} do
      conn =
        log_in_user(conn, user_fixture(),
          token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
        )

      # Preferences changes how the console shows things, not the account.
      {:ok, lv, _html} = live(conn, ~p"/users/settings/preferences")
      assert has_element?(lv, "#preferences_form")

      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               live(conn, ~p"/users/settings/delete")

      # A patch from Preferences to Account asks too.
      lv |> render_patch(~p"/users/settings")
      assert_redirect(lv, ~p"/users/log-in")
    end
  end

  describe "update email form" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "updates the user email", %{conn: conn, user: user} do
      new_email = unique_user_email()

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#email_form", %{
          "user" => %{"email" => new_email}
        })
        |> render_submit()

      assert result =~ "A link to confirm your email"
      assert Accounts.get_user_by_email(user.email)
    end

    test "without mail, the address cannot be changed, and the page says why", %{
      conn: conn,
      user: user
    } do
      Apiary.Mail.put_test_source(:none)
      {:ok, lv, html} = live(conn, ~p"/users/settings")

      assert html =~
               "Changing your address needs mail. Ask an admin of this Qory Apiary to set it up."

      refute html =~ "We send a confirmation link to the new address."
      assert has_element?(lv, "#email_form input[name='user[email]'][disabled]")
      assert has_element?(lv, "#email_form button[type=submit][disabled]")

      # A crafted submit changes nothing and sends nothing.
      lv
      |> element("#email_form")
      |> render_submit(%{"user" => %{"email" => unique_user_email()}})

      refute_received {:email, %Swoosh.Email{subject: "Confirm your new email address" <> _}}

      refute Apiary.Repo.get_by(Accounts.UserToken,
               user_id: user.id,
               context: "change:#{user.email}"
             )
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> element("#email_form")
        |> render_change(%{
          "action" => "update_email",
          "user" => %{"email" => "with spaces"}
        })

      assert result =~ "Change email"
      assert result =~ "must have the @ sign and no spaces"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#email_form", %{
          "user" => %{"email" => user.email}
        })
        |> render_submit()

      assert result =~ "Change email"
      assert result =~ "did not change"
    end
  end

  describe "update password form" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "with mail, the password is optional beside log-in links", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      assert has_element?(lv, "#password_form", "Optional. Log-in links keep working either way.")
    end

    test "without mail, the password form says nothing of log-in links", %{conn: conn} do
      Apiary.Mail.put_test_source(:none)
      {:ok, lv, html} = live(conn, ~p"/users/settings")

      assert has_element?(lv, "#password_form button[type=submit]", "Save password")
      refute html =~ "Log-in links keep working"
      refute html =~ "Optional."
    end

    test "updates the user password", %{conn: conn, user: user} do
      new_password = valid_user_password()

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      form =
        form(lv, "#password_form", %{
          "user" => %{
            "email" => user.email,
            "password" => new_password,
            "password_confirmation" => new_password
          }
        })

      render_submit(form)

      new_password_conn = follow_trigger_action(form, conn)

      assert redirected_to(new_password_conn) == ~p"/users/settings"

      assert get_session(new_password_conn, :user_token) != get_session(conn, :user_token)

      assert Phoenix.Flash.get(new_password_conn.assigns.flash, :info) =~
               "Your password is updated."

      assert Accounts.get_user_by_email_and_password(user.email, new_password)
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> element("#password_form")
        |> render_change(%{
          "user" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })

      assert result =~ "Save password"
      assert result =~ "should be at least 12 character(s)"
      assert result =~ "does not match password"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#password_form", %{
          "user" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })
        |> render_submit()

      assert result =~ "Save password"
      assert result =~ "should be at least 12 character(s)"
      assert result =~ "does not match password"
    end
  end

  describe "confirm email" do
    setup %{conn: conn} do
      user = user_fixture()
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
        end)

      %{conn: log_in_user(conn, user), token: token, email: email, user: user}
    end

    test "updates the user email once", %{conn: conn, user: user, token: token, email: email} do
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")

      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"info" => message} = flash
      assert message == "Your email address is changed."
      refute Accounts.get_user_by_email(user.email)
      assert Accounts.get_user_by_email(email)

      # use confirm token again
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"error" => message} = flash
      assert message == "That link has expired. Ask for a new one below."
    end

    test "without mail, an expired link does not offer a new one", %{conn: conn} do
      Apiary.Mail.put_test_source(:none)

      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/oops")
      assert {:live_redirect, %{to: "/users/settings", flash: %{"error" => message}}} = redirect
      assert message == "That link has expired."
    end

    test "does not update email with invalid token", %{conn: conn, user: user} do
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/oops")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"error" => message} = flash
      assert message == "That link has expired. Ask for a new one below."
      assert Accounts.get_user_by_email(user.email)
    end

    test "redirects if user is not logged in", %{token: token} do
      conn = build_conn()
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")
      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => message} = flash
      assert message == "You must log in to access this page."
    end
  end

  describe "preferences form" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "offers the time zones by region, the person's selected", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings/preferences")

      assert has_element?(lv, "#preferences_time_zone option[value='Etc/UTC'][selected]")

      assert has_element?(
               lv,
               "#preferences_time_zone optgroup[label='Europe'] option[value='Europe/Berlin']"
             )

      assert has_element?(
               lv,
               "#preferences_time_zone option[value='America/Argentina/Buenos_Aires']",
               "Argentina/Buenos Aires"
             )
    end

    test "offers the theme and the keyboard shortcuts, the browser's own", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings/preferences")

      # The theme is the account menu's: the same event, a radio for each, and the script
      # marks the one in force.
      for theme <- ~w(system light dark) do
        assert has_element?(
                 lv,
                 "#theme-picker input[type=radio][name=theme][data-phx-theme='#{theme}']"
               )
      end

      assert has_element?(lv, "#theme-picker legend", "Theme")

      # The single-key shortcuts: a switch, on until the browser says otherwise; ⌘K is
      # never turned off.
      assert has_element?(
               lv,
               "button#shortcuts-switch[role=switch][aria-checked=true][data-pref=shortcuts]"
             )

      assert has_element?(lv, "label[for=shortcuts-switch]", "Keyboard shortcuts")
      assert has_element?(lv, "#shortcuts-switch-description", "Ctrl+K")
    end

    test "with one language, shows it and offers no choice", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings/preferences")

      refute has_element?(lv, "#preferences_language option")
      assert has_element?(lv, "p#preferences_language")
      refute has_element?(lv, "#preferences_form [name='preferences[skin]']")
    end

    test "saves the time zone and says so", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings/preferences")

      html =
        lv
        |> form("#preferences_form", %{"preferences" => %{"time_zone" => "America/Lima"}})
        |> render_submit()

      assert html =~ "Preferences saved."
      assert Accounts.get_user!(user.id).time_zone == "America/Lima"
      assert has_element?(lv, "#preferences_time_zone option[value='America/Lima'][selected]")
    end

    test "refuses a time zone the database does not know", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings/preferences")

      render_submit(lv, "update_preferences", %{"preferences" => %{"time_zone" => "Mars/Base"}})

      assert has_element?(lv, "#preferences_time_zone-error")
      refute has_element?(lv, "#preferences_time_zone option[value='Mars/Base']")
      assert Accounts.get_user!(user.id).time_zone == "Etc/UTC"
    end

    test "refuses a language the application has no catalogue for", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings/preferences")

      render_submit(lv, "update_preferences", %{"preferences" => %{"language" => "xx"}})

      refute render(lv) =~ "Preferences saved."
      assert Accounts.get_user!(user.id).language == "en"
    end

    test "keeps a zone chosen outside the list selected", %{conn: conn, user: user} do
      for zone <- ["UTC", "Europe/Oslo"] do
        {:ok, _user} = Accounts.update_user_preferences(user, %{time_zone: zone})
        {:ok, lv, _html} = live(conn, ~p"/users/settings/preferences")

        assert has_element?(lv, "#preferences_time_zone option[value='#{zone}'][selected]")
      end
    end

    test "names each zone's countries, so a country without a zone of its own is found",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings/preferences")

      assert has_element?(lv, "#preferences_time_zone option[value='Europe/Berlin']", "Norway")
      assert has_element?(lv, "#preferences_time_zone option[value='Africa/Abidjan']", "Iceland")
    end
  end
end
