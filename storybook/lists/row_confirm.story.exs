defmodule ApiaryWeb.Storybook.Lists.RowConfirm do
  @moduledoc false
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ApiaryWeb.CoreComponents

  def doc,
    do:
      "A row asking to confirm an act on it (docs/ui.md, Components): in a table wider than " <>
        "its box, the question and its buttons stay in the box's view, however far it is " <>
        "scrolled."

  def render(assigns) do
    assigns =
      assign(assigns,
        secrets: [
          secret("s1", "FORGE_TOKEN", "default", "acme/shop, acme/shared-ui", "dana"),
          secret("s2", "REGISTRY_PASSWORD", "registry-ci", "acme/shop", "lee"),
          secret("s3", "DEPLOY_SSH_KEY", "deploy-2026-09", "acme/deploy-scripts", "dana")
        ]
      )

    # The story holds the table to the width it is given, as a page's column does, so the
    # table scrolls in its own box (`[contain:inline-size]`: the storybook's frame would
    # otherwise widen to the table).
    ~H"""
    <div class="grid max-w-3xl grid-cols-[minmax(0,1fr)] gap-3 p-6 [contain:inline-size]">
      <.table
        id="secrets"
        label="Secrets"
        rows={@secrets}
        row_id={&"secret-#{&1.id}"}
        confirming="secret-s2"
      >
        <:col :let={secret} label="Name" kind="title">
          <span class="font-mono">{secret.name}</span>
        </:col>
        <:col :let={secret} label="Value ID" kind="faint">
          <span class="font-mono">{secret.value_id}</span>
        </:col>
        <:col :let={secret} label="Repositories">{secret.repositories}</:col>
        <:col :let={secret} label="Added by">{secret.by}</:col>
        <:col :let={secret} label="Updated">{secret.updated}</:col>
        <:col :let={secret} label="Last used">{secret.used}</:col>
        <:action :let={secret}>
          <.row_menu id={"secret-#{secret.id}-menu"} label={"Actions for #{secret.name}"}>
            <.menu_item patch="#">Rotate…</.menu_item>
            <.menu_divider />
            <.menu_item patch="#">Delete…</.menu_item>
          </.row_menu>
        </:action>
        <:confirm :let={secret}>
          <.inline_confirm
            id={"secret-#{secret.id}-confirm"}
            question={"Delete #{secret.name}?"}
            cancel="#"
          >
            The secret and its value are deleted. This cannot be undone.
            <:action>
              <.button variant="danger" size="xs">Yes, delete</.button>
            </:action>
          </.inline_confirm>
        </:confirm>
      </.table>
    </div>
    """
  end

  defp secret(id, name, value_id, repositories, by) do
    %{
      id: id,
      name: name,
      value_id: value_id,
      repositories: repositories,
      by: by,
      updated: "12 September 2026, 09:41",
      used: "2 minutes ago by run 4182"
    }
  end
end
