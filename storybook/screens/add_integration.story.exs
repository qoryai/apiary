defmodule ApiaryWeb.Storybook.Screens.AddIntegration do
  @moduledoc false
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ApiaryWeb.CoreComponents

  alias ApiaryWeb.{RunComponents, SettingsComponents}
  alias ApiaryWeb.Storybook.{Mockup, Sample}

  def doc,
    do:
      "Add integration, two ways: built in, an LLM provider or a service that ships inside " <>
        "Apiary, or from a release on GitHub, GitLab or Forgejo/Gitea, or at a URL, whose " <>
        "description.json says what it is. Qory's own are suggested beside the sources."

  # Where a release is published, each a tab of the story: its forge, or a URL.
  @sources [
    {:release_github, :github},
    {:release_gitlab, :gitlab},
    {:release_forgejo, :forgejo},
    {:release_url, :url}
  ]

  def navigation do
    [{:built_in, "Built in"}] ++
      for({tab, source} <- @sources, do: {tab, "From a release › #{Mockup.forge_label(source)}"}) ++
      for(item <- Sample.suggested(), do: {suggested_tab(item), "Suggested › #{item.repo}"})
  end

  def render(assigns) do
    assigns = assign(assigns, :current, assigns.tab || :built_in)

    ~H"""
    <Mockup.shell theme={@theme} nav={:settings}>
      <:crumb href={Mockup.path("integrations", :all, @theme)}>Integrations</:crumb>
      <:crumb>Add integration</:crumb>

      <SettingsComponents.layout
        scope={Sample.scope()}
        kind={:workspace}
        sections={Mockup.settings_sections(@theme)}
        counts={Mockup.settings_counts()}
        current={:integrations}
        title="Add integration"
      >
        <:subtitle>Choose where it comes from. You link its secrets once it is added.</:subtitle>

        <div class="[--q-gutter:0px]">
          <RunComponents.tabs id="add-integration-tabs" label="Where it comes from">
            <:tab
              id="add-tab-built-in"
              navigate={Mockup.path("add_integration", :built_in, @theme)}
              current={@current == :built_in}
              icon="hero-cube"
            >
              Built in
            </:tab>
            <:tab
              id="add-tab-release"
              navigate={Mockup.path("add_integration", :release_github, @theme)}
              current={@current != :built_in}
              icon="hero-arrow-down-tray"
            >
              From a release
            </:tab>
          </RunComponents.tabs>
        </div>

        <.built_in :if={@current == :built_in} theme={@theme} />
        <.from_release :if={@current != :built_in} current={@current} theme={@theme} />
      </SettingsComponents.layout>
    </Mockup.shell>
    """
  end

  attr :theme, :any, required: true

  defp built_in(assigns) do
    assigns = assign(assigns, :catalogue, Sample.built_in())

    ~H"""
    <p class="text-[13px]/[18px] text-muted">
      What ships inside Apiary: LLM providers and services. Each is added once, and serves
      every target of the workspace that chooses it. Everything else comes from a release.
    </p>
    <.table
      id="built-in"
      label="Built-in integrations"
      rows={@catalogue}
      row_id={&"built-in-#{&1.id}"}
    >
      <:col :let={item} label="Integration" kind="title">{item.name}</:col>
      <:col :let={item} label="Roles"><Mockup.roles roles={item.roles} /></:col>
      <:col :let={item} label="Connects" from="sm"><Mockup.ways ways={item.ways} /></:col>
      <:action :let={item}>
        <.state_word :if={item.added}>Added</.state_word>
        <.button
          :if={!item.added}
          variant="link"
          href={Mockup.path("integrations", :all, @theme)}
          aria-label={"Add #{item.name}"}
        >
          Add
        </.button>
      </:action>
    </.table>
    """
  end

  attr :current, :atom, required: true
  attr :theme, :any, required: true

  defp from_release(assigns) do
    {source, found} = chosen(assigns.current)
    added = MapSet.new(Sample.integrations(), &(&1.source && &1.source.repo))

    assigns =
      assign(assigns,
        source: source,
        found: found,
        sources: @sources,
        suggested: Enum.map(Sample.suggested(), &Map.put(&1, :added, &1.repo in added))
      )

    ~H"""
    <p class="max-w-[72ch] text-[13px]/[18px] text-muted">
      An integration is a program its publisher releases: on a forge, or at an address of
      its own. Choose where the release is published and which one it is.
    </p>

    <div class="grid gap-3">
      <.views id="release-sources" label="Where the release is published">
        <:view
          :for={{tab, place} <- @sources}
          id={"release-source-#{place}"}
          navigate={Mockup.path("add_integration", tab, @theme)}
          current={place == @source}
        >
          {Mockup.forge_label(place)}
        </:view>
      </.views>

      <section id="add-suggested" aria-labelledby="add-suggested-title" class="grid gap-1.5">
        <h3 id="add-suggested-title" class="text-[12.5px]/[18px] font-medium text-muted">
          Suggested <span class="font-normal text-faint">· Qory's own</span>
        </h3>
        <ul class="grid gap-1.5">
          <li
            :for={item <- @suggested}
            id={"suggested-#{item.id}"}
            class="flex flex-wrap items-center gap-x-3 gap-y-1 rounded-md border border-line px-3 py-2 text-[13px]/5"
          >
            <span class="font-medium">{item.name}</span>
            <span class="q-mono text-muted">{item.repo}</span>
            <Mockup.roles roles={item.roles} />
            <span class="ml-auto inline-flex items-baseline gap-3">
              <span :if={item.added} class="text-[12.5px]/[18px] text-faint">
                In this workspace
              </span>
              <.button
                variant="link"
                href={Mockup.path("add_integration", suggested_tab(item), @theme)}
                aria-label={"Choose #{item.repo} #{item.version}"}
              >
                Choose {item.version}
              </.button>
            </span>
          </li>
        </ul>
      </section>
    </div>

    <form id="add-from-release" class="grid gap-4" novalidate>
      <.input
        :if={@source == :github}
        id="add-repository"
        name="repository"
        label="Repository"
        prefix="github.com/"
        value={@found.repo}
        placeholder="owner/repo"
      />
      <.input
        :if={@source == :gitlab}
        id="add-project"
        name="project"
        label="Project path"
        prefix="gitlab.com/"
        value={@found.project}
        placeholder="group/project"
        hint="The project's full path, its groups included, such as acme/tools/qory-jira."
      />
      <.input
        :if={@source == :forgejo}
        id="add-host"
        name="host"
        label="Server"
        value={@found.host}
        placeholder="git.example.com"
        hint="The host of the Forgejo or Gitea server."
      />
      <.input
        :if={@source == :forgejo}
        id="add-repository"
        name="repository"
        label="Repository"
        value={@found.repo}
        placeholder="owner/repo"
      />
      <.input
        :if={@source != :url}
        id="add-version"
        name="version"
        label="Version"
        value={@found.version}
        hint="A release of the repository, by its tag, such as 1.4.0."
      />
      <.input
        :if={@source == :url}
        id="add-url"
        name="url"
        label="Address of its description.json"
        value={@found.url}
        placeholder="https://"
        hint="An HTTPS address, such as https://downloads.example.com/qory-jira/1.4.0/description.json."
      />
      <.notice>
        Qory reads the release's <code class="font-mono">description.json</code>: the
        integration's name, its version, its roles, the ways it connects and the settings it
        declares, each secret or plain. Nothing of the release runs here.
      </.notice>

      <SettingsComponents.part id="add-found" title="Found in description.json">
        <dl class="grid grid-cols-[max-content_minmax(0,1fr)] gap-x-4 gap-y-2 text-[13px]/5">
          <dt class="text-faint">Name</dt>
          <dd class="font-medium">{@found.name}</dd>
          <dt class="text-faint">Version</dt>
          <dd class="q-mono">{@found.version}</dd>
          <dt class="text-faint">Roles</dt>
          <dd><Mockup.roles roles={@found.roles} /></dd>
          <dt class="text-faint">About</dt>
          <dd>{@found.about}</dd>
          <dt class="text-faint">Connects</dt>
          <dd><Mockup.ways ways={@found.ways} /></dd>
          <dt class="text-faint">Secret settings</dt>
          <dd class="q-mono">{Enum.join(@found.secrets, ", ")}</dd>
          <dt class="text-faint">Plain settings</dt>
          <dd>{Enum.join(@found.settings, ", ")}</dd>
        </dl>
        <.code_block code={@found.json} label="description.json" />
        <p id="add-publisher" class="text-[13px]/5 text-muted">
          Published by <span class="font-medium text-base-content">{@found.publisher}</span>
          · This program runs on your nodes with the secrets you link to it.
        </p>
      </SettingsComponents.part>

      <SettingsComponents.save
        id="add-save"
        cancel={Mockup.path("integrations", :all, @theme)}
        cancel_by="href"
      >
        <.button variant="primary" href={Mockup.path("integrations", :all, @theme)}>
          Add {@found.name}
        </.button>
        <:note>{secrets_note(@found.secrets)}</:note>
      </SettingsComponents.save>
    </form>
    """
  end

  # The source a tab shows and the release it found: a source's own tab the sample's, a
  # suggestion's tab that suggestion on GitHub.
  defp chosen(tab) do
    case List.keyfind(@sources, tab, 0) do
      {^tab, source} -> {source, Sample.described()}
      nil -> {:github, Enum.find(Sample.suggested(), &(suggested_tab(&1) == tab))}
    end
  end

  defp suggested_tab(item), do: String.to_atom("suggested_" <> item.id)

  defp secrets_note([secret]), do: "Its secret setting, #{secret}, is linked next."

  defp secrets_note(secrets),
    do: "Its secret settings, #{Enum.join(secrets, " and ")}, are linked next."
end
