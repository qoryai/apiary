defmodule Apiary.Runs.RunCredentials do
  # The credential entries of a run (`Apiary.Runs.RunCredential`), recorded at its claim
  # (`Apiary.Dispatches.Handover`) and read for its run configuration
  # (`Apiary.Policy.ComposedConfiguration`) and its secrets request
  # (`Apiary.Runs.SecretsRequest`).
  #
  # ## The work entry
  #
  # `form_work/4` forms the run's work entry, `work-1`, from what the claim read, without
  # a lock: a collection that can change the run's target, the connection through which
  # it came, and its adapter's apply items (`Apiary.Nodes.Node`'s `source_apply`).
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
  #   * The run ends `write_without_work_item`: its access level is `write` and it has no
  #     work item, or one with no public id, so it has no branch to limit its push
  #     credential to. A prebuild has no work item and access `:read`: it is not this case.
  #     A `write-no-push` run forms a read `work-1` with no work item.
  #   * Else the entry: the apply items filled with the run's target path, exactly as the
  #     adapter wrote it, a filled path that repeats an earlier one of its item left out;
  #     the collection's id and ref, with that path, as its resource; and access `:read`,
  #     whatever the run's access level: the run's sessions get a read credential. No item
  #     has `"push_ref"`: one that the adapter's template has is dropped.
  #
  # ## The push entry
  #
  # `push_from/3` forms the run's push entry, `push-1`, from its work entry: the same
  # connection, adapter, resource and filled apply items, with purpose `:push` and access
  # `:write`, and `"push_ref"` on each apply item: `refs/heads/qory/` and the work item's
  # public id (`wi_`...), the one branch Forager's push proxy lets the run push. Only a run
  # whose access level is `write` has one: a `read` run, a `write-no-push` run and a
  # prebuild have the work entry alone. Only Forager's push proxy gets the push entry's
  # value; the run's sessions get the work entry's.
  #
  # The claim writes the entries with their run (`insert!/2`), once. `work/1` and `push/1`
  # read them back for the run's documents and its secrets request.
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
  @push_name "push-1"
  @push_ref "refs/heads/qory/"
  @prebuild DispatchRun.prebuild()

  @doc false
  # form_work/4 is the work entry of the run of the queue `dispatch_run`, whose work item
  # is `work_item` (nil for a prebuild), whose target is `target` (`%{system:, path:}`,
  # nil for none) and whose access level is `level`, as the claim computed it for the
  # run's documents (`run_access/1`), else read now: `{:ok, entry}`, not yet stored,
  # `{:ok, nil}` for none, or `{:end, :target_access_gone}` (the moduledoc).
  @spec form_work(DispatchRun.t(), WorkItem.t() | nil, map | nil, atom | nil) ::
          {:ok, RunCredential.t() | nil} | {:end, :target_access_gone | :write_without_work_item}
  def form_work(dispatch_run, work_item, target, level \\ nil)

  def form_work(%DispatchRun{}, _work_item, nil, _level), do: {:ok, nil}

  def form_work(%DispatchRun{} = dispatch_run, work_item, %{path: _path} = target, level),
    do:
      work_from(
        dispatch_run,
        work_item,
        collection(dispatch_run, work_item, target),
        target,
        level
      )

  @doc false
  # work_collection/3 is the collection the work entry of the run of the queue
  # `dispatch_run` comes from, `{collection, connection, adapter}`, nil for none (the
  # moduledoc), read once, without a lock, for `work_from/5`. Nil, with no query, for a
  # run with no target, which has no work entry. `Apiary.Artifacts` reads it too, for the
  # adapter whose feed gets the `watch` entry of a run's submission version.
  @spec work_collection(DispatchRun.t(), WorkItem.t() | nil, map | nil) ::
          {Collection.t(), Connection.t(), Node.t()} | nil
  def work_collection(%DispatchRun{}, _work_item, nil), do: nil

  def work_collection(%DispatchRun{} = dispatch_run, work_item, target),
    do: collection(dispatch_run, work_item, target)

  @doc false
  # work_from/5 is `form_work/4` for the collection `work_collection/3` read.
  @spec work_from(
          DispatchRun.t(),
          WorkItem.t() | nil,
          {Collection.t(), Connection.t(), Node.t()} | nil,
          map | nil,
          atom | nil
        ) ::
          {:ok, RunCredential.t() | nil} | {:end, :target_access_gone | :write_without_work_item}
  def work_from(dispatch_run, work_item, collection, target, level \\ nil)

  def work_from(%DispatchRun{}, _work_item, _collection, nil, _level), do: {:ok, nil}

  def work_from(%DispatchRun{} = dispatch_run, work_item, collection, %{path: path}, level) do
    level = level || run_access(dispatch_run)

    case collection do
      nil ->
        {:ok, nil}

      {_collection, _connection, %Node{source_apply: nil}} ->
        {:ok, nil}

      {%Collection{ended_at: %DateTime{}}, _connection, _adapter} ->
        {:end, :target_access_gone}

      {_collection, %Connection{state: state}, _adapter} when state != :connected ->
        {:end, :target_access_gone}

      {collection, connection, adapter} ->
        with :ok <- branch(level, work_item),
             {:ok, apply} <- fill(adapter, path) do
          {:ok, entry(dispatch_run, collection, connection, adapter, path, apply)}
        end
    end
  end

  # A write run needs the work item's public id, which is its branch (`push_from/3`).
  defp branch(:write, %WorkItem{public_id: public_id}) when is_binary(public_id), do: :ok
  defp branch(:write, _work_item), do: {:end, :write_without_work_item}
  defp branch(_level, _work_item), do: :ok

  defp fill(adapter, path) do
    case ApplyTemplates.fill(adapter.source_apply, path) do
      {:ok, apply} -> {:ok, apply}
      {:error, :path_refused} -> {:end, :target_access_gone}
    end
  end

  @doc false
  # reach/3 is how the run's work entry reaches its target, from the collection
  # `form_work/4` takes: `{:gone, adapter}` for a collection that ended or a connection
  # not connected, `{:path_refused, adapter}` for a target path its adapter's apply items
  # do not take, else `{:reaches, adapter}`; nil for no collection. Read without a lock,
  # for the text of why a run ended `target_access_gone` (`Apiary.Stages.StopCause`).
  @spec reach(DispatchRun.t(), WorkItem.t() | nil, map | nil) ::
          {:gone | :path_refused | :reaches, Node.t()} | nil
  def reach(%DispatchRun{} = dispatch_run, work_item, %{path: path} = target) do
    case collection(dispatch_run, work_item, target) do
      nil ->
        nil

      {%Collection{ended_at: %DateTime{}}, _connection, adapter} ->
        {:gone, adapter}

      {_collection, %Connection{state: state}, adapter} when state != :connected ->
        {:gone, adapter}

      {_collection, _connection, %Node{source_apply: nil} = adapter} ->
        {:reaches, adapter}

      {_collection, _connection, adapter} ->
        {filled(adapter, path), adapter}
    end
  end

  def reach(%DispatchRun{}, _work_item, _target), do: nil

  defp filled(adapter, path) do
    case ApplyTemplates.fill(adapter.source_apply, path) do
      {:ok, _apply} -> :reaches
      {:error, :path_refused} -> :path_refused
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
      access: :read,
      resources: [
        %{
          "collection_id" => collection.id,
          "external_ref" => collection.external_ref,
          "path" => path
        }
      ],
      apply: Enum.map(apply, &(&1.values |> Map.new() |> Map.delete("push_ref"))),
      placeholders: nil
    }
  end

  @doc false
  # push_from/3 is the push entry of a run whose work entry is `work` (`form_work/4`), whose
  # access level is `level` and whose work item is `work_item`: `work`'s entry with the
  # name `push-1`, purpose `:push`, access `:write` and, on each apply item, `"push_ref"`:
  # `refs/heads/qory/<the work item's public id>`. The adapter's call has no branch:
  # Forager's push proxy refuses (403) a push to any other ref. Nil for every level but
  # `:write`, for no work entry, and for a work item with no public id, which
  # `form_work/4` ends `write_without_work_item` before.
  @spec push_from(RunCredential.t() | nil, atom | nil, WorkItem.t() | nil) ::
          RunCredential.t() | nil
  def push_from(%RunCredential{} = work, :write, %WorkItem{public_id: public_id})
      when is_binary(public_id) do
    %RunCredential{
      work
      | name: @push_name,
        purpose: :push,
        access: :write,
        apply: Enum.map(work.apply, &Map.put(&1, "push_ref", @push_ref <> public_id))
    }
  end

  def push_from(_work, _level, _work_item), do: nil

  @doc false
  # run_access/1 is the access level of the run of the queue `dispatch_run`: its harness
  # walk's, `:read` for a prebuild and for a run with no walk. With the workflow model, the
  # lower of the walk's and the stage entry's (`Apiary.Stages.run_access/2`). The claim
  # computes it once, for the run's documents and its work entry
  # (`Apiary.Dispatches.Handover`).
  @spec run_access(DispatchRun.t()) :: :read | :write_no_push | :write
  def run_access(%DispatchRun{step: @prebuild}), do: :read

  def run_access(%DispatchRun{id: id} = dispatch_run) do
    walk =
      Repo.one(from h in RunHarness, where: h.dispatch_run_id == ^id, select: h.access_level) ||
        :read

    Apiary.Stages.run_access(walk, dispatch_run)
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
  def work(run), do: listed(run, :work)

  @doc false
  # push/1 is the push entry of `run`, as `work/1` is the work entry, with `purpose`
  # `push` in its entry. Nil for a run with no push entry.
  @spec push(map | nil) ::
          %{
            name: String.t(),
            entry: Jason.OrderedObject.t(),
            hosts: [String.t()],
            row: RunCredential.t()
          }
          | nil
  def push(run), do: listed(run, :push)

  defp listed(%{id: run_id}, purpose) when is_binary(run_id) do
    query = from c in RunCredential, where: c.run_id == ^run_id and c.purpose == ^purpose

    case Repo.one(query) do
      nil ->
        nil

      %RunCredential{} = row ->
        %{
          name: row.name,
          entry: listed_entry(row),
          hosts: ApplyTemplates.hosts(row.apply),
          row: row
        }
    end
  end

  defp listed(_run, _purpose), do: nil

  @doc false
  # workspace_hosts/1 is the hosts a run of `workspace` can gain with its work entry: the
  # hosts of the apply items (`Apiary.Integrations.ApplyTemplates.hosts/1`) of each adapter
  # whose collection is assigned to the workspace, is live and is on a connected
  # connection, and whose latest start said its collections have targets and declared apply
  # items (`form_work/4` takes such a collection). `[%{host:, adapter:}]`, the adapter as
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

  defp listed_entry(%{name: name, purpose: purpose, apply: apply, placeholders: placeholders}) do
    Jason.OrderedObject.new(
      [
        {"name", name},
        {"purpose", Atom.to_string(purpose)},
        {"apply", Enum.map(apply, &ApplyTemplates.ordered/1)}
      ] ++ if(placeholders, do: [{"placeholders", placeholders}], else: [])
    )
  end

  @doc false
  # insert!/2 stores `entry`, which `form_work/4` or `push_from/3` formed, for the registered
  # `run`, inside the claim's transaction.
  @spec insert!(RunCredential.t(), Run.t()) :: RunCredential.t()
  def insert!(%RunCredential{} = entry, %Run{id: run_id, registered_at: at}),
    do: Repo.insert!(%{entry | run_id: run_id, inserted_at: at})
end
