defmodule Apiary.Stacks.OwnerMigrationTest do
  # The migration that keeps the owner of each stack row, run down and up again inside the
  # test's transaction, which rolls it all back: up renames the column and sets each NULL
  # owner to the instance's organisation; down renames it back. It changes `stacks` under
  # every other test, so this is not async. The rows are read and written in raw SQL, as
  # the schema has one name of the column's two.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures

  @migration {20_261_025_140_000, Apiary.Repo.Migrations.KeepTheOwnerOfEachStack,
              "keep_the_owner_of_each_stack"}

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

  defp down! do
    {version, migration, _name} = @migration
    Ecto.Migrator.down(Repo, version, migration, @options)
  end

  defp up! do
    {version, migration, _name} = @migration
    Ecto.Migrator.up(Repo, version, migration, @options)
  end

  defp columns do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns WHERE table_name = 'stacks' " <>
          "AND column_name IN ('saved_by_organisation_id', 'owner_organisation_id')"
      )

    List.flatten(rows)
  end

  # A row at the workspace of `scope` for `workflow`, owned by `owner` in the column
  # `saved_by_organisation_id`, nil for none.
  defp insert!(scope, workflow, owner) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO stacks (id, organisation_id, workspace_id, workflow, harness, " <>
        "saved_by_organisation_id, inserted_at, updated_at) " <>
        "VALUES ($1, $2, $3, $4, $5, $6, now(), now())",
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(scope.organisation.id),
        Ecto.UUID.dump!(scope.workspace.id),
        workflow,
        "extends: {git: https://code.example.com/team/stacks, ref: main}\n",
        owner && Ecto.UUID.dump!(owner)
      ]
    )

    id
  end

  defp owner(id) do
    %{rows: [[owner]]} =
      Repo.query!("SELECT owner_organisation_id FROM stacks WHERE id = $1", [
        Ecto.UUID.dump!(id)
      ])

    owner && Ecto.UUID.load!(owner)
  end

  test "up sets each null owner to the instance's organisation, and keeps the others" do
    %{scope: scope} = sign_up_fixture()
    instance = Apiary.Edition.instance_organisation_id()
    refute instance == scope.organisation.id

    assert :ok = down!()
    assert columns() == ["saved_by_organisation_id"]

    unowned = insert!(scope, "explore", nil)
    owned = insert!(scope, "review", scope.organisation.id)

    assert :ok = up!()
    assert columns() == ["owner_organisation_id"]
    assert owner(unowned) == instance
    assert owner(owned) == scope.organisation.id
  end

  test "down renames the column back, with the owners up wrote" do
    %{scope: scope} = sign_up_fixture()
    assert :ok = down!()
    unowned = insert!(scope, "explore", nil)
    assert :ok = up!()

    assert :ok = down!()
    assert columns() == ["saved_by_organisation_id"]

    %{rows: [[owner]]} =
      Repo.query!("SELECT saved_by_organisation_id FROM stacks WHERE id = $1", [
        Ecto.UUID.dump!(unowned)
      ])

    assert Ecto.UUID.load!(owner) == Apiary.Edition.instance_organisation_id()
    assert :ok = up!()
  end
end
