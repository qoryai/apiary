defmodule ApiaryWeb.Storybook.Screens.Integrations do
  @moduledoc false
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ApiaryWeb.CoreComponents

  alias ApiaryWeb.SettingsComponents
  alias ApiaryWeb.Storybook.{Mockup, Sample}

  def doc,
    do:
      "Settings › Integrations: what the workspace's runs connect to, by role, and the " <>
        "ways each connects, API, MCP or both. One integration can have several roles, " <>
        "and Services holds the tools too; its row leads to its page."

  # Each view and the roles it holds: Services holds the tools as well.
  @views [
    {:all, "All", nil},
    {:task_sources, "Task sources", [:task_source]},
    {:llm_providers, "LLM providers", [:llm_provider]},
    {:outputs, "Outputs", [:output]},
    {:services, "Services", [:service, :tool]}
  ]

  def navigation, do: for({tab, label, _role} <- @views, do: {tab, label})

  def render(assigns) do
    integrations = Sample.integrations()
    roles = Enum.find_value(@views, fn {tab, _label, roles} -> tab == assigns.tab && roles end)

    assigns =
      assign(assigns,
        views:
          for {tab, label, roles} <- @views do
            %{tab: tab, label: label, count: Enum.count(integrations, &in_view?(&1, roles))}
          end,
        rows: Enum.filter(integrations, &in_view?(&1, roles)),
        current: assigns.tab || :all
      )

    ~H"""
    <Mockup.shell theme={@theme} nav={:settings}>
      <SettingsComponents.layout
        scope={Sample.scope()}
        kind={:workspace}
        sections={Mockup.settings_sections(@theme)}
        counts={Mockup.settings_counts()}
        current={:integrations}
        measure="list"
        title="Integrations"
      >
        <:subtitle>
          What the runs of this workspace connect to: where their tasks come from, the models
          they use, where their results go and the services they reach.
        </:subtitle>
        <:actions>
          <.button
            id="add-integration"
            variant="primary"
            href={Mockup.path("add_integration", :built_in, @theme)}
          >
            <.icon name="hero-plus-micro" class="size-4" />Add integration
          </.button>
        </:actions>

        <div class="grid gap-3">
          <.views id="integration-views" label="Roles">
            <:view
              :for={view <- @views}
              id={"integration-view-#{view.tab}"}
              navigate={Mockup.path("integrations", view.tab, @theme)}
              count={view.count}
              current={view.tab == @current}
            >
              {view.label}
            </:view>
          </.views>

          <div class="q-bar">
            <.list_search
              id="integrations-search"
              label="Find an integration"
              placeholder="Find an integration, e.g. github or source:acme"
              live={false}
            />
          </div>

          <.table id="integrations" label="Integrations" rows={@rows} row_id={&"integration-#{&1.id}"}>
            <:col :let={integration} label="Integration" kind="title">
              <a
                href={Mockup.path("integration", String.to_atom(integration.id), @theme)}
                class="q-title hover:underline"
              >
                {integration.name}
              </a>
            </:col>
            <:col :let={integration} label="Source" from="md">
              <Mockup.source source={integration.source} />
            </:col>
            <:col :let={integration} label="Roles">
              <Mockup.roles roles={integration.roles} />
            </:col>
            <:col :let={integration} label="Connects" from="sm">
              <Mockup.ways ways={integration.ways} />
            </:col>
            <:col :let={integration} label="Targets" kind="num" from="md">
              {integration.targets}
            </:col>
            <:col :let={integration} label="State">
              <Mockup.status integration={integration} id={"integration-#{integration.id}-state"} />
            </:col>
            <:action :let={integration}>
              <.button
                :if={Mockup.needs_secret?(integration)}
                variant="link"
                href={Mockup.path("integration", String.to_atom("#{integration.id}_secrets"), @theme)}
                aria-label={"Choose a secret for #{integration.name}"}
              >
                Choose a secret
              </.button>
              <.row_menu
                id={"integration-#{integration.id}-menu"}
                label={"Actions for #{integration.name}"}
              >
                <.menu_item href={
                  Mockup.path("integration", String.to_atom("#{integration.id}_secrets"), @theme)
                }>
                  Secrets
                </.menu_item>
                <.menu_item href={
                  Mockup.path("integration", String.to_atom("#{integration.id}_settings"), @theme)
                }>
                  Settings
                </.menu_item>
                <.menu_divider />
                <.menu_item href="#">Remove…</.menu_item>
              </.row_menu>
            </:action>
          </.table>

          <p class="text-[12.5px]/[18px] text-faint">
            An integration with several roles is counted under each: GitHub is a task source,
            an output and a service. Services holds the tools too, such as Docs search.
            Source is Built in for an LLM provider or a service that ships inside Apiary, and
            otherwise the publisher's repository and the release it was added at. Connects says
            how a run reaches it: through Qory's API, as an MCP server, or both. Targets counts
            the targets whose run setup uses it.
          </p>
        </div>
      </SettingsComponents.layout>
    </Mockup.shell>
    """
  end

  defp in_view?(_integration, nil), do: true
  defp in_view?(integration, roles), do: Enum.any?(integration.roles, &(&1 in roles))
end
