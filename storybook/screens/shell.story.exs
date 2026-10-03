defmodule ApiaryWeb.Storybook.Screens.Shell do
  @moduledoc false
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ApiaryWeb.CoreComponents

  alias ApiaryWeb.Storybook.Mockup

  def doc,
    do:
      "The shell as the mock-ups propose it: one list without headings, Overview, Runs, " <>
        "Targets, Nodes, Network access and Policy, and Settings at the sidebar's foot " <>
        "holds Integrations. Every link that has a screen leads to it."

  def navigation do
    [{:overview, "Overview"}, {:nodes, "Nodes current"}, {:folded, "Folded"}]
  end

  # The screens of the mock-ups, for the overview's list.
  @screens [
    {"settings", :general, "Settings",
     "General, Integrations, Secrets and variables, Access keys, Members."},
    {"integrations", :all, "Settings › Integrations",
     "Every integration with its source, roles and state, by role."},
    {"integration", :github, "An integration", "GitHub: Overview, Secrets and Settings."},
    {"add_integration", :built_in, "Add integration", "Built in, from GitHub, or private."},
    {"run_setup", nil, "A target's run setup",
     "acme/shop's task source, LLM provider, outputs and services."},
    {"nodes", :all, "Nodes",
     "Nodes and node pools, Running or last seen, a pool's instances beneath it."},
    {"node", :build_01, "A node or pool",
     "Overview, Runs, Access key and Settings; a key awaiting approval, revoked, replaced."}
  ]

  def render(%{tab: :nodes} = assigns) do
    ~H"""
    <Mockup.shell theme={@theme} nav={:nodes}>
      <Mockup.nodes theme={@theme} />
    </Mockup.shell>
    """
  end

  def render(assigns) do
    assigns = assign(assigns, :screens, @screens)

    ~H"""
    <Mockup.shell
      theme={@theme}
      nav={:overview}
      folded={@tab == :folded}
      fold={Mockup.path("shell", if(@tab == :folded, do: :overview, else: :folded), @theme)}
    >
      <.header>
        Overview
        <:subtitle>What needs you in shop, then what its agents did.</:subtitle>
      </.header>

      <.notice>
        These are mock-ups: the sidebar is one list with Nodes in it, and Settings holds
        Integrations. Each link below, and each in the sidebar that has a screen, opens it.
      </.notice>

      <.card>
        <:title>Screens</:title>
        <ul class="grid gap-3">
          <li :for={{story, tab, title, about} <- @screens} class="grid gap-0.5">
            <a href={Mockup.path(story, tab, @theme)} class="font-medium text-accent hover:underline">
              {title}
            </a>
            <span class="text-[12.5px]/[18px] text-muted">{about}</span>
          </li>
        </ul>
      </.card>
    </Mockup.shell>
    """
  end
end
