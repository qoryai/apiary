defmodule Apiary.Environments.TargetMigrationTest do
  # The migration that keeps the target an environment record was queued for and the
  # target its build was built for, run down and up again inside the test's transaction,
  # which rolls it all back: up fills the queued target from the collection's current
  # target, where it has one, and keeps no built target. It changes `environments` under
  # every other test, so this is not async. The rows are read and written in raw SQL, as
  # the record's schema names the columns the migration takes away.
  use Apiary.DataCase, async: false

  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  @moduletag needs: :factory

  @target {20_261_019_000_100, Apiary.Repo.Migrations.KeepTheTargetAnEnvironmentWasBuiltFor,
           "keep_the_target_an_environment_was_built_for"}

  setup_all do
    {version, migration, name} = @target

    if not Code.ensure_loaded?(migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{version}_#{name}.exs")
      |> Code.require_file()
    end

    :ok
  end

  @options [log: false, migration_lock: false]

  defp down!({version, migration, _name}),
    do: assert(:ok = Ecto.Migrator.down(Repo, version, migration, @options))

  defp up!({version, migration, _name}),
    do: assert(:ok = Ecto.Migrator.up(Repo, version, migration, @options))

  defp columns do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns " <>
          "WHERE table_name = 'environments' AND column_name LIKE '%target%' ORDER BY column_name"
      )

    List.flatten(rows)
  end

  # A record of `collection` for `pool`, as one kept before the migration.
  defp insert!(scope, pool, collection) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO environments (id, organisation_id, workspace_id, pool_id, " <>
        "source_collection_id, queued_ref, queued_at, inserted_at, updated_at) " <>
        "VALUES ($1, $2, $3, $4, $5, 'env-1', now(), now(), now())",
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(scope.organisation.id),
        Ecto.UUID.dump!(scope.workspace.id),
        Ecto.UUID.dump!(pool.id),
        Ecto.UUID.dump!(collection.id)
      ]
    )

    id
  end

  defp targets(id) do
    %{rows: [row]} =
      Repo.query!(
        "SELECT queued_target_system, queued_target_path, built_target_system, " <>
          "built_target_path FROM environments WHERE id = $1",
        [Ecto.UUID.dump!(id)]
      )

    row
  end

  test "up fills the queued target from the collection's target, and no built target; down takes the columns away" do
    %{scope: scope} = sign_up_fixture()
    pool = pool_fixture(scope)
    shop = collection_fixture(scope, target_path: "acme/shop", environment_ref: nil)
    bare = collection_fixture(scope, target_system: nil, target_path: nil, environment_ref: nil)

    down!(@target)
    assert columns() == []

    with_target = insert!(scope, pool, shop)
    without_target = insert!(scope, pool, bare)

    up!(@target)

    assert columns() == ~w(built_target_path built_target_system queued_target_path
                           queued_target_system)

    assert targets(with_target) == ["code.example.com", "acme/shop", nil, nil]
    assert targets(without_target) == [nil, nil, nil, nil]

    down!(@target)
    assert columns() == []
    up!(@target)
    assert targets(with_target) == ["code.example.com", "acme/shop", nil, nil]
  end
end
