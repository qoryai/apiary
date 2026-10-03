defmodule ApiaryWeb.Storybook.Screens.Integration do
  @moduledoc false
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ApiaryWeb.CoreComponents

  alias ApiaryWeb.{RunComponents, SettingsComponents}
  alias ApiaryWeb.Storybook.{Mockup, Sample}

  def doc,
    do:
      "An integration's page, under Settings › Integrations: its source, version, roles and " <>
        "the ways it connects, then Overview, Secrets and Settings, which ask for each " <>
        "setting it declares, secret or plain. Each integration of the list has one; Slack " <>
        "shows a secret linked to none."

  # Three tabs an integration: its Overview at its id, then its Secrets and its Settings.
  def navigation do
    for integration <- Sample.integrations(),
        {suffix, label} <- [{"", ""}, {"_secrets", " › Secrets"}, {"_settings", " › Settings"}],
        do: {String.to_atom(integration.id <> suffix), integration.name <> label}
  end

  @roles [
    task_source: "Gives a run its task.",
    llm_provider: "Serves the models a run's runtime asks for.",
    output: "Receives what a run did when it ends.",
    service: "Reached by a run while it works, with credentials the run never sees.",
    tool: "Called by the agent of a run while it works; listed under Services."
  ]

  @ways [
    api: "A run reaches it through Qory's API, with credentials the run never sees.",
    mcp: "The agent of a run calls it as an MCP server."
  ]

  def render(assigns) do
    {integration, page} = find(assigns.tab)

    assigns =
      assign(assigns,
        integration: integration,
        page: page,
        tab_path:
          &Mockup.path("integration", String.to_atom(integration.id <> &1), assigns.theme),
        roles: @roles,
        ways: @ways,
        secrets: Mockup.secrets(integration),
        plain: Mockup.plain_settings(integration),
        unlinked: Enum.count(Mockup.secrets(integration), &is_nil(&1.linked))
      )

    ~H"""
    <Mockup.shell theme={@theme} nav={:settings}>
      <:crumb href={Mockup.path("integrations", :all, @theme)}>Integrations</:crumb>
      <:crumb>{@integration.name}</:crumb>

      <SettingsComponents.layout
        scope={Sample.scope()}
        kind={:workspace}
        sections={Mockup.settings_sections(@theme)}
        counts={Mockup.settings_counts()}
        current={:integrations}
        title={@integration.name}
      >
        <:subtitle>
          <span class="inline-flex flex-wrap items-baseline gap-x-2 gap-y-1">
            <Mockup.source source={@integration.source} />
            <span :if={@integration.source} class="text-faint" aria-hidden="true">·</span>
            <span :if={@integration.source}>from a {Mockup.forge_label(@integration.source.forge)} release</span>
            <span class="text-faint" aria-hidden="true">·</span>
            <span>added by {@integration.added}</span>
          </span>
        </:subtitle>

        <span class="inline-flex flex-wrap items-center gap-x-3 gap-y-1">
          <Mockup.roles roles={@integration.roles} />
          <span class="inline-flex items-baseline gap-1.5 text-[12.5px]/[18px] text-muted">
            Connects by <Mockup.ways ways={@integration.ways} class="text-base-content" />
          </span>
        </span>

        <div class="[--q-gutter:0px]">
          <RunComponents.tabs id="integration-tabs" label={@integration.name}>
            <:tab
              id="integration-tab-overview"
              navigate={@tab_path.("")}
              current={@page == :overview}
              icon="hero-book-open"
            >
              Overview
            </:tab>
            <:tab
              id="integration-tab-secrets"
              navigate={@tab_path.("_secrets")}
              current={@page == :secrets}
              icon="hero-key"
              count={length(@secrets)}
            >
              Secrets
            </:tab>
            <:tab
              id="integration-tab-settings"
              navigate={@tab_path.("_settings")}
              current={@page == :settings}
              icon="hero-adjustments-horizontal"
              count={length(@plain)}
            >
              Settings
            </:tab>
          </RunComponents.tabs>
        </div>

        <.overview :if={@page == :overview} {assigns} />
        <.secrets :if={@page == :secrets} {assigns} />
        <.settings :if={@page == :settings} {assigns} />
      </SettingsComponents.layout>
    </Mockup.shell>
    """
  end

  defp overview(assigns) do
    ~H"""
    <.notice :if={@unlinked > 0} kind={:warning}>
      <strong>{@integration.name} needs a secret.</strong>
      A run that uses it waits until each secret it declares is linked.
      <a href={@tab_path.("_secrets")} class="font-medium underline">Choose a secret</a>
    </.notice>

    <p class="max-w-[72ch] text-[13.5px]/5">{@integration.about}</p>

    <SettingsComponents.part id="integration-roles" title="Roles">
      <dl class="grid grid-cols-[max-content_minmax(0,1fr)] gap-x-4 gap-y-2 text-[13px]/5">
        <%= for role <- @integration.roles do %>
          <dt class="font-medium">{Mockup.role_label(role)}</dt>
          <dd class="text-muted">{@roles[role]}</dd>
        <% end %>
      </dl>
    </SettingsComponents.part>

    <SettingsComponents.part id="integration-ways" title="How it connects">
      <dl class="grid grid-cols-[max-content_minmax(0,1fr)] gap-x-4 gap-y-2 text-[13px]/5">
        <%= for way <- @integration.ways do %>
          <dt class="q-mono font-medium">{Mockup.way_label(way)}</dt>
          <dd class="text-muted">{@ways[way]}</dd>
        <% end %>
      </dl>
      <p class="text-[12.5px]/[18px] text-faint">
        A target's run setup chooses which of them its runs use.
      </p>
    </SettingsComponents.part>

    <SettingsComponents.part id="integration-about" title="About">
      <dl class="grid grid-cols-[max-content_minmax(0,1fr)] gap-x-4 gap-y-2 text-[13px]/5">
        <dt class="text-faint">Source</dt>
        <dd><Mockup.source source={@integration.source} /></dd>
        <dt :if={@integration.source} class="text-faint">Release</dt>
        <dd :if={@integration.source}>
          {Mockup.forge_label(@integration.source.forge)}<span
            :if={@integration.source.host}
            class="text-muted"
          >, at <span class="q-mono">{@integration.source.host}</span></span>
        </dd>
        <dt :if={@integration.source} class="text-faint">Publisher</dt>
        <dd :if={@integration.source} class="q-mono">{@integration.source.publisher}</dd>
        <dt class="text-faint">Used by</dt>
        <dd :if={@integration.targets > 0}>
          <a href={Mockup.path("run_setup", nil, @theme)} class="text-accent hover:underline">{@integration.targets} targets</a><span class="text-muted">, in their run setup</span>
        </dd>
        <dd :if={@integration.targets == 0} class="text-muted">No target yet</dd>
        <dt class="text-faint">Added</dt>
        <dd>{@integration.added}</dd>
      </dl>
      <p :if={@integration.source} class="text-[12.5px]/[18px] text-faint">
        This program runs on your nodes with the secrets you link to it.
      </p>
    </SettingsComponents.part>
    """
  end

  defp secrets(assigns) do
    ~H"""
    <p class="max-w-[72ch] text-[13px]/[18px] text-muted">
      Each secret setting the integration declares is linked to a secret of the workspace, by
      its name and environment. The integration reads it when a run needs it; the run never
      sees it. Its plain settings are under <a
        href={@tab_path.("_settings")}
        class="text-accent hover:underline"
      >Settings</a>.
    </p>

    <.table
      id="integration-secrets"
      label={"Secrets of #{@integration.name}"}
      rows={@secrets}
      row_id={&"secret-#{&1.id}"}
    >
      <:col :let={secret} label="Secret setting" kind="title">
        <span class="grid">
          <span class="q-title-mono">{secret.id}</span>
          <span class="text-[12.5px]/[18px] font-normal text-muted">{secret.about}</span>
        </span>
      </:col>
      <:col :let={secret} label="Workspace secret">
        <span :if={secret.linked} class="inline-flex flex-wrap items-baseline gap-1.5">
          <.icon name="hero-arrow-right-micro" class="size-3.5 self-center text-faint" />
          <span class="q-mono text-base-content">{secret.linked}</span>
          <span class="text-faint" aria-hidden="true">·</span>
          <span>{secret.environment}</span>
        </span>
        <.state_word :if={!secret.linked} id={"secret-#{secret.id}-state"} hot>
          Needs a secret
        </.state_word>
      </:col>
      <:action :let={secret}>
        <.button
          :if={secret.linked}
          variant="link"
          href={Mockup.path("settings", :secrets, @theme)}
          aria-label={"Change the secret linked to #{secret.id}"}
        >
          Change
        </.button>
        <.button
          :if={!secret.linked}
          variant="link"
          href={Mockup.path("settings", :secrets, @theme)}
          aria-label={"Choose a secret for #{secret.id}"}
        >
          Choose a secret
        </.button>
      </:action>
    </.table>

    <p class="text-[12.5px]/[18px] text-faint">
      The workspace's secrets are in <a
        href={Mockup.path("settings", :secrets, @theme)}
        class="text-accent hover:underline"
      >
        Secrets and variables</a>, where one secret can serve several integrations.
    </p>
    """
  end

  defp settings(assigns) do
    ~H"""
    <p class="max-w-[72ch] text-[13px]/[18px] text-muted">
      Each plain setting the integration declares, with its value. Its secret settings are
      linked under <a href={@tab_path.("_secrets")} class="text-accent hover:underline">Secrets</a>.
    </p>

    <form id="integration-settings" class="grid gap-4" novalidate>
      <.input
        :if={@integration.source}
        id="integration-repository"
        name="repository"
        label={if @integration.source.forge == :gitlab, do: "Project path", else: "Repository"}
        prefix={host(@integration.source) <> "/"}
        value={@integration.source.repo}
        readonly
      />
      <.input
        :if={@integration.source}
        id="integration-version"
        name="version"
        type="select"
        label="Version"
        options={versions(@integration.source)}
        value={@integration.source.version}
        hint="A release of the repository. Qory reads its description.json again when you change it."
      />
      <%= for setting <- @plain do %>
        <.input
          :if={setting.type == "checkbox"}
          id={"setting-#{setting.id}"}
          name={setting.id}
          type="checkbox"
          label={setting.label}
          checked={setting.value}
        />
        <.input
          :if={setting.type != "checkbox"}
          id={"setting-#{setting.id}"}
          name={setting.id}
          label={setting.label}
          value={setting.value}
          hint={setting.hint}
        />
      <% end %>
      <SettingsComponents.save>
        <.button variant="primary" type="button">Save settings</.button>
        <:note>Runs that start after it use them.</:note>
      </SettingsComponents.save>
    </form>
    """
  end

  # The integration and the page of it that `tab` names; its Overview without a tab.
  defp find(tab) do
    name = to_string(tab || "")

    Enum.find_value(Sample.integrations(), {hd(Sample.integrations()), :overview}, fn
      %{id: ^name} = integration -> {integration, :overview}
      integration -> page(integration, name)
    end)
  end

  defp page(%{id: id} = integration, name) do
    cond do
      name == id <> "_secrets" -> {integration, :secrets}
      name == id <> "_settings" -> {integration, :settings}
      true -> nil
    end
  end

  # The versions a release can be moved to: the one it is at, and the latest if newer.
  defp versions(%{version: latest, latest: latest}), do: [{"#{latest} (latest)", latest}]

  defp versions(%{version: version, latest: latest}),
    do: [version, {"#{latest} (latest)", latest}]

  # The server of a release's forge.
  defp host(%{forge: :github}), do: "github.com"
  defp host(%{forge: :gitlab}), do: "gitlab.com"
  defp host(%{forge: :forgejo, host: host}), do: host
end
