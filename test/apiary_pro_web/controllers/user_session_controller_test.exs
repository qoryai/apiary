defmodule ApiaryProWeb.UserSessionControllerTest do
  @moduledoc """
  Signing in to a suspended account: the edition refuses it (`ApiaryPro.Suspensions`), and the
  core's log-in refuses any account the edition refuses
  (`Apiary.Accounts.sign_in_refusal/1`), once the person has shown the account is theirs.
  """
  use ApiaryWeb.ConnCase, async: true

  import Apiary.AccountsFixtures

  alias Apiary.Accounts

  describe "POST /users/log-in - a suspended account" do
    setup do
      %{user: user} = Apiary.OrganisationsFixtures.sign_up_fixture()
      user = set_password(user)

      Apiary.Repo.insert!(%ApiaryPro.Suspensions.AccountSuspension{
        user_id: user.id,
        suspended_at: DateTime.utc_now()
      })

      %{user: user}
    end

    test "is refused with its password, and told whom to ask", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/log-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Contact support. This account cannot log in at the moment."
    end

    test "is refused with a link, which is used up", %{conn: conn, user: user} do
      {token, _hashed_token} = generate_user_magic_link_token(user)

      conn = post(conn, ~p"/users/log-in", %{"user" => %{"token" => token}})

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "cannot log in at the moment"
      refute Accounts.get_user_by_magic_link_token(token)
    end

    test "a wrong password says nothing of the suspension", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => "invalid_password"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "That email and password do not match."
    end
  end
end
