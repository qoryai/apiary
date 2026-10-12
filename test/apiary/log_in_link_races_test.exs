defmodule Apiary.LogInLinkRacesTest do
  # A log-in link's first use on an unconfirmed account (`Apiary.Accounts.login_user_by_magic_link/1`)
  # and what may run at the same moment: a second use of the same link, and a change of
  # password from a session the link is about to end. Each side is on a connection of
  # its own, outside the SQL sandbox, so each commits and each waits on the other's locks
  # as it would in production. Not async: what these tests commit is visible to every
  # other test while they run, and they delete it again before they end.
  #
  # The rule under test: the confirmation holds the account's row, `FOR NO KEY UPDATE`,
  # and so does a change of password; whichever comes second waits, then sees what the
  # first did.
  use ExUnit.Case, async: false
  use ApiaryWeb, :verified_routes

  import Ecto.Query
  import Phoenix.ConnTest
  import Apiary.Races

  alias Apiary.{Accounts, Repo}
  alias Apiary.Accounts.{User, UserToken}

  @endpoint ApiaryWeb.Endpoint

  setup_all :clean_up_leftovers
  setup :setup_races

  setup do
    %{user: user} = sign_up()

    # An account whose address nobody confirmed yet, as a sign-up without mail makes it.
    Repo.update_all(from(u in User, where: u.id == ^user.id),
      set: [confirmed_at: nil, hashed_password: nil]
    )

    %{user: Accounts.get_user!(user.id)}
  end

  defp link(user) do
    {token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    token
  end

  test "of two uses at once of one link, the first confirms the account and the second finds the link used",
       %{user: user} do
    link = link(user)

    {first, first_pid} = hold(fn -> Accounts.login_user_by_magic_link(link) end)
    assert {:ok, {%User{confirmed_at: %DateTime{}}, _ended}} = first.result

    second = start(fn -> Accounts.login_user_by_magic_link(link) end)
    await_blocked(second.backend, first_pid)
    commit(first)

    assert {:error, :not_found} = Task.await(second.task)
  end

  test "a change of password waiting on the first link's confirmation sets nothing, and the person is sent to log in",
       %{user: user} do
    {:ok, {user, _ended}} =
      Accounts.update_user_password(user, %{
        password: "a pass phrase set first",
        password_confirmation: "a pass phrase set first"
      })

    session = Accounts.generate_user_session_token(user)
    link = link(user)

    {first, first_pid} = hold(fn -> Accounts.login_user_by_magic_link(link) end)
    assert {:ok, {_user, _ended}, :password_removed} = first.result

    # Whoever set the password, signed in, changes it while the owner's link confirms.
    conn = init_test_session(build_conn(), %{user_token: session})

    second =
      start(fn ->
        post(conn, ~p"/users/update-password", %{
          "user" => %{
            "password" => "a later pass phrase",
            "password_confirmation" => "a later pass phrase"
          }
        })
      end)

    await_blocked(second.backend, first_pid)
    commit(first)

    conn = Task.await(second.task)
    assert redirected_to(conn) == ~p"/users/log-in"

    assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
             "You must log in to access this page."

    reloaded = Accounts.get_user!(user.id)
    assert reloaded.confirmed_at
    assert is_nil(reloaded.hashed_password)
    refute Accounts.get_user_by_email_and_password(user.email, "a later pass phrase")
    refute Accounts.get_user_by_session_token(session)
  end
end
