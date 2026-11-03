defmodule Apiary.WorkItems.ProposalCommentsMigrationTest do
  # The migration that keeps comments on a proposal and options of a question
  # (`KeepCommentsOnAProposal`), run down and up again inside the test's transaction,
  # which rolls it all back. With no comment kept, down keeps the answers and brings
  # back `work_item_confirmations.changes` and the checks of before; with a comment kept,
  # down stops with its refusal. It changes `work_item_answers` and
  # `work_item_confirmations` under every other test, so this is not async.
  use Apiary.DataCase, async: false

  # Running a migration up again while later ones are applied makes Ecto warn that an
  # older migration ran after a newer one. The log is kept from the output and shown
  # only when a test fails.
  @moduletag :capture_log
  @moduletag needs: :factory

  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.WorkItems

  @version 20_261_103_100_000
  @migration Apiary.Repo.Migrations.KeepCommentsOnAProposal
  @options [log: false, migration_lock: false]

  @refusal "Qory Apiary keeps people's comments on a proposal, which have no question, " <>
             "and questions of up to 20000 characters, so this migration rolls back only " <>
             "while no comment and no question longer than 2000 characters is kept. Some are."

  setup_all do
    unless Code.ensure_loaded?(@migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{@version}_keep_comments_on_a_proposal.exs")
      |> Code.require_file()
    end

    :ok
  end

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope}
  end

  defp columns(table) do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name, is_nullable FROM information_schema.columns " <>
          "WHERE table_name = $1",
        [table]
      )

    Map.new(rows, fn [name, nullable] -> {name, nullable} end)
  end

  defp check(name) do
    case Repo.query!(
           "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = $1",
           [name]
         ) do
      %{rows: [[definition]]} -> definition
      %{rows: []} -> nil
    end
  end

  defp answers do
    %{rows: rows} =
      Repo.query!("SELECT question, answer FROM work_item_answers ORDER BY position")

    rows
  end

  test "with no comment kept, down keeps the answers and brings changes and the checks back",
       %{scope: scope} do
    work_item = work_item_fixture(scope)
    explore_run_fixture(work_item, result: questions_result())
    {:ok, _} = WorkItems.answer(scope, work_item, 1, %{"1" => "The main one.", "2" => "Spring"})

    assert :ok = Ecto.Migrator.down(Repo, @version, @migration, @options)

    assert answers() == [["Which basket?", "The main one."], ["Which sale?", "Spring"]]

    answer_columns = columns("work_item_answers")
    assert answer_columns["question"] == "NO"

    for column <- ~w(custom proposal_version done_version done_at),
        do: refute(Map.has_key?(answer_columns, column), column)

    assert columns("work_item_confirmations")["changes"] == "NO"
    assert check("work_item_confirmations_changes_check") =~ "jsonb_typeof(changes)"
    assert check("work_item_answers_question_check") =~ "2000"
    assert check("work_item_answers_kind_check") == nil

    assert :ok = Ecto.Migrator.up(Repo, @version, @migration, @options)

    assert columns("work_item_answers")["question"] == "YES"
    refute Map.has_key?(columns("work_item_confirmations"), "changes")
    assert check("work_item_answers_kind_check") =~ "CASE"
    assert %{rows: [[true], [true]]} = Repo.query!("SELECT custom FROM work_item_answers")
  end

  test "with a comment kept, down stops with its refusal and keeps the comment", %{
    scope: scope
  } do
    work_item = work_item_fixture(scope)
    explore_run_fixture(work_item, result: understood_result())
    {:ok, _} = WorkItems.answer(scope, work_item, 1, "Offer a refund first.")

    # The migration's transaction, a savepoint of the test's, is rolled back.
    error =
      assert_raise Postgrex.Error, fn ->
        Ecto.Migrator.down(Repo, @version, @migration, @options)
      end

    assert %Postgrex.Error{postgres: %{code: :raise_exception, pg_code: "P0001"}} = error
    assert error.postgres.message == @refusal
    assert answers() == [[nil, "Offer a refund first."]]
    assert Map.has_key?(columns("work_item_answers"), "done_version")
  end
end
