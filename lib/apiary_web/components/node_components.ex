defmodule ApiaryWeb.NodeComponents do
  @moduledoc """
  What the Nodes list and a node's page say alike (`docs/ui.md`, Nodes): a node's state in
  words, from what it is doing (`Apiary.Nodes.activity/3`), and the sentence that says what
  an instance is. And what a node's page's two LiveViews share: its header
  (`node_header/1`) and its tabs (`node_tabs/1`), Overview, Access key and Settings. And
  what the two places that give a person the command that connects a machine share, the
  Access key tab's command page and the workspace overview's first-run box: the command
  (`enrol_command/2`), and the notice that machines can't reach a loopback address
  (`unreachable_server/1`).

  A node's state is never Online or Offline. A Node says "Running" while its instance
  runs; a pool says how many of its instances run, against its limit when it has one
  ("3 of 10 running", "3 running"). One that runs nothing says when an instance of it was
  last seen, ticking in the browser, or "Never seen".
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
        <% @activity.last -> %>
          {gettext("Last seen")}
          <.relative_time id={"#{@id}-seen"} at={@activity.last.last_seen_at} />
        <% true -> %>
          <span class="text-faint">{gettext("Never seen")}</span>
      <% end %>
    </span>
    """
  end

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
        "An instance is what a runner with this node's key reports itself as, and anyone with the key can report any instance: a machine you want to cut off on its own needs a node of its own."
      )

  @doc """
  node_header/1 is the header of a node's page: its name, the page's `<h1>`; its public id
  beside it; and one muted line, its kind, its state and who made it and when.
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
  enrol_command/2 is the command that connects a machine: `qory access-key enrol`, this
  server's address and the code as the machine sends it. Only a page that shows the
  command once calls it, with the code it holds.
  """
  @spec enrol_command(String.t(), String.t()) :: String.t()
  def enrol_command(server, code) when is_binary(server) and is_binary(code),
    do: "qory access-key enrol #{server} #{code}"

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
          "%{url} works only on the computer Qory runs on. Set PUBLIC_URL to the address machines use, and the command will carry it.",
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

  @doc "kind_label/1 is a node's kind in a word or two: Node, Node pool."
  @spec kind_label(Node.kind()) :: String.t()
  def kind_label(:node), do: gettext("Node")
  def kind_label(:pool), do: gettext("Node pool")
end
