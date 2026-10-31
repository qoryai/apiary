defmodule Apiary.Repo.Migrations.KeepEachWorkspaceSProcess do
  use Ecto.Migration

  # A workspace's process (`Apiary.Processes`): its stages in order, as one document of
  # `priv/schemas/process/v1.schema.json`, kept as versions. Each save is a new row,
  # numbered 1, 2, … within the workspace. `status` is `current`, at most one per
  # workspace; `trial`, a version chosen work items run on before it is made current;
  # `past`, a current version a later one replaced; or `dropped`, a trial that was not
  # made current. `author_id` is nil for the copy of the type's default made when the
  # workspace was created. `template` is the `{type, version}` of the default it copied.
  #
  # A work item keeps the version it runs under and where it is in it: the stage, the
  # stage's state, the round, the entry of the stage's sequence and, inside a loop, the
  # entry of the loop's body. A dispatched run keeps the same, with its workflow and the
  # machine type its entry asked for.
  #
  # Every existing workspace gets version 1, a copy of the software type's default as it
  # is written below, and every open work item gets that version and the stage that
  # matches where it is today: Shape, waiting at its gate, once its proposal is confirmed;
  # otherwise Explore, at the round of its newest explore run.
  @public_id "^pv_[0-9a-hjkmnp-tv-z]{16}$"
  @stage_id "^st_[0-9a-hjkmnp-tv-z]{10}$"
  @states ~w(running waiting_inputs waiting_answers waiting_workflow escalated at_gate done)

  # The software type's default process, version 1, as the backfill copies it.
  @explore "st_r79kph11eg"
  @shape "st_p9w5cvh311"
  @default %{
    "schema" => "qory.process/v1",
    "machine" => "default",
    "stages" => [
      %{
        "id" => @explore,
        "name" => "Explore",
        "inputs" => [],
        "sequence" => [
          %{"loop" => %{"rounds" => 3, "body" => [%{"workflow" => "explore-a-ticket"}]}}
        ],
        "outputs" => [%{"type" => "proposal", "required" => true}],
        "gate" => %{"kind" => "person", "approvers" => "members"}
      },
      %{
        "id" => @shape,
        "name" => "Shape",
        "inputs" => [],
        "sequence" => [],
        "outputs" => [],
        "gate" => %{"kind" => "person", "approvers" => "members"}
      },
      %{
        "id" => "st_6ns22c4pav",
        "name" => "Build",
        "inputs" => [],
        "sequence" => [],
        "outputs" => [],
        "gate" => %{"kind" => "person", "approvers" => "members"}
      },
      %{
        "id" => "st_m1mqbeywdg",
        "name" => "Verify",
        "inputs" => [],
        "sequence" => [],
        "outputs" => [],
        "gate" => %{"kind" => "person", "approvers" => "members"}
      },
      %{
        "id" => "st_k9kpv17xmy",
        "name" => "Release",
        "inputs" => [],
        "sequence" => [],
        "outputs" => [],
        "gate" => %{"kind" => "person", "approvers" => "members"}
      }
    ]
  }

  def up do
    create table(:process_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :public_id, :text, null: false

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :number, :integer, null: false
      add :status, :text, null: false
      add :document, :map, null: false
      add :author_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      add :based_on_id,
          references(:process_versions, type: :binary_id, on_delete: :nilify_all)

      add :template, :map

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:process_versions, [:public_id])
    create unique_index(:process_versions, [:workspace_id, :number])

    # At most one current version per workspace.
    create unique_index(:process_versions, [:workspace_id],
             where: "status = 'current'",
             name: :process_versions_one_current_index
           )

    create constraint(:process_versions, :process_versions_public_id_check,
             check: "public_id ~ '#{@public_id}'"
           )

    create constraint(:process_versions, :process_versions_status_check,
             check: "status IN ('current', 'trial', 'past', 'dropped')"
           )

    create constraint(:process_versions, :process_versions_number_check, check: "number >= 1")

    alter table(:work_items) do
      add :process_version_id,
          references(:process_versions, type: :binary_id, on_delete: :nothing)

      add :stage_id, :text
      add :stage_state, :text
      add :stage_round, :integer
      add :stage_entry, :integer
      add :loop_entry, :integer
    end

    create index(:work_items, [:process_version_id])

    alter table(:dispatch_runs) do
      add :process_version_id,
          references(:process_versions, type: :binary_id, on_delete: :nothing)

      add :stage_id, :text
      add :round, :integer
      add :stage_entry, :integer
      add :loop_entry, :integer
      add :workflow, :text
      add :machine_type, :text
    end

    create index(:dispatch_runs, [:process_version_id])

    for table <- [:work_items, :dispatch_runs] do
      create constraint(table, :"#{table}_stage_id_check",
               check:
                 "stage_id IS NULL OR (stage_id ~ '#{@stage_id}' AND process_version_id IS NOT NULL)"
             )

      create constraint(table, :"#{table}_entries_check",
               check:
                 "(stage_entry IS NULL OR stage_entry >= 0) AND (loop_entry IS NULL OR loop_entry >= 0)"
             )
    end

    create constraint(:work_items, :work_items_stage_state_check,
             check:
               "stage_state IS NULL OR (stage_id IS NOT NULL AND stage_state IN (#{Enum.map_join(@states, ", ", &"'#{&1}'")}))"
           )

    create constraint(:work_items, :work_items_stage_round_check,
             check: "stage_round IS NULL OR stage_round >= 0"
           )

    create constraint(:dispatch_runs, :dispatch_runs_round_check,
             check: "round IS NULL OR round >= 1"
           )

    flush()
    backfill(repo())
  end

  # backfill/1 gives each workspace with no version its version 1, and each open work item
  # with no version that version and its stage. The public ids are made as
  # `workspace_public_id()` makes a workspace's (20261011100000), by a function that lives
  # for this session alone. Public for the migration's test.
  @doc false
  def backfill(repo) do
    repo.query!("""
    CREATE FUNCTION pg_temp.process_version_public_id() RETURNS text LANGUAGE plpgsql VOLATILE AS $$
    DECLARE
      alphabet constant text := '0123456789abcdefghjkmnpqrstvwxyz';
      raw constant bytea := uuid_send(gen_random_uuid());
      bits constant bit(80) :=
        ('x' || encode(substring(raw FROM 1 FOR 6) || substring(raw FROM 11 FOR 4), 'hex'))::bit(80);
      id text := 'pv_';
    BEGIN
      FOR i IN 0..15 LOOP
        id := id || substr(alphabet, substring(bits FROM i * 5 + 1 FOR 5)::integer + 1, 1);
      END LOOP;
      RETURN id;
    END
    $$
    """)

    repo.query!(
      """
      INSERT INTO process_versions
        (id, public_id, organisation_id, workspace_id, number, status, document, author_id,
         based_on_id, template, inserted_at, updated_at)
      SELECT gen_random_uuid(), pg_temp.process_version_public_id(), w.organisation_id, w.id,
             1, 'current', $1::jsonb, NULL, NULL,
             jsonb_build_object('type', coalesce(w.type, 'qory.software'), 'version', 1),
             now(), now()
      FROM workspaces w
      WHERE NOT EXISTS (SELECT 1 FROM process_versions v WHERE v.workspace_id = w.id)
      """,
      [@default]
    )

    # The open work items, `exploring`: Shape at its gate once the proposal of the current
    # take in is confirmed; else Explore, at the round of the newest explore run of the
    # take in, in the state that run leaves it: running while it has not ended, at the gate
    # with a proposal, waiting for answers to its questions until they are answered, and
    # escalated for a run that ended with neither. With no run yet, Explore is running.
    repo.query!("""
    WITH newest AS (
      SELECT DISTINCT ON (r.work_item_id) r.work_item_id, r.attempt, r.state, r.result_outcome
      FROM dispatch_runs r
      JOIN work_items wi ON wi.id = r.work_item_id AND r.take_in = wi.take_in
      WHERE r.step = 'explore'
      ORDER BY r.work_item_id, r.attempt DESC
    ),
    placed AS (
      SELECT wi.id,
             pv.id AS version_id,
             EXISTS (
               SELECT 1 FROM work_item_confirmations c
               WHERE c.work_item_id = wi.id AND c.take_in = wi.take_in
             ) AS confirmed,
             n.work_item_id IS NOT NULL AS ran,
             n.attempt, n.state, n.result_outcome,
             EXISTS (
               SELECT 1 FROM work_item_answers a
               WHERE a.work_item_id = wi.id AND a.take_in = wi.take_in
                 AND a.attempt = n.attempt AND a.answered_at IS NOT NULL
             ) AS answered
      FROM work_items wi
      JOIN process_versions pv ON pv.workspace_id = wi.workspace_id AND pv.status = 'current'
      LEFT JOIN newest n ON n.work_item_id = wi.id
      WHERE wi.state = 'exploring' AND wi.process_version_id IS NULL
    )
    UPDATE work_items wi
    SET process_version_id = p.version_id,
        stage_id = CASE WHEN p.confirmed THEN '#{@shape}' ELSE '#{@explore}' END,
        stage_state = CASE
          WHEN p.confirmed THEN 'at_gate'
          WHEN NOT p.ran OR p.state <> 'ended' THEN 'running'
          WHEN p.result_outcome = 'proposal' THEN 'at_gate'
          WHEN p.result_outcome = 'questions' AND p.answered THEN 'running'
          WHEN p.result_outcome = 'questions' THEN 'waiting_answers'
          ELSE 'escalated'
        END,
        stage_round = CASE WHEN p.confirmed THEN 0 ELSE coalesce(p.attempt, 0) END,
        stage_entry = 0,
        loop_entry = CASE WHEN p.confirmed THEN NULL ELSE 0 END
    FROM placed p
    WHERE wi.id = p.id
    """)

    repo.query!("DROP FUNCTION pg_temp.process_version_public_id()")
    :ok
  end

  # Rolled back, the processes and every work item's and run's place in them are gone.
  def down do
    for table <- [:work_items, :dispatch_runs] do
      drop constraint(table, :"#{table}_stage_id_check")
      drop constraint(table, :"#{table}_entries_check")
    end

    drop constraint(:work_items, :work_items_stage_state_check)
    drop constraint(:work_items, :work_items_stage_round_check)
    drop constraint(:dispatch_runs, :dispatch_runs_round_check)

    drop index(:dispatch_runs, [:process_version_id])

    alter table(:dispatch_runs) do
      remove :process_version_id
      remove :stage_id
      remove :round
      remove :stage_entry
      remove :loop_entry
      remove :workflow
      remove :machine_type
    end

    drop index(:work_items, [:process_version_id])

    alter table(:work_items) do
      remove :process_version_id
      remove :stage_id
      remove :stage_state
      remove :stage_round
      remove :stage_entry
      remove :loop_entry
    end

    drop table(:process_versions)
  end
end
