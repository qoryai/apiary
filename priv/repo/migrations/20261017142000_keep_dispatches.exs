defmodule Apiary.Repo.Migrations.KeepDispatches do
  use Ecto.Migration

  # The runs a workspace's node pools claim and start (`Apiary.Dispatches.DispatchRun`),
  # and each claim of one (`Apiary.Dispatches.Dispatch`), as the provisioner contract
  # describes them. The tables hold the rows; nothing here claims, queues or frees.
  #
  # - `dispatch_runs`: a run waiting in its workspace's queue, one queue per workspace,
  #   which any node pool of the workspace may claim from. `run_id` is the run's id, a
  #   UUID Qory gives it, unique on the instance: the contract's `run_id`, and, once the
  #   run is handed over, the registered run's run id. `step` is the contract's step
  #   pattern. `take_in` is the take in of the work item the run is for, and `attempt`
  #   counts the runs within it, from 1 to `of`. `state` is `waiting`, `claimed`,
  #   `handed_over` or `ended`; an ended one has an end cause, and only an ended one has
  #   it. `queued_at` orders the queue.
  # - `dispatches`: one claim of one run, by one node pool, with the access key the claim
  #   was signed with. `public_id` is `dp_` and sixteen lowercase Crockford base32
  #   characters, never claimed again; `dispatch_public_id()` makes one in SQL, as
  #   `run_public_id()` does (20261017100000). `lease_until` is the one deadline, ten
  #   minutes from the claim in whole seconds, as the claim answer gives it. `external_type`,
  #   `external_ref` and `external_url` are the job at the system that runs it, as the
  #   starter named it when it said the job started: external, and set together.
  #   `handed_over_at`, `stale_at` (its lease lapsed before its handover, at or after
  #   `lease_until`) and `ended_at` with its end cause say where it stands; `slot_freed_at`
  #   is when the slot of the pool's instance limit it took at the claim was freed. At most
  #   one dispatch of a run is live and not stale at a time.
  # - `runs.dispatch_run_id`: the run of the queue a registered run is, set when the run is
  #   handed over and registered, unique. The link is kept on `runs` alone, so that no two
  #   tables hold a key to each other and the purge has one order to delete them in.
  #
  # The end causes, the same list on both tables, each from where it is named:
  #
  # - `released`: the starter's release, release.schema.json (before its handover with
  #   retry false, the run ends; after it, the run ends whatever retry says).
  # - `closed`, `undone`: the work item was closed or undone while the run waited or
  #   before its handover, refusal.schema.json (410 gone).
  # - `run_ended`: the run ended by its outcome or its exit, after its handover, and a
  #   stale dispatch ends with its run, handover.schema.json.
  # - `lost`: a handed-over run whose job never attached by its `attach_by`, or that had
  #   neither an outcome nor an exit by its step's limit after its attach, ended by the
  #   liveness check (`Apiary.Dispatches.RunEnd`).
  #
  # Every table is held to its workspace's organisation by the composite key, a dispatch's
  # run to its workspace, and a dispatch's node pool to its workspace. A run of the queue
  # names its work item by its workspace here; 20261017144000 names it by the
  # organisation instead, so that the run stays in its workspace when the work item moves
  # to another.
  # The workspace's rows go with it (`ON DELETE CASCADE`). The node pool and the access key
  # are NO ACTION, as a work item's connection is: a node and a key are deleted softly,
  # and their rows go only with the purge, which deletes the dispatches first.
  @public_id "^dp_[0-9a-hjkmnp-tv-z]{16}$"
  # definitions.schema.json, $defs.step.
  @step "^[a-z][a-z_]{0,39}$"
  # definitions.schema.json, $defs.job_system.
  @job_system "^[a-z][a-z0-9 -]{0,39}$"
  @states ~w(waiting claimed handed_over ended)
  @end_causes ~w(released closed undone run_ended lost)

  def up do
    execute("""
    CREATE FUNCTION dispatch_public_id() RETURNS text LANGUAGE plpgsql VOLATILE
    SET search_path = pg_catalog AS $$
    DECLARE
      alphabet constant text := '0123456789abcdefghjkmnpqrstvwxyz';
      raw constant bytea := uuid_send(gen_random_uuid());
      bits constant bit(80) :=
        ('x' || encode(substring(raw FROM 1 FOR 6) || substring(raw FROM 11 FOR 4), 'hex'))::bit(80);
      id text := 'dp_';
    BEGIN
      FOR i IN 0..15 LOOP
        id := id || substr(alphabet, substring(bits FROM i * 5 + 1 FOR 5)::integer + 1, 1);
      END LOOP;
      RETURN id;
    END
    $$
    """)

    create table(:dispatch_runs, primary_key: false) do
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

      add :work_item_id,
          references(:work_items,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :run_id, :uuid, null: false
      add :step, :text, null: false
      add :take_in, :integer, null: false
      add :attempt, :integer, null: false
      add :of, :integer, null: false
      add :state, :text, null: false, default: "waiting"
      add :end_cause, :text
      add :queued_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:dispatch_runs, [:run_id])
    create unique_index(:dispatch_runs, [:id, :workspace_id])
    create unique_index(:dispatch_runs, [:work_item_id, :take_in, :attempt])
    create index(:dispatch_runs, [:organisation_id, :workspace_id])

    create index(:dispatch_runs, [:workspace_id, :queued_at],
             where: "state = 'waiting'",
             name: :dispatch_runs_waiting_index
           )

    create constraint(:dispatch_runs, :dispatch_runs_step_check, check: "step ~ '#{@step}'")
    create constraint(:dispatch_runs, :dispatch_runs_take_in_check, check: "take_in >= 1")

    create constraint(:dispatch_runs, :dispatch_runs_attempt_check,
             check: "attempt >= 1 AND attempt <= of"
           )

    create constraint(:dispatch_runs, :dispatch_runs_state_check,
             check: "state IN (#{list(@states)})"
           )

    create constraint(:dispatch_runs, :dispatch_runs_end_cause_check,
             check: "end_cause IS NULL OR end_cause IN (#{list(@end_causes)})"
           )

    create constraint(:dispatch_runs, :dispatch_runs_ended_check,
             check: "(state = 'ended') = (end_cause IS NOT NULL)"
           )

    create table(:dispatches, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :public_id, :text, null: false, default: fragment("dispatch_public_id()")

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

      add :dispatch_run_id,
          references(:dispatch_runs,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            match: :full,
            on_delete: :delete_all
          ),
          null: false

      add :pool_id,
          references(:nodes,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            match: :full,
            on_delete: :nothing
          ),
          null: false

      add :access_key_id, references(:access_keys, type: :binary_id, on_delete: :nothing),
        null: false

      add :claimed_at, :utc_datetime_usec, null: false
      add :lease_until, :utc_datetime_usec, null: false
      add :dispatched_at, :utc_datetime_usec
      add :external_type, :text
      add :external_ref, :text
      add :external_url, :text
      add :handed_over_at, :utc_datetime_usec
      add :stale_at, :utc_datetime_usec
      add :ended_at, :utc_datetime_usec
      add :end_cause, :text
      add :slot_freed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:dispatches, [:public_id])
    create index(:dispatches, [:dispatch_run_id])
    create index(:dispatches, [:pool_id])
    create index(:dispatches, [:access_key_id])
    create index(:dispatches, [:organisation_id, :workspace_id])

    create unique_index(:dispatches, [:dispatch_run_id],
             where: "ended_at IS NULL AND stale_at IS NULL",
             name: :dispatches_live_index
           )

    create index(:dispatches, [:pool_id],
             where: "slot_freed_at IS NULL",
             name: :dispatches_slot_held_index
           )

    create constraint(:dispatches, :dispatches_public_id_format,
             check: "public_id ~ '#{@public_id}'"
           )

    # The claim answer gives lease_until in whole seconds; the one stored is that one.
    create constraint(:dispatches, :dispatches_lease_check,
             check: "lease_until > claimed_at AND lease_until = date_trunc('second', lease_until)"
           )

    create constraint(:dispatches, :dispatches_external_type_check,
             check: "external_type IS NULL OR external_type ~ '#{@job_system}'"
           )

    # The integration contract's $defs.ref and $defs.url.
    create constraint(:dispatches, :dispatches_external_ref_check,
             check: "external_ref IS NULL OR char_length(external_ref) BETWEEN 1 AND 200"
           )

    create constraint(:dispatches, :dispatches_external_url_check,
             check:
               "external_url IS NULL OR (char_length(external_url) <= 2048 AND " <>
                 "external_url ~ '^https://[^[:space:]]+$')"
           )

    # Set together, and only once the starter said the job started.
    create constraint(:dispatches, :dispatches_external_check,
             check:
               "(external_type IS NULL AND external_ref IS NULL AND external_url IS NULL) OR " <>
                 "(external_type IS NOT NULL AND external_ref IS NOT NULL AND " <>
                 "external_url IS NOT NULL AND dispatched_at IS NOT NULL)"
           )

    # Handed over after dispatched, before the lease lapsed, and never once stale.
    create constraint(:dispatches, :dispatches_handed_over_check,
             check:
               "handed_over_at IS NULL OR (dispatched_at IS NOT NULL AND " <>
                 "handed_over_at < lease_until AND stale_at IS NULL)"
           )

    create constraint(:dispatches, :dispatches_stale_check,
             check: "stale_at IS NULL OR stale_at >= lease_until"
           )

    create constraint(:dispatches, :dispatches_end_cause_check,
             check: "end_cause IS NULL OR end_cause IN (#{list(@end_causes)})"
           )

    create constraint(:dispatches, :dispatches_ended_check,
             check: "(ended_at IS NULL) = (end_cause IS NULL)"
           )

    alter table(:runs) do
      add :dispatch_run_id,
          references(:dispatch_runs,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            on_delete: {:nilify, [:dispatch_run_id]}
          )
    end

    create unique_index(:runs, [:dispatch_run_id])
  end

  # Rolled back, a run is never a dispatched one, and the queue and its claims go.
  def down do
    drop index(:runs, [:dispatch_run_id])

    alter table(:runs) do
      remove :dispatch_run_id
    end

    drop table(:dispatches)
    drop table(:dispatch_runs)

    execute("DROP FUNCTION dispatch_public_id()")
  end

  defp list(values), do: Enum.map_join(values, ", ", &"'#{&1}'")
end
