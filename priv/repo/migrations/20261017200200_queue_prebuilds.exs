defmodule Apiary.Repo.Migrations.QueuePrebuilds do
  use Ecto.Migration

  # A run of the queue for the step `prebuild` (`Apiary.Dispatches.DispatchRun`): it
  # builds the environment of a collection's target for one node pool, and has no work
  # item.
  #
  # - `source_collection_id`: the collection whose target it builds, held to the run's
  #   organisation by the composite key.
  # - `pool_id`: the node pool it is held for, of the run's workspace: only a claim by
  #   that pool takes it. A run for any other step is held for none, and any pool of its
  #   workspace may claim it.
  # - `environment_ref`: the collection's `environment_ref` it was queued for, 1 to 200
  #   characters.
  #
  # A prebuild has none of a work item's take in: `work_item_id`, `take_in`, `attempt` and
  # `of` are empty for it, and set for every other step, which has none of the three
  # above (`dispatch_runs_step_shape_check`). So the work item's key becomes MATCH SIMPLE:
  # MATCH FULL refuses an empty `work_item_id` beside the run's `organisation_id`.
  #
  # At most one prebuild waits per collection and node pool
  # (`dispatch_runs_waiting_prebuild_index`): a newer `environment_ref` updates the
  # waiting one. A claimed, handed-over or ended one is left out of the index, so a change
  # while one is claimed or runs queues the one that waits next.
  #
  # The end causes, on both tables: `collection_ended`, the collection of a prebuild
  # ended, was assigned to none or to another workspace, has no target or no
  # `environment_ref`, or its connection ended, before the run was handed over;
  # `superseded`, a claimed prebuild whose lease lapsed while another prebuild of its
  # collection and pool waited or went back to waiting.
  #
  # The collection and the node pool are NO ACTION, as a dispatch's pool is: the purge
  # deletes the runs of the queue before them. Rolled back, the shape and the causes are
  # as before, and the roll back refuses while a run of the queue for the step `prebuild`
  # is kept.
  @end_causes ~w(released closed undone run_ended lost)
  @prebuild_causes @end_causes ++ ~w(collection_ended superseded)

  def up do
    execute("""
    ALTER TABLE dispatch_runs DROP CONSTRAINT dispatch_runs_work_item_id_fkey,
      ADD CONSTRAINT dispatch_runs_work_item_id_fkey
      FOREIGN KEY (work_item_id, organisation_id) REFERENCES work_items (id, organisation_id)
      ON DELETE CASCADE
    """)

    alter table(:dispatch_runs) do
      modify :work_item_id, :binary_id, null: true
      modify :take_in, :integer, null: true
      modify :attempt, :integer, null: true
      modify :of, :integer, null: true

      add :source_collection_id,
          references(:source_collections,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            on_delete: :nothing
          )

      add :pool_id,
          references(:nodes,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            on_delete: :nothing
          )

      add :environment_ref, :text
    end

    create index(:dispatch_runs, [:source_collection_id],
             where: "source_collection_id IS NOT NULL"
           )

    create index(:dispatch_runs, [:pool_id], where: "pool_id IS NOT NULL")

    create unique_index(:dispatch_runs, [:source_collection_id, :pool_id],
             where: "step = 'prebuild' AND state = 'waiting'",
             name: :dispatch_runs_waiting_prebuild_index
           )

    create constraint(:dispatch_runs, :dispatch_runs_step_shape_check,
             check:
               "(step = 'prebuild' AND work_item_id IS NULL AND take_in IS NULL AND " <>
                 "attempt IS NULL AND of IS NULL AND source_collection_id IS NOT NULL AND " <>
                 "pool_id IS NOT NULL AND environment_ref IS NOT NULL AND " <>
                 "char_length(environment_ref) BETWEEN 1 AND 200) OR " <>
                 "(step <> 'prebuild' AND work_item_id IS NOT NULL AND take_in IS NOT NULL AND " <>
                 "attempt IS NOT NULL AND of IS NOT NULL AND source_collection_id IS NULL AND " <>
                 "pool_id IS NULL AND environment_ref IS NULL)"
           )

    causes(@prebuild_causes)
  end

  def down do
    causes(@end_causes)
    drop constraint(:dispatch_runs, :dispatch_runs_step_shape_check)

    drop index(:dispatch_runs, [:source_collection_id, :pool_id],
           name: :dispatch_runs_waiting_prebuild_index
         )

    drop index(:dispatch_runs, [:pool_id])
    drop index(:dispatch_runs, [:source_collection_id])

    alter table(:dispatch_runs) do
      remove :environment_ref
      remove :pool_id
      remove :source_collection_id
      modify :of, :integer, null: false
      modify :attempt, :integer, null: false
      modify :take_in, :integer, null: false
      modify :work_item_id, :binary_id, null: false
    end

    execute("""
    ALTER TABLE dispatch_runs DROP CONSTRAINT dispatch_runs_work_item_id_fkey,
      ADD CONSTRAINT dispatch_runs_work_item_id_fkey
      FOREIGN KEY (work_item_id, organisation_id) REFERENCES work_items (id, organisation_id)
      MATCH FULL ON DELETE CASCADE
    """)
  end

  defp causes(causes) do
    list = Enum.map_join(causes, ", ", &"'#{&1}'")

    for table <- [:dispatch_runs, :dispatches] do
      drop constraint(table, :"#{table}_end_cause_check")

      create constraint(table, :"#{table}_end_cause_check",
               check: "end_cause IS NULL OR end_cause IN (#{list})"
             )
    end
  end
end
