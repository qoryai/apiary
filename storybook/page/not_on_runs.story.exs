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
        description: "Once, near the top of a page over data no run receives yet."
      },
      %Variation{
        id: :own_words,
        attributes: %{id: "links-not-yet"},
        slots: ["Runs don't receive these links yet."]
      }
    ]
  end
end
