defmodule ApiaryWeb.Storybook.Screens.Machines do
  @moduledoc false
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  alias ApiaryWeb.Storybook.Mockup

  def doc,
    do:
      "Record › Machines: every machine that posts runs, by its instance id, its state, its " <>
        "access key and its Qory version. Ten machines share one key."

  def navigation, do: [{:all, "All"}, {:online, "Online"}, {:offline, "Offline"}]

  def render(assigns) do
    ~H"""
    <Mockup.shell theme={@theme} nav={:machines}>
      <Mockup.machines theme={@theme} view={@tab} />
    </Mockup.shell>
    """
  end
end
