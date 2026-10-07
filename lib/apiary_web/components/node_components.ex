defmodule ApiaryWeb.NodeComponents do
  @moduledoc """
  What the Nodes list and a node's page say alike (`docs/ui.md`, Nodes): a node's state in
  words, from what it is doing (`Apiary.Nodes.activity/3`), the sentence that says what an
  instance is, and the line that says nodes receive no runs yet, since Qory can't check a
  node's key yet. And what a node's page's two LiveViews share: its header
  (`node_header/1`) and its tabs (`node_tabs/1`), Overview, Access key and Settings; and
  an enrolment code's expiry (`code_expiry/1`).

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
  the node's key, never an identity, once runners use a node's keys, which they don't yet.
  """
  @spec instance_sentence() :: String.t()
  def instance_sentence,
    do:
      gettext(
        "Once runners use a node's keys, an instance is what a runner with this node's key reports itself as, and anyone with the key can report any instance: a machine you want to cut off on its own needs a node of its own."
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
  not_yet/1 is the one plain line a page about a node's keys says, once, near its top:
  Qory can't check a node's keys yet, so nodes receive no runs, and machines send their
  runs with a workspace access key, with the way to them (Workspace settings › Access
  keys). Its words are the page's own sentence, which ends with `%{link}`, where the link
  goes, flush against the full stop.
  """
  attr :id, :string, default: "not-on-runs"
  attr :scope, :map, required: true
  attr :text, :any, required: true, doc: "`rich_gettext/2` of the sentence, with `link`"
  attr :class, :any, default: nil

  def not_yet(assigns) do
    ~H"""
    <.not_on_runs id={@id} class={@class}>
      <.rich text={@text}>
        <:part name={:link}><.keys_link id={"#{@id}-keys"} scope={@scope} /></:part>
      </.rich>
    </.not_on_runs>
    """
  end

  attr :id, :string, required: true
  attr :scope, :map, required: true

  # Written flush: no whitespace inside the link or after it, before the sentence's stop.
  defp keys_link(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={~p"/#{@scope.organisation}/#{@scope.workspace}/settings/keys"}
      class="text-accent hover:underline"
    >{gettext("Workspace settings › Access keys")}</.link>
    """
  end

  @doc """
  code_expiry/1 is an enrolment code's expiry, as a term and its description in a `<dl>`:
  "Expires" and the moment, as the reader's clock writes it, or "Expired" once `now` is
  past it. The description is the moment, or the page's own words (`inner_block`). The
  term's id is the description's, then `-label`.
  """
  attr :id, :string, required: true
  attr :at, DateTime, required: true, doc: "when the code expires"
  attr :now, DateTime, required: true, doc: "the moment the page last read the codes"
  slot :inner_block, doc: "the description's words, where the moment alone does not do"

  def code_expiry(assigns) do
    ~H"""
    <dt id={"#{@id}-label"} class="text-faint">
      {if DateTime.after?(@at, @now), do: gettext("Expires"), else: gettext("Expired")}
    </dt>
    <dd id={@id}>
      {if @inner_block == [], do: Format.datetime(@at), else: render_slot(@inner_block)}
    </dd>
    """
  end

  @doc "kind_label/1 is a node's kind in a word or two: Node, Node pool."
  @spec kind_label(Node.kind()) :: String.t()
  def kind_label(:node), do: gettext("Node")
  def kind_label(:pool), do: gettext("Node pool")
end
