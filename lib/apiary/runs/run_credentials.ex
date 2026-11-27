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
  #     never requests a forge's credential from a tracker's adapter. The harness walk
  #     reads the target's file from the same collection (`target_collection/4`). Of the
  #     matching collections, the run takes one that is live and on a connected connection
  #     before one that is not; then its ticket's collection (`Apiary.Sources.Item`)
  #     before another; then the oldest, by `inserted_at`, then by id. A deleted adapter's
  #     collection still matches: its connection ended with the adapter, so the run ends
  #     `target_access_gone`, and its stop cause shows that integration.
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
  # ## The harness entries
  #
  # `form_harness/2` forms the run's harness entries, `harness-1` to `harness-5`, from the
  # links its harness walk resolved (`Apiary.Harnesses.entries/1`), in that order: one
  # entry per link of the run's organisation, one per resource of a link through an
  # assignment. Each entry is read only, under the link's grant (`grant_id`, no
  # connection), and takes its adapter's apply items (`Apiary.Nodes.Node`'s
  # `source_apply`):
  #
  #   * a path with `{target.path}` is filled with each resource's path, as the adapter
  #     resolved it (`Apiary.Integrations.ApplyTemplates.fill/2`), the paths of all its
  #     resources in one item, each once; where one of its resources has no path, the
  #     item has no `paths`, so it covers every path of its hosts;
  #   * only the items whose hosts are all in the run's `stack_hosts` are kept, since only
  #     the stack proxy sets a harness credential, on those hosts alone.
  #
  # A link whose adapter is gone or declares no apply items, or keeps no item, gets no
  # entry. The entries are refused, and the run does not start, when a resource's path is
  # one the templates refuse (`:path_refused`), an item gets more than 32 paths
  # (`:too_many_paths`), or two entries have items on one host that overlap or have no
  # paths (`:overlap`), which the gateway refuses (`run-configuration.schema.json`). So,
  # without the adapters' paths, a run has one link per forge host.
  #
  # The claim writes the entries with their run (`insert!/2`), once. `work/1`, `push/1` and
  # `harness/1` read them back for the run's documents and its secrets request.
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
  @harness_prefix "harness-"
  # The most paths of an item (`run-configuration.schema.json`, `credential_paths`).
  @max_paths 32
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
  # run with no target, which has no work entry.
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

  defp collection(%DispatchRun{} = dispatch_run, %WorkItem{} = work_item, target),
    do:
      target_collection(
        dispatch_run.organisation_id,
        dispatch_run.workspace_id,
        work_item,
        target
      )

  defp collection(%DispatchRun{}, _work_item, _target), do: nil

  @doc false
  # target_collection/4 is the collection of `target` in the workspace `workspace_id` of
  # the organisation `organisation_id` that a run of `work_item` (nil for none) takes,
  # `{collection, connection, adapter}`, nil for none: the work entry's (the moduledoc)
  # and the harness walk's (`Apiary.Harnesses.Walk`), so both read the same collection.
  # The collection has the target's system and path, and its adapter said its
  # collections have targets. Live on a connected connection first,
  # then the work item's ticket's, then the oldest. Nil for a target with no address.
  @spec target_collection(Ecto.UUID.t(), Ecto.UUID.t(), WorkItem.t() | nil, map) ::
          {Collection.t(), Connection.t(), Node.t()} | nil
  def target_collection(organisation_id, workspace_id, work_item, %{system: system, path: path})
      when is_binary(system) and is_binary(path) do
    from([c, n, a] in with_adapter(),
      where:
        c.organisation_id == ^organisation_id and c.workspace_id == ^workspace_id and
          c.target_system == ^system and c.target_path == ^path and a.targets == true,
      order_by: [desc: is_nil(c.ended_at) and n.state == :connected]
    )
    |> ticket_first(work_item)
    |> order_by_age()
    |> Repo.one()
  end

  def target_collection(_organisation_id, _workspace_id, _work_item, _target), do: nil

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
  # form_harness/2 is the harness entries of the run of the queue `dispatch_run`, whose
  # run configuration has `stack_hosts` (the moduledoc): `{:ok, entries}`, not yet stored,
  # `[]` for none, or `{:error, reason, at}`: `:path_refused` with `{:source, git}`, the
  # address of the source whose path the templates refuse; `:too_many_paths` with
  # `{:host, host}`, the first host of the item; or, with the host two items claim
  # (`conflict/1`): `:integration_overlap` with `{:host, host}` where the adapter's items
  # cause it, `:overlap` with `{:host, host}` where the entries of two links do, and
  # `:nested_sources` with `{:nested, host, first, second}` where two resources of one
  # assigned link nest, `first` and `second` the address of the first source each reads,
  # nil for none.
  @spec form_harness(DispatchRun.t(), [String.t()]) ::
          {:ok, [RunCredential.t()]}
          | {:error, :path_refused, {:source, String.t() | nil}}
          | {:error, :too_many_paths | :overlap | :integration_overlap, {:host, String.t()}}
          | {:error, :nested_sources, {:nested, String.t(), String.t() | nil, String.t() | nil}}
  def form_harness(%DispatchRun{} = dispatch_run, stack_hosts) when is_list(stack_hosts) do
    dispatch_run
    |> Apiary.Harnesses.entries()
    |> Enum.reduce_while({:ok, []}, fn link, {:ok, formed} ->
      case harness_apply(link, stack_hosts) do
        {:ok, nil} -> {:cont, {:ok, formed}}
        {:ok, {apply, fixed}} -> {:cont, {:ok, formed ++ [{link, apply, fixed}]}}
        {:error, _reason, _at} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, formed} ->
        claims =
          for {link, apply, fixed} <- formed,
              do: %{grant: link.link_id, items: apply, fixed: fixed}

        case conflict(claims) do
          nil ->
            {:ok, harness_rows(dispatch_run, Enum.map(formed, &Tuple.delete_at(&1, 2)))}

          {host, :integration} ->
            {:error, :integration_overlap, {:host, host}}

          {host, :accounts} ->
            {:error, :overlap, {:host, host}}

          {host, {:nested, m, n}} ->
            [first, second] = for i <- [m, n], do: formed |> Enum.at(i) |> elem(0) |> entry_git()
            {:error, :nested_sources, {:nested, host, first, second}}
        end

      error ->
        error
    end
  end

  defp harness_rows(dispatch_run, formed) do
    formed
    |> Enum.with_index(1)
    |> Enum.map(fn {{link, apply}, n} ->
      %RunCredential{
        organisation_id: dispatch_run.organisation_id,
        workspace_id: dispatch_run.workspace_id,
        connection_id: nil,
        grant_id: link.link_id,
        adapter_id: link.adapter_id,
        name: @harness_prefix <> Integer.to_string(n),
        purpose: :harness,
        access: :read,
        resources: link.resources,
        apply: apply,
        placeholders: nil
      }
    end)
  end

  # The address of the first source the first resource of the harness entry `link` reads,
  # nil for none.
  defp entry_git(link), do: Enum.find_value(link.resources, &first_git/1)

  # The apply items of one harness entry, each a map in a run configuration's order of
  # members (the moduledoc), and the paths of the adapter's templates that no resource
  # fills (no `{target.path}`); nil for no item.
  defp harness_apply(link, stack_hosts) do
    case link.adapter_id && Repo.get(Node, link.adapter_id) do
      %Node{source_apply: [_ | _] = items, deleted_at: nil} ->
        items =
          Enum.filter(items, fn %{"hosts" => hosts} -> Enum.all?(hosts, &(&1 in stack_hosts)) end)

        fixed =
          for %{"paths" => [_ | _] = paths} <- items,
              path <- paths,
              not String.contains?(path, "{target.path}"),
              uniq: true,
              do: path

        items
        |> Enum.reduce_while({:ok, []}, fn item, {:ok, done} ->
          case harness_item(item, link.resources) do
            {:ok, item} -> {:cont, {:ok, done ++ [item]}}
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, []} -> {:ok, nil}
          {:ok, apply} -> {:ok, {apply, fixed}}
          error -> error
        end

      _none ->
        {:ok, nil}
    end
  end

  # One template item for `resources`: its paths filled with each resource's path.
  defp harness_item(%{"paths" => templates} = item, resources) do
    filled? = Enum.any?(templates, &String.contains?(&1, "{target.path}"))

    cond do
      not filled? ->
        {:ok, ordered_map(item)}

      Enum.any?(resources, &is_nil(&1["path"])) ->
        {:ok, item |> Map.delete("paths") |> ordered_map()}

      true ->
        Enum.reduce_while(resources, {:ok, []}, fn resource, {:ok, all} ->
          case ApplyTemplates.fill([item], resource["path"]) do
            {:ok, [filled]} ->
              {:cont, {:ok, all ++ filled["paths"]}}

            {:error, :path_refused} ->
              {:halt, {:error, :path_refused, {:source, first_git(resource)}}}
          end
        end)
        |> case do
          {:ok, all} ->
            all = Enum.uniq(all)

            if length(all) > @max_paths,
              do: {:error, :too_many_paths, {:host, hd(item["hosts"])}},
              else: {:ok, item |> Map.put("paths", all) |> ordered_map()}

          error ->
            error
        end
    end
  end

  defp harness_item(item, _resources), do: {:ok, ordered_map(item)}

  # The address of the first source a resource reads, nil for none.
  defp first_git(resource) do
    Enum.find_value(List.wrap(resource["sources"]), fn
      %{"git" => git} when is_binary(git) -> git
      _source -> nil
    end)
  end

  defp ordered_map(item), do: item |> ApplyTemplates.ordered() |> Map.get(:values) |> Map.new()

  @doc false
  # overlap?/1 is whether two apply items of the harness entries whose items are `entries`
  # (one list of items each, each entry of a link of its own), of one entry or of two,
  # claim one host in a way the gateway refuses (`conflict/1`).
  @spec overlap?([[map]]) :: boolean
  def overlap?(entries),
    do: conflict(for(items <- entries, do: %{grant: nil, items: items, fixed: []})) != nil

  @doc false
  # conflict/1 is the first host that two apply items of the harness entries `entries`
  # claim in a way the gateway refuses, with who causes it, nil for none. Each entry is
  # `%{grant:, items:, fixed:}`: the id of its link, its apply items, and the paths of the
  # adapter's templates that no resource fills. As the gateway checks a run
  # configuration's harness credentials, each item is compared with every item before
  # it, of the same entry or of another, and on a host both claim, one of them has no
  # `paths`, or a path of one and a path of the other match one request. A path matches
  # whole, or up to a final `*` as a prefix, and a segment written `{}` matches one
  # segment that is not empty.
  #
  # `{host, :integration}` where the adapter's items cause it: two items of one entry, an
  # item with no paths (a resource the adapter resolved no path for), or a path that no
  # resource fills. Else, for two entries whose paths filled from resources match:
  # `{host, {:nested, m, n}}` for two entries of one link, the indexes of the earlier
  # entry and the later one, whose resources nest; `{host, :accounts}` for entries of two
  # links.
  @spec conflict([%{grant: term, items: [map], fixed: [String.t()]}]) ::
          {String.t(), :integration | :accounts | {:nested, integer, integer}} | nil
  def conflict(entries) do
    items =
      for {entry, n} <- Enum.with_index(entries), item <- entry.items do
        {item, entry, n}
      end
      |> Enum.with_index()

    Enum.find_value(items, fn {later, i} ->
      Enum.find_value(Enum.take(items, i), fn {earlier, _j} ->
        {item, _entry, _n} = later

        Enum.find_value(item["hosts"], fn host ->
          if host in elem(earlier, 0)["hosts"], do: claim_conflict(host, earlier, later)
        end)
      end)
    end)
  end

  # Two items, each with its entry and that entry's index, on `host`, which both claim.
  defp claim_conflict(host, {a, entry_a, m}, {b, entry_b, n}) do
    if pathless?(a) or pathless?(b) do
      {host, :integration}
    else
      meeting = for x <- a["paths"], y <- b["paths"], paths_meet?(x, y), do: {x, y}

      cond do
        meeting == [] ->
          nil

        m == n or Enum.any?(meeting, fn {x, y} -> x in entry_a.fixed or y in entry_b.fixed end) ->
          {host, :integration}

        not is_nil(entry_a.grant) and entry_a.grant == entry_b.grant ->
          {host, {:nested, m, n}}

        true ->
          {host, :accounts}
      end
    end
  end

  defp pathless?(item), do: item["paths"] in [nil, []]

  # Whether two path patterns match one request path.
  defp paths_meet?(a, b), do: meet?(pattern(a), pattern(b))

  # A pattern's segments, and whether it ends with `*`: the last segment is then the
  # prefix of a segment, after which anything may follow.
  defp pattern(path) do
    {path, star} =
      if String.ends_with?(path, "*"),
        do: {String.trim_trailing(path, "*"), true},
        else: {path, false}

    ["" | segments] = String.split(path, "/")
    {segments, star}
  end

  # Two last segments that each end with `*` meet where either is `{}` or one is a prefix
  # of the other. A last segment ending with `*` and a whole segment of the other pattern
  # meet where that segment matches a segment that starts with the prefix.
  defp meet?({[a], true}, {[b], true}),
    do: a == "{}" or b == "{}" or String.starts_with?(a, b) or String.starts_with?(b, a)

  defp meet?({[a], true}, {[b | _], _star}), do: prefix_meets?(a, b)
  defp meet?({[a | _], _star}, {[b], true}), do: prefix_meets?(b, a)
  defp meet?({[], false}, {[], false}), do: true

  defp meet?({[a | rest_a], star_a}, {[b | rest_b], star_b}) do
    segment_meets?(a, b) and meet?({rest_a, star_a}, {rest_b, star_b})
  end

  defp meet?(_a, _b), do: false

  # The prefix of a last segment that ends with `*`, and a whole segment pattern of the
  # other path.
  defp prefix_meets?("{}", segment), do: segment != ""
  defp prefix_meets?(_prefix, "{}"), do: true
  defp prefix_meets?(prefix, segment), do: String.starts_with?(segment, prefix)

  defp segment_meets?("{}", b), do: b != ""
  defp segment_meets?(a, "{}"), do: a != ""
  defp segment_meets?(a, b), do: a == b

  @doc false
  # run_access/1 is the access level of the run of the queue `dispatch_run`: its harness
  # walk's. With the workflow model, the lower of the walk's and the stage entry's, and
  # for a run of a stage that shares one run, the highest level of the stage's entries,
  # each no higher than its workflow resolves (`Apiary.Stages.run_access/2`). A harness
  # that reads for every workflow keeps the run at `:read`, whatever its stage: a
  # prebuild, a run with no walk, and a run whose walk is the built-in harness of a test
  # work item (`Apiary.Harnesses.Builtin`), which reads only. The claim computes the level
  # once, for the run's documents and its work entry (`Apiary.Dispatches.Handover`), and
  # Cancel run reads it for a run the claim recorded no level for (`Apiary.Runs.Cancel`).
  @spec run_access(DispatchRun.t()) :: :read | :write_no_push | :write
  def run_access(%DispatchRun{step: @prebuild}), do: :read

  def run_access(%DispatchRun{id: id} = dispatch_run) do
    walk =
      Repo.one(
        from h in RunHarness,
          where: h.dispatch_run_id == ^id,
          select: %{level: h.access_level, origin: h.origin}
      )

    case walk do
      nil -> :read
      %{origin: :builtin} -> :read
      %{level: level} -> Apiary.Stages.run_access(level, dispatch_run)
    end
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
        listed_row(row)
    end
  end

  defp listed(_run, _purpose), do: nil

  defp listed_row(%RunCredential{} = row) do
    %{
      name: row.name,
      entry: listed_entry(row),
      hosts: ApplyTemplates.hosts(row.apply),
      row: row
    }
  end

  @doc false
  # harness/1 is the harness entries of `run`, as `work/1` is the work entry, with
  # `purpose` `harness`, in the order of their names; `[]` for none.
  @spec harness(map | nil) :: [
          %{
            name: String.t(),
            entry: Jason.OrderedObject.t(),
            hosts: [String.t()],
            row: RunCredential.t()
          }
        ]
  def harness(%{id: run_id}) when is_binary(run_id) do
    from(c in RunCredential,
      where: c.run_id == ^run_id and c.purpose == :harness,
      order_by: [asc: c.name]
    )
    |> Repo.all()
    |> Enum.map(&listed_row/1)
  end

  def harness(_run), do: []

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
