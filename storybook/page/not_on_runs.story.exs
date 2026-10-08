defmodule ApiaryWeb.Storybook.Page.NotOnRuns do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &ApiaryWeb.PageComponents.not_on_runs/1
  def imports, do: [{ApiaryWeb.CoreComponents, icon: 1}]
  def container, do: {:div, class: "w-full p-6"}

  def variations do
    [
      %Variation{
        id: :default,
        description:
          "Once, near the top of a page over data no run receives, in the page's own " <>
            "words, saying what a run receives.",
        slots: ["A run receives only its security policy."]
      },
      %Variation{
        id: :own_words,
        attributes: %{id: "policy-only"},
        slots: ["Qory Apiary sends a run only its security policy."]
      }
    ]
  end
end
