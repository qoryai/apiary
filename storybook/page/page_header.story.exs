defmodule ApiaryWeb.Storybook.Page.PageHeader do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &ApiaryWeb.PageComponents.page_header/1

  def imports,
    do: [{ApiaryWeb.CoreComponents, icon: 1, button: 1, badge: 1}]

  def container, do: {:div, class: "w-full p-6"}

  def variations do
    [
      %Variation{
        id: :title_and_line,
        description: "A list's header: its title and one line of what it is for.",
        attributes: %{title: "Targets"},
        slots: [~s|<:description>What this workspace's runs worked on.</:description>|]
      },
      %Variation{
        id: :with_actions,
        description: "At most one primary and one default action, at the right.",
        attributes: %{title: "Nodes"},
        slots: [
          ~s|<:description>The machines and pools your runs run on.</:description>|,
          ~s|<:actions><.button>New node pool</.button><.button variant="primary">New node</.button></:actions>|
        ]
      },
      %Variation{
        id: :with_a_badge_and_a_line,
        description:
          "A tag beside the title, and under the description what the page says of itself.",
        attributes: %{title: "Runs"},
        slots: [
          ~s|<:badge><.badge color="info" dot>3 alive</.badge></:badge>|,
          ~s|<:description>Every run of this workspace.</:description>|,
          ~s|<p class="text-sm text-muted">Showing the runs of acme/shop only.</p>|
        ]
      }
    ]
  end
end
