defmodule ApiaryWeb.Storybook.Screens.Settings do
  @moduledoc false
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ApiaryWeb.CoreComponents

  alias ApiaryWeb.SettingsComponents
  alias ApiaryWeb.Storybook.{Mockup, Sample}

  def doc,
    do:
      "The workspace's settings as the mock-ups propose them: General, Integrations, " <>
        "Secrets and variables, Access keys and Members, each leading to its screen."

  def navigation,
    do: [{:general, "General"}, {:secrets, "Secrets and variables"}, {:members, "Members"}]

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
        measure={if @current == :general, do: "read", else: "list"}
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
        <.members :if={@current == :members} />
      </SettingsComponents.layout>
    </Mockup.shell>
    """
  end

  defp title(:general), do: "General"
  defp title(:secrets), do: "Secrets and variables"
  defp title(:members), do: "Members"

  defp subtitle(:general), do: "The workspace's name and its path."

  defp subtitle(:secrets),
    do:
      "A secret is given to the integrations that link it, never shown again; a variable is a " <>
        "plain value every run reads. Each is set per environment."

  defp subtitle(:members), do: "The people of Acme who reach this workspace, and their level."

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
        <:col :let={{secret, _i}} label="Environment">{secret.environment}</:col>
        <:col :let={{secret, _i}} label="Used by">
          <span :if={secret.used_by == []} class="q-faint">Not linked</span>
          <a
            :for={id <- secret.used_by}
            href={Mockup.path("integration", String.to_atom("#{id}_secrets"), @theme)}
            class="hover:underline"
          >
            {@names[id]}
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
        <:col :let={{variable, _i}} label="Environment">{variable.environment}</:col>
      </.table>
    </SettingsComponents.part>
    """
  end

  defp members(assigns) do
    assigns =
      assign(assigns, :people, [
        %{email: "dana@example.com", level: "Owner", since: "2 Sept 2026"},
        %{email: "lee@example.com", level: "Admin", since: "3 Sept 2026"},
        %{email: "sam@example.com", level: "Member", since: "21 Sept 2026"}
      ])

    ~H"""
    <.table id="members" label="Members" rows={@people} row_id={&"member-#{&1.email}"}>
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
end
