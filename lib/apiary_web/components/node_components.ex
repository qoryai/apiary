defmodule ApiaryWeb.NodeComponents do
  @moduledoc """
  What the Nodes list and a node's page say alike (`docs/ui.md`, Nodes): a node's state in
  words, from what it is doing (`Apiary.Nodes.activity/3`), and the sentence that says
  what an instance is.

  A node's state is never Online or Offline. A Node says "Running" while its instance
  runs; a pool says how many of its instances run, against its limit when it has one
  ("3 of 10 running", "3 running"). One that runs nothing says when an instance of it was
  last seen, ticking in the browser, or "Never seen".
  """
  use ApiaryWeb, :html

  alias Apiary.Nodes.Node

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
        "An instance is what a runner using this node's key reports itself as; anyone with the key can report any instance. Cut off a machine by giving it a node of its own."
      )
end
