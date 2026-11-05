defmodule Apiary.Repo.Migrations.DropWorkItemAnswers do
  use Ecto.Migration

  # Explore's answers and review comments are kept in the work item's artifacts
  # `questions` and `review-comments` (`Apiary.Explore.Questions`,
  # `Apiary.Explore.ReviewComments`), and no code reads or writes `work_item_answers`.
  # The table goes, with its rows: no work item kept in production has one, so none is
  # moved.
  #
  # Rolled back, the table comes back empty, as `KeepATakeInSAnswersAndConfirmation` and
  # `KeepCommentsOnAProposal` left it: its columns, its keys, its indexes and its checks.
  def up do
    drop table(:work_item_answers)
  end

  def down do
    create table(:work_item_answers, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :workspace_id,
          references(:workspaces,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :work_item_id, :binary_id, null: false
      add :take_in, :integer, null: false
      add :attempt, :integer, null: false
      add :position, :integer, null: false
      add :question, :text
      add :answer, :text, null: false
      add :answered_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :answered_at, :utc_datetime_usec, null: false
      add :custom, :boolean
      add :proposal_version, :integer
      add :done_version, :integer
      add :done_at, :utc_datetime_usec
    end

    execute("""
    ALTER TABLE work_item_answers ADD CONSTRAINT work_item_answers_work_item_id_fkey
      FOREIGN KEY (work_item_id, workspace_id) REFERENCES work_items (id, workspace_id)
      MATCH FULL ON DELETE CASCADE ON UPDATE CASCADE
    """)

    create unique_index(:work_item_answers, [:work_item_id, :take_in, :attempt, :position])
    create index(:work_item_answers, [:organisation_id, :workspace_id])
    create index(:work_item_answers, [:answered_by_id])

    create constraint(:work_item_answers, :work_item_answers_run_check,
             check: "take_in >= 1 AND attempt >= 1 AND position BETWEEN 1 AND 20"
           )

    create constraint(:work_item_answers, :work_item_answers_question_check,
             check: "question IS NULL OR char_length(question) BETWEEN 1 AND 20000"
           )

    create constraint(:work_item_answers, :work_item_answers_answer_check,
             check: "char_length(answer) BETWEEN 1 AND 2000"
           )

    create constraint(:work_item_answers, :work_item_answers_kind_check,
             check: """
             CASE WHEN question IS NULL
               THEN custom IS NULL AND position = 1
                 AND proposal_version IS NOT NULL AND proposal_version >= 1
                 AND (done_version IS NULL) = (done_at IS NULL)
                 AND (done_version IS NULL OR done_version >= 1)
               ELSE custom IS NOT NULL AND proposal_version IS NULL
                 AND done_version IS NULL AND done_at IS NULL
             END
             """
           )
  end
end
