defmodule Apiary.Deletion.Tables do
  @moduledoc """
  Every table that holds an organisation's rows, in the order the purge of an organisation
  or a workspace deletes them (`Apiary.Deletion`).

  A table is on the list when it has an `organisation_id` column, and every one that has
  is; the test compares the list with the database's schema (`Apiary.Deletion.TablesCase`),
  so a table added later fails it until it is listed. The list is in **delete order**: a
  table comes before every table it has a foreign key to, so deleting an organisation's
  rows table by table, in this order, never waits on a key another of its rows still
  holds. The test checks that too.

  The walk is the edition's tables (`c:Apiary.Edition.deletion_tables/0`), in the
  edition's delete order, then the core's, in theirs. The edition's go first because a
  foreign key only ever points from an edition's table to a core table, never back: an
  edition adds tables beside the core's and alters none of them, so no core table can hold
  a key to one of the edition's, and purging all of the edition's tables before any of the
  core's is always a valid order. Each side keeps its order within it.

  A table marked `:workspace` also has `workspace_id` and holds a workspace's rows:
  `workspace_tables/0` lists those, in the same order, the tables a workspace's purge
  walks. A table marked `:organisation` holds the organisation's rows: `memberships`
  has no workspace, since a person stays in the organisation when a workspace goes, and
  only their access to it goes with it. A table so marked may have a `workspace_id` all
  the same, a link to a workspace that its rows outlive (`outliving_tables/0`): the
  workspace's purge links them to none before it walks, and the organisation's purge
  deletes them. `organisations` itself is not on the list: its row is deleted last, after
  them all. Nor are the instance's tables, `users` and
  `users_tokens` (an account belongs to no organisation), `purged_organisations` (what the
  instance keeps of a purged organisation), `access_key_public_keys` (the ledger of public
  keys, which outlives the keys, `Apiary.AccessKeys.PublicKey`), `type_template_versions`
  (the workspace types' default processes, `Apiary.Processes.TypeTemplate`),
  `qory_harness_files` and `qory_harness_heads` (the files of the Qory harness by commit,
  Apiary.Harnesses.Qory) and Oban's.
  """

  @typedoc "What a table holds: an organisation's rows, or a workspace's too."
  @type mark :: :organisation | :workspace

  # Children first: a run's events, log, transcript, connections, steps and credential
  # entries before the run; the deliveries before the access keys they name; the composed run
  # configurations before the run configurations they were composed from; the run
  # configurations and the policy's rules
  # before the targets, and so are the pins; the runs before the runs of the queue they
  # name; an artifact's files before its versions, its versions before it, and the
  # versions before the runs of the queue they link to; a dispatch's machine log before
  # the dispatch, the dispatches before the runs of
  # the queue, the node pools and the access keys they name, and the runs of the queue
  # before their work items; the environment records before the
  # node pools and the collections they name; a node's instances before the access keys
  # they name; the access keys before the enrolment codes they arrived by, and
  # the keys, the codes, the runs, the instances and the organisation's connections to
  # adapters before the nodes they name; the work items before the tickets they name, a
  # ticket's comments before the ticket, and the tickets and the bookkeeping of their
  # listings before the collections they belong to; the rules of grants before the grants
  # and the workspaces they name; an adapter's collections, the
  # bookkeeping of their listings, the grants and the linked passes before the connections
  # they name; a work item's events, answers, confirmations and comments before the work
  # item, and so are its artifacts, the workspace's artifact types, the decisions at its
  # gates and its stages' failed checks; its escalations before the runs of the queue they
  # name; the work items and the runs of the queue before the process versions they run
  # under, and a work item or a run of another workspace that still links to one has that
  # link set to null (`ON DELETE SET NULL`); a model choice's fallbacks before the choice
  # and the connections they name, and a workspace's purge deletes them with its choices
  # (`ON DELETE CASCADE`); a connection's workspaces before the
  # connection, and the connections before the releases, the service definitions and the
  # secrets they name; a model key's states and settings before the secret's value they
  # name, which a workspace's purge deletes with them (`ON DELETE CASCADE`); everything
  # of a workspace before the workspace.
  #
  # A run of the queue names its work item by the organisation, not the workspace: it
  # stays in the workspace it was queued in when its work item moves to another. So a
  # workspace's purge deletes the runs of the queue of that workspace, whatever workspace
  # their work items are in, and the work items of that workspace, whose runs of the queue
  # in another workspace go with them (`ON DELETE CASCADE`), their dispatches with those,
  # and the runs registered for them keep no link to them.
  @tables [
    {"leaked_secrets", :workspace},
    {"log_chunks", :workspace},
    {"session_chunks", :workspace},
    {"events", :workspace},
    {"connections", :workspace},
    {"run_steps", :workspace},
    {"deliveries", :workspace},
    {"composed_run_configurations", :workspace},
    {"run_configurations", :workspace},
    {"run_credentials", :workspace},
    {"runs", :workspace},
    {"artifact_files", :workspace},
    {"artifact_versions", :workspace},
    {"artifacts", :workspace},
    {"dispatch_machine_logs", :workspace},
    {"dispatches", :workspace},
    {"gate_decisions", :workspace},
    {"escalations", :workspace},
    {"stage_checks", :workspace},
    {"dispatch_runs", :workspace},
    {"environments", :workspace},
    {"work_item_events", :workspace},
    {"work_item_confirmations", :workspace},
    {"work_item_comments", :workspace},
    {"model_choice_fallbacks", :organisation},
    {"model_choices", :workspace},
    {"time_limits", :workspace},
    {"stacks", :workspace},
    {"artifact_types", :workspace},
    {"work_items", :workspace},
    {"process_versions", :workspace},
    {"work_item_counters", :workspace},
    {"run_counters", :workspace},
    {"retention_runs", :workspace},
    {"policy_rules", :workspace},
    {"connection_workspaces", :workspace},
    {"organisation_connections", :organisation},
    {"service_definitions", :organisation},
    {"integration_releases", :organisation},
    {"variables", :workspace},
    {"model_key_states", :organisation},
    {"model_key_settings", :organisation},
    {"secret_values", :workspace},
    {"secrets", :workspace},
    {"workspace_data_keys", :workspace},
    {"organisation_data_keys", :organisation},
    {"target_pins", :workspace},
    {"targets", :workspace},
    {"node_instances", :workspace},
    {"access_keys", :workspace},
    {"access_key_enrolment_codes", :workspace},
    {"source_item_comments", :organisation},
    {"source_items", :organisation},
    {"source_item_listings", :organisation},
    {"source_collection_listings", :organisation},
    {"source_collections", :organisation},
    {"grant_rules", :workspace},
    {"adapter_grants", :organisation},
    {"adapter_linked_passes", :organisation},
    {"adapter_connections", :organisation},
    {"nodes", :workspace},
    {"invitations", :workspace},
    {"harness_assignments", :organisation},
    {"memberships", :organisation},
    {"audit_entries", :workspace},
    {"last_workspaces", :workspace},
    {"workspaces", :organisation}
  ]

  @doc """
  tables/0 is every table with an organisation's rows, in delete order: the edition's,
  then the core's.
  """
  @spec tables() :: [String.t()]
  def tables, do: Enum.map(walk(), &elem(&1, 0))

  @doc """
  workspace_tables/0 is the tables with a workspace's rows, `workspace_id` beside
  `organisation_id`, in delete order: the tables a workspace's purge walks.
  """
  @spec workspace_tables() :: [String.t()]
  def workspace_tables, do: for({table, :workspace} <- walk(), do: table)

  @doc """
  outliving_tables/0 is the core's tables marked `:organisation` that have a
  `workspace_id`: their rows stay with the organisation when the workspace they link to is
  purged, which links them to none first (`Apiary.Deletion.purge_workspace/1`).
  """
  @spec outliving_tables() :: [String.t()]
  def outliving_tables, do: ["source_collections"]

  @doc """
  boot!/0 checks the walk once at boot, so an edition's list that names a table twice, one
  of the core's, or a mark that is neither `:organisation` nor `:workspace`, stops the
  boot. Returns the tables.
  """
  @spec boot!() :: [String.t()]
  def boot!, do: tables()

  # The edition's tables and the core's, checked once and kept for the life of the node.
  defp walk do
    case :persistent_term.get({__MODULE__, :walk}, nil) do
      nil ->
        walk = check!(Apiary.Edition.deletion_tables(), @tables)
        :persistent_term.put({__MODULE__, :walk}, walk)
        walk

      walk ->
        walk
    end
  end

  @doc false
  @spec check!([{String.t(), mark}], [{String.t(), mark}]) :: [{String.t(), mark}]
  def check!(edition, core) do
    walk = edition ++ core

    for entry <- edition do
      case entry do
        {table, mark} when is_binary(table) and mark in [:organisation, :workspace] ->
          :ok

        other ->
          raise ArgumentError,
                "the edition's deletion tables are {table, :organisation | :workspace}, " <>
                  "got: #{inspect(other)}"
      end
    end

    case walk
         |> Enum.map(&elem(&1, 0))
         |> Enum.frequencies()
         |> Enum.filter(&(elem(&1, 1) > 1)) do
      [] ->
        walk

      twice ->
        raise ArgumentError,
              "a table is listed once among the deletion tables, got twice: " <>
                Enum.map_join(twice, ", ", &elem(&1, 0))
    end
  end
end
