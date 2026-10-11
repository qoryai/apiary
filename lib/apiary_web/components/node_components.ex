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

  A node's state is never Online or Offline. A Node says "Running" while its instance
  runs; a pool says how many of its instances run, against its limit when it has one
  ("3 of 10 running", "3 running"). One that runs nothing says when an instance of it was
  last seen, or, with no instance left, when one of its keys was last used, ticking in the
  browser (`seen_at/1`), or "Never seen".
  """
  use ApiaryWeb, :html

  alias Apiary.Nodes.Node
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
        "An instance is what Forager, run with this node's key, reports itself as, and anyone with the key can report any instance: to cut off one machine alone, give it a separate node."
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
        <.rich text={
          rich_gettext(
            "Runs of %{name} go through the gateway %{gateway}, at %{url}.",
            name: @node.name,
            gateway: @gateway.name,
            url: {:m, @gateway.url}
          )
        } />
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
  of); Direct; and each gateway the node may name, by name. It shows the errors
  `Apiary.Nodes` gives `gateway_choice` and `gateway_id` once the form was sent.
  `choice_params/1` turns what it sends into those two fields.
  """
  attr :form, Phoenix.HTML.Form, required: true
  attr :gateways, :list, required: true, doc: "the gateways the node may name"
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
        [{gettext("Direct"), "direct"}] ++
        Enum.map(assigns.gateways, &{&1.name, &1.id}) ++ gone

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
      hint={
        @default &&
          gettext(
            "On Default gateway, runs go through %{name}, this workspace's default. On Direct, they go through no gateway.",
            name: @default.name
          )
      }
      disabled={@disabled}
    />
    """
  end

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
  in_use_words/2 is why a gateway was not deleted, from what
  `Apiary.Gateways.delete_blockers/1` answered: the nodes that point to it, and the runs
  going through it (`runs`, when the answer has them). Only the nodes and runs of the
  scope's workspace are named, by name and by run id, the first #{@shown} of each, then
  "and N more", which counts the rest and those of any other workspace too. Nil when
  nothing stops the deletion.
  """
  @spec in_use_words(Apiary.Accounts.Scope.t(), map) :: String.t() | nil
  def in_use_words(scope, blockers) do
    nodes = listed(scope, Map.get(blockers, :nodes, []), & &1.name, :nodes)
    runs = listed(scope, Map.get(blockers, :runs, []), & &1.run_id, :runs)

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

  # The names or ids of the scope's workspace's rows, the first few, then how many more,
  # those of another workspace among them, never named.
  defp listed(scope, rows, name, what) do
    {here, elsewhere} =
      Enum.split_with(
        rows,
        &(&1.organisation_id == scope.organisation.id and &1.workspace_id == scope.workspace.id)
      )

    {shown, rest} = here |> Enum.map(name) |> Enum.split(@shown)
    more = length(rest) + length(elsewhere)

    cond do
      rows == [] -> nil
      shown == [] -> elsewhere_words(what, more)
      more == 0 -> Enum.join(shown, ", ")
      true -> Enum.join(shown, ", ") <> " " <> more_words(more)
    end
  end

  defp more_words(more),
    do: ngettext("and %{number} more", "and %{number} more", more, number: Format.number(more))

  defp elsewhere_words(:nodes, count),
    do:
      ngettext(
        "%{number} node of another workspace",
        "%{number} nodes of other workspaces",
        count,
        number: Format.number(count)
      )

  defp elsewhere_words(:runs, count),
    do:
      ngettext(
        "%{number} run of another workspace",
        "%{number} runs of other workspaces",
        count,
        number: Format.number(count)
      )

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
