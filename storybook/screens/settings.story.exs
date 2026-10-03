defmodule ApiaryWeb.Storybook.Screens.Settings do
  @moduledoc false
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ApiaryWeb.CoreComponents

  alias ApiaryWeb.SettingsComponents
  alias ApiaryWeb.Storybook.{Mockup, Sample}

  def doc,
    do:
      "The workspace's settings as the mock-ups propose them: General, People, Runs, " <>
        "Integrations, and Secrets and variables, each leading to its screen."

  def navigation,
    do: [
      {:general, "General"},
      {:people, "People"},
      {:runs, "Runs"},
      {:secrets, "Secrets and variables"}
    ]

  def render(assigns) do
    assigns = assign(assigns, :current, assigns.tab || :general)

    ~H"""
    <Mockup.shell theme={@theme} nav={:settings}>
      <SettingsComponents.layout
        scope={Sample.scope()}
        kind={:workspace}
        sections={Mockup.settings_sections(@theme)}
        counts={Mockup.settings_counts()}
        current={@current}
        measure={if @current in [:general, :runs], do: "read", else: "list"}
        title={title(@current)}
      >
        <:subtitle>{subtitle(@current)}</:subtitle>
        <:actions :if={@current == :secrets}>
          <.button id="new-secret" variant="primary" href="#">
            <.icon name="hero-plus-micro" class="size-4" />New secret
          </.button>
        </:actions>

        <.general :if={@current == :general} />
        <.secrets :if={@current == :secrets} theme={@theme} />
        <.people :if={@current == :people} />
        <.runs :if={@current == :runs} />
      </SettingsComponents.layout>
    </Mockup.shell>
    """
  end

  defp title(:general), do: "General"
  defp title(:secrets), do: "Secrets and variables"
  defp title(:people), do: "People"
  defp title(:runs), do: "Runs"

  defp subtitle(:general), do: "The workspace's name and its path."

  defp subtitle(:secrets),
    do:
      "A secret is given to the integrations that link it and never shown again: one value, " <>
        "or several, each under a value ID you name. A variable is a plain value runs read, " <>
        "set for the workspace or for one repository."

  defp subtitle(:people), do: "The people of Acme who reach this workspace, and their level."
  defp subtitle(:runs), do: "How long the workspace keeps what its runs recorded."

  defp general(assigns) do
    ~H"""
    <form id="workspace-general" class="grid gap-4" novalidate>
      <.input id="workspace-name" name="name" label="Name" value="shop" />
      <.input id="workspace-slug" name="slug" label="Path" prefix="acme/" value="shop" />
      <SettingsComponents.save>
        <.button variant="primary" type="button">Save</.button>
        <:note>A placeholder in these mock-ups: General is as it is today.</:note>
      </SettingsComponents.save>
    </form>
    """
  end

  attr :theme, :any, required: true

  defp secrets(assigns) do
    %{secrets: secrets, variables: variables} = Sample.workspace_secrets()
    names = Map.new(Sample.integrations(), &{&1.id, &1.name})

    assigns =
      assign(assigns,
        secrets: Enum.with_index(secrets),
        variables: Enum.with_index(variables),
        names: names
      )

    ~H"""
    <SettingsComponents.part id="workspace-secrets" title="Secrets" count={length(@secrets)}>
      <.table
        id="secrets"
        label="Secrets"
        rows={@secrets}
        row_id={fn {_secret, i} -> "secret-#{i}" end}
      >
        <:col :let={{secret, _i}} label="Name" kind="title">
          <span class="q-title-mono">{secret.name}</span>
        </:col>
        <:col :let={{secret, _i}} label="Values">
          <span :if={!secret.values} class="text-muted">One value</span>
          <span :if={secret.values} class="q-mono">{Enum.join(secret.values, ", ")}</span>
        </:col>
        <:col :let={{secret, _i}} label="Used by">
          <span :if={secret.used_by == []} class="q-faint">Not linked</span>
          <a
            :for={{id, value_id} <- secret.used_by}
            href={Mockup.path("integration", String.to_atom("#{id}_secrets"), @theme)}
            class="hover:underline"
          >
            {@names[id]}<span :if={value_id} class="q-mono text-muted"> · {value_id}</span>
          </a>
        </:col>
        <:col :let={{secret, _i}} label="Updated" from="sm">{secret.updated}</:col>
        <:action :let={{secret, i}}>
          <.row_menu id={"secret-#{i}-menu"} label={"Actions for #{secret.name}"}>
            <.menu_item href="#">Update…</.menu_item>
            <.menu_divider />
            <.menu_item href="#">Delete…</.menu_item>
          </.row_menu>
        </:action>
      </.table>
    </SettingsComponents.part>

    <SettingsComponents.part id="workspace-variables" title="Variables" count={length(@variables)}>
      <.table
        id="variables"
        label="Variables"
        rows={@variables}
        row_id={fn {_variable, i} -> "variable-#{i}" end}
      >
        <:col :let={{variable, _i}} label="Name" kind="title">
          <span class="q-title-mono">{variable.name}</span>
        </:col>
        <:col :let={{variable, _i}} label="Value"><span class="q-mono">{variable.value}</span></:col>
        <:col :let={{variable, _i}} label="Level">
          <span :if={!variable.repository}>Workspace</span>
          <span :if={variable.repository} class="inline-flex items-baseline gap-1.5">
            Repository <span class="q-mono">{variable.repository}</span>
          </span>
        </:col>
      </.table>
      <p class="text-[12.5px]/[18px] text-faint">
        A variable set for a repository wins over the workspace's for that repository's runs:
        acme/shared-ui runs npm test, every other repository make test.
      </p>
    </SettingsComponents.part>
    """
  end

  defp people(assigns) do
    assigns =
      assign(assigns, :people, [
        %{email: "dana@example.com", level: "Owner", since: "2 Sept 2026"},
        %{email: "lee@example.com", level: "Admin", since: "3 Sept 2026"},
        %{email: "sam@example.com", level: "Member", since: "21 Sept 2026"}
      ])

    ~H"""
    <.table id="people" label="People" rows={@people} row_id={&"person-#{&1.email}"}>
      <:col :let={person} label="Person" kind="title">
        <span class="inline-flex items-center gap-2">
          <.avatar name={person.email} size="sm" />{person.email}
        </span>
      </:col>
      <:col :let={person} label="Level">{person.level}</:col>
      <:col :let={person} label="Since" from="sm">{person.since}</:col>
    </.table>
    <p class="text-[12.5px]/[18px] text-faint">
      A placeholder in these mock-ups: who reaches the workspace, as the organisation's People
      says today.
    </p>
    """
  end

  # Today's Retention, renamed: how long a run's events and its log output are kept.
  defp runs(assigns) do
    ~H"""
    <form id="workspace-runs" class="grid gap-4" novalidate>
      <div class="q-form-two">
        <.input
          id="runs-events"
          name="events_retention_days"
          label="Keep a run's events for"
          value="90"
          hint="In days; empty keeps everything."
        />
        <.input
          id="runs-log"
          name="log_retention_days"
          label="Keep a run's log output for"
          value="30"
          hint="In days; empty keeps everything."
        />
      </div>
      <p class="max-w-[72ch] text-[13px]/[20px] text-muted">
        A run that ended is pruned whole, counted from its last event: first its log output,
        then its timeline. The run stays in the list with its state and its counts.
      </p>
      <SettingsComponents.save>
        <.button variant="primary" type="button">Save</.button>
        <:note>Keeps a run's events for 90 days, its log output for 30.</:note>
      </SettingsComponents.save>
    </form>
    <p class="text-[12.5px]/[18px] text-faint">
      A placeholder in these mock-ups: Runs is today's Retention, renamed.
    </p>
    """
  end
end
