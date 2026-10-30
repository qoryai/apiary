defmodule Apiary.Runs.RunCredentials do
  # The credential entries of a run (`Apiary.Runs.RunCredential`), recorded at its claim
  # (`Apiary.Dispatches.Handover`) and read for its run configuration
  # (`Apiary.Policy.ComposedConfiguration`) and its secrets request
  # (`Apiary.Runs.SecretsRequest`).
  #
  # ## The work entry
  #
  # `form_work/3` forms the run's work entry, `work-1`, from what the claim read, without
  # a lock: a collection that can change the run's target, the connection through which
  # it came, its adapter's apply items (`Apiary.Nodes.Node`'s `source_apply`) and the
  # run's access level.
  #
  #   * A prebuild's collection is the one it builds (`source_collection_id`).
  #   * A run with a work item takes a matching collection: one assigned to the run's
  #     workspace, whose adapter's latest start said its collections have targets
  #     (`Apiary.Nodes.Node`'s `targets`), and whose target system and path equal the
  #     run's target. A collection of an adapter that did not say so never counts, even
  #     when its target equals the run's, as a tracker's collection's may. So the claim
  #     never requests a forge's credential from a tracker's adapter. Of the matching
  #     collections, the run takes one that is live and on a connected connection before
  #     one that is not; then its ticket's collection (`Apiary.Sources.Item`) before
  #     another; then the oldest, by `inserted_at`, then by id.
  #
  #   * No entry, and the run runs as before: a run with no target, no collection (no
  #     matching one for a run with a work item), or an adapter whose latest start
  #     declared no apply items.
  #   * The run ends `target_access_gone`: the collection ended, or its connection is not
  #     connected, or the target path is one the templates refuse
  #     (`Apiary.Integrations.ApplyTemplates.fill/2`).
  #   * Else the entry: the apply items filled with the run's target path, exactly as the
  #     adapter wrote it, a filled path that repeats an earlier one of its item left out;
  #     the collection's id and ref, with that path, as its resource; and the access level
  #     of the run's harness walk (`Apiary.Harnesses.RunHarness`'s `access_level`), `:read`
  #     for a prebuild and for a run with no walk.
  #
  # The claim writes the entry with its run (`insert!/2`), once. `work/1` reads it back for
  # the run's documents and its secrets request.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias Apiary.Adapters.{Collection, Connection}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Harnesses.RunHarness
  alias Apiary.Integrations.ApplyTemplates
  alias Apiary.Nodes.Node
  alias Apiary.Repo
  alias Apiary.Runs.{Run, RunCredential}
  alias Apiary.Sources.Item
  alias Apiary.WorkItems.WorkItem

  @work_name "work-1"
  @prebuild DispatchRun.prebuild()

  @doc false
  # form_work/3 is the work entry of the run of the queue `dispatch_run`, whose work item
  # is `work_item` (nil for a prebuild) and whose target is `target` (`%{system:, path:}`,
  # nil for none): `{:ok, entry}`, not yet stored, `{:ok, nil}` for none, or
  # `{:end, :target_access_gone}` (the moduledoc).
  @spec form_work(DispatchRun.t(), WorkItem.t() | nil, map | nil) ::
          {:ok, RunCredential.t() | nil} | {:end, :target_access_gone}
  def form_work(%DispatchRun{}, _work_item, nil), do: {:ok, nil}

  def form_work(%DispatchRun{} = dispatch_run, work_item, %{path: path} = target) do
    case collection(dispatch_run, work_item, target) do
      nil ->
        {:ok, nil}

      {_collection, _connection, %Node{source_apply: nil}} ->
        {:ok, nil}

      {%Collection{ended_at: %DateTime{}}, _connection, _adapter} ->
        {:end, :target_access_gone}

      {_collection, %Connection{state: state}, _adapter} when state != :connected ->
        {:end, :target_access_gone}

      {collection, connection, adapter} ->
        case ApplyTemplates.fill(adapter.source_apply, path) do
          {:ok, apply} ->
            {:ok, entry(dispatch_run, collection, connection, adapter, path, apply)}

          {:error, :path_refused} ->
            {:end, :target_access_gone}
        end
    end
  end

  # The collection the run's work entry comes from, with its connection and adapter: a
  # prebuild's, or for a run with a work item the matching collection it takes (the
  # moduledoc). Nil where there is none.
  defp collection(%DispatchRun{source_collection_id: id}, _work_item, _target)
       when is_binary(id),
       do: Repo.one(from([c, n, a] in with_adapter(), where: c.id == ^id))

  defp collection(
         %DispatchRun{} = dispatch_run,
         %WorkItem{} = work_item,
         %{system: system, path: path}
       )
       when is_binary(system) and is_binary(path) do
    from([c, n, a] in with_adapter(),
      where:
        c.organisation_id == ^dispatch_run.organisation_id and
          c.workspace_id == ^dispatch_run.workspace_id and c.target_system == ^system and
          c.target_path == ^path and a.targets == true,
      order_by: [desc: is_nil(c.ended_at) and n.state == :connected]
    )
    |> ticket_first(work_item)
    |> order_by_age()
    |> Repo.one()
  end

  defp collection(%DispatchRun{}, _work_item, _target), do: nil

  defp with_adapter do
    from c in Collection,
      join: n in Connection,
      on: n.id == c.connection_id,
      join: a in Node,
      on: a.id == c.adapter_id,
      select: {c, n, a}
  end

  # The run's ticket's collection before any other, where the work item has a ticket.
  defp ticket_first(query, %WorkItem{item_id: item_id}) when is_binary(item_id) do
    from [c] in query,
      left_join: i in Item,
      on: i.collection_id == c.id and i.id == ^item_id,
      order_by: [desc: not is_nil(i.id)]
  end

  defp ticket_first(query, _work_item), do: query

  defp order_by_age(query),
    do: from([c] in query, order_by: [asc: c.inserted_at, asc: c.id], limit: 1)

  defp entry(dispatch_run, collection, connection, adapter, path, apply) do
    %RunCredential{
      organisation_id: dispatch_run.organisation_id,
      workspace_id: dispatch_run.workspace_id,
      connection_id: connection.id,
      adapter_id: adapter.id,
      name: @work_name,
      purpose: :work,
      access: access(dispatch_run),
      resources: [
        %{
          "collection_id" => collection.id,
          "external_ref" => collection.external_ref,
          "path" => path
        }
      ],
      apply: Enum.map(apply, &Map.new(&1.values)),
      placeholders: nil
    }
  end

  # The run's access level: its harness walk's, `:read` for a prebuild and for a run with
  # no walk.
  defp access(%DispatchRun{step: @prebuild}), do: :read

  defp access(%DispatchRun{id: id}) do
    Repo.one(from h in RunHarness, where: h.dispatch_run_id == ^id, select: h.access_level) ||
      :read
  end

  @doc false
  # work/1 is the work entry of `run` (a run, or a map with its `id`), as the run's run
  # configuration lists it: `%{name:, entry:, hosts:, row:}`, the entry a host credential
  # of the Forager contract (`name`, `purpose` `work`, `apply`, and `placeholders` where it
  # has some), the hosts of its apply items, each once, in their order, and the stored row
  # (`Apiary.Runs.RunCredential`), which the secrets request issues the entry's value
  # from (`Apiary.Runs.WorkCredential`). Nil for none.
  @spec work(map | nil) ::
          %{
            name: String.t(),
            entry: Jason.OrderedObject.t(),
            hosts: [String.t()],
            row: RunCredential.t()
          }
          | nil
  def work(%{id: run_id}) when is_binary(run_id) do
    query = from c in RunCredential, where: c.run_id == ^run_id and c.purpose == :work

    case Repo.one(query) do
      nil ->
        nil

      %RunCredential{} = row ->
        %{
          name: row.name,
          entry: work_entry(row),
          hosts: ApplyTemplates.hosts(row.apply),
          row: row
        }
    end
  end

  def work(_run), do: nil

  @doc false
  # workspace_hosts/1 is the hosts a run of `workspace` can gain with its work entry: the
  # hosts of the apply items (`Apiary.Integrations.ApplyTemplates.hosts/1`) of each adapter
  # whose collection is assigned to the workspace, is live and is on a connected
  # connection, and whose latest start said its collections have targets and declared apply
  # items (`form_work/3` takes such a collection). `[%{host:, adapter:}]`, the adapter as
  # `Apiary.Adapters.title/1` writes it, in the order of the collections' age. A run gains
  # only the hosts of the one collection it takes. `[]` without the `factory` feature.
  @spec workspace_hosts(Apiary.Organisations.Workspace.t()) :: [
          %{host: String.t(), adapter: String.t()}
        ]
  def workspace_hosts(%Apiary.Organisations.Workspace{} = workspace) do
    if Apiary.Features.on?(:factory) do
      from([c, n, a] in with_adapter(),
        where: c.organisation_id == ^workspace.organisation_id,
        where: c.workspace_id == ^workspace.id,
        where: is_nil(c.ended_at) and n.state == :connected,
        where: a.targets == true and not is_nil(a.source_apply),
        order_by: [asc: c.inserted_at, asc: c.id]
      )
      |> Repo.all()
      |> Enum.flat_map(fn {_collection, _connection, adapter} ->
        for host <- ApplyTemplates.hosts(adapter.source_apply),
            do: %{host: host, adapter: Apiary.Adapters.title(adapter)}
      end)
      |> Enum.uniq()
    else
      []
    end
  end

  defp work_entry(%{name: name, apply: apply, placeholders: placeholders}) do
    Jason.OrderedObject.new(
      [
        {"name", name},
        {"purpose", "work"},
        {"apply", Enum.map(apply, &ApplyTemplates.ordered/1)}
      ] ++ if(placeholders, do: [{"placeholders", placeholders}], else: [])
    )
  end

  @doc false
  # insert!/2 stores `entry`, which `form_work/3` formed, for the registered `run`, inside
  # the claim's transaction.
  @spec insert!(RunCredential.t(), Run.t()) :: RunCredential.t()
  def insert!(%RunCredential{} = entry, %Run{id: run_id, registered_at: at}),
    do: Repo.insert!(%{entry | run_id: run_id, inserted_at: at})
end
