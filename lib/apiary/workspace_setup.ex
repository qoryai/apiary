defmodule Apiary.WorkspaceSetup do
  # What the set-up reads: the steps of the set-up flow (`flow/0`), each done by its rule
  # here, and the state of a workspace's test run. The set-up page
  # (`ApiaryWeb.WorkspaceSetupLive`) reads them.
  #
  # The flow's steps, in order: Name, Work sources, Destinations, Model, Harness, Machines
  # and Test run. Every step after Name is not done while the workspace does not exist. A
  # step is done by its rule:
  #
  #   * `name?/1`: the workspace exists;
  #   * `sources?/2`: a row of the workspace's work-source tick list is ticked: a
  #     collection of the list (`collections/3`, `:sources`) assigned to the workspace
  #     with its Backlog on;
  #   * `destinations?/2`: a row of the workspace's destination tick list is ticked: a
  #     collection of the list (`collections/3`, `:destinations`) assigned to the
  #     workspace;
  #   * `model_key?/1`: the workspace's model choice (level 5), whose model provider
  #     reaches the workspace and has at least one key. The runtime is checked when the
  #     choice is saved, so the rule resolves none;
  #   * `harness?/1`: the workspace has a saved harness choice (`Apiary.Stacks.choice/1`),
  #     or has none and its organisation shares a harness (`Apiary.Stacks.shared/1`);
  #   * Machines: `machines/1` finds a ready pool. The step reads the pools that serve the
  #     workspace's runs, each with its state, and for a pool that is not ready the reason
  #     (`pools/1`, `t:pool_line/0`). A pool the step makes for the workspace has the
  #     name `pool_name/1`;
  #   * `test?/1`: the edition's `test_run_passed?/1`.
  #
  # The edition has four rules of the set-up: `c:Apiary.Edition.work_source_ready/1`,
  # `c:Apiary.Edition.machines_ready/1`, `c:Apiary.Edition.model_key_ready?/1` and
  # `c:Apiary.Edition.test_run_passed?/1`, which may count what serves the workspace from
  # another organisation. The core's edition answers with the functions here:
  #
  #   * `work_source/1`: the live collections assigned to the workspace, of a connection
  #     of its organisation that is connected and that an adapter's listing has named
  #     (`listed_at`), of an adapter in use, counted per adapter;
  #   * `machines/1`: a node pool that serves the workspace's runs, with an active key,
  #     and the gateway its choice resolves to, with an active key too
  #     (`Apiary.Gateways.resolve/1`). The pools that serve them (`serving_pools/1`) are
  #     the workspace's pools in use, or, while it has none, the instance's pool, as a
  #     claim takes them (`Apiary.Dispatches.no_pool_in_use/0`);
  #   * `model_key?/1`, the Model step's rule too: on the chain of model choices that
  #     resolves for the workspace's runs (`Apiary.ModelChoices.chain_owner/1`), a choice
  #     that a run reads with a model provider that has at least one key: for the
  #     organisation's chain, the workspace's choice (level 5,
  #     `Apiary.ModelChoices.ModelChoice`), whose provider reaches the workspace; for an
  #     operator's chain, the operator's default (level 6), the one level a run reads of
  #     it, and a provider of the operator's with a key;
  #   * `test_passed?/1`: a run of one of the workspace's test work items
  #     (`Apiary.WorkItems.take_in_test/2`) that ended by its exit, `run_ended`, with its
  #     registered run `completed`.
  #
  # `test_run/2` is the state of the latest test work item's latest run, for the step's
  # line. `collections/3` is the rows of the tick lists of Work sources and Destinations,
  # to a person who may read the instance's adapters, and `tick/5` one tick or untick of
  # a row, which no page calls. `cards/4` is the cards of the set-up's steps Work sources
  # and Destinations, one per grant, and `card/5` one of them, for the chooser, to a
  # person who may read the instance's adapters; `all?/3` is whether a card's grant is set
  # to All for the workspace. `tick/5` changes a collection through
  # `Apiary.Adapters.Collections`, which checks access. None of the others checks access:
  # the page's reader reads them.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  import Ecto.Query, warn: false

  alias Apiary.{Access, AccessKeys, Adapters, Edition, Gateways, ModelChoices, Repo, Stacks}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Collection, Collections, Connection, Grant, GrantRule}
  alias Apiary.Connections.Connection, as: ModelProvider
  alias Apiary.Connections.ConnectionWorkspace
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.ModelChoices.ModelChoice
  alias Apiary.Nodes.{Installed, Node}
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Runs.Run
  alias Apiary.Secrets.Value
  alias Apiary.WorkItems.WorkItem

  # How long the test run may wait for a machine before the step says so.
  @machine_wait_seconds 300

  # The steps of the set-up flow, in order. A step is one entry here, its rule in
  # `done?/3`, and its page (`ApiaryWeb.WorkspaceSetupLive`).
  @flow [:name, :sources, :destinations, :model, :harness, :machines, :test]

  @typedoc "A step of the set-up flow (`flow/0`)."
  @type step :: :name | :sources | :destinations | :model | :harness | :machines | :test

  @typedoc """
  A row of a tick list (`collections/3`): a live collection with its connection, and the
  workspace it is assigned to, nil for none.
  """
  @type tick_row :: %{
          collection: Collection.t(),
          connection: Connection.t(),
          workspace: Workspace.t() | nil
        }

  @typedoc """
  A card of the Work sources or Destinations step (`cards/4`): a live grant of a
  connection of the organisation, with its connection and its adapter; how many live
  collections of the grant the step's list has (`total`), and how many of them are chosen
  for the workspace (`chosen`), as `ticked?/3` counts them; and the grant's rule
  (`Apiary.Adapters.GrantRule`), with its workspace, nil for none.
  """
  @type card :: %{
          grant: Grant.t(),
          connection: Connection.t(),
          adapter: Node.t(),
          total: non_neg_integer,
          chosen: non_neg_integer,
          rule: GrantRule.t() | nil
        }

  @typedoc "An adapter whose collections are assigned to the workspace, with how many."
  @type source :: %{adapter: Node.t(), collections: pos_integer}

  @typedoc "A node pool that serves the workspace's runs, and its gateway."
  @type machines :: %{pool: Node.t(), gateway: Node.t()}

  @typedoc """
  A line of the Machines step (`pools/1`): a node pool that serves the workspace's runs,
  nil where the instance has no pool; `instance`, whether it is the instance's pool; and
  its state: `{:ready, gateway}`, or `{:not_ready, reason}`, where `reason` is the first
  of these that holds:

  - `:no_pool`: no pool serves the workspace's runs;
  - `:no_active_key`: the pool has no active access key;
  - `:direct`: the pool's gateway choice is Direct: its runs go through no gateway;
  - `:no_gateway`: no gateway exists for the pool's choice: no default gateway resolves,
    or the named gateway is deleted or gone;
  - `:gateway_not_serving`: the named gateway exists, and the pool's runs may not go
    through it: it may not serve the pool's workspace, or, for the instance's pool, it is
    not the instance's gateway;
  - `:gateway_without_key`: the gateway its choice resolves to has no active access key.
  """
  @type pool_line :: %{
          pool: Node.t() | nil,
          instance: boolean,
          state: {:ready, Node.t()} | {:not_ready, not_ready_reason}
        }

  @typedoc "Why a line of the Machines step is not ready (`t:pool_line/0`)."
  @type not_ready_reason ::
          :no_pool
          | :no_active_key
          | :direct
          | :no_gateway
          | :gateway_not_serving
          | :gateway_without_key

  @typedoc """
  The latest test run: `:waiting` for a machine, `:running` once claimed, `:passed`, or
  `{:failed, cause}`: `:no_machine` (it waited more than 5 minutes), `:model_key_missing`
  (its gateway refused it for a missing model key), `:silent` (lost: no word from it for
  10 minutes), `:ended` (its run ended in any other way: the run's preparation
  (`Apiary.Runs.Preparation`) and end say why), or `:no_run` (it ended before a claim
  registered a run). `run` is the run its claim registered, nil before.
  """
  @type test_run :: %{
          state:
            :waiting
            | :running
            | :passed
            | {:failed, :no_machine | :model_key_missing | :silent | :ended | :no_run},
          work_item: WorkItem.t(),
          dispatch_run: DispatchRun.t(),
          run: Run.t() | nil
        }

  @doc false
  # machine_wait_seconds/0 is how long a test run waits for a machine before its step says
  # that none has taken it.
  @spec machine_wait_seconds() :: pos_integer
  def machine_wait_seconds, do: @machine_wait_seconds

  ## The flow

  @doc false
  # flow/0 is the ids of the set-up flow's steps, in order.
  @spec flow() :: [step]
  def flow, do: @flow

  @doc false
  # done?/3 is whether `step` is done, by its rule, for `organisation`, a workspace of the
  # type `domain` (`Apiary.Lingo.Domain`), and `workspace`, nil before it exists. Every
  # step after Name is not done while the workspace does not exist.
  @spec done?(step, Organisation.t(), {module, Workspace.t() | nil}) :: boolean
  def done?(:name, _organisation, {_domain, workspace}), do: name?(workspace)
  def done?(_step, _organisation, {_domain, nil}), do: false
  def done?(:sources, _organisation, {domain, workspace}), do: sources?(workspace, domain)

  def done?(:destinations, _organisation, {domain, workspace}),
    do: destinations?(workspace, domain)

  def done?(:model, _organisation, {_domain, workspace}), do: model_key?(workspace)
  def done?(:harness, _organisation, {_domain, workspace}), do: harness?(workspace)
  def done?(:machines, _organisation, {_domain, workspace}), do: machines(workspace) != nil
  def done?(:test, _organisation, {_domain, workspace}), do: test?(workspace)

  @doc false
  # connected_ids/3 is the ids of the adapters in use with items (`:items`) or with
  # `targets` true (`:targets`) that serve `domain` and that `organisation` has a
  # connected connection of.
  @spec connected_ids(Organisation.t(), module, :items | :targets) :: MapSet.t(Ecto.UUID.t())
  def connected_ids(%Organisation{id: organisation_id}, domain, role),
    do:
      organisation_id
      |> connected_adapters(domain, role)
      |> select([_k, n], n.id)
      |> Repo.all()
      |> MapSet.new()

  defp connected_adapters(organisation_id, domain, role) do
    name = domain.name()

    from(k in Connection,
      join: n in Node,
      on: n.id == k.adapter_id,
      where: k.organisation_id == ^organisation_id,
      where: k.state == :connected and is_nil(k.ended_at),
      where: n.kind == :adapter and is_nil(n.deleted_at),
      where: is_nil(n.domains) or ^name in n.domains
    )
    |> where_role(role)
  end

  defp where_role(query, :items), do: where(query, [_k, n], n.items)
  defp where_role(query, :targets), do: where(query, [_k, n], n.targets == true)

  @doc false
  # name?/1 is whether the workspace exists.
  @spec name?(Workspace.t() | nil) :: boolean
  def name?(workspace), do: match?(%Workspace{}, workspace)

  @doc false
  # sources?/2 is whether a row of the work-source tick list of `workspace` of the type
  # `domain` is ticked: a collection of the list (`collections/3`, `:sources`) assigned to
  # `workspace` with its Backlog on.
  @spec sources?(Workspace.t(), module) :: boolean
  def sources?(%Workspace{id: workspace_id, organisation_id: organisation_id}, domain) do
    organisation_id
    |> list_query(domain, :sources)
    |> where([c], c.workspace_id == ^workspace_id and c.backlog)
    |> Repo.exists?()
  end

  @doc false
  # source_names/2 is the names of the adapters whose collections `sources?/2` counts for
  # the scope's workspace of the type `domain`: on the work-source list, assigned to the
  # workspace, with their Backlog on. Each name once, in alphabetical order. `[]` to a
  # person whom the tick list shows no row (`collections/3`: `adapter.read`).
  @spec source_names(Scope.t(), module) :: [String.t()]
  def source_names(%Scope{workspace: %Workspace{id: workspace_id}} = scope, domain) do
    if Access.can?(scope, :"adapter.read", scope.organisation) do
      scope.organisation.id
      |> list_query(domain, :sources)
      |> where([c], c.workspace_id == ^workspace_id and c.backlog)
      |> select([_c, _k, n], n.name)
      |> distinct(true)
      |> order_by([_c, _k, n], asc: n.name)
      |> Repo.all()
    else
      []
    end
  end

  @doc false
  # destinations?/2 is whether a row of the destination tick list of `workspace` of the
  # type `domain` is ticked: a collection of the list (`collections/3`, `:destinations`)
  # assigned to `workspace`.
  @spec destinations?(Workspace.t(), module) :: boolean
  def destinations?(%Workspace{id: workspace_id, organisation_id: organisation_id}, domain) do
    organisation_id
    |> list_query(domain, :destinations)
    |> where([c], c.workspace_id == ^workspace_id)
    |> Repo.exists?()
  end

  @doc false
  # destination_names/2 is the titles of the collections `destinations?/2` counts for the
  # scope's workspace of the type `domain`, in the order of the destination tick list
  # (`collections/3`). `[]` to a person whom the tick list shows no row (`adapter.read`).
  @spec destination_names(Scope.t(), module) :: [String.t()]
  def destination_names(%Scope{workspace: %Workspace{id: workspace_id}} = scope, domain) do
    if Access.can?(scope, :"adapter.read", scope.organisation) do
      scope.organisation.id
      |> list_query(domain, :destinations)
      |> where([c], c.workspace_id == ^workspace_id)
      |> order_by([c, _k, n],
        asc: fragment("lower(?)", n.name),
        asc: n.id,
        asc: fragment("lower(?)", c.title),
        asc: c.id
      )
      |> select([c], c.title)
      |> Repo.all()
    else
      []
    end
  end

  @doc false
  # harness?/1 is whether `workspace` has a saved harness choice, or its organisation
  # shares a harness that the workspace takes.
  @spec harness?(Workspace.t()) :: boolean
  def harness?(%Workspace{} = workspace),
    do:
      Stacks.choice(workspace) != nil or
        Stacks.shared(%Organisation{id: workspace.organisation_id}) != nil

  @doc false
  # test?/1 is whether the edition counts a test run of `workspace` that passed
  # (`c:Apiary.Edition.test_run_passed?/1`).
  @spec test?(Workspace.t()) :: boolean
  def test?(%Workspace{} = workspace), do: Edition.test_run_passed?(workspace)

  ## The tick lists

  @doc false
  # collections/3 is the rows of a tick list for `domain`, a workspace's type, grouped by
  # adapter, by the adapter's name, then by title: the live collections of the scope's organisation,
  # of a connection that is connected, of an adapter in use that serves `domain`, each with
  # its connection and the workspace it is assigned to. For `:sources`, the collections
  # with items of an adapter with items; for `:destinations`, the collections with a
  # target of an adapter with `targets` true. `[]` to a person who may not read the
  # instance's adapters in the organisation (`adapter.read`).
  @spec collections(Scope.t(), module, :sources | :destinations) :: [{Node.t(), [tick_row]}]
  def collections(
        %Scope{organisation: %Organisation{id: organisation_id} = organisation} = scope,
        domain,
        list
      ) do
    if Access.can?(scope, :"adapter.read", organisation) do
      from([c, k, n] in list_query(organisation_id, domain, list),
        left_join: w in Workspace,
        on: w.id == c.workspace_id,
        order_by: [
          asc: fragment("lower(?)", n.name),
          asc: n.id,
          asc: fragment("lower(?)", c.title),
          asc: c.id
        ],
        select: {n, %{collection: c, connection: k, workspace: w}}
      )
      |> Repo.all()
      |> Enum.chunk_by(fn {adapter, _row} -> adapter.id end)
      |> Enum.map(fn [{adapter, _row} | _rest] = rows ->
        {adapter, Enum.map(rows, &elem(&1, 1))}
      end)
    else
      []
    end
  end

  # The collections of a tick list (`collections/3`), as `[c, k, n]`: collection,
  # connection, adapter.
  defp list_query(organisation_id, domain, list) do
    name = domain.name()

    from(c in Collection,
      join: k in Connection,
      on: k.id == c.connection_id and k.organisation_id == c.organisation_id,
      join: n in Node,
      on: n.id == c.adapter_id,
      where: c.organisation_id == ^organisation_id and is_nil(c.ended_at),
      where: k.state == :connected and is_nil(k.ended_at),
      where: n.kind == :adapter and is_nil(n.deleted_at),
      where: is_nil(n.domains) or ^name in n.domains
    )
    |> where_list(list)
  end

  defp where_list(query, :sources), do: where(query, [c, _k, n], c.items and n.items)

  defp where_list(query, :destinations),
    do: where(query, [c, _k, n], n.targets == true and not is_nil(c.target_system))

  @doc false
  # ticked?/3 is whether `row` of the tick list `list` is ticked for `workspace`: a work
  # source while it is the workspace's with its Backlog on; a destination while it is the
  # workspace's.
  @spec ticked?(:sources | :destinations, tick_row, Workspace.t()) :: boolean
  def ticked?(:sources, %{collection: c}, %Workspace{id: id}),
    do: c.workspace_id == id and c.backlog

  def ticked?(:destinations, %{collection: c}, %Workspace{id: id}), do: c.workspace_id == id

  @doc false
  # tick/5 ticks or unticks the collection `collection_id` in the tick list `list` of
  # `workspace` of the type `domain`, on the list as it stands now (`collections/3`), not as
  # a page last showed it:
  #
  #   * ticking a work source assigns the collection and turns its Backlog on;
  #   * ticking a destination assigns it with its Backlog off, unless it is ticked as a
  #     work source;
  #   * unticking a work source turns its Backlog off, and unassigns a collection that is
  #     no destination;
  #   * unticking a destination turns its Backlog off and unassigns it.
  #
  # `{:error, :unlisted}` for a collection the list does not have, and
  # `{:error, :elsewhere}` for one in another workspace, which changes nothing: moving it
  # stays on the organisation's integration page. `Apiary.Adapters.Collections` returns
  # neither atom. Else the answer of
  # `Apiary.Adapters.Collections.assign_collections/4` and
  # `Apiary.Adapters.Collections.set_collection_backlog/4`: `{:error, :forbidden}` to a
  # person whom `collection.assign` or `collection.set_backlog` does not allow, and
  # `{:error, :not_found}` where the connection, the workspace or the collection ended
  # after the read.
  @spec tick(Scope.t(), Workspace.t(), module, :sources | :destinations, term) ::
          :ok | {:error, term}
  def tick(%Scope{} = scope, %Workspace{} = workspace, domain, list, collection_id) do
    found =
      scope
      |> collections(domain, list)
      |> Enum.find_value(fn {adapter, rows} ->
        Enum.find_value(rows, &(&1.collection.id == collection_id && {adapter, &1}))
      end)

    case found do
      nil ->
        {:error, :unlisted}

      {_adapter, %{workspace: %Workspace{id: id}}} when id != workspace.id ->
        {:error, :elsewhere}

      {adapter, row} ->
        toggle(scope, workspace, list, adapter, row)
    end
  end

  defp toggle(scope, workspace, list, adapter, %{collection: collection} = row) do
    here? = collection.workspace_id == workspace.id
    switch? = collection.items and Adapters.items?(adapter)
    destination? = adapter.targets == true and not is_nil(collection.target_system)

    case {list, ticked?(list, row, workspace)} do
      {:sources, false} ->
        with :ok <- if(here?, do: :ok, else: assign_row(scope, row, workspace)),
             do: if(switch?, do: backlog(scope, row, true), else: :ok)

      {:sources, true} ->
        with :ok <- if(switch?, do: backlog(scope, row, false), else: :ok),
             do: if(destination?, do: :ok, else: assign_row(scope, row, nil))

      {:destinations, false} ->
        with :ok <- if(here?, do: :ok, else: assign_row(scope, row, workspace)),
             do: if(switch? and not here?, do: backlog(scope, row, false), else: :ok)

      {:destinations, true} ->
        with :ok <- if(switch?, do: backlog(scope, row, false), else: :ok),
             do: assign_row(scope, row, nil)
    end
  end

  defp assign_row(scope, %{collection: collection, connection: connection}, workspace) do
    case Collections.assign_collections(scope, connection, [collection.id], workspace) do
      {:ok, _count} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp backlog(scope, %{collection: collection, connection: connection}, on) do
    case Collections.set_collection_backlog(scope, connection, collection.id, on) do
      {:ok, _count} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  ## The cards

  @doc false
  # cards/4 is the cards of the list `list` for `workspace` of the type `domain`: one per
  # live grant of a connection of the scope's organisation that is connected, of an
  # adapter in use that serves `domain` and has the list's role (items for `:sources`,
  # `targets` true for `:destinations`), by the adapter's name, then by the account's
  # title. `[]` to a person who may not read the instance's adapters in the organisation
  # (`adapter.read`).
  @spec cards(Scope.t(), module, :sources | :destinations, Workspace.t()) :: [card]
  def cards(scope, domain, list, workspace), do: read_cards(scope, domain, list, workspace, nil)

  @doc false
  # card/5 is the card among `cards/4`'s whose grant's public id is `public_id`; nil for
  # none.
  @spec card(Scope.t(), module, :sources | :destinations, Workspace.t(), term) :: card | nil
  def card(scope, domain, list, workspace, public_id) when is_binary(public_id) do
    if Apiary.PublicId.valid?(Grant.prefix(), public_id),
      do: scope |> read_cards(domain, list, workspace, public_id) |> List.first()
  end

  def card(_scope, _domain, _list, _workspace, _public_id), do: nil

  defp read_cards(
         %Scope{organisation: %Organisation{id: organisation_id} = organisation} = scope,
         domain,
         list,
         %Workspace{organisation_id: organisation_id} = workspace,
         public_id
       ) do
    if Access.can?(scope, :"adapter.read", organisation) do
      found =
        organisation_id
        |> grants_query(domain, list)
        |> then(&if(public_id, do: where(&1, [g], g.public_id == ^public_id), else: &1))
        |> Repo.all()

      ids = Enum.map(found, fn {grant, _k, _n} -> grant.id end)
      counts = card_counts(ids, list, workspace)

      rules =
        Repo.all(from r in GrantRule, where: r.grant_id in ^ids, preload: :workspace)
        |> Map.new(&{&1.grant_id, &1})

      for {grant, connection, adapter} <- found do
        {total, chosen} = Map.get(counts, grant.id, {0, 0})

        %{
          grant: %{grant | connection: connection, adapter: adapter},
          connection: connection,
          adapter: adapter,
          total: total,
          chosen: chosen,
          rule: Map.get(rules, grant.id)
        }
      end
    else
      []
    end
  end

  defp read_cards(_scope, _domain, _list, _workspace, _public_id), do: []

  # The live grants of the cards, as `{grant, connection, adapter}`.
  defp grants_query(organisation_id, domain, list) do
    name = domain.name()

    query =
      from g in Grant,
        join: k in Connection,
        on: k.id == g.connection_id and k.organisation_id == g.organisation_id,
        join: n in Node,
        on: n.id == k.adapter_id,
        where: g.organisation_id == ^organisation_id and is_nil(g.ended_at),
        where: k.state == :connected and is_nil(k.ended_at),
        where: n.kind == :adapter and is_nil(n.deleted_at),
        where: is_nil(n.domains) or ^name in n.domains,
        order_by: [
          asc: fragment("lower(?)", n.name),
          asc: n.id,
          asc: fragment("lower(coalesce(?, ''))", g.account_title),
          asc: g.id
        ],
        select: {g, k, n}

    case list do
      :sources -> where(query, [_g, _k, n], n.items)
      :destinations -> where(query, [_g, _k, n], n.targets == true)
    end
  end

  # How many live collections of each of the grants `ids` the list `list` has, and how
  # many of them are chosen for `workspace`, by grant id.
  defp card_counts([], _list, _workspace), do: %{}

  defp card_counts(ids, list, %Workspace{id: workspace_id}) do
    query =
      from c in Collection,
        where: c.grant_id in ^ids and is_nil(c.ended_at),
        group_by: c.grant_id

    case list do
      :sources ->
        from c in query,
          where: c.items,
          select:
            {c.grant_id,
             {count(c.id), filter(count(c.id), c.workspace_id == ^workspace_id and c.backlog)}}

      :destinations ->
        from c in query,
          where: not is_nil(c.target_system),
          select:
            {c.grant_id, {count(c.id), filter(count(c.id), c.workspace_id == ^workspace_id)}}
    end
    |> Repo.all()
    |> Map.new()
  end

  @doc false
  # all?/3 is whether the grant of `card` is set to All for `workspace` in the list
  # `list`: its rule is the workspace's, chosen in Work sources for `:sources`, in either
  # list for `:destinations`, since every work source is also a destination.
  @spec all?(card, :sources | :destinations, Workspace.t()) :: boolean
  def all?(%{rule: %GrantRule{workspace_id: id, backlog: backlog}}, list, %Workspace{id: id}),
    do: list == :destinations or backlog

  def all?(_card, _list, _workspace), do: false

  ## The edition's rules, as the core's edition answers them

  @doc false
  # work_source/1 is each adapter in use with live collections assigned to `workspace` of
  # a connection that is connected and listed, with how many, by the adapter's name.
  @spec work_source(Workspace.t()) :: [source]
  def work_source(%Workspace{id: workspace_id, organisation_id: organisation_id}) do
    from(c in Collection,
      join: k in Connection,
      on: k.id == c.connection_id and k.organisation_id == c.organisation_id,
      join: n in Node,
      on: n.id == c.adapter_id,
      where: c.organisation_id == ^organisation_id and c.workspace_id == ^workspace_id,
      where: is_nil(c.ended_at),
      where: k.state == :connected and is_nil(k.ended_at) and not is_nil(k.listed_at),
      where: n.kind == :adapter and is_nil(n.deleted_at),
      group_by: n.id,
      order_by: [asc: fragment("lower(?)", n.name), asc: n.id],
      select: %{adapter: n, collections: count(c.id)}
    )
    |> Repo.all()
  end

  @doc false
  # machines/1 is the first node pool that serves `workspace`'s runs with an active key
  # and whose choice resolves to a gateway with an active key, with that gateway; nil for
  # none.
  @spec machines(Workspace.t()) :: machines | nil
  def machines(%Workspace{} = workspace) do
    workspace
    |> serving_pools()
    |> Enum.find_value(fn pool ->
      case pool_state(pool) do
        {:ready, gateway} -> %{pool: pool, gateway: gateway}
        {:not_ready, _reason} -> nil
      end
    end)
  end

  @doc false
  # pools/1 is the lines of the Machines step: each node pool that serves `workspace`'s
  # runs (`serving_pools/1`), with its state, by the rule of `machines/1`. Where the
  # workspace has no pool in use and the instance has none either, one line: the
  # instance's pool, not ready for `:no_pool`.
  @spec pools(Workspace.t()) :: [pool_line]
  def pools(%Workspace{} = workspace) do
    case serving_pools(workspace) do
      [] ->
        [%{pool: nil, instance: true, state: {:not_ready, :no_pool}}]

      pools ->
        for pool <- pools,
            do: %{pool: pool, instance: is_nil(pool.workspace_id), state: pool_state(pool)}
    end
  end

  @doc false
  # instance_line/0 is the line of the instance's pool, with its state by the rule of
  # `machines/1`, whether it serves a workspace or not; not ready for `:no_pool` where the
  # instance has no pool.
  @spec instance_line() :: pool_line
  def instance_line do
    case Repo.one(Installed.live_query(:pool)) do
      nil -> %{pool: nil, instance: true, state: {:not_ready, :no_pool}}
      pool -> %{pool: pool, instance: true, state: pool_state(pool)}
    end
  end

  # A pool is ready with an active key and a choice that resolves to a gateway with an
  # active key; else not ready, for the first reason of `t:not_ready_reason/0` that holds.
  # `Gateways.resolve/1` returns `:gateway_key` for a gateway alone, never for a pool.
  defp pool_state(pool) do
    with {:key, true} <- {:key, AccessKeys.active_key?(pool)},
         {:gateway, gateway} <- Gateways.resolve(pool) do
      {:ready, gateway}
    else
      {:key, false} -> {:not_ready, :no_active_key}
      :direct -> {:not_ready, :direct}
      {:error, :no_default_gateway} -> {:not_ready, :no_gateway}
      {:error, :gateway_not_serving} -> {:not_ready, named_gateway_reason(pool)}
      {:error, :gateway_without_key} -> {:not_ready, :gateway_without_key}
    end
  end

  # `Gateways.resolve/1` returns `:gateway_not_serving` for a named gateway that is
  # deleted or gone too: then no gateway exists for the pool's choice.
  defp named_gateway_reason(%Node{gateway_id: nil}), do: :no_gateway

  defp named_gateway_reason(%Node{gateway_id: id}) do
    case Repo.get(Node, id) do
      %Node{deleted_at: nil} -> :gateway_not_serving
      _deleted_or_gone -> :no_gateway
    end
  end

  @doc false
  # instance_pool?/1 is whether the instance's pool serves `workspace`'s runs: whether the
  # workspace has no node pool in use.
  @spec instance_pool?(Workspace.t()) :: boolean
  def instance_pool?(%Workspace{} = workspace),
    do: not Repo.exists?(workspace_pools(workspace))

  @doc false
  # serving_pools/1 is the node pools that serve `workspace`'s runs: the workspace's pools
  # in use, oldest first, or the instance's pool while it has none; `[]` where neither is.
  @spec serving_pools(Workspace.t()) :: [Node.t()]
  def serving_pools(%Workspace{} = workspace) do
    case Repo.all(workspace_pools(workspace)) do
      [] -> List.wrap(Repo.one(Installed.live_query(:pool)))
      pools -> Enum.map(pools, &%{&1 | workspace: workspace})
    end
  end

  defp workspace_pools(%Workspace{id: workspace_id}) do
    from n in Node,
      where: n.workspace_id == ^workspace_id and n.kind == :pool and is_nil(n.deleted_at),
      order_by: [asc: n.inserted_at, asc: n.id]
  end

  # The longest node name, in code points: the database's `nodes_name_check` counts with
  # `char_length`. `Apiary.Nodes.Node` allows 80 graphemes, and a grapheme has 1 code
  # point or more.
  @pool_name_max 80

  @doc false
  # pool_name/1 is the name of the pool the Machines step makes for `workspace`: its name,
  # cut to the whole graphemes that fit in 80 code points, then trailing whitespace trimmed.
  @spec pool_name(Workspace.t()) :: String.t()
  def pool_name(%Workspace{name: name}) do
    name
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn grapheme, {kept, count} ->
      count = count + length(String.codepoints(grapheme))

      if count <= @pool_name_max,
        do: {:cont, {[grapheme | kept], count}},
        else: {:halt, {kept, count}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join()
    |> String.trim_trailing()
  end

  @doc false
  # model_key?/1 is whether the chain of model choices that resolves for `workspace`'s runs
  # has a choice a run reads with a model provider that has a key: on the organisation's
  # chain, the workspace's choice (level 5), whose provider reaches the workspace; on an
  # operator's, the operator's default (level 6), and a provider of that chain with a key.
  # False on an operator's chain whose operator the edition does not name.
  @spec model_key?(Workspace.t()) :: boolean
  def model_key?(%Workspace{organisation_id: organisation_id} = workspace) do
    case ModelChoices.chain_owner(organisation_id) do
      {_chain, nil} ->
        false

      {"operator", owner_id} ->
        Repo.exists?(provider_with_key("operator", owner_id)) and
          Repo.exists?(operator_default(owner_id))

      {chain, owner_id} ->
        Repo.exists?(workspace_choice(chain, owner_id, workspace))
    end
  end

  @doc false
  # model_name/1 is the model of the choice `model_key?/1` counts for the scope's
  # workspace, as the Model step shows it chosen (`Apiary.ModelChoices.shown_model/2`), for
  # a person who may read the choices of that chain as the step reads them
  # (`Apiary.ModelChoices.list_choices/2`: the features, `connection.read`, and for the
  # operator's chain `c:Apiary.Edition.operator_chain_writer?/1`); else nil, as without a
  # choice.
  @spec model_name(Scope.t()) :: String.t() | nil
  def model_name(
        %Scope{workspace: %Workspace{organisation_id: organisation_id} = workspace} = scope
      ) do
    query =
      case ModelChoices.chain_owner(organisation_id) do
        {_chain, nil} ->
          nil

        {chain, owner_id} ->
          if readable_chain?(scope, chain), do: chain_choice(chain, owner_id, workspace)
      end

    with %Ecto.Query{} <- query,
         {%ModelChoice{model_id: model_id}, %ModelProvider{} = provider} <-
           query
           |> join(:inner, [m], p in ModelProvider, on: p.id == m.connection_id)
           |> select([m, ..., p], {m, p})
           |> limit(1)
           |> Repo.one() do
      ModelChoices.shown_model(provider, model_id)
    else
      _none -> nil
    end
  end

  defp readable_chain?(scope, chain),
    do: match?({:ok, _choices}, ModelChoices.list_choices(scope, chain))

  defp chain_choice("operator", owner_id, _workspace), do: operator_default(owner_id)
  defp chain_choice(chain, owner_id, workspace), do: workspace_choice(chain, owner_id, workspace)

  # The model providers of `chain` of the organisation `owner_id` that have a key.
  defp provider_with_key(chain, owner_id) do
    from c in ModelProvider,
      join: v in Value,
      on: v.secret_id == c.secret_id,
      where: c.organisation_id == ^owner_id and not is_nil(c.provider_kind),
      where: c.chain == ^chain
  end

  # The operator's default (level 6) on the operator's chain, of the organisation
  # `owner_id`.
  defp operator_default(owner_id) do
    from m in ModelChoice,
      where: m.organisation_id == ^owner_id and m.chain == "operator",
      where: is_nil(m.workspace_id) and is_nil(m.target_id) and is_nil(m.workflow)
  end

  # The choice of `workspace` (level 5) on `chain` of the organisation `owner_id`, whose
  # model provider has a key and applies to every workspace or lists `workspace`.
  defp workspace_choice(chain, owner_id, %Workspace{id: workspace_id}) do
    from m in ModelChoice,
      join: c in ModelProvider,
      on: c.id == m.connection_id,
      join: v in Value,
      on: v.secret_id == c.secret_id,
      left_join: w in ConnectionWorkspace,
      on: w.connection_id == c.id and w.workspace_id == ^workspace_id,
      where: m.organisation_id == ^owner_id and m.workspace_id == ^workspace_id,
      where: is_nil(m.target_id) and is_nil(m.workflow) and m.chain == ^chain,
      where: c.organisation_id == ^owner_id and not is_nil(c.provider_kind),
      where: c.chain == ^chain,
      where: c.applies_to == "all" or not is_nil(w.workspace_id)
  end

  @doc false
  # test_passed?/1 is whether a run of a test work item of `workspace` ended by its exit
  # with its registered run completed.
  @spec test_passed?(Workspace.t()) :: boolean
  def test_passed?(%Workspace{id: workspace_id, organisation_id: organisation_id}) do
    Repo.exists?(
      from d in DispatchRun,
        join: w in WorkItem,
        on: w.id == d.work_item_id,
        join: r in Run,
        on: r.dispatch_run_id == d.id,
        where: w.organisation_id == ^organisation_id and w.workspace_id == ^workspace_id,
        where: w.test and d.state == :ended and d.end_cause == :run_ended,
        where: r.state == "completed"
    )
  end

  ## The test run

  @doc false
  # test_run/2 is the latest run of `workspace`'s latest test work item, read at `now`,
  # with its state (`t:test_run/0`); nil while the workspace has no test work item.
  @spec test_run(Workspace.t(), DateTime.t()) :: test_run | nil
  def test_run(%Workspace{id: workspace_id, organisation_id: organisation_id}, now) do
    work_item =
      Repo.one(
        from w in WorkItem,
          where: w.organisation_id == ^organisation_id and w.workspace_id == ^workspace_id,
          where: w.test,
          order_by: [desc: w.number],
          limit: 1
      )

    dispatch_run =
      work_item &&
        Repo.one(
          from d in DispatchRun,
            where: d.work_item_id == ^work_item.id,
            order_by: [desc: d.take_in, desc: d.attempt],
            limit: 1,
            preload: [run: :node]
        )

    if dispatch_run do
      %{
        state: test_state(dispatch_run, dispatch_run.run, now),
        work_item: work_item,
        dispatch_run: dispatch_run,
        run: dispatch_run.run
      }
    end
  end

  defp test_state(%DispatchRun{state: :waiting, queued_at: queued_at}, _run, now) do
    if DateTime.diff(now, queued_at, :second) > @machine_wait_seconds,
      do: {:failed, :no_machine},
      else: :waiting
  end

  defp test_state(%DispatchRun{state: state}, _run, _now) when state in [:claimed, :handed_over],
    do: :running

  defp test_state(%DispatchRun{end_cause: :run_ended}, %Run{state: "completed"}, _now),
    do: :passed

  defp test_state(%DispatchRun{end_cause: :run_refused, end_detail: "model_key_missing"}, _, _),
    do: {:failed, :model_key_missing}

  defp test_state(%DispatchRun{end_cause: :lost}, %Run{silenced_at: %DateTime{}}, _now),
    do: {:failed, :silent}

  defp test_state(_dispatch_run, %Run{}, _now), do: {:failed, :ended}
  defp test_state(_dispatch_run, nil, _now), do: {:failed, :no_run}
end
