defmodule ApiaryWeb.Storybook.Page.PageTabs do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &ApiaryWeb.PageComponents.page_tabs/1
  def imports, do: [{ApiaryWeb.CoreComponents, icon: 1}]
  def container, do: {:div, class: "w-full p-6 [--q-gutter:1.5rem] [--q-bar:0px]"}

  def variations do
    [
      %Variation{
        id: :a_target,
        description: "A target's tabs: Overview, Policy, and Settings last, set apart.",
        attributes: %{id: "target-tabs", label: "Target", current: :overview},
        slots: [
          ~s|<:tab key={:overview} patch="#">Overview</:tab>|,
          ~s|<:tab key={:policy} patch="#">Policy</:tab>|,
          ~s|<:tab key={:settings} patch="#" settings>Settings</:tab>|
        ]
      },
      %Variation{
        id: :a_run,
        description: "A run's tabs, with a count and its denials in red.",
        attributes: %{id: "run-tabs", label: "Run", current: :connections},
        slots: [
          ~s|<:tab key={:timeline} patch="#" icon="hero-queue-list">Timeline</:tab>|,
          ~s|<:tab key={:terminal} patch="#" icon="hero-command-line">Terminal</:tab>|,
          ~s|<:tab key={:connections} patch="#" icon="hero-globe-alt" count={2} tone="error">Network access</:tab>|,
          ~s|<:tab key={:details} patch="#" icon="hero-information-circle">Details</:tab>|
        ]
      }
    ]
  end
end
