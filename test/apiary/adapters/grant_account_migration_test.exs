defmodule Apiary.Adapters.GrantAccountMigrationTest do
  # The migration of a grant's account and a collection's grant, run down and up again
  # inside the test's transaction, which rolls it all back: up adds `account_ref`,
  # `account_title` and `grant_id`, NULL for the rows there already, with their checks,
  # the foreign key that keeps a collection's grant a grant of its connection, and the
  # ended reason of a grant end; down takes them away and deletes the grants a grant end
  # ended. It changes `adapter_grants` and `source_collections` under every other test, so
  # this is not async.
  use Apiary.DataCase, async: false

  # Running a migration down and up again while later ones are applied makes Ecto warn.
  @moduletag :capture_log
  @moduletag needs: :factory

  import Ecto.Query, only: [from: 2]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  @version 20_261_025_160_700
  @migration Apiary.Repo.Migrations.KeepAGrantSAccountAndItsCollections

  setup_all do
    if not Code.ensure_loaded?(@migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{@version}_keep_a_grant_s_account_and_its_collections.exs")
      |> Code.require_file()
    end

    :ok
  end

  @options [log: false, migration_lock: false]

  defp down!, do: assert(:ok = Ecto.Migrator.down(Repo, @version, @migration, @options))
  defp up!, do: assert(:ok = Ecto.Migrator.up(Repo, @version, @migration, @options))

  defp columns do
    Repo.query!(
      "SELECT table_name, column_name FROM information_schema.columns " <>
        "WHERE column_name IN ('account_ref', 'account_title', 'grant_id') " <>
        "AND table_name IN ('adapter_grants', 'source_collections') " <>
        "ORDER BY table_name, column_name"
    ).rows
  end

  defp query!(sql, params), do: Repo.query!(sql, Enum.map(params, &dump/1))

  defp dump(<<_::288>> = uuid), do: Ecto.UUID.dump!(uuid)
  defp dump(value), do: value

  defp grant_row?(id),
    do: Repo.exists?(from g in "adapter_grants", where: g.id == type(^id, :binary_id))

  # A grant and a collection as they stood before the migration: no account, no grant.
  defp old_rows(scope) do
    %{adapter: adapter} = connectable_adapter_fixture()
    {connection, _nonce} = connection_fixture(scope, adapter, :listed)
    ref = listing_grant(connection, "G_OLD")
    grant = Repo.get_by!(Apiary.Adapters.Grant, connection_id: connection.id, grant_ref: ref)

    query!("UPDATE adapter_grants SET account_ref = NULL, account_title = NULL WHERE id = $1", [
      grant.id
    ])

    collection =
      Repo.insert!(%Apiary.Adapters.Collection{
        public_id: Apiary.PublicId.generate(Apiary.Adapters.Collection.prefix()),
        organisation_id: scope.organisation.id,
        adapter_id: adapter.id,
        connection_id: connection.id,
        external_ref: "OLD",
        url: "https://tracker.acme.example/OLD",
        title: "Old",
        last_listed_at: DateTime.utc_now(:second)
      })

    {connection, grant, collection}
  end

  test "rows there already keep no account and no grant; up adds the checks and the key" do
    %{scope: scope} = sign_up_fixture()
    {connection, grant, collection} = old_rows(scope)

    down!()
    assert columns() == []

    up!()

    assert columns() == [
             ["adapter_grants", "account_ref"],
             ["adapter_grants", "account_title"],
             ["source_collections", "grant_id"]
           ]

    assert %{account_ref: nil, account_title: nil, state: :live} = Repo.reload!(grant)
    assert %{grant_id: nil, ended_at: nil} = Repo.reload!(collection)

    # An account is both members or neither, and within its lengths.
    for set <- [
          "account_ref = '1001'",
          "account_title = 'acme'",
          "account_ref = '', account_title = 'acme'",
          "account_ref = '1001', account_title = ''",
          "account_ref = '1001', account_title = repeat('t', 1025)"
        ] do
      assert_raise Postgrex.Error, ~r/adapter_grants_account_check/, fn ->
        Repo.transaction(fn ->
          query!("UPDATE adapter_grants SET #{set} WHERE id = $1", [grant.id])
        end)
      end
    end

    assert %{num_rows: 1} =
             query!(
               "UPDATE adapter_grants SET account_ref = '1001', account_title = 'acme' WHERE id = $1",
               [grant.id]
             )

    # A collection's grant is a grant of its connection.
    %{scope: other} = sign_up_fixture()
    {elsewhere, _nonce} = connection_fixture(other, connectable_adapter_fixture().adapter)
    their_ref = listing_grant(elsewhere)

    theirs =
      Repo.get_by!(Apiary.Adapters.Grant, connection_id: elsewhere.id, grant_ref: their_ref)

    assert_raise Postgrex.Error, ~r/source_collections_grant_id_fkey/, fn ->
      Repo.transaction(fn ->
        query!("UPDATE source_collections SET grant_id = $1 WHERE id = $2", [
          theirs.id,
          collection.id
        ])
      end)
    end

    assert %{num_rows: 1} =
             query!("UPDATE source_collections SET grant_id = $1 WHERE id = $2", [
               grant.id,
               collection.id
             ])

    assert connection.id == Repo.reload!(collection).connection_id
  end

  test "the ended reason of a grant end; down deletes the grants it ended, and keeps the others" do
    %{scope: scope} = sign_up_fixture()
    {connection, grant, _collection} = old_rows(scope)
    ended_ref = listing_grant(connection, "G_ENDED")

    ended =
      Repo.get_by!(Apiary.Adapters.Grant, connection_id: connection.id, grant_ref: ended_ref)

    assert %{num_rows: 1} =
             query!(
               "UPDATE adapter_grants SET state = 'ended', ended_at = now(), " <>
                 "ended_reason = 'adapter_reported' WHERE id = $1",
               [ended.id]
             )

    down!()
    refute grant_row?(ended.id)
    assert grant_row?(grant.id)

    assert_raise Postgrex.Error, ~r/adapter_grants_ended_reason_check/, fn ->
      Repo.transaction(fn ->
        query!(
          "UPDATE adapter_grants SET state = 'ended', ended_at = now(), " <>
            "ended_reason = 'adapter_reported' WHERE id = $1",
          [grant.id]
        )
      end)
    end

    up!()
  end
end
