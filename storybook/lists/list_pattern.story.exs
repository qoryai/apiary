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
        keys: [
          %{id: "k1", label: "ci-runner", key_id: "ak_7Q2M", by: "dana", used: "2 minutes ago"},
          %{id: "k2", label: "build-02", key_id: "ak_9F4C", by: "lee", used: "1 hour ago"},
          %{id: "k3", label: "nightly", key_id: "ak_3XKD", by: "dana", used: "3 days ago"}
        ]
      )

    ~H"""
    <div class="grid max-w-4xl gap-3 p-6">
      <.views id="keys-views" label="Views">
        <:view patch="/acme/shop/settings/keys" count="3" current>All</:view>
        <:view patch="/acme/shop/settings/keys?view=in-use" count="2">In use</:view>
        <:view patch="/acme/shop/settings/keys?view=revoked" count="1">Revoked</:view>
      </.views>

      <div class="q-bar">
        <.list_search
          id="keys-search"
          label="Find a key"
          placeholder="Find a key, e.g. ci by:dana"
          value="ci"
        />
        <.filter_menu id="keys-filter" count={1}>
          <.menu_heading title="Added by" />
          <.menu_item id="keys-filter-dana" patch="#" checked hint="2 keys">dana</.menu_item>
          <.menu_item id="keys-filter-lee" patch="#" checked={false} hint="1 key">lee</.menu_item>
        </.filter_menu>
        <.sort_menu id="keys-sort" current="Recently used">
          <.menu_item id="keys-sort-used" patch="#" checked>Recently used</.menu_item>
          <.menu_item id="keys-sort-label" patch="#" checked={false}>Label</.menu_item>
        </.sort_menu>
        <.button variant="primary" navigate="/acme/shop/settings/keys/new">
          <.icon name="hero-plus-micro" class="size-4" />New access key
        </.button>
      </div>

      <.filter_tokens id="keys-tokens" clear="/acme/shop/settings/keys">
        <:token id="keys-token-by" class="q-tok-q" patch="#" label="Remove by:dana">
          <span class="q-tok-k">by:</span>dana
        </:token>
      </.filter_tokens>

      <div role="status" class="q-status">
        <p class="q-matchline"><b>2</b> keys match</p>
      </div>

      <.table id="keys" label="Access keys" rows={@keys} row_id={&"key-#{&1.id}"}>
        <:col :let={key} label="Label" kind="title">{key.label}</:col>
        <:col :let={key} label="Key id" kind="faint">
          <span class="font-mono">{key.key_id}</span>
        </:col>
        <:col :let={key} label="Added by" from="sm">{key.by}</:col>
        <:col :let={key} label="Last used" from="md">{key.used}</:col>
        <:action :let={key}>
          <.row_menu id={"key-#{key.id}-menu"} label={"Actions for #{key.label}"}>
            <.menu_item patch="#">Rotate…</.menu_item>
            <.menu_divider />
            <.menu_item patch="#">Revoke…</.menu_item>
          </.row_menu>
        </:action>
      </.table>

      <RunComponents.pager
        id="keys-pages"
        prefix="keys-pages"
        first={51}
        last={53}
        total={53}
        previous="/acme/shop/settings/keys?page=1"
        next={false}
        previous_label="Previous"
        next_label="Next"
      />
    </div>
    """
  end
end
