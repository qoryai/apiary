defmodule ApiaryWeb.NodeComponents do
  @moduledoc """
  What the Nodes list and a node's page say alike (`docs/ui.md`, Nodes): a node's state in
  words, from what it is doing (`Apiary.Nodes.activity/3`), and the sentence that says what
  an instance is. And what a node's page's two LiveViews share: its header
  (`node_header/1`) and its tabs (`node_tabs/1`), Overview, Access key and Settings. And
  what the two places that give a person the command that connects a machine share, the
  Access key tab's command page and the workspace overview's first-run box: the command
  (`enrol_command/3`), and the notice that machines can't reach a loopback address
  (`unreachable_server/1`). And what a node that chose a gateway is told wherever it is
  told how to connect: the gateway its runs go through, at its URL (`through_gateway/1`).
  And what the pages say of a gateway wherever it lives: where its page is
  (`gateway_path/2`), its name, with its organisation's where that is not the node's
  (`gateway_name/2`), whether the console offers gateways at the organisation
  (`organisation_gateways?/0`), and who uses an organisation's gateway now
  (`using_words/2`).

  A node's state is never Online or Offline. A Node says "Running" while its instance
  runs; a pool says how many of its instances run, against its limit when it has one
  ("3 of 10 running", "3 running"). One that runs nothing says when an instance of it was
  last seen, or, with no instance left, when one of its keys was last used, ticking in the
  browser (`seen_at/1`), or "Never seen".
  """
  use ApiaryWeb, :html

  alias Apiary.Accounts.Scope
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Organisation
  alias ApiaryWeb.People

  attr :id, :string, required: true
  attr :node, Node, required: true
  attr :activity, :map, required: true, doc: "the node's `t:Apiary.Nodes.activity/0`"
  attr :class, :any, default: nil

  @doc "node_state/1 is a node's state in words: running, last seen, or never seen."
  def node_state(assigns) do
    ~H"""
    <span id={@id} class={@class}>
      <%= cond do %>
        <% @activity.running != [] -> %>
          <span class="q-sdot q-sdot-running">
            <i aria-hidden="true"></i><span>{running_words(@node, length(@activity.running))}</span>
          </span>
        <% seen = seen_at(@activity) -> %>
          {gettext("Last seen")}
          <.relative_time id={"#{@id}-seen"} at={seen} />
        <% true -> %>
          <span class="text-faint">{gettext("Never seen")}</span>
      <% end %>
    </span>
    """
  end

  @doc """
  seen_at/1 is when a node was last seen, from its `t:Apiary.Nodes.activity/0`: its
  instance seen last, or, when no instance is left (a pool's are pruned after a day), the
  last use of one of its keys, revoked ones too; nil when neither was.
  """
  @spec seen_at(map) :: DateTime.t() | nil
  def seen_at(%{last: %{last_seen_at: at}}), do: at
  def seen_at(%{used: %DateTime{} = at}), do: at
  def seen_at(_activity), do: nil

  @doc """
  running_words/2 is how many instances of `node` run, `count`, as its state says it:
  "Running" for a Node, "3 of 10 running" for a pool with a limit, "3 running" for one
  without.
  """
  @spec running_words(Node.t(), non_neg_integer) :: String.t()
  def running_words(%Node{kind: :node}, _count), do: gettext("Running")

  def running_words(%Node{instance_limit: nil}, count),
    do: gettext("%{running} running", running: Format.number(count))

  def running_words(%Node{instance_limit: limit}, count),
    do:
      gettext("%{running} of %{limit} running",
        running: Format.number(count),
        limit: Format.number(limit)
      )

  @doc """
  instance_sentence/0 is what every node's page says of an instance: a claim made under
  the node's key, never an identity.
  """
  @spec instance_sentence() :: String.t()
  def instance_sentence,
    do:
      gettext(
        "An instance is what Forager, run with this node's key, reports itself as, and anyone with the key can report any instance: a machine you want to cut off on its own needs a node of its own."
      )

  @doc """
  node_header/1 is the header of a node's page: its name, the page's `<h1>`; its public id
  beside it, and Default beside a gateway that is its workspace's default gateway; and one
  muted line, its kind, its state and who made it and when.
  """
  attr :node, Node, required: true
  attr :activity, :map, required: true, doc: "the node's `t:Apiary.Nodes.activity/0`"

  def node_header(assigns) do
    ~H"""
    <.page_header id="node-header" title={@node.name}>
      <:badge>
        <span id="node-public-id" class="q-mono text-[13px] font-normal text-muted">
          {@node.public_id}
        </span>
        <.badge :if={@node.kind == :gateway && @node.default_gateway} class="ml-2 font-normal">
          <span id="node-default">{gettext("Default")}</span>
        </.badge>
      </:badge>
      <:description>
        <span id="node-meta" class="inline-flex flex-wrap items-baseline gap-x-2 gap-y-1">
          <span id="node-kind">{kind_label(@node.kind)}</span>
          <span class="text-faint" aria-hidden="true">·</span>
          <.node_state id="node-state" node={@node} activity={@activity} />
          <span :if={@node.created_by} class="text-faint" aria-hidden="true">·</span>
          <span :if={@node.created_by} id="node-made">
            {gettext("made by %{person}, %{date}",
              person: People.email(@node.created_by),
              date: Format.day(@node.inserted_at)
            )}
          </span>
        </span>
      </:description>
    </.page_header>
    """
  end

  @doc """
  node_tabs/1 is a node's tabs: Overview, Access key, and Settings last, set apart. Overview
  and Settings are patches of `ApiaryWeb.NodeLive.Show`, Access key is
  `ApiaryWeb.NodeLive.AccessKey`'s: `view` names the LiveView the tabs are drawn in, so each
  tab of another is a navigation.
  """
  attr :node, Node, required: true
  attr :paths, :map, required: true, doc: "`overview`, `access_key` and `settings`"
  attr :current, :atom, required: true, values: [:overview, :access_key, :settings]
  attr :view, :atom, required: true, values: [:show, :access_key]

  def node_tabs(assigns) do
    ~H"""
    <.page_tabs id="node-tabs" label={kind_label(@node.kind)} current={@current}>
      <:tab
        key={:overview}
        patch={if @view == :show, do: @paths.overview}
        navigate={if @view != :show, do: @paths.overview}
        icon="hero-book-open"
      >
        {gettext("Overview")}
      </:tab>
      <:tab
        key={:access_key}
        patch={if @view == :access_key, do: @paths.access_key}
        navigate={if @view != :access_key, do: @paths.access_key}
        icon="hero-key"
      >
        {gettext("Access key")}
      </:tab>
      <:tab
        key={:settings}
        patch={if @view == :show, do: @paths.settings}
        navigate={if @view != :show, do: @paths.settings}
        icon="hero-cog-6-tooth"
        settings
      >
        {gettext("Settings")}
      </:tab>
    </.page_tabs>
    """
  end

  @doc """
  enrol_command/3 is the command that connects a machine: `qory access-key enrol`, this
  server's address and the code as the machine sends it. Only a page that shows the
  command once calls it, with the code it holds. With `replace: true`, for a node that has
  or had a key, it carries `--replace`, so that a machine already holding a key moves to
  the new one; qory enrols a machine without a key with it all the same.
  """
  @spec enrol_command(String.t(), String.t(), [{:replace, boolean}]) :: String.t()
  def enrol_command(server, code, opts \\ []) when is_binary(server) and is_binary(code) do
    if Keyword.get(opts, :replace, false),
      do: "qory access-key enrol --replace #{server} #{code}",
      else: "qory access-key enrol #{server} #{code}"
  end

  @doc """
  unreachable_server/1 is the notice a command's page shows when the server's address,
  which the command carries, is a loopback one (`loopback?/1`): no other machine reaches
  it, and `PUBLIC_URL` sets the one they use. Nothing where the address is any other.
  """
  attr :id, :string, required: true
  attr :url, :string, required: true, doc: "the server's address, as the command carries it"

  def unreachable_server(assigns) do
    ~H"""
    <div :if={loopback?(@url)} id={@id}>
      <.notice kind={:warning}>
        <strong>{gettext("Machines can't reach this address.")}</strong>
        {gettext(
          "%{url} works only on the computer Qory Apiary runs on. Set PUBLIC_URL to the address machines use, and the command will carry it.",
          url: @url
        )}
      </.notice>
    </div>
    """
  end

  @doc """
  loopback?/1 is whether `url`'s host is one only the computer it names reaches:
  `localhost`, a name under `.localhost`, or a loopback address, IPv4 (`127.0.0.0/8`), IPv6
  (`::1`) or IPv4 mapped into IPv6.
  """
  @spec loopback?(String.t()) :: boolean
  def loopback?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" ->
        host = host |> String.downcase() |> String.trim_trailing(".")
        host == "localhost" or String.ends_with?(host, ".localhost") or loopback_ip?(host)

      _no_host ->
        false
    end
  end

  defp loopback_ip?(host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      {:ok, {0, 0, 0, 0, 0, 0xFFFF, high, _low}} -> Bitwise.bsr(high, 8) == 127
      _other -> false
    end
  end

  @doc """
  through_gateway/1 is what a node's enrol instructions say of its choice of gateway
  (`Apiary.Gateways.chosen/1`), as the choice leads now: that its runs go through that
  gateway, named with its URL, and, while the gateway holds no active access key, that it
  isn't connected; for a node on Default gateway while no gateway is the default, only
  that. The enrol command and the Forager file are the same either way: they point at Qory
  Apiary. Nothing for a node that goes direct, a gateway, or a node whose named gateway is
  gone.
  """
  attr :id, :string, required: true
  attr :node, Node, required: true
  attr :gateway, :any, required: true, doc: "the gateway the node's runs go through, or nil"
  attr :connected, :boolean, required: true, doc: "whether the gateway holds an active key"

  def through_gateway(assigns) do
    assigns =
      assign(assigns,
        no_default:
          is_nil(assigns.gateway) and assigns.node.kind != :gateway and
            assigns.node.gateway_choice == :default
      )

    ~H"""
    <div :if={@gateway} id={@id}>
      <.notice kind={:info}>
        <.rich
          :if={@gateway.organisation_id == @node.organisation_id}
          text={
            rich_gettext(
              "Runs of %{name} go through the gateway %{gateway}, at %{url}.",
              name: @node.name,
              gateway: @gateway.name,
              url: {:m, @gateway.url}
            )
          }
        />
        <.rich
          :if={@gateway.organisation_id != @node.organisation_id}
          text={
            rich_gettext(
              "Runs of %{name} go through the gateway %{gateway} of %{organisation}, at %{url}.",
              name: @node.name,
              gateway: @gateway.name,
              organisation: organisation_name(@gateway),
              url: {:m, @gateway.url}
            )
          }
        />
        <span :if={!@connected} id={"#{@id}-unconnected"}>
          {gettext("%{gateway} has no active access key, so it isn't connected.",
            gateway: @gateway.name
          )}
        </span>
      </.notice>
    </div>
    <div :if={@no_default} id={@id}>
      <.notice kind={:info}>{gettext("No gateway is the default now.")}</.notice>
    </div>
    """
  end

  @doc """
  gateway_field/1 is the field of a node's or a pool's form that chooses its gateway,
  `node[gateway]`: Default gateway, offered only where `offer_default` (a default
  resolves for the workspace, or the node is on it already, which keeping asks nothing
  of); Direct; and each gateway the node may name, by name (`Apiary.Gateways.gateway_choices/1`,
  by level). Where the gateways are of more than one level, they are grouped by it: "This
  workspace", then each organisation by its name, the node's first. It shows the errors
  `Apiary.Nodes` gives `gateway_choice` and `gateway_id` once the form was sent.
  `choice_params/1` turns what it sends into those two fields.
  """
  attr :form, Phoenix.HTML.Form, required: true

  attr :gateways, :list,
    required: true,
    doc: "the gateways the node may name, by level, each with its organisation"

  attr :default, :any, required: true, doc: "the workspace's default gateway, or nil"
  attr :offer_default, :boolean, required: true
  attr :disabled, :boolean, default: false

  def gateway_field(assigns) do
    changeset = assigns.form.source
    choice = Ecto.Changeset.get_field(changeset, :gateway_choice)
    named = Ecto.Changeset.get_field(changeset, :gateway_id)
    ids = Enum.map(assigns.gateways, & &1.id)

    # A gateway the node names that is no longer among those it may name: kept as it is,
    # so that saving something else does not move the node.
    gone =
      if choice == :named and named not in ids,
        do: [{gettext("A gateway that is gone"), named || ""}],
        else: []

    options =
      if(assigns.offer_default, do: [{gettext("Default gateway"), "default"}], else: []) ++
        [{gettext("Direct"), "direct"}] ++ gateway_options(assigns.gateways) ++ gone

    errors =
      if changeset.action,
        do:
          for(
            {field, error} <- changeset.errors,
            field in [:gateway_choice, :gateway_id],
            do: ApiaryWeb.CoreComponents.translate_error(error)
          ),
        else: []

    assigns =
      assign(assigns,
        options: options,
        value: if(choice == :named, do: named || "", else: to_string(choice)),
        errors: errors,
        name: assigns.form[:gateway].name,
        input_id: assigns.form[:gateway].id
      )

    ~H"""
    <.input
      id={@input_id}
      name={@name}
      type="select"
      label={gettext("Gateway")}
      value={@value}
      options={@options}
      errors={@errors}
      hint={@default && default_hint(@default)}
      disabled={@disabled}
    />
    """
  end

  # The gateways a node may name, as the select offers them: by name, in one list while
  # they are all of one level, else in a group a level.
  defp gateway_options(gateways) do
    case Enum.chunk_by(gateways, &level_key/1) do
      [] ->
        []

      [one] ->
        Enum.map(one, &{&1.name, &1.id})

      levels ->
        Enum.map(levels, fn [first | _] = level ->
          {level_label(first), Enum.map(level, &{&1.name, &1.id})}
        end)
    end
  end

  defp level_key(%Node{workspace_id: nil, organisation_id: id}), do: {:organisation, id}
  defp level_key(%Node{workspace_id: id}), do: {:workspace, id}

  defp level_label(%Node{workspace_id: nil} = gateway), do: organisation_name(gateway)
  defp level_label(%Node{}), do: gettext("This workspace")

  defp default_hint(%Node{workspace_id: nil} = default),
    do:
      gettext(
        "On Default gateway, runs go through %{name}, the default for %{organisation}. On Direct, they go through no gateway.",
        name: default.name,
        organisation: organisation_name(default)
      )

  defp default_hint(%Node{} = default),
    do:
      gettext(
        "On Default gateway, runs go through %{name}, this workspace's default. On Direct, they go through no gateway.",
        name: default.name
      )

  @doc """
  choice_params/1 is a node's form's parameters with what `gateway_field/1` sent, `gateway`,
  turned into the fields `Apiary.Nodes` takes: `default` and `direct` as the
  `gateway_choice` they name, anything else as `named` with that `gateway_id`. Parameters
  without it are as they were.
  """
  @spec choice_params(map) :: map
  def choice_params(%{"gateway" => value} = params) when value in ["default", "direct"],
    do: params |> Map.delete("gateway") |> Map.put("gateway_choice", value)

  def choice_params(%{"gateway" => value} = params),
    do:
      params
      |> Map.delete("gateway")
      |> Map.merge(%{"gateway_choice" => "named", "gateway_id" => value})

  def choice_params(params), do: params

  # How many names or run ids a refusal to delete a gateway shows before "and N more".
  @shown 5

  @doc """
  in_use_words/3 is why a gateway was not deleted, from what
  `Apiary.Gateways.delete_blockers/1` answered: the nodes that point to it, and the runs
  going through it (`runs`, when the answer has them). Only the nodes and runs the reader
  may open are named, by name and by run id, the first #{@shown} of each, then
  "and N more", which counts the rest and those of any other workspace too. For a
  workspace's gateway, those are the ones of the scope's workspace; for an organisation's,
  `reached`, the ids of the workspaces the reader reaches (`reached_workspaces/1`), and
  the rest are counted as in workspaces they don't have access to. Nil when nothing stops
  the deletion.
  """
  @spec in_use_words(Scope.t(), map, MapSet.t() | nil) :: String.t() | nil
  def in_use_words(scope, blockers, reached \\ nil) do
    nodes = listed(scope, reached, Map.get(blockers, :nodes, []), & &1.name, :nodes)
    runs = listed(scope, reached, Map.get(blockers, :runs, []), & &1.run_id, :runs)

    cond do
      nodes && runs ->
        gettext(
          "Nodes use this gateway: %{nodes}. Runs are going through it: %{runs}. Delete it once the nodes point elsewhere and the runs end.",
          nodes: nodes,
          runs: runs
        )

      nodes ->
        gettext(
          "Nodes use this gateway: %{nodes}. Point them to another gateway or to direct, then delete it.",
          nodes: nodes
        )

      runs ->
        gettext("Runs are going through this gateway: %{runs}. Delete it once they end.",
          runs: runs
        )

      true ->
        nil
    end
  end

  # The names or ids of the rows the reader may open, the first few, then how many more,
  # those of another workspace among them, never named.
  defp listed(scope, reached, rows, name, what) do
    {here, elsewhere} = Enum.split_with(rows, &named_here?(scope, reached, &1))
    {shown, rest} = here |> Enum.map(name) |> Enum.split(@shown)
    more = length(rest) + length(elsewhere)

    cond do
      rows == [] -> nil
      shown == [] -> elsewhere_words(what, reached, more)
      more == 0 -> Enum.join(shown, ", ")
      true -> Enum.join(shown, ", ") <> " " <> more_words(more)
    end
  end

  defp named_here?(scope, nil, row),
    do: row.organisation_id == scope.organisation.id and row.workspace_id == scope.workspace.id

  defp named_here?(_scope, reached, row), do: MapSet.member?(reached, row.workspace_id)

  defp more_words(more),
    do: ngettext("and %{number} more", "and %{number} more", more, number: Format.number(more))

  defp elsewhere_words(:nodes, nil, count),
    do:
      ngettext(
        "%{number} node of another workspace",
        "%{number} nodes of other workspaces",
        count,
        number: Format.number(count)
      )

  defp elsewhere_words(:runs, nil, count),
    do:
      ngettext(
        "%{number} run of another workspace",
        "%{number} runs of other workspaces",
        count,
        number: Format.number(count)
      )

  defp elsewhere_words(:nodes, _reached, count),
    do:
      ngettext(
        "%{number} node in a workspace you don't have access to",
        "%{number} nodes in workspaces you don't have access to",
        count,
        number: Format.number(count)
      )

  defp elsewhere_words(:runs, _reached, count),
    do:
      ngettext(
        "%{number} run in a workspace you don't have access to",
        "%{number} runs in workspaces you don't have access to",
        count,
        number: Format.number(count)
      )

  @doc """
  using_words/2 says which workspaces' nodes use an organisation's gateway now, from
  `Apiary.Gateways.workspaces_using/1`: "Nodes in Acme › Main, Beta › Build and 2 more
  workspaces use it now.", naming each workspace the reader reaches (`reached`, from
  `reached_workspaces/1`) by its organisation and its name, and counting the rest; "No
  node uses it now." when there are none.
  """
  @spec using_words([%Apiary.Organisations.Workspace{}], MapSet.t()) :: String.t()
  def using_words([], _reached), do: gettext("No node uses it now.")

  def using_words(workspaces, reached) do
    {named, others} = Enum.split_with(workspaces, &MapSet.member?(reached, &1.id))

    names =
      Enum.map(
        named,
        &gettext("%{organisation} › %{workspace}",
          organisation: &1.organisation.name,
          workspace: &1.name
        )
      )

    list =
      case {names, length(others)} do
        {names, 0} ->
          Enum.join(names, ", ")

        {[], count} ->
          ngettext("%{number} workspace", "%{number} workspaces", count,
            number: Format.number(count)
          )

        {names, count} ->
          Enum.join(names, ", ") <>
            " " <>
            ngettext("and %{number} more workspace", "and %{number} more workspaces", count,
              number: Format.number(count)
            )
      end

    gettext("Nodes in %{list} use it now.", list: list)
  end

  @doc """
  reached_workspaces/1 is the ids of the workspaces the reader reaches, from the places
  the console lists for them (`Apiary.Organisations.list_places/1`, the pages'
  `memberships`): the workspaces a page may name to them.
  """
  @spec reached_workspaces([map]) :: MapSet.t()
  def reached_workspaces(places) when is_list(places),
    do: MapSet.new(for place <- places, %{id: id} <- Map.get(place, :workspaces, []), do: id)

  @doc """
  organisation_gateways?/0 says whether the console offers gateways at an organisation:
  its Gateways page, the sidebar's entry and New's, where an organisation may have more
  than one workspace (`c:Apiary.Edition.limits/0`). With one workspace an organisation's
  gateways stay at the workspace.
  """
  @spec organisation_gateways?() :: boolean
  def organisation_gateways?, do: Apiary.Edition.limits().workspaces != 1

  @doc """
  gateway_path/2 is the page of `gateway` the reader of `scope` opens: a workspace's
  gateway under the workspace's Nodes, an organisation's under its Gateways; nil for a
  gateway of another organisation, which its page is not the reader's to open.
  """
  @spec gateway_path(Scope.t(), Node.t()) :: String.t() | nil
  def gateway_path(%Scope{organisation: %{id: id} = organisation}, %Node{
        organisation_id: id,
        workspace_id: nil,
        public_id: public_id
      }),
      do: ~p"/#{organisation}/gateways/#{public_id}"

  def gateway_path(%Scope{organisation: %{id: id} = organisation, workspace: workspace}, %Node{
        organisation_id: id,
        public_id: public_id
      })
      when not is_nil(workspace),
      do: ~p"/#{organisation}/#{workspace}/nodes/#{public_id}"

  def gateway_path(_scope, _gateway), do: nil

  @doc """
  gateway_name/2 is `gateway`'s name as a node of the organisation `organisation_id`
  names it: its name alone, or "edge-1 of Acme" for a gateway of another organisation,
  whose organisation must be loaded.
  """
  @spec gateway_name(Ecto.UUID.t(), Node.t()) :: String.t()
  def gateway_name(organisation_id, %Node{organisation_id: organisation_id, name: name}),
    do: name

  def gateway_name(_organisation_id, %Node{} = gateway),
    do:
      gettext("%{gateway} of %{organisation}",
        gateway: gateway.name,
        organisation: organisation_name(gateway)
      )

  @doc """
  managed_by/3 is what a nodes' page says, to a person of `scope` who may not take
  `action`, of who manages the nodes: the edition's sentence
  (`c:ApiaryWeb.Edition.nodes_managed_by_sentence/1`), else who may take it
  (`ApiaryWeb.Access.who_may/3`, `default` in the core's words).
  """
  @spec managed_by(Scope.t(), atom, String.t()) :: String.t()
  def managed_by(%Scope{} = scope, action, default),
    do:
      ApiaryWeb.Edition.nodes_managed_by_sentence(scope.organisation) ||
        ApiaryWeb.Access.who_may(scope, action, default)

  defp organisation_name(%Node{organisation: %Organisation{name: name}}), do: name

  @doc """
  limit_refused/1 is what a node's pages say to a person of `scope` who changes the node
  but not a pool's instance limit (`node.set_limit`): the edition's words of who may
  (`ApiaryWeb.Access.who_may/3`), else "You can't change the instance limit.".
  """
  @spec limit_refused(Scope.t()) :: String.t()
  def limit_refused(scope),
    do:
      ApiaryWeb.Access.who_may(
        scope,
        :"node.set_limit",
        gettext("You can't change the instance limit.")
      )

  @doc """
  node_place/1 is where a node's page stands, from its path's parameters: `:workspace`,
  under a workspace's Nodes, or `:organisation`, under the organisation's Gateways.
  """
  @spec node_place(map) :: :workspace | :organisation
  def node_place(%{"workspace" => _workspace}), do: :workspace
  def node_place(%{}), do: :organisation

  @doc """
  find_node/3 is the node a page at `place` opens: a node, pool or gateway of the scope's
  workspace in use, or a gateway in use of the scope's organisation, where the console
  offers them (`organisation_gateways?/0`); nil for any other.
  """
  @spec find_node(Scope.t(), :workspace | :organisation, String.t()) :: Node.t() | nil
  def find_node(scope, :workspace, public_id), do: Apiary.Nodes.get_node(scope, public_id)

  def find_node(scope, :organisation, public_id) do
    if organisation_gateways?(),
      do: Apiary.Nodes.get_organisation_gateway(scope, public_id)
  end

  @doc """
  nodes_path/2 is the list a node's page at `place` belongs to: the workspace's Nodes, or
  the organisation's Gateways.
  """
  @spec nodes_path(Scope.t(), :workspace | :organisation) :: String.t()
  def nodes_path(scope, :workspace), do: ~p"/#{scope.organisation}/#{scope.workspace}/nodes"
  def nodes_path(scope, :organisation), do: ~p"/#{scope.organisation}/gateways"

  @doc "node_base/3 is the path of the page at `place` of the node `public_id`."
  @spec node_base(Scope.t(), :workspace | :organisation, String.t()) :: String.t()
  def node_base(scope, :workspace, public_id),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/nodes/#{public_id}"

  def node_base(scope, :organisation, public_id),
    do: ~p"/#{scope.organisation}/gateways/#{public_id}"

  @doc "nodes_label/1 is the name of the list a node's page at `place` belongs to."
  @spec nodes_label(:workspace | :organisation) :: String.t()
  def nodes_label(:workspace), do: gettext("Nodes")
  def nodes_label(:organisation), do: gettext("Gateways")

  @doc "nodes_nav/1 is the sidebar's entry of the list a node's page at `place` belongs to."
  @spec nodes_nav(:workspace | :organisation) :: :nodes | :gateways
  def nodes_nav(:workspace), do: :nodes
  def nodes_nav(:organisation), do: :gateways

  @doc """
  reads_nodes?/2 says whether the person of `scope` still reads the nodes at `place`: the
  workspace's, or the organisation's gateways.
  """
  @spec reads_nodes?(Scope.t(), :workspace | :organisation) :: boolean
  def reads_nodes?(scope, :workspace),
    do: Apiary.Access.can?(scope, :"node.read", scope.workspace)

  def reads_nodes?(scope, :organisation),
    do: Apiary.Access.can?(scope, :"node.read", scope.organisation)

  @doc "url_hint/0 is what a gateway's URL field says under it, as it is made and changed."
  @spec url_hint() :: String.t()
  def url_hint,
    do: gettext("Where nodes reach the gateway: https://, a host, and a port if needed.")

  @doc "kind_label/1 is a node's kind in a word or two: Node, Node pool, Gateway."
  @spec kind_label(Node.kind()) :: String.t()
  def kind_label(:node), do: gettext("Node")
  def kind_label(:pool), do: gettext("Node pool")
  def kind_label(:gateway), do: gettext("Gateway")
end
