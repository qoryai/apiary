defmodule ApiaryWeb.Storybook.Lists.ListPattern do
  @moduledoc false
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ApiaryWeb.CoreComponents

  alias ApiaryWeb.RunComponents

  def doc,
    do:
      "One way to narrow a list (docs/ui.md, Lists): views as tabs with their counts, one " <>
        "search, one Filter menu, Sort, the filters in force as tokens, the rows, the pages."

  def render(assigns) do
    assigns =
      assign(assigns,
        nodes: [
          %{id: "n1", name: "build-01", node_id: "nd_7Q2M", kind: "Node", seen: "2 minutes ago"},
          %{id: "n2", name: "build-02", node_id: "nd_9F4C", kind: "Node", seen: "1 hour ago"},
          %{id: "n3", name: "spot-runners", node_id: "np_3XKD", kind: "Pool", seen: "3 days ago"}
        ]
      )

    ~H"""
    <div class="grid max-w-4xl gap-3 p-6">
      <.views id="nodes-views" label="Views">
        <:view patch="/acme/shop/nodes" count="3" current>All</:view>
        <:view patch="/acme/shop/nodes?view=running" count="2">Running</:view>
        <:view patch="/acme/shop/nodes?view=idle" count="1">Not running</:view>
      </.views>

      <div class="q-bar">
        <.list_search
          id="nodes-search"
          label="Find a node"
          placeholder="Find a node, e.g. build kind:node"
          value="build"
        />
        <.filter_menu id="nodes-filter" count={1}>
          <.menu_heading title="Kind" />
          <.menu_item id="nodes-filter-node" patch="#" checked hint="2 nodes">Node</.menu_item>
          <.menu_item id="nodes-filter-pool" patch="#" checked={false} hint="1 node">
            Pool
          </.menu_item>
        </.filter_menu>
        <.sort_menu id="nodes-sort" current="Last seen">
          <.menu_item id="nodes-sort-seen" patch="#" checked>Last seen</.menu_item>
          <.menu_item id="nodes-sort-name" patch="#" checked={false}>Name</.menu_item>
        </.sort_menu>
        <.button variant="primary" navigate="/acme/shop/nodes/new">
          <.icon name="hero-plus-micro" class="size-4" />New node
        </.button>
      </div>

      <.filter_tokens id="nodes-tokens" clear="/acme/shop/nodes">
        <:token id="nodes-token-kind" class="q-tok-q" patch="#" label="Remove kind:node">
          <span class="q-tok-k">kind:</span>node
        </:token>
      </.filter_tokens>

      <div role="status" class="q-status">
        <p class="q-matchline"><b>2</b> nodes match</p>
      </div>

      <.table id="nodes" label="Nodes" rows={@nodes} row_id={&"node-#{&1.id}"}>
        <:col :let={node} label="Name" kind="title">{node.name}</:col>
        <:col :let={node} label="Node id" kind="faint">
          <span class="font-mono">{node.node_id}</span>
        </:col>
        <:col :let={node} label="Kind" from="sm">{node.kind}</:col>
        <:col :let={node} label="Last seen" from="md">{node.seen}</:col>
        <:action :let={node}>
          <.row_menu id={"node-#{node.id}-menu"} label={"Actions for #{node.name}"}>
            <.menu_item patch="#">Access key</.menu_item>
            <.menu_divider />
            <.menu_item patch="#">Delete…</.menu_item>
          </.row_menu>
        </:action>
      </.table>

      <RunComponents.pager
        id="nodes-pages"
        prefix="nodes-pages"
        first={51}
        last={53}
        total={53}
        previous="/acme/shop/nodes?page=1"
        next={false}
        previous_label="Previous"
        next_label="Next"
      />
    </div>
    """
  end
end
