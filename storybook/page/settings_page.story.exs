defmodule ApiaryWeb.Storybook.Page.SettingsPage do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &ApiaryWeb.PageComponents.settings_page/1
  def imports, do: [{ApiaryWeb.CoreComponents, icon: 1, button: 1}]
  def container, do: {:div, class: "w-full p-6"}

  def variations do
    [
      %Variation{
        id: :a_workspace_section,
        description:
          "A section of a workspace's settings: the level's heading, then the section. " <>
            "The frame lists the sections as its second column.",
        attributes: %{heading: "Workspace settings", section: :runs, title: "Runs"},
        slots: [
          ~s|<:subtitle>How long this workspace keeps its runs, their events and their logs.</:subtitle>|,
          ~s|<p class="text-sm">Keep runs for 90 days.</p>|
        ]
      },
      %Variation{
        id: :a_list_with_an_action,
        attributes: %{
          heading: "Organisation settings",
          section: :people,
          title: "People",
          measure: "list"
        },
        slots: [
          ~s|<:subtitle>Who belongs to acme, and at what level.</:subtitle>|,
          ~s|<:actions><.button variant="primary">Invite people</.button></:actions>|,
          ~s|<p class="text-sm">dana@example.com, Owner</p>|
        ]
      },
      %Variation{
        id: :your_settings,
        description: "A person's own section: its title is the page's h1.",
        attributes: %{section: :user_preferences, title: "Preferences"},
        slots: [~s|<p class="text-sm">Language, time zone and theme.</p>|]
      }
    ]
  end
end
