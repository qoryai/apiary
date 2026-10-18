defmodule Apiary.Runs.TargetShapeMigrationTest do
  # The migration that refuses a work item's target, or a target's further repositories,
  # with a segment starting with a dash or a system with an empty label, run down and up
  # again inside the test's transaction, which rolls it all back. It changes `work_items`
  # and `targets` under every other test, so this is not async.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log

  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  @shape {20_261_019_000_300, Apiary.Repo.Migrations.RefuseADashLedRepositoryOrAnEmptyHostLabel,
          "refuse_a_dash_led_repository_or_an_empty_host_label"}

  @checks ["targets_further_repositories_shape_check", "work_items_target_shape_check"]

  setup_all do
    {version, migration, name} = @shape

    unless Code.ensure_loaded?(migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{version}_#{name}.exs")
      |> Code.require_file()
    end

    :ok
  end

  @options [log: false, migration_lock: false]

  defp down!({version, migration, _name}),
    do: assert(:ok = Ecto.Migrator.down(Repo, version, migration, @options))

  defp up({version, migration, _name}),
    do: Ecto.Migrator.up(Repo, version, migration, @options)

  defp checks do
    %{rows: rows} =
      Repo.query!("SELECT conname FROM pg_constraint WHERE conname = ANY($1)", [@checks])

    rows |> List.flatten() |> Enum.sort()
  end

  defp update!(table, id, assignments, params) do
    Repo.query!("UPDATE #{table} SET #{assignments} WHERE id = $1", [
      Ecto.UUID.dump!(id) | params
    ])
  end

  setup do
    %{scope: scope} = sign_up_fixture()

    :ok =
      Apiary.Runs.Target.insert_new(scope.organisation.id, scope.workspace.id, [
        %{system: "code.example.com", path: "acme/shop"}
      ])

    %{
      work_item: work_item_fixture(scope),
      target: Apiary.Targets.get(scope, "code.example.com", "acme/shop")
    }
  end

  test "up refuses while a row is outside a check, and adds neither; once it is gone, both",
       %{work_item: work_item, target: target} do
    assert checks() == @checks
    down!(@shape)
    assert checks() == []

    for {table, id, assignments, params} <- [
          {"work_items", work_item.id, "target_path = $2", ["acme/-rf"]},
          {"work_items", work_item.id, "target_system = $2", ["forge..example.com"]},
          {"targets", target.id, "further_repositories = $2", [["acme/docs", "acme/-rf"]]}
        ] do
      assert %{num_rows: 1} = update!(table, id, assignments, params)

      # The migration's transaction, a savepoint of the test's, is rolled back.
      error = assert_raise Postgrex.Error, fn -> up(@shape) end
      assert error.postgres.code == :check_violation
      assert checks() == []

      update!(
        "work_items",
        work_item.id,
        "target_system = $2, target_path = $3",
        ["code.example.com", "acme/shop"]
      )

      update!("targets", target.id, "further_repositories = $2", [[]])
    end

    assert :ok = up(@shape)
    assert checks() == @checks
  end
end
