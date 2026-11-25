defmodule Apiary.Repo.Migrations.KeepTheFindingsOfAWorkItem do
  use Ecto.Migration

  # The findings of a work item: the problems that its reviews and checks raised about a
  # target, each with its history (`Apiary.Findings`).
  #
  # - `findings`: one row per finding. `number` counts the findings of the work item from
  #   1, across its take ins and targets, and is shown as `f<number>`. `take_in` and
  #   `target_id` are the take in and the target the finding is about. `stage_id` is the
  #   stage that owns the finding: the stage whose checks raised it and whose re-check
  #   closes it. `source_kind` is `reviewer`, `check`, `criterion`, `scenario` or `hook`,
  #   and `source_name` the role, check, criterion, scenario or hook. `place` is the
  #   JSON object `{quote, file?, line?, version?}`. `state` is `open`, `fixed`,
  #   `dismissed` or `accepted`; `closed_by_person` is true while a person's dismissal or
  #   acceptance closes it, and `disputed` true after a reply that disputed it.
  # - `finding_events`: the history of a finding, in the order of `position`, from 1.
  #   `round` and `stage_id` are the work item's `stage_round` and `stage_id` when the
  #   event was written. `actor_kind` is `qory`, with `actor_name` the role or check that
  #   wrote the event and `run_id` the run, or `person`, with `user_id`. A row is never
  #   changed: the trigger `finding_events_unchanged` refuses an UPDATE, and a DELETE
  #   other than the one that deleting its finding, work item or organisation cascades
  #   to. So `run_id` and `user_id` have no foreign key, whose action would change the
  #   row.
  # - `finding_bases`: the version that the first run of a take in on a target started
  #   from, one row per work item, take in and target, written once (the unique index).
  #
  # `version` of an event, `place.version` and `base` are in the grammar of the run
  # contract's `target_version`: 1 to 255 letters, digits and the characters `._/-`.
  # The rows follow their work item to another workspace: they keep no workspace.
  @states ~w(open fixed dismissed accepted)
  @source_kinds ~w(reviewer check criterion scenario hook)
  @kinds ~w(raised repeated replied_fixed replied_disputed closed_fixed closed_dismissed
            repeated_after_person_close dismissed_by_person accepted sent_back reopened)
  @version "^[A-Za-z0-9._/-]{1,255}$"

  def up do
    create table(:findings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :work_item_id, references(:work_items, type: :binary_id, on_delete: :delete_all),
        null: false

      add :number, :integer, null: false
      add :take_in, :integer, null: false
      add :target_id, references(:targets, type: :binary_id, on_delete: :delete_all), null: false
      add :stage_id, :text, null: false
      add :source_kind, :text, null: false
      add :source_name, :text, null: false
      add :severity, :text, null: false
      add :place, :jsonb, null: false
      add :point, :text, null: false
      add :problem, :text, null: false
      add :fix, :text, null: false
      add :proof, :text, null: false
      add :state, :text, null: false
      add :closed_by_person, :boolean, null: false, default: false
      add :disputed, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:findings, [:work_item_id, :number])
    create index(:findings, [:work_item_id, :take_in, :stage_id, :state])
    create index(:findings, [:organisation_id])
    create index(:findings, [:target_id])

    create constraint(:findings, :findings_number_check, check: "number >= 1")
    create constraint(:findings, :findings_state_check, check: in_list("state", @states))

    create constraint(:findings, :findings_source_kind_check,
             check: in_list("source_kind", @source_kinds)
           )

    create constraint(:findings, :findings_severity_check,
             check: in_list("severity", ~w(blocking non-blocking))
           )

    create constraint(:findings, :findings_place_check,
             check:
               "jsonb_typeof(place) = 'object' AND jsonb_typeof(place->'quote') = 'string' " <>
                 "AND (NOT place ? 'version' OR place->>'version' ~ '#{@version}')"
           )

    create constraint(:findings, :findings_closed_by_person_check,
             check: "NOT closed_by_person OR state IN ('dismissed', 'accepted')"
           )

    create table(:finding_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :finding_id, references(:findings, type: :binary_id, on_delete: :delete_all),
        null: false

      add :position, :integer, null: false
      add :kind, :text, null: false
      add :round, :integer, null: false
      add :stage_id, :text, null: false
      add :actor_kind, :text, null: false
      add :actor_name, :text
      add :run_id, :binary_id
      add :user_id, :binary_id
      add :version, :text
      add :reason, :text
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:finding_events, [:finding_id, :position])

    create constraint(:finding_events, :finding_events_kind_check, check: in_list("kind", @kinds))

    create constraint(:finding_events, :finding_events_round_check, check: "round >= 1")

    create constraint(:finding_events, :finding_events_actor_check,
             check:
               "(actor_kind = 'qory' AND actor_name IS NOT NULL AND user_id IS NULL) OR " <>
                 "(actor_kind = 'person' AND actor_name IS NULL AND run_id IS NULL)"
           )

    create constraint(:finding_events, :finding_events_version_check,
             check: "version IS NULL OR version ~ '#{@version}'"
           )

    execute """
    CREATE FUNCTION finding_events_unchanged() RETURNS trigger AS $$
    BEGIN
      -- A cascade from the finding, its work item or its organisation runs inside the
      -- foreign key's trigger, one level down.
      IF TG_OP = 'DELETE' AND pg_trigger_depth() > 1 THEN
        RETURN OLD;
      END IF;
      RAISE EXCEPTION 'finding events are only added: % refused', TG_OP
        USING ERRCODE = 'restrict_violation';
    END
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER finding_events_unchanged BEFORE UPDATE OR DELETE ON finding_events
    FOR EACH ROW EXECUTE FUNCTION finding_events_unchanged()
    """

    create table(:finding_bases, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :work_item_id, references(:work_items, type: :binary_id, on_delete: :delete_all),
        null: false

      add :take_in, :integer, null: false
      add :target_id, references(:targets, type: :binary_id, on_delete: :delete_all), null: false
      add :base, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:finding_bases, [:work_item_id, :take_in, :target_id])
    create index(:finding_bases, [:organisation_id])
    create index(:finding_bases, [:target_id])

    create constraint(:finding_bases, :finding_bases_base_check, check: "base ~ '#{@version}'")
  end

  def down do
    drop table(:finding_bases)
    execute "DROP TRIGGER finding_events_unchanged ON finding_events"
    drop table(:finding_events)
    execute "DROP FUNCTION finding_events_unchanged()"
    drop table(:findings)
  end

  defp in_list(column, values),
    do: "#{column} IN (#{Enum.map_join(values, ", ", &"'#{&1}'")})"
end
