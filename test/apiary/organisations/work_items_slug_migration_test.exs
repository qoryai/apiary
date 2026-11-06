defmodule Apiary.Organisations.WorkItemsSlugMigrationTest do
  # The migration that moves an organisation off the slug `work-items`, run down and up
  # again inside the test's transaction, which rolls it all back. It changes rows of
  # `organisations` under every other test, so this is not async.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log

  import Apiary.OrganisationsFixtures

  alias Apiary.Organisations.{Organisation, Workspace}

  @move {20_261_106_120_000, Apiary.Repo.Migrations.MoveTheWorkItemsSlug,
         "move_the_work_items_slug"}

  setup_all do
    {version, migration, name} = @move

    unless Code.ensure_loaded?(migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{version}_#{name}.exs")
      |> Code.require_file()
    end

    :ok
  end

  @options [log: false, migration_lock: false]

  defp migrate! do
    {version, migration, _name} = @move
    assert :ok = Ecto.Migrator.down(Repo, version, migration, @options)
    assert :ok = Ecto.Migrator.up(Repo, version, migration, @options)
  end

  # A slug set as an instance of an earlier release could have given it, past the checks
  # of today's code.
  defp held!(%{__struct__: schema, id: id}, slug) do
    table = schema.__schema__(:source)
    Repo.query!("UPDATE #{table} SET slug = $2 WHERE id = $1", [Ecto.UUID.dump!(id), slug])
  end

  defp slug(%Organisation{id: id}), do: Repo.get!(Organisation, id).slug
  defp slug(%Workspace{id: id}), do: Repo.get!(Workspace, id).slug

  test "moves the organisation at work-items to work-items-2" do
    %{organisation: organisation} = sign_up_fixture()
    held!(organisation, "work-items")

    migrate!()

    assert slug(organisation) == "work-items-2"
  end

  test "moves it to work-items-3 when work-items-2 is taken, by one marked for deletion too" do
    %{organisation: organisation} = sign_up_fixture()
    %{organisation: taken} = sign_up_fixture()
    held!(organisation, "work-items")
    held!(taken, "work-items-2")

    Repo.query!(
      "UPDATE organisations SET deletion_marked_at = now(), purge_after = now(), " <>
        "purge_trigger = 'grace_period' WHERE id = $1",
      [Ecto.UUID.dump!(taken.id)]
    )

    migrate!()

    assert slug(organisation) == "work-items-3"
    assert slug(taken) == "work-items-2"
  end

  test "leaves another organisation's slug and a workspace at work-items as they are" do
    %{organisation: other} = sign_up_fixture()
    %{workspace: workspace} = sign_up_fixture()
    held!(other, "work-items-x")
    held!(workspace, "work-items")

    migrate!()

    assert slug(other) == "work-items-x"
    assert slug(workspace) == "work-items"
  end
end
