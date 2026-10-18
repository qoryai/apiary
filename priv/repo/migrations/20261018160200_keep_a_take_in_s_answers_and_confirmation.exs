defmodule Apiary.Repo.Migrations.KeepATakeInSAnswersAndConfirmation do
  use Ecto.Migration

  # What members give Explore within a take in of a work item (`Apiary.WorkItems.Answer`,
  # `Apiary.WorkItems.Confirmation`), and the events that say so:
  #
  # - `work_item_answers`: one row per question a run of the take in asked and a member
  #   answered, by the run's `attempt` and the question's `position` in the run's result.
  #   `position` is 1 to 20, and `question` 1 to 2,000 characters: the explore result's
  #   rules (`priv/contract/explore/v1/result.schema.json`, which `Apiary.Explore.Result`
  #   parses by), at most 20 `questions`, each a `$defs/short_text` of 1 to 2,000
  #   characters. The question is kept as the run asked it, for the input of the take in's
  #   next run and for the page, whatever happens to the run's events later. `answer` is
  #   1 to 2,000 characters by a separate rule: the explore input's answer
  #   (`priv/contract/explore/v1/inputs.schema.json`, `answers[].answer`), also a
  #   `$defs/short_text`. One answer per (work item, take in, attempt, position).
  # - `work_item_confirmations`: one per take in at most, the member's confirmation of
  #   the proposal of a run of the take in, by its `attempt`: `result`, the run's result
  #   as Qory read it, a JSON object, and `changes`, the fields the member changed before
  #   confirming, by name, a JSON object, empty for none; each 1 MiB at most as the
  #   database encodes it.
  # - `work_item_events` may be `answered`, `confirmed` or `explore_again`.
  #
  # Who answered or confirmed is a plain reference, set to NULL should the account's row
  # ever go, so nothing takes an answer or a confirmation away with it; a page and a run's
  # input name a person without one as a former member. Each table is held to its
  # workspace's organisation, and each row to its work item and the work item's workspace
  # by the composite key, which follows the work item to another workspace
  # (`ON UPDATE CASCADE`) and goes with it, as the work item's events do. Both tables are
  # new, and empty.

  def up do
    drop constraint(:work_item_events, :work_item_events_kind_check)

    create constraint(:work_item_events, :work_item_events_kind_check,
             check:
               "kind IN ('taken_in', 'declined', 'closed', 'undone', 'answered', " <>
                 "'confirmed', 'explore_again')"
           )

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
      add :question, :text, null: false
      add :answer, :text, null: false
      add :answered_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :answered_at, :utc_datetime_usec, null: false
    end

    work_item_key(:work_item_answers)

    create unique_index(:work_item_answers, [:work_item_id, :take_in, :attempt, :position])
    create index(:work_item_answers, [:organisation_id, :workspace_id])
    create index(:work_item_answers, [:answered_by_id])

    create constraint(:work_item_answers, :work_item_answers_run_check,
             check: "take_in >= 1 AND attempt >= 1 AND position BETWEEN 1 AND 20"
           )

    create constraint(:work_item_answers, :work_item_answers_question_check,
             check: "char_length(question) BETWEEN 1 AND 2000"
           )

    create constraint(:work_item_answers, :work_item_answers_answer_check,
             check: "char_length(answer) BETWEEN 1 AND 2000"
           )

    create table(:work_item_confirmations, primary_key: false) do
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
      add :result, :jsonb, null: false
      add :changes, :jsonb, null: false, default: fragment("'{}'::jsonb")
      add :confirmed_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :confirmed_at, :utc_datetime_usec, null: false
    end

    work_item_key(:work_item_confirmations)

    create unique_index(:work_item_confirmations, [:work_item_id, :take_in])
    create index(:work_item_confirmations, [:organisation_id, :workspace_id])
    create index(:work_item_confirmations, [:confirmed_by_id])

    create constraint(:work_item_confirmations, :work_item_confirmations_run_check,
             check: "take_in >= 1 AND attempt >= 1"
           )

    create constraint(:work_item_confirmations, :work_item_confirmations_result_check,
             check: "jsonb_typeof(result) = 'object' AND octet_length(result::text) <= 1048576"
           )

    create constraint(:work_item_confirmations, :work_item_confirmations_changes_check,
             check: "jsonb_typeof(changes) = 'object' AND octet_length(changes::text) <= 1048576"
           )
  end

  # Rolled back, the two tables go, and an event may no longer be `answered`, `confirmed`
  # or `explore_again`, so the roll back refuses while an event of those kinds is kept: it
  # deletes no event, and none of the records the tables hold.
  @refusal "Qory Apiary keeps what members gave Explore, and an event of a work item may be " <>
             "answered, confirmed or explore_again, so this migration rolls back only " <>
             "while no event is of those kinds. Some are."

  def down do
    execute("LOCK TABLE work_item_events IN SHARE MODE")

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM work_item_events WHERE kind IN ('answered', 'confirmed', 'explore_again')
      ) THEN
        RAISE EXCEPTION '#{@refusal}';
      END IF;
    END
    $$
    """)

    drop table(:work_item_confirmations)
    drop table(:work_item_answers)

    drop constraint(:work_item_events, :work_item_events_kind_check)

    create constraint(:work_item_events, :work_item_events_kind_check,
             check: "kind IN ('taken_in', 'declined', 'closed', 'undone')"
           )
  end

  # The key of a row to its work item and the work item's workspace, which follows the
  # work item to another workspace and goes with it.
  defp work_item_key(table) do
    execute("""
    ALTER TABLE #{table} ADD CONSTRAINT #{table}_work_item_id_fkey
      FOREIGN KEY (work_item_id, workspace_id) REFERENCES work_items (id, workspace_id)
      MATCH FULL ON DELETE CASCADE ON UPDATE CASCADE
    """)
  end
end
