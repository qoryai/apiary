defmodule Apiary.Repo.Migrations.KeepCommentsOnAProposal do
  use Ecto.Migration

  # A person comments on Explore's proposal, and a question offers options
  # (`Apiary.WorkItems.Answer`, `Apiary.WorkItems.Moves`):
  #
  # - `work_item_answers` keeps comments beside answers. A comment has no `question`, so
  #   the column may be empty; its `position` is 1, so a run's proposal has at most one
  #   comment, and `proposal_version` is the version of the proposal it is on. Once a
  #   saved update of the proposal read it, `done_version` is that update's version and
  #   `done_at` when it was saved. An answer has a `question`, 1 to 20,000 characters,
  #   as a Markdown question of the explore result may be, and `custom`: true for the
  #   person's text, false for the title of an option the run offered. Every answer kept
  #   before this migration is the person's text, so it gets `custom` true.
  # - `work_item_confirmations.changes` goes: a person changes a proposal with a comment,
  #   which the next run reads, and no longer before a confirmation.
  #
  # Rolled back, `changes` comes back empty. The roll back refuses while a comment, or a
  # question longer than 2,000 characters, is kept, since neither fits the columns
  # again: it deletes no row.
  def up do
    alter table(:work_item_answers) do
      modify :question, :text, null: true, from: {:text, null: false}
      add :custom, :boolean
      add :proposal_version, :integer
      add :done_version, :integer
      add :done_at, :utc_datetime_usec
    end

    execute("UPDATE work_item_answers SET custom = true")

    drop constraint(:work_item_answers, :work_item_answers_question_check)

    create constraint(:work_item_answers, :work_item_answers_question_check,
             check: "question IS NULL OR char_length(question) BETWEEN 1 AND 20000"
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

    alter table(:work_item_confirmations) do
      remove :changes
    end
  end

  @refusal "Qory Apiary keeps people's comments on a proposal, which have no question, " <>
             "and questions of up to 20000 characters, so this migration rolls back only " <>
             "while no comment and no question longer than 2000 characters is kept. Some are."

  def down do
    execute("LOCK TABLE work_item_answers IN SHARE MODE")

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM work_item_answers
        WHERE question IS NULL OR char_length(question) > 2000
      ) THEN
        RAISE EXCEPTION '#{@refusal}';
      END IF;
    END
    $$
    """)

    alter table(:work_item_confirmations) do
      add :changes, :jsonb, null: false, default: fragment("'{}'::jsonb")
    end

    create constraint(:work_item_confirmations, :work_item_confirmations_changes_check,
             check: "jsonb_typeof(changes) = 'object' AND octet_length(changes::text) <= 1048576"
           )

    drop constraint(:work_item_answers, :work_item_answers_kind_check)
    drop constraint(:work_item_answers, :work_item_answers_question_check)

    create constraint(:work_item_answers, :work_item_answers_question_check,
             check: "char_length(question) BETWEEN 1 AND 2000"
           )

    alter table(:work_item_answers) do
      modify :question, :text, null: false, from: {:text, null: true}
      remove :custom
      remove :proposal_version
      remove :done_version
      remove :done_at
    end
  end
end
