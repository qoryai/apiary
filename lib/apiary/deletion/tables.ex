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
  edition's own delete order, then the core's, in theirs. The edition's go first because a
  foreign key only ever points from an edition's table to a core table, never back: an
  edition adds tables beside the core's and alters none of them, so no core table can hold
  a key to one of the edition's, and purging all of the edition's tables before any of the
  core's is always a valid order. Each side keeps its own order within it.

  A table marked `:workspace` also has `workspace_id` and holds a workspace's rows:
  `workspace_tables/0` lists those, in the same order, the tables a workspace's purge
  walks. A table marked `:organisation` holds the organisation's own rows: `memberships`
  has no workspace, since a person stays in the organisation when a workspace goes, and
  only their access to it goes with it. `organisations` itself is not on the list: its row
  is deleted last, after them all. Nor are the instance's own tables, `users` and
  `users_tokens` (an account belongs to no organisation), `purged_organisations` (what the
  instance keeps of a purged organisation), `access_key_public_keys` (the ledger of public
  keys, which outlives the keys, `Apiary.AccessKeys.PublicKey`) and Oban's.
  """

  @typedoc "What a table holds: an organisation's own rows, or a workspace's too."
  @type mark :: :organisation | :workspace

  # Children first: a run's events, log and connections before the run; the deliveries
  # before the access keys they name; the run configurations and the policy's rules before
  # the targets, and so are the pins; a node's instances before the access keys they name;
  # the access keys before the enrolment codes they arrived by, and the keys, the codes,
  # the runs and the instances before the nodes they name; everything of a workspace
  # before the workspace.
  @tables [
    {"log_chunks", :workspace},
    {"events", :workspace},
    {"connections", :workspace},
    {"deliveries", :workspace},
    {"run_configurations", :workspace},
    {"runs", :workspace},
    {"retention_runs", :workspace},
    {"policy_rules", :workspace},
    {"connection_targets", :workspace},
    {"workspace_connections", :workspace},
    {"service_definitions", :workspace},
    {"integration_releases", :workspace},
    {"variables", :workspace},
    {"secret_values", :workspace},
    {"secrets", :workspace},
    {"workspace_data_keys", :workspace},
    {"target_pins", :workspace},
    {"targets", :workspace},
    {"node_instances", :workspace},
    {"access_keys", :workspace},
    {"access_key_enrolment_codes", :workspace},
    {"nodes", :workspace},
    {"invitations", :workspace},
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
