defmodule ApiaryWeb.UserLive.PasswordTest do
  @moduledoc """
  A password link's page, `/users/password/:token` (`ApiaryWeb.UserLive.Password`): it
  names the account, sets its password once, ends every session of it, and sends the
  person to log in; a link that does not work says so the same way whatever the reason.
  """
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Apiary.AccountsFixtures

  alias Apiary.{Accounts, Repo}
  alias Apiary.Accounts.{User, UserToken}

  @password "a long pass phrase"

  # A password link as `Apiary.Accounts.build_password_link/3` stores it.
  defp link(user, context \\ "password") do
    {token, user_token} = UserToken.build_password_link_token(user, context)
    Repo.insert!(user_token)
    token
  end

  defp params(password, confirmation \\ nil),
    do: %{
      "user" => %{"password" => password, "password_confirmation" => confirmation || password}
    }

  # The account is signed up with the suite's mail; the page is then opened without.
  setup do
    user = user_fixture()
    Apiary.Mail.put_test_source(:none)
    %{user: user}
  end

  test "names the account and asks for the new password twice", %{conn: conn, user: user} do
    {:ok, _lv, html} = live(conn, ~p"/users/password/#{link(user)}")

    assert html =~ "Set your password"
    assert html =~ user.email
    assert html =~ "New password"
    assert html =~ "Confirm new password"
    assert html =~ "Setting the password logs this account out everywhere."
    # The page writes no password back.
    refute html =~ ~s(value="#{@password}")
  end

  test "sets the password, ends every session, and goes to log in", %{conn: conn, user: user} do
    session = Accounts.generate_user_session_token(user)
    token = link(user)
    {:ok, lv, _html} = live(conn, ~p"/users/password/#{token}")

    lv |> form("#password_form", params(@password)) |> render_submit()
    flash = assert_redirect(lv, "/users/log-in")

    assert flash["info"] == "Your password is set. Log in with it."
    refute inspect(flash) =~ token
    assert %User{} = Accounts.get_user_by_email_and_password(user.email, @password)
    refute Accounts.get_user_by_session_token(session)

    # Once: the same link again says it has expired.
    {:ok, _lv, html} = live(conn, ~p"/users/password/#{token}")
    assert html =~ "That password link has expired"
    refute html =~ user.email
  end

  test "a password refused shows the form's error, and the link still works",
       %{conn: conn, user: user} do
    token = link(user)
    {:ok, lv, _html} = live(conn, ~p"/users/password/#{token}")

    html =
      lv
      |> form("#password_form", params(@password, "something else entirely"))
      |> render_submit()

    assert html =~ "does not match password"

    html = lv |> form("#password_form", params("short")) |> render_submit()
    assert html =~ "should be at least 12 character(s)"

    assert Accounts.get_user_by_password_link(token)
    refute Accounts.get_user_by_email_and_password(user.email, @password)

    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             lv |> form("#password_form", params(@password)) |> render_submit()
  end

  test "a link that is none, expired or ended by a newer one says the same", %{
    conn: conn,
    user: user
  } do
    expired = link(user, "password:release")
    at = DateTime.add(DateTime.utc_now(:second), -61 * 60, :second)

    Repo.update_all(
      from(t in UserToken, where: t.user_id == ^user.id and t.context == "password:release"),
      set: [inserted_at: at]
    )

    for token <- ["not-a-token", Base.url_encode64(:crypto.strong_rand_bytes(32)), expired] do
      {:ok, _lv, html} = live(conn, ~p"/users/password/#{token}")
      assert html =~ "That password link has expired"
      assert html =~ "Ask an admin of this Qory Apiary for a new one."
      refute html =~ user.email
      refute html =~ "password_form"
    end
  end

  test "a link used meanwhile, between the page and the submit, says it has expired",
       %{conn: conn, user: user} do
    token = link(user)
    {:ok, lv, _html} = live(conn, ~p"/users/password/#{token}")
    {:ok, _} = Accounts.set_password_by_link(token, params(@password)["user"])

    html = lv |> form("#password_form", params("another pass phrase")) |> render_submit()
    assert html =~ "That password link has expired"
    refute Accounts.get_user_by_email_and_password(user.email, "another pass phrase")
  end

  test "signed in as the account, setting the password logs the page's session out too",
       %{conn: conn, user: user} do
    conn = log_in_user(conn, user)
    {:ok, lv, _html} = live(conn, ~p"/users/password/#{link(user)}")

    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             lv |> form("#password_form", params(@password)) |> render_submit()

    refute Accounts.get_user_by_session_token(get_session(conn, :user_token))
  end
end
