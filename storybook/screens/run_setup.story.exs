defmodule ApiaryWeb.Storybook.Screens.RunSetup do
  @moduledoc false
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ApiaryWeb.CoreComponents

  alias ApiaryWeb.{RunComponents, SettingsComponents}
  alias ApiaryWeb.Storybook.{Mockup, Sample}

  def doc,
    do:
      "A target's Run setup tab: what a run of acme/shop starts with, each an integration " <>
        "of the workspace of that role, and for each output and service chosen the ways " <>
        "its runs use it, API or MCP, of those it offers."

  # What acme/shop has chosen.
  @task_source "github"
  @llm_provider "anthropic"
  @outputs ~w(github webhook)
  @services ~w(github internal_api registry docs_search)

  # The ways acme/shop's runs use each output and service it chose.
  @ways %{
    "outputs" => %{"github" => [:api], "webhook" => [:api]},
    "services" => %{
      "github" => [:api, :mcp],
      "internal_api" => [:api],
      "registry" => [:api],
      "docs_search" => [:mcp]
    }
  }

  def render(assigns) do
    integrations = Sample.integrations()
    of = fn role -> Enum.filter(integrations, &(role in &1.roles)) end

    assigns =
      assign(assigns,
        task_sources: of.(:task_source),
        llm_providers: of.(:llm_provider),
        outputs: of.(:output),
        services:
          Enum.filter(integrations, &Enum.any?(&1.roles, fn r -> r in [:service, :tool] end)),
        task_source: @task_source,
        llm_provider: @llm_provider,
        chosen_outputs: @outputs,
        chosen_services: @services,
        ways: @ways
      )

    ~H"""
    <Mockup.shell theme={@theme} nav={:pin_shop}>
      <:crumb><RunComponents.target_name path="acme/shop" /></:crumb>

      <header class="q-tgt-head">
        <div class="min-w-0 flex-1">
          <h1 class="q-tgt-h1">
            <.icon name="hero-folder" class="size-5 flex-none text-muted" />
            <RunComponents.target_name path="acme/shop" class="min-w-0 truncate" />
          </h1>
          <p class="q-tgt-meta">
            <span>1,284 runs since 2 Sept 2026</span>
            <span class="q-tgt-meta-sep" aria-hidden="true">·</span>
            <span>last run 4 minutes ago</span>
          </p>
        </div>
        <div class="q-tgt-actions">
          <.button>
            <.icon name="hero-star-micro" class="size-4 text-primary" />Pinned
          </.button>
          <.button href="#">
            Open on git.example.com
            <.icon name="hero-arrow-top-right-on-square-micro" class="size-3.5" />
          </.button>
        </div>
      </header>

      <RunComponents.tabs id="target-tabs" label="Target">
        <:tab id="target-tab-overview" icon="hero-book-open">Overview</:tab>
        <:tab id="target-tab-runs" icon="hero-play-circle" count={1284}>Runs</:tab>
        <:tab id="target-tab-network" icon="hero-globe-alt">Network access</:tab>
        <:tab id="target-tab-policy" icon="hero-shield-check">Policy</:tab>
        <:tab
          id="target-tab-run-setup"
          navigate={Mockup.path("run_setup", nil, @theme)}
          icon="hero-adjustments-horizontal"
          current
        >
          Run setup
        </:tab>
      </RunComponents.tabs>

      <form id="run-setup" class="grid max-w-[45rem] gap-5" novalidate>
        <p class="text-[13px]/[18px] text-muted">
          What a run of acme/shop starts with: where its task comes from, the models it uses,
          where its results go and the services it may reach. Each is one of the workspace's <a
            href={Mockup.path("integrations", :all, @theme)}
            class="text-accent hover:underline"
          >
            integrations</a>.
        </p>

        <.input
          id="run-setup-task-source"
          name="task_source"
          type="select"
          label="Task source"
          prompt="None: a run brings its own task"
          options={for i <- @task_sources, do: {i.name, i.id}}
          value={@task_source}
          hint="Where a run of acme/shop takes its task from."
        />

        <.input
          id="run-setup-llm-provider"
          name="llm_provider"
          type="select"
          label="LLM provider"
          options={for i <- @llm_providers, do: {i.name, i.id}}
          value={@llm_provider}
          hint="The models the run's runtime is given."
        />

        <.choices
          id="run-setup-outputs"
          legend="Outputs"
          hint="Each receives what a run did when it ends."
          integrations={@outputs}
          chosen={@chosen_outputs}
          ways={@ways["outputs"]}
          theme={@theme}
        />

        <.choices
          id="run-setup-services"
          legend="Services"
          hint="What a run may reach while it works, the tools among them; it never sees their credentials."
          integrations={@services}
          chosen={@chosen_services}
          ways={@ways["services"]}
          theme={@theme}
        />

        <SettingsComponents.save>
          <.button variant="primary" type="button">Save run setup</.button>
          <:note>The next run of acme/shop starts with it.</:note>
        </SettingsComponents.save>
      </form>
    </Mockup.shell>
    """
  end

  attr :id, :string, required: true
  attr :legend, :string, required: true
  attr :hint, :string, required: true
  attr :integrations, :list, required: true
  attr :chosen, :list, required: true
  attr :ways, :map, required: true, doc: "the ways the target uses each one chosen"
  attr :theme, :any, required: true

  # A role whose integrations a target may take several of: a checkbox each; beside one
  # chosen, a checkbox for each way it offers, checked for those the runs use, the only one
  # fixed; and the state of one that needs a secret, with the way to its secrets.
  defp choices(assigns) do
    ~H"""
    <fieldset id={@id} class="fieldset gap-2" aria-describedby={"#{@id}-hint"}>
      <legend class="mb-1 text-[13px]/[18px] font-medium">{@legend}</legend>
      <div :for={integration <- @integrations} class="flex flex-wrap items-center gap-x-3">
        <.input
          id={"#{@id}-#{integration.id}"}
          name={"#{@id}[#{integration.id}]"}
          type="checkbox"
          label={integration.name}
          checked={integration.id in @chosen}
        />
        <span
          :if={integration.id in @chosen}
          role="group"
          aria-label={"Ways the runs use #{integration.name}"}
          class="inline-flex items-center gap-3 border-l border-line pl-3"
        >
          <.input
            :for={way <- integration.ways}
            id={"#{@id}-#{integration.id}-#{way}"}
            name={"#{@id}[#{integration.id}_ways][#{way}]"}
            type="checkbox"
            label={Mockup.way_label(way)}
            checked={way in Map.get(@ways, integration.id, [])}
            disabled={length(integration.ways) == 1}
          />
        </span>
        <a
          :if={Mockup.needs_secret?(integration)}
          href={Mockup.path("integration", String.to_atom("#{integration.id}_secrets"), @theme)}
          class="hover:underline"
        >
          <.state_word hot>Needs a secret</.state_word>
        </a>
      </div>
      <p id={"#{@id}-hint"} class="text-[12.5px]/[18px] text-muted">
        {@hint} Beside each chosen, the ways its runs use it: API, MCP, or both where it offers both.
      </p>
    </fieldset>
    """
  end
end
