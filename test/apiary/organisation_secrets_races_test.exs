defmodule Apiary.OrganisationSecretsRacesTest do
  # The first secrets of one organisation, those without a workspace, written at once.
  # Each side runs on a connection apart, outside the SQL sandbox, so each commits and
  # each waits on the other's locks as it would in production. Not async: what these tests
  # commit is visible to every other test while they run, and they delete it again before
  # they end.
  #
  # The rule under test (`Apiary.Secrets`): an organisation has one data key, made with its
  # first secret. Every write of its secrets takes the organisation's advisory transaction
  # lock for its secrets, so a second first secret waits for the first and finds its key;
  # and should two ever get to the key at once, the unique index on
  # `organisation_data_keys (organisation_id)` keeps one, `ON CONFLICT DO NOTHING` leaves
  # it, and the read after takes it.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.Races

  alias Apiary.{Edition, EditionStubs, KeyDerivation, Repo, Secrets}
  alias Apiary.Secrets.{Cipher, OrganisationDataKey, Value}

  @moduletag needs: :secrets

  setup_all :clean_up_leftovers
  setup :setup_races

  setup do
    Edition.put_test_stub(EditionStubs.GrantsOrganisationSecrets)
  end

  defp keys(organisation),
    do: Repo.all(from k in OrganisationDataKey, where: k.organisation_id == ^organisation.id)

  defp data_key_of(secret),
    do:
      Repo.one!(
        from v in Value, where: v.secret_id == ^secret.id, select: v.organisation_data_key_id
      )

  defp create(scope, name, value),
    do: Secrets.create_organisation_secret(scope, %{name: name, value: value})

  defp dump(id), do: Ecto.UUID.dump!(id)

  # An organisation's secret left without values, and its value as the database held it,
  # to insert again.
  defp secret_without_values(scope) do
    {:ok, secret} = create(scope, "ONE", "one value")
    value = Repo.one!(from v in Value, where: v.secret_id == ^secret.id)
    Repo.delete_all(from v in Value, where: v.secret_id == ^secret.id)
    {secret, value}
  end

  defp insert_without_workspace(secret, value),
    do:
      Repo.query(
        """
        INSERT INTO secret_values
          (id, organisation_id, workspace_id, secret_id, value_id, organisation_data_key_id,
           nonce, ciphertext, inserted_at, updated_at)
        VALUES ($1, $2, NULL, $3, NULL, $4, $5, $6, now(), now())
        """,
        [
          dump(Ecto.UUID.generate()),
          dump(secret.organisation_id),
          dump(secret.id),
          dump(value.organisation_data_key_id),
          value.nonce,
          value.ciphertext
        ]
      )

  defp give_workspace(secret, workspace),
    do:
      Repo.query("UPDATE secrets SET workspace_id = $1 WHERE id = $2", [
        dump(workspace.id),
        dump(secret.id)
      ])

  defp values_of(secret),
    do: Repo.all(from v in Value, where: v.secret_id == ^secret.id, select: v.workspace_id)

  defp workspace_of(secret),
    do: Repo.one!(from s in "secrets", where: s.id == ^dump(secret.id), select: s.workspace_id)

  test "two first secrets: the second waits, and finds the first's key" do
    owner = sign_up()
    admin = member(owner.scope, :admin)

    {first, first_pid} = hold(fn -> create(owner.scope, "ONE", "one value") end)
    assert {:ok, one} = first.result

    second = start(fn -> create(admin.scope, "TWO", "two value") end)

    await_blocked(second.backend, first_pid)
    commit(first)

    assert {:ok, two} = Task.await(second.task)
    assert [%OrganisationDataKey{id: key_id}] = keys(owner.organisation)
    assert data_key_of(one) == key_id
    assert data_key_of(two) == key_id

    assert Secrets.reveal_for_sealing(owner.organisation, one.public_id, nil) ==
             {:ok, "one value"}

    assert Secrets.reveal_for_sealing(owner.organisation, two.public_id, nil) ==
             {:ok, "two value"}
  end

  test "writes of one organisation's secrets take turns" do
    owner = sign_up()
    {:ok, _key_made} = create(owner.scope, "FIRST", "x")

    # Two other secrets, nothing in common but their organisation: the second waits on the
    # organisation's advisory lock alone.
    {first, first_pid} = hold(fn -> create(owner.scope, "ONE", "one value") end)
    assert {:ok, _one} = first.result

    second = start(fn -> create(owner.scope, "TWO", "two value") end)

    await_blocked(second.backend, first_pid)
    commit(first)

    assert {:ok, _two} = Task.await(second.task)
    assert [%OrganisationDataKey{}] = keys(owner.organisation)
  end

  test "first secrets let go at once make one data key" do
    owner = sign_up()

    results =
      0..(sides(4) - 1)
      |> Enum.map(fn index ->
        fn -> create(owner.scope, "KEY_#{index}", "value #{index}") end
      end)
      |> together()

    assert Enum.all?(results, &match?({:ok, _secret}, &1))
    assert [%OrganisationDataKey{id: key_id}] = keys(owner.organisation)

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

        Repo.insert!(%OrganisationDataKey{
          organisation_id: organisation.id,
          wrapped_key:
            Cipher.wrap(
              values_key,
              Cipher.new_data_key(),
              Cipher.organisation_data_key_aad(organisation.id)
            ),
          wrapping_key_id: key_id
        })
      end)

    %OrganisationDataKey{id: made_id} = first.result

    # The secret's insert of its key waits on the unique index, then does nothing.
    second = start(fn -> create(owner.scope, "ONE", "one value") end)

    await_blocked(second.backend, first_pid)
    commit(first)

    assert {:ok, secret} = Task.await(second.task)
    assert [%OrganisationDataKey{id: ^made_id}] = keys(organisation)
    assert data_key_of(secret) == made_id

    assert Secrets.reveal_for_sealing(organisation, secret.public_id, nil) ==
             {:ok, "one value"}
  end

  # The scope match (`secret_value_scope_matches`) against a change of a secret's level,
  # each in SQL at READ COMMITTED, the app's level; the app never changes a secret's
  # level. A value without a workspace locks its secret's row, so the two take turns, and
  # the second finds what the first committed. A change run directly under REPEATABLE READ
  # or SERIALIZABLE reads its snapshot and is not refused by these triggers, though such a
  # value decrypts nowhere.
  test "a value without a workspace, inserted while its secret gets one: refused" do
    owner = sign_up()
    {secret, value} = secret_without_values(owner.scope)

    {first, first_pid} = hold(fn -> give_workspace(secret, owner.workspace) end)
    assert {:ok, %{num_rows: 1}} = first.result

    second = start(fn -> insert_without_workspace(secret, value) end)

    await_blocked(second.backend, first_pid)
    commit(first)

    assert {:error, %Postgrex.Error{postgres: %{constraint: "secret_value_scope_matches"}}} =
             Task.await(second.task)

    assert values_of(secret) == []
    assert workspace_of(secret) == dump(owner.workspace.id)
  end

  test "a secret given a workspace while a value without one is inserted: refused" do
    owner = sign_up()
    {secret, value} = secret_without_values(owner.scope)

    {first, first_pid} = hold(fn -> insert_without_workspace(secret, value) end)
    assert {:ok, %{num_rows: 1}} = first.result

    second = start(fn -> give_workspace(secret, owner.workspace) end)

    await_blocked(second.backend, first_pid)
    commit(first)

    assert {:error, %Postgrex.Error{postgres: %{constraint: "secret_value_scope_matches"}}} =
             Task.await(second.task)

    assert values_of(secret) == [nil]
    assert workspace_of(secret) == nil
  end
end
