defmodule Apiary.Organisations.SlugsKeptBackMigrationTest do
  # The migration that moves an organisation or a workspace off a slug kept back, run down
  # and up again inside the test's transaction, which rolls it all back. It changes rows
  # of `organisations` and `workspaces` under every other test, so this is not async.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log

  import Apiary.OrganisationsFixtures

  alias Apiary.Organisations.{Organisation, Workspace}

  @move {20_261_012_100_000, Apiary.Repo.Migrations.MoveTheSlugsKeptBack,
         "move_the_slugs_kept_back"}

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

  test "moves every holder of a name kept back to the first free slug with -2, -3, …" do
    %{organisation: admin, workspace: api} = sign_up_fixture()
    %{organisation: admin_2, workspace: new} = sign_up_fixture()
    %{organisation: api_organisation, workspace: kept} = sign_up_fixture()
    %{organisation: new_organisation} = sign_up_fixture()
    %{organisation: other} = sign_up_fixture()

    taken = workspace_fixture(api_organisation, "Taken")
    second_api = workspace_fixture(api_organisation, "Second")

    held!(admin, "admin")
    held!(admin_2, "admin-2")
    held!(api_organisation, "api")
    held!(new_organisation, "new")
    held!(other, "apis")

    held!(api, "api")
    held!(new, "new")
    # `admin` is an organisation slug kept back, not a workspace one.
    held!(kept, "admin")
    held!(taken, "api-2")
    held!(second_api, "api")

    migrate!()

    # `admin-2` is taken, so the next.
    assert slug(admin) == "admin-3"
    assert slug(admin_2) == "admin-2"
    assert slug(api_organisation) == "api-2"
    assert slug(new_organisation) == "new-2"
    assert slug(other) == "apis"

    # A workspace's slug is free or taken within its organisation.
    assert slug(api) == "api-2"
    assert slug(new) == "new-2"
    assert slug(kept) == "admin"
    assert slug(taken) == "api-2"
    assert slug(second_api) == "api-3"
  end

  test "with no holder, nothing changes" do
    %{organisation: organisation, workspace: workspace} = sign_up_fixture()

    migrate!()

    assert slug(organisation) == organisation.slug
    assert slug(workspace) == workspace.slug
  end
end
