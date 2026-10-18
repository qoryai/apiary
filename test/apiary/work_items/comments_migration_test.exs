defmodule Apiary.WorkItems.CommentsMigrationTest do
  # The migration that keeps people's comments on a work item, run down and up again
  # inside the test's transaction, which rolls it all back. It drops a table under every
  # other test, so this is not async.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log

  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.WorkItems

  @comments {20_261_019_000_400, Apiary.Repo.Migrations.KeepPeopleSCommentsOnAWorkItem,
             "keep_people_s_comments_on_a_work_item"}

  setup_all do
    {version, migration, name} = @comments

    unless Code.ensure_loaded?(migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{version}_#{name}.exs")
      |> Code.require_file()
    end

    :ok
  end

  @options [log: false, migration_lock: false]

  defp down({version, migration, _name}),
    do: Ecto.Migrator.down(Repo, version, migration, @options)

  defp up!({version, migration, _name}),
    do: assert(:ok = Ecto.Migrator.up(Repo, version, migration, @options))

  defp table? do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM information_schema.tables WHERE table_name = 'work_item_comments'"
      )

    n == 1
  end

  test "down removes the table while it keeps no comment; up brings it back" do
    assert table?()
    assert :ok = down(@comments)
    refute table?()

    up!(@comments)
    assert table?()
  end

  @tag needs: :factory
  test "down refuses while a comment is kept, deleted or not, and deletes none" do
    %{scope: scope} = sign_up_fixture()
    work_item = work_item_fixture(scope)
    {:ok, comment} = WorkItems.comment(scope, work_item, "Seen on staging")

    # The migration's transaction, a savepoint of the test's, is rolled back.
    assert_raise Postgrex.Error,
                 ~r/Qory Apiary keeps the comments people wrote on work items, so this migration rolls back only while none is kept\. Some are\./,
                 fn -> down(@comments) end

    assert table?()
    {:ok, _deleted} = WorkItems.delete_comment(scope, comment.public_id)

    assert_raise Postgrex.Error, ~r/rolls back only while none is kept/, fn ->
      down(@comments)
    end

    assert [%{body: nil}] = WorkItems.list_comments(scope, work_item)
  end
end
