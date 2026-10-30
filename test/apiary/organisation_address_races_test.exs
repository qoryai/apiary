defmodule Apiary.OrganisationAddressRacesTest do
  # A rename or a sign-up that reads an address as free while another organisation's rename
  # takes it and has not committed yet. Each side is on a connection of its own, outside
  # the SQL sandbox, so each commits and each waits on the other's locks as it would in
  # production. Not async: what these tests commit is visible to every other test while
  # they run, and they delete it again before they end.
  #
  # The rule under test: the check before the write does not see the other side's slug;
  # the unique index makes the write wait for the other side, then refuses it, and the
  # name is refused with the address, read again.
  use ExUnit.Case, async: false

  import Apiary.Races

  alias Apiary.{Organisations, Repo}
  alias Apiary.Accounts.User
  alias Apiary.Organisations.{Organisation, Slug}

  setup_all :clean_up_leftovers
  setup :setup_races

  # The other organisation renamed to `target`, held open until `commit/1`.
  defp hold_rename(target) do
    %{scope: other} = sign_up()

    {held, backend} =
      hold(fn -> Organisations.update_organisation(other, %{"name" => target}) end)

    assert {:ok, %Organisation{}} = held.result
    {held, backend}
  end

  defp taken(target),
    do: "Choose another name. Another organisation has the address /#{Slug.from_name(target)}."

  test "a rename waiting on the other's rename to the same address is refused, with the address" do
    %{scope: scope, organisation: organisation} = sign_up()
    target = name("Target")
    {held, held_backend} = hold_rename(target)

    second =
      start(fn ->
        Organisations.update_organisation(scope, %{"name" => String.upcase(target)})
      end)

    await_blocked(second.backend, held_backend)
    commit(held)

    assert {:error, %Ecto.Changeset{} = changeset} = Task.await(second.task)
    message = taken(target)
    assert [{^message, _keys}] = Keyword.get_values(changeset.errors, :name) |> render()
    assert Repo.get!(Organisation, organisation.id).slug == organisation.slug
  end

  test "a sign-up waiting on the other's rename to the same address is refused on the name" do
    target = name("Target")
    {held, held_backend} = hold_rename(target)
    address = email()

    second =
      start(fn ->
        Organisations.sign_up_user(
          %{email: address, organisation_name: String.upcase(target)},
          nil,
          open: true
        )
      end)

    await_blocked(second.backend, held_backend)
    commit(held)

    assert {:error, %Ecto.Changeset{} = changeset} = Task.await(second.task)
    message = taken(target)

    assert [{^message, _keys}] =
             Keyword.get_values(changeset.errors, :organisation_name) |> render()

    refute Repo.get_by(User, email: address)
  end

  # Each error as its message with its bindings filled in.
  defp render(errors) do
    for {message, keys} <- errors do
      {Regex.replace(~r/%{(\w+)}/, message, fn _, key ->
         keys |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
       end), keys}
    end
  end
end
