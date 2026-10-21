defmodule Apiary.Dispatches.RefAtMigrationTest do
  # The migration that keeps when a prebuild took its environment_ref, run down and up
  # again inside the test's transaction, which rolls it all back: up gives every prebuild
  # its queued_at, and a run without an environment_ref none. It changes `dispatch_runs`
  # under every other test, so this is not async. The rows are read in raw SQL, as the
  # schema names the column the migration takes away.
  use Apiary.DataCase, async: false

  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Environments}

  @moduletag needs: :factory

  @migration {20_261_019_000_120, Apiary.Repo.Migrations.KeepWhenAPrebuildTookItsRef,
              "keep_when_a_prebuild_took_its_ref"}

  setup_all do
    {version, migration, name} = @migration

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

  defp column? do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns " <>
          "WHERE table_name = 'dispatch_runs' AND column_name = 'environment_ref_at'"
      )

    rows != []
  end

  defp times(id) do
    %{rows: [row]} =
      Repo.query!(
        "SELECT queued_at, environment_ref_at FROM dispatch_runs WHERE id = $1",
        [Ecto.UUID.dump!(id)]
      )

    row
  end

  test "up gives every prebuild its queued_at and a run without a ref none; down takes the column away" do
    %{scope: scope} = sign_up_fixture()
    _pool = pool_fixture(scope)
    collection = collection_fixture(scope)

    {:ok, [prebuild]} =
      Repo.transact(fn -> {:ok, Environments.trigger([collection], Dispatches.now())} end)

    {:ok, explore} = Repo.transact(fn -> Dispatches.queue(work_item_fixture(scope), 1) end)

    down!(@migration)
    refute column?()
    up!(@migration)
    assert column?()

    assert [queued_at, queued_at] = times(prebuild.id)
    assert [%NaiveDateTime{}, nil] = times(explore.id)
  end
end
