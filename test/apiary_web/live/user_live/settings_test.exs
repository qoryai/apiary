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
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

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

    test "with one language, shows it and offers no choice", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      refute has_element?(lv, "#preferences_language option")
      assert has_element?(lv, "p#preferences_language")
      refute has_element?(lv, "#preferences_form [name='preferences[skin]']")
    end

    test "saves the time zone and says so", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      html =
        lv
        |> form("#preferences_form", %{"preferences" => %{"time_zone" => "America/Lima"}})
        |> render_submit()

      assert html =~ "Preferences saved."
      assert Accounts.get_user!(user.id).time_zone == "America/Lima"
      assert has_element?(lv, "#preferences_time_zone option[value='America/Lima'][selected]")
    end

    test "refuses a time zone the database does not know", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      render_submit(lv, "update_preferences", %{"preferences" => %{"time_zone" => "Mars/Base"}})

      assert has_element?(lv, "#preferences_time_zone-error")
      refute has_element?(lv, "#preferences_time_zone option[value='Mars/Base']")
      assert Accounts.get_user!(user.id).time_zone == "Etc/UTC"
    end

    test "refuses a language the application has no catalogue for", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      render_submit(lv, "update_preferences", %{"preferences" => %{"language" => "xx"}})

      refute render(lv) =~ "Preferences saved."
      assert Accounts.get_user!(user.id).language == "en"
    end

    test "keeps a zone chosen outside the list selected", %{conn: conn, user: user} do
      for zone <- ["UTC", "Europe/Oslo"] do
        {:ok, _user} = Accounts.update_user_preferences(user, %{time_zone: zone})
        {:ok, lv, _html} = live(conn, ~p"/users/settings")

        assert has_element?(lv, "#preferences_time_zone option[value='#{zone}'][selected]")
      end
    end

    test "names each zone's countries, so a country without a zone of its own is found",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      assert has_element?(lv, "#preferences_time_zone option[value='Europe/Berlin']", "Norway")
      assert has_element?(lv, "#preferences_time_zone option[value='Africa/Abidjan']", "Iceland")
    end
  end
end
