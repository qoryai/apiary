defmodule ApiaryWeb.Storybook.Screens.AddIntegration do
  @moduledoc false
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ApiaryWeb.CoreComponents

  alias ApiaryWeb.{RunComponents, SettingsComponents}
  alias ApiaryWeb.Storybook.{Mockup, Sample}

  def doc,
    do:
      "Add integration, three ways: one built in, one from a GitHub repository whose " <>
        "description.json says what it is, or a private one, which an edition may add."

  def navigation,
    do: [{:built_in, "Built in"}, {:from_github, "From GitHub"}, {:private, "Private"}]

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
              id="add-tab-github"
              navigate={Mockup.path("add_integration", :from_github, @theme)}
              current={@current == :from_github}
              icon="hero-code-bracket"
            >
              From GitHub
            </:tab>
            <:tab
              id="add-tab-private"
              navigate={Mockup.path("add_integration", :private, @theme)}
              current={@current == :private}
              icon="hero-lock-closed"
            >
              Private
              <.badge>Not in this edition</.badge>
            </:tab>
          </RunComponents.tabs>
        </div>

        <.built_in :if={@current == :built_in} theme={@theme} />
        <.from_github :if={@current == :from_github} theme={@theme} />
        <.private :if={@current == :private} />
      </SettingsComponents.layout>
    </Mockup.shell>
    """
  end

  attr :theme, :any, required: true

  defp built_in(assigns) do
    assigns = assign(assigns, :catalogue, Sample.built_in())

    ~H"""
    <p class="text-[13px]/[18px] text-muted">
      The integrations Qory ships with. Each is added once, and serves every target of the
      workspace that chooses it.
    </p>
    <.table
      id="built-in"
      label="Built-in integrations"
      rows={@catalogue}
      row_id={&"built-in-#{&1.id}"}
    >
      <:col :let={item} label="Integration" kind="title">{item.name}</:col>
      <:col :let={item} label="Roles"><Mockup.roles roles={item.roles} /></:col>
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

  attr :theme, :any, required: true

  defp from_github(assigns) do
    assigns = assign(assigns, :found, Sample.described())

    ~H"""
    <form id="add-from-github" class="grid gap-4" novalidate>
      <.input
        id="add-repository"
        name="repository"
        label="Repository"
        prefix="github.com/"
        value={@found.repo}
        placeholder="owner/repo"
      />
      <.input
        id="add-version"
        name="version"
        label="Version"
        value={@found.version}
        hint="A tag of the repository, such as 1.4.0."
      />
      <.notice>
        Qory reads the repository's <code class="font-mono">description.json</code>
        at that version: the integration's name, its roles, the secrets it declares and its
        settings. Nothing else of the repository runs here.
      </.notice>

      <SettingsComponents.part id="add-found" title="Found in description.json">
        <dl class="grid grid-cols-[max-content_minmax(0,1fr)] gap-x-4 gap-y-2 text-[13px]/5">
          <dt class="text-faint">Name</dt>
          <dd class="font-medium">{@found.name}</dd>
          <dt class="text-faint">Roles</dt>
          <dd><Mockup.roles roles={@found.roles} /></dd>
          <dt class="text-faint">About</dt>
          <dd>{@found.about}</dd>
          <dt class="text-faint">Secrets</dt>
          <dd class="q-mono">{Enum.join(@found.secrets, ", ")}</dd>
          <dt class="text-faint">Settings</dt>
          <dd>{Enum.join(@found.settings, ", ")}</dd>
        </dl>
        <.code_block code={@found.json} label="description.json" />
      </SettingsComponents.part>

      <SettingsComponents.save>
        <.button variant="primary" href={Mockup.path("integrations", :all, @theme)}>
          Add {@found.name}
        </.button>
        <:note>Its secret, api_token, is linked next.</:note>
      </SettingsComponents.save>
    </form>
    """
  end

  defp private(assigns) do
    ~H"""
    <.notice>
      <strong>Private integrations are not in this edition.</strong>
      Add one from a private repository or a registry of your own, read with a token you give.
    </.notice>
    <form id="add-private" class="grid gap-4" novalidate>
      <.input
        id="add-private-repository"
        name="repository"
        label="Repository"
        value="git.example.com/acme/qory-billing"
        disabled
      />
      <.input id="add-private-version" name="version" label="Version" value="1.0.0" disabled />
      <.input
        id="add-private-token"
        name="token"
        label="Read token"
        type="password"
        value=""
        disabled
      />
      <SettingsComponents.save>
        <.button variant="primary" disabled>Add integration</.button>
        <:note>Not in this edition.</:note>
      </SettingsComponents.save>
    </form>
    """
  end
end
