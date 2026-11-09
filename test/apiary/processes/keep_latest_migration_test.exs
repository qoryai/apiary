defmodule Apiary.Processes.KeepLatestMigrationTest do
  # The migration that adds `workspaces.keep_process_latest`, run down and up again inside
  # the test's transaction, which rolls it all back: up turns the switch off for each
  # workspace whose current version a person saved, or whose version 1 is a version of
  # the workspace type an instance admin saved, and leaves every other row empty. It
  # changes `workspaces` under every other test, so this is not async.
  use Apiary.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures

  alias Apiary.Processes.{TypeTemplate, TypeTemplates, Version}

  @migration {20_261_108_120_000,
              Apiary.Repo.Migrations.KeepWhetherAWorkspaceKeepsItsProcessAtTheLatest,
              "keep_whether_a_workspace_keeps_its_process_at_the_latest"}

  @options [log: false, migration_lock: false]

  setup_all do
    {version, migration, name} = @migration

    if not Code.ensure_loaded?(migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{version}_#{name}.exs")
      |> Code.require_file()
    end

    :ok
  end

  defp migrate_again! do
    {version, migration, _name} = @migration
    :ok = Ecto.Migrator.down(Repo, version, migration, @options)
    :ok = Ecto.Migrator.up(Repo, version, migration, @options)
  end

  defp keep(scope) do
    Repo.one(
      from w in "workspaces",
        where: w.id == type(^scope.workspace.id, :binary_id),
        select: w.keep_process_latest
    )
  end

  defp version_one(scope),
    do: Repo.one!(from v in Version, where: v.workspace_id == ^scope.workspace.id)

  defp set_author(version, author_id) do
    {1, _rows} =
      Repo.update_all(from(v in Version, where: v.id == ^version.id),
        set: [author_id: author_id]
      )
  end

  test "turns the switch off where a person saved the process, and only there" do
    # Version 1 copied from the template, with no author.
    %{scope: copied} = sign_up_fixture()

    # Version 1 saved by a person.
    %{scope: edited} = sign_up_fixture()
    set_author(version_one(edited), edited.user.id)

    # A person saved version 1; version 2, current, has no author.
    %{scope: followed} = sign_up_fixture()
    %Version{} = v1 = version_one(followed)
    set_author(v1, followed.user.id)

    {1, _rows} =
      Repo.update_all(from(v in Version, where: v.id == ^v1.id), set: [status: :past])

    Repo.insert!(%{
      v1
      | id: nil,
        public_id: Apiary.PublicId.generate("pv"),
        number: 2,
        status: :current,
        author_id: nil,
        based_on_id: v1.id
    })

    # Version 1 copied from a version of the workspace type an instance admin saved.
    newest = TypeTemplates.newest("qory.software")

    Repo.insert!(%TypeTemplate{
      type: "qory.software",
      number: newest.number + 1,
      document: newest.document,
      based_on: newest.number,
      author_id: edited.user.id
    })

    %{scope: admin_saved} = sign_up_fixture()
    assert version_one(admin_saved).author_id == nil

    migrate_again!()

    assert keep(copied) == nil
    assert keep(edited) == false
    assert keep(followed) == nil
    assert keep(admin_saved) == false
  end
end
