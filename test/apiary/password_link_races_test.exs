defmodule Apiary.PasswordLinkRacesTest do
  # Two uses of one password link at once (`Apiary.Accounts.set_password_by_link/2`), and a
  # use while a new link is made, each on a connection of its own, outside the SQL sandbox,
  # so each commits and each waits on the other's locks as it would in production. Not
  # async: what these tests commit is visible to every other test while they run, and they
  # delete it again before they end.
  #
  # The rule under test: a use holds the account, then deletes the link's row, in its
  # transaction; a second use waits on the account, and then finds the link gone. The link
  # sets one password, once.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.Races

  alias Apiary.{Accounts, Repo}
  alias Apiary.Accounts.{User, UserToken}

  setup_all :clean_up_leftovers
  setup :setup_races

  setup do
    %{user: user} = sign_up()
    # The link as `Apiary.Accounts.build_password_link/3` stores it, committed.
    {token, user_token} = UserToken.build_password_link_token(user, "password")
    Repo.insert!(user_token)
    %{user: user, token: token}
  end

  defp set(token, password),
    do:
      Accounts.set_password_by_link(token, %{
        "password" => password,
        "password_confirmation" => password
      })

  test "of two uses at once, the first sets the password and the second is refused", ctx do
    {first, first_pid} = hold(fn -> set(ctx.token, "the first pass phrase") end)
    assert {:ok, {%User{}, _ended}} = first.result

    second = start(fn -> set(ctx.token, "the second pass phrase") end)
    await_blocked(second.backend, first_pid)
    commit(first)

    assert {:error, :invalid} = Task.await(second.task)
    assert Accounts.get_user_by_email_and_password(ctx.user.email, "the first pass phrase")
    refute Accounts.get_user_by_email_and_password(ctx.user.email, "the second pass phrase")

    assert Repo.all(
             from t in UserToken, where: t.user_id == ^ctx.user.id and t.context == "password"
           ) == []
  end

  # Making a link holds the account, then ends the account's links
  # (`Apiary.Accounts.build_password_link/3`); a use holds the account before it uses its
  # link up. One order, so neither waits on the other's second step: no deadlock.
  test "a use waits on a link being made, then finds its link ended", ctx do
    # The making's first step: the account, held.
    {made, made_pid} =
      hold(fn ->
        Repo.one!(from u in User, where: u.id == ^ctx.user.id, lock: "FOR NO KEY UPDATE")
      end)

    use = start(fn -> set(ctx.token, "a new pass phrase") end)
    await_blocked(use.backend, made_pid)

    # Its second step, while the use waits on the account: the link ended, at once.
    assert {1, _} =
             continue(made, fn ->
               Repo.delete_all(
                 from t in UserToken,
                   where:
                     t.user_id == ^ctx.user.id and
                       t.context in ^UserToken.password_link_contexts()
               )
             end)

    commit(made)

    assert {:error, :invalid} = Task.await(use.task)
    refute Accounts.get_user_by_email_and_password(ctx.user.email, "a new pass phrase")
  end
end
