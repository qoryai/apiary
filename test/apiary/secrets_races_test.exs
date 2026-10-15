defmodule Apiary.SecretsRacesTest do
  # The first secrets of one organisation, written at once, from two workspaces of it.
  # Each side runs on a connection of its own, outside the SQL sandbox, so each commits and
  # each waits on the other's locks as it would in production. Not async: what these tests
  # commit is visible to every other test while they run, and they delete it again before
  # they end.
  #
  # The rule under test (`Apiary.Secrets`): an organisation has one data key, made with its
  # first secret. Every write of its secrets takes the organisation's advisory transaction
  # lock, so a second first secret waits for the first and finds its key; and should two
  # ever get to the key at once, the unique index on `organisation_data_keys
  # (organisation_id)` keeps one, `ON CONFLICT DO NOTHING` leaves it, and the read after
  # takes it.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.Races

  alias Apiary.{KeyDerivation, OrganisationsFixtures, Repo, Secrets}
  alias Apiary.Secrets.{Cipher, DataKey, Value}

  @moduletag needs: :secrets

  setup_all :clean_up_leftovers
  setup :setup_races

  defp keys(organisation),
    do: Repo.all(from k in DataKey, where: k.organisation_id == ^organisation.id)

  defp data_key_of(secret),
    do: Repo.one!(from v in Value, where: v.secret_id == ^secret.id, select: v.data_key_id)

  defp second_workspace(%{organisation: organisation, user: user}) do
    workspace = OrganisationsFixtures.workspace_fixture(organisation, "Second")
    OrganisationsFixtures.workspace_scope(user, workspace)
  end

  test "two first secrets from two workspaces: the second waits, and finds the first's key" do
    owner = sign_up()
    elsewhere = second_workspace(owner)

    {first, first_pid} =
      hold(fn -> Secrets.create_secret(owner.scope, %{name: "ONE", value: "one value"}) end)

    assert {:ok, one} = first.result

    second =
      start(fn -> Secrets.create_secret(elsewhere, %{name: "TWO", value: "two value"}) end)

    await_blocked(second.backend, first_pid)
    commit(first)

    assert {:ok, two} = Task.await(second.task)
    assert [%DataKey{id: key_id}] = keys(owner.organisation)
    assert data_key_of(one) == key_id
    assert data_key_of(two) == key_id

    assert Secrets.reveal_for_sealing(owner.organisation, one.public_id, nil) ==
             {:ok, "one value"}

    assert Secrets.reveal_for_sealing(owner.organisation, two.public_id, nil) ==
             {:ok, "two value"}
  end

  test "writes of one organisation's secrets take turns, from any workspace of it" do
    owner = sign_up()
    elsewhere = second_workspace(owner)
    {:ok, _key_made} = Secrets.create_secret(owner.scope, %{name: "FIRST", value: "x"})

    # Two other secrets, nothing in common but their organisation: the second waits on the
    # organisation's advisory lock alone.
    {first, first_pid} =
      hold(fn -> Secrets.create_secret(owner.scope, %{name: "ONE", value: "one value"}) end)

    assert {:ok, _one} = first.result

    second =
      start(fn -> Secrets.create_secret(elsewhere, %{name: "TWO", value: "two value"}) end)

    await_blocked(second.backend, first_pid)
    commit(first)

    assert {:ok, _two} = Task.await(second.task)
    assert [%DataKey{}] = keys(owner.organisation)
  end

  test "first secrets let go at once make one data key" do
    owner = sign_up()
    elsewhere = second_workspace(owner)
    scopes = Enum.take(Stream.cycle([owner.scope, elsewhere]), sides(4))

    results =
      scopes
      |> Enum.with_index()
      |> Enum.map(fn {scope, index} ->
        fn -> Secrets.create_secret(scope, %{name: "KEY_#{index}", value: "value #{index}"}) end
      end)
      |> together()

    assert Enum.all?(results, &match?({:ok, _secret}, &1))
    assert [%DataKey{id: key_id}] = keys(owner.organisation)

    for {:ok, secret} <- results do
      assert data_key_of(secret) == key_id
    end
  end

  test "a data key made while the first secret makes one: the secret takes it" do
    owner = sign_up()
    organisation = owner.organisation

    # A key made by a transaction that took no advisory lock, and holds its row open.
    {first, first_pid} =
      hold(fn ->
        {key_id, values_key} = KeyDerivation.key(:values)

        Repo.insert!(%DataKey{
          organisation_id: organisation.id,
          wrapped_key:
            Cipher.wrap(values_key, Cipher.new_data_key(), Cipher.data_key_aad(organisation.id)),
          wrapping_key_id: key_id
        })
      end)

    %DataKey{id: made_id} = first.result

    # The secret's insert of its key waits on the unique index, then does nothing.
    second =
      start(fn -> Secrets.create_secret(owner.scope, %{name: "ONE", value: "one value"}) end)

    await_blocked(second.backend, first_pid)
    commit(first)

    assert {:ok, secret} = Task.await(second.task)
    assert [%DataKey{id: ^made_id}] = keys(organisation)
    assert data_key_of(secret) == made_id

    assert Secrets.reveal_for_sealing(organisation, secret.public_id, nil) ==
             {:ok, "one value"}
  end
end
