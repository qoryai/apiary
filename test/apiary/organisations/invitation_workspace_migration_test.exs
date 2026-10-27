defmodule Apiary.Organisations.InvitationWorkspaceMigrationTest do
  # The migration that lets an invitation have no workspace, run down and up again inside
  # the test's transaction, which rolls it all back. It changes `invitations` under every
  # other test, so this is not async.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log

  import Apiary.AccountsFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Organisations
  alias Apiary.Organisations.Invitation

  @migration {20_261_027_090_000, Apiary.Repo.Migrations.LetAnInvitationHaveNoWorkspace,
              "let_an_invitation_have_no_workspace"}

  setup_all do
    {version, migration, name} = @migration

    unless Code.ensure_loaded?(migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{version}_#{name}.exs")
      |> Code.require_file()
    end

    :ok
  end

  @options [log: false, migration_lock: false]

  defp down, do: Ecto.Migrator.down(Repo, elem(@migration, 0), elem(@migration, 1), @options)

  defp up!,
    do: assert(:ok = Ecto.Migrator.up(Repo, elem(@migration, 0), elem(@migration, 1), @options))

  # Whether `workspace_id` is nullable, and the key to the workspace.
  defp shape do
    %{rows: [[nullable]]} =
      Repo.query!(
        "SELECT is_nullable FROM information_schema.columns " <>
          "WHERE table_name = 'invitations' AND column_name = 'workspace_id'"
      )

    %{rows: [[key]]} =
      Repo.query!(
        "SELECT pg_get_constraintdef(oid) FROM pg_constraint " <>
          "WHERE conname = 'invitations_workspace_id_fkey'"
      )

    {nullable, key}
  end

  @up {"YES",
       "FOREIGN KEY (workspace_id, organisation_id) " <>
         "REFERENCES workspaces(id, organisation_id) ON DELETE CASCADE"}

  @down {"NO",
         "FOREIGN KEY (workspace_id, organisation_id) " <>
           "REFERENCES workspaces(id, organisation_id) MATCH FULL ON DELETE CASCADE"}

  # The owner of a fresh organisation with no workspace, at the organisation alone.
  defp without_workspace do
    Apiary.Mail.put_test_source(:none)

    {:ok, %{user: user}} =
      Organisations.sign_up_user(
        %{
          email: unique_user_email(),
          organisation_name: unique_organisation_name(),
          password: valid_user_password(),
          password_confirmation: valid_user_password()
        },
        nil,
        open: true,
        workspace: false
      )

    Organisations.load_scope(Apiary.Accounts.Scope.for_user(user))
  end

  test "down makes the workspace required and the key MATCH FULL again; up brings it back" do
    %{scope: scope} = sign_up_fixture()
    %{invitation: invitation} = invitation_fixture(scope)

    assert shape() == @up
    assert :ok = down()
    assert shape() == @down
    assert Repo.get(Invitation, invitation.id)

    up!()
    assert shape() == @up
    assert %Invitation{workspace_id: workspace_id} = Repo.get(Invitation, invitation.id)
    assert workspace_id == scope.workspace.id
  end

  test "down refuses while an invitation has no workspace, and changes nothing" do
    %{invitation: invitation} = invitation_fixture(without_workspace())
    assert invitation.workspace_id == nil

    # The migration's transaction, a savepoint of the test's, is rolled back.
    assert_raise Postgrex.Error,
                 ~r/this migration rolls back only while every invitation has a workspace/,
                 fn -> down() end

    assert shape() == @up
    assert %Invitation{workspace_id: nil} = Repo.get(Invitation, invitation.id)
  end
end
