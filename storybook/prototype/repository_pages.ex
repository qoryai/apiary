defmodule ApiaryWeb.Prototype.RepositoryPages do
  @moduledoc """
  A repository in the prototype (`ApiaryWeb.Prototype`), a level of its own: its
  operational tabs, Overview, Runs and Network access, the workspace's records with the
  repository fixed; and ⚙ Settings at the right end of the tab bar, with Integrations,
  Policy and Variables.
  """
  use Phoenix.Component

  import ApiaryWeb.CoreComponents

  alias ApiaryWeb.Prototype, as: P
  alias ApiaryWeb.Format
  alias ApiaryWeb.Prototype.{Data, SettingsPages, Shell, WorkspacePages}
  alias ApiaryWeb.SettingsComponents

  def render(assigns) do
    repo = assigns.page.repo

    assigns =
      assign(assigns,
        repo: repo,
        tab: assigns.page.page,
        member: assigns.role == :member,
        runs: Enum.filter(Data.runs(), &(&1.repo == repo.path)),
        conns: Data.connections(repo.path),
        shop: repo.path == "acme/shop"
      )

    ~H"""
    <Shell.level_header
      icon="hero-folder"
      tabs_label={@repo.path}
      settings_href={P.repo(@repo.path, "/settings")}
      settings_current={@tab in [:settings_integrations, :settings_policy, :settings_variables]}
    >
      <:name>{@repo.path}</:name>
      <:meta>
        <span>{Format.number(@repo.runs * 6)} runs since 2 Sept 2026</span>
        <span class="q-tgt-meta-sep" aria-hidden="true">·</span>
        <span>last run {@repo.last}</span>
      </:meta>
      <:actions>
        <.button>
          <.icon
            name={if @repo.pinned, do: "hero-star-solid", else: "hero-star"}
            class="size-4 text-primary"
          />
          {if @repo.pinned, do: "Pinned", else: "Pin"}
        </.button>
        <.button title="Opens the repository on its forge, in a new tab">
          Open on github.com <.icon name="hero-arrow-top-right-on-square-micro" class="size-3.5" />
        </.button>
      </:actions>
      <:tab href={P.repo(@repo.path)} current={@tab == :overview} icon="hero-book-open">
        Overview
      </:tab>
      <:tab
        href={P.repo(@repo.path, "/runs")}
        current={@tab == :runs}
        icon="hero-play-circle"
        count={Format.number(@repo.runs * 6)}
      >
        Runs
      </:tab>
      <:tab
        href={P.repo(@repo.path, "/network")}
        current={@tab == :network}
        icon="hero-globe-alt"
        count={Enum.count(@conns, &(&1.state == :refused))}
      >
        Network access
      </:tab>
    </Shell.level_header>

    <.overview :if={@tab == :overview} {assigns} />
    <WorkspacePages.runs_list
      :if={@tab == :runs}
      runs={@runs}
      view={@params["view"]}
      base={P.repo(@repo.path, "/runs")}
      fixed={{"repo", @repo.path}}
      total={Format.number(@repo.runs * 6)}
    />
    <WorkspacePages.network_list
      :if={@tab == :network}
      conns={@conns}
      view={@params["view"]}
      base={P.repo(@repo.path, "/network")}
      back={P.repo(@repo.path, "/network")}
      repo={@repo.path}
      fixed
    />
    <.settings
      :if={@tab in [:settings_integrations, :settings_policy, :settings_variables]}
      {assigns}
    />
    """
  end

  defp overview(assigns) do
    ~H"""
    <div class="grid gap-6 lg:grid-cols-[minmax(0,1fr)_20rem]">
      <div class="grid content-start gap-4">
        <section class="grid gap-2 rounded-box border border-line p-4">
          <h2 class="font-semibold">Latest runs</h2>
          <div :for={r <- Enum.take(@runs, 3)} class="flex items-center gap-3 text-[13.5px]/5">
            <.link patch={P.run(r.id)} class="min-w-0 flex-1 truncate hover:underline">{r.task}</.link>
            <Shell.run_state state={r.state} />
            <span class="w-10 text-right text-faint">{r.took}</span>
          </div>
          <p :if={@runs == []} class="text-[13px] text-muted">No run in 14 days.</p>
          <Shell.go href={P.repo(@repo.path, "/runs")} class="text-[13px]">All runs</Shell.go>
        </section>

        <section class="grid gap-2 rounded-box border border-line p-4">
          <h2 class="font-semibold">Refused in 14 days</h2>
          <div
            :for={c <- Enum.filter(@conns, &(&1.state == :refused))}
            class="flex items-center gap-3 text-[13.5px]/5"
          >
            <span class="q-mono min-w-0 flex-1 truncate">{c.host}
            <span class="text-faint">{c.path}</span></span>
            <span class="text-error">{c.count}</span>
            <Shell.go
              :if={!c.rule}
              href={
                P.new_rule(host: c.host, path: c.path, repo: @repo.path, back: P.repo(@repo.path))
              }
            >
              Allow…
            </Shell.go>
          </div>
          <p :if={!Enum.any?(@conns, &(&1.state == :refused))} class="text-[13px] text-muted">
            Nothing refused.
          </p>
          <Shell.go href={P.repo(@repo.path, "/network")} class="text-[13px]">
            All in Network access
          </Shell.go>
        </section>

        <p class="max-w-[72ch] text-[12.5px]/[18px] text-faint">
          What Apiary knows: this repository's name and forge, from its runs. It doesn't read its
          code or manage its webhooks; the integrations its runs use say what they do.
        </p>
      </div>

      <aside class="grid content-start gap-5 text-[13px]/5">
        <section class="grid gap-1.5">
          <h2 class="font-semibold">About</h2>
          <.kv k="Forge">github.com</.kv>
          <.kv k="Path"><span class="q-mono">{@repo.path}</span></.kv>
          <.kv k="First seen">2 Sept 2026</.kv>
          <.kv k="Nodes used">
            {@runs |> Enum.map(& &1.node) |> Enum.uniq() |> Enum.join(", ")}
          </.kv>
          <.kv k="Runtimes">claude-code</.kv>
        </section>
        <section class="grid gap-1.5">
          <h2 class="font-semibold">Its settings</h2>
          <.link patch={P.repo(@repo.path, "/settings/policy")} class="flex gap-2 hover:underline">
            <span class="w-24 text-muted">Policy</span>
            <span class="flex-1">{if @shop, do: "Enforce, 3 own rules", else: "Follows the workspace"}</span>
            <span class="text-accent">→</span>
          </.link>
          <.link patch={P.repo(@repo.path, "/settings")} class="flex gap-2 hover:underline">
            <span class="w-24 text-muted">Integrations</span>
            <span class="flex-1">GitHub, Anthropic, +3</span>
            <span class="text-accent">→</span>
          </.link>
          <.link patch={P.repo(@repo.path, "/settings/variables")} class="flex gap-2 hover:underline">
            <span class="w-24 text-muted">Variables</span>
            <span class="flex-1">{if @shop, do: "2 of its own", else: "The workspace's"}</span>
            <span class="text-accent">→</span>
          </.link>
        </section>
      </aside>
    </div>
    """
  end

  attr :k, :string, required: true
  slot :inner_block, required: true

  defp kv(assigns) do
    ~H"""
    <div class="grid grid-cols-[6.5rem_minmax(0,1fr)] gap-2">
      <span class="text-muted">{@k}</span><span class="min-w-0">{render_slot(@inner_block)}</span>
    </div>
    """
  end

  ## Settings

  defp settings(assigns) do
    assigns =
      assign(assigns,
        groups: [
          {nil,
           [
             %{
               key: :settings_integrations,
               label: "Integrations",
               href: P.repo(assigns.repo.path, "/settings")
             },
             %{
               key: :settings_policy,
               label: "Policy",
               href: P.repo(assigns.repo.path, "/settings/policy")
             },
             %{
               key: :settings_variables,
               label: "Variables",
               href: P.repo(assigns.repo.path, "/settings/variables")
             }
           ]}
        ]
      )

    ~H"""
    <.integrations :if={@tab == :settings_integrations} {assigns} />
    <.policy :if={@tab == :settings_policy} {assigns} />
    <.variables :if={@tab == :settings_variables} {assigns} />
    """
  end

  defp integrations(assigns) do
    ~H"""
    <Shell.settings
      groups={@groups}
      current={:settings_integrations}
      title="Integrations"
      readonly={@member}
    >
      <:subtitle>
        What runs of {@repo.path} connect to. Integrations and their secrets are set up once in
        the workspace's <.link
          patch={P.ws("/settings/integrations")}
          class="text-accent hover:underline"
        >
          Settings › Integrations</.link>; here you choose which of them this repository's runs use.
      </:subtitle>

      <.group id="before" stage="Before the run" title="Where tasks come from">
        <.choice id="ts-github" name="GitHub" checked={true} member={@member}>
          Turns an issue labelled agent into a run's task.
        </.choice>
        <.choice id="ts-jira" name="Jira" checked={false} member={@member}>
          Not used by this repository.
        </.choice>
      </.group>

      <.group id="models" stage="During the run" title="Which AI models the agent uses">
        <.choice id="mp-anthropic" name="Anthropic" all member={@member}>All repositories</.choice>
        <.choice id="mp-gateway" name="Model gateway" checked={false} member={@member} />
      </.group>

      <.group id="services" stage="During the run" title="Services the agent may use">
        <p class="pl-7 text-[12px] font-medium text-faint">How the agent uses it</p>
        <.choice id="sv-github" name="GitHub" all member={@member}>
          <.ways api mcp member={@member} />
        </.choice>
        <.choice id="sv-internal" name="Internal API" checked={true} member={@member}>
          <.ways api member={@member} />
        </.choice>
        <.choice id="sv-registry" name="Package registry" all member={@member}>
          <.ways api member={@member} />
        </.choice>
        <.choice id="sv-docs" name="Docs search" checked={false} member={@member}>
          <span class="text-faint">Uses it as a tool (MCP)</span>
        </.choice>
      </.group>

      <.group id="after" stage="After the run" title="Where results go">
        <.choice id="out-github" name="GitHub" checked={true} member={@member}>
          Opens a pull request with the run's changes.
        </.choice>
        <.choice id="out-slack" name="Slack" checked={false} member={@member}>
          <.state_word hot>Needs a secret</.state_word>
          <Shell.go href={P.integration("slack")}>Link it</Shell.go>
        </.choice>
      </.group>

      <SettingsComponents.save>
        <.button
          :if={!@member}
          variant="primary"
          type="button"
          phx-click="done"
          phx-value-to={P.repo(@repo.path, "/settings")}
          phx-value-say={"Saved. The next run of #{@repo.path} uses this."}
        >
          Save
        </.button>
        <:note>The next run of {@repo.path} uses this.</:note>
      </SettingsComponents.save>
      <p class="text-[12.5px]/[18px] text-faint">
        ✓ without a box: set for all repositories in the workspace's Settings. Only its ways can
        be narrowed here, from the defaults set on the integration.
      </p>
    </Shell.settings>
    """
  end

  attr :id, :string, required: true
  attr :stage, :string, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  defp group(assigns) do
    ~H"""
    <fieldset id={@id} class="grid gap-2">
      <legend class="mb-1 text-[11px]/4 font-semibold uppercase tracking-[0.04em] text-faint">
        {@stage} ·
        <span class="normal-case tracking-normal text-[13px] text-base-content">{@title}</span>
      </legend>
      {render_slot(@inner_block)}
    </fieldset>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :checked, :boolean, default: false
  attr :all, :boolean, default: false
  attr :member, :boolean, default: false
  slot :inner_block

  defp choice(assigns) do
    ~H"""
    <div class="grid grid-cols-[1.25rem_10rem_minmax(0,1fr)] items-center gap-x-2 text-[13.5px]/5">
      <span :if={@all} class="text-success" title="Set for all repositories">✓</span>
      <input
        :if={!@all}
        id={@id}
        type="checkbox"
        class="checkbox checkbox-sm checkbox-primary"
        checked={@checked}
        disabled={@member}
      />
      <label for={@id} class="font-medium">{@name}</label>
      <span class="min-w-0 text-muted">{render_slot(@inner_block)}</span>
    </div>
    """
  end

  attr :api, :boolean, default: false
  attr :mcp, :boolean, default: false
  attr :member, :boolean, default: false

  defp ways(assigns) do
    ~H"""
    <span class="inline-flex flex-wrap gap-4">
      <label :if={@api} class="inline-flex items-center gap-1.5">
        <input type="checkbox" class="checkbox checkbox-xs" checked disabled={@member} />
        Calls its API
      </label>
      <label :if={@mcp} class="inline-flex items-center gap-1.5">
        <input type="checkbox" class="checkbox checkbox-xs" checked disabled={@member} />
        Uses it as a tool (MCP)
      </label>
    </span>
    """
  end

  defp policy(assigns) do
    rules =
      if assigns.shop, do: Data.repository_rules() ++ Data.rules(), else: Data.rules()

    assigns = assign(assigns, rules: rules)

    ~H"""
    <Shell.settings groups={@groups} current={:settings_policy} title="Policy" measure="list">
      <:subtitle>
        Its mode, and its own rules beside the workspace's. Its rules narrow the workspace's;
        a locked rule holds.
      </:subtitle>
      <.input
        id="repo-mode"
        name="mode"
        type="radio"
        label="Mode"
        options={[
          {"Follow the workspace (Enforce)", "follow"},
          {"Observe", "observe"},
          {"Enforce", "enforce"}
        ]}
        value="follow"
        disabled={@member}
      />
      <div class="q-bar">
        <.list_search
          id="repo-rule-search"
          label="Find a host"
          placeholder="Find a host"
          live={false}
        />
        <.button
          variant="primary"
          patch={P.new_rule(repo: @repo.path, back: P.repo(@repo.path, "/settings/policy"))}
        >
          Add rule
        </.button>
      </div>
      <SettingsPages.rules_table id="repo-rules" rules={@rules} owner={@role == :owner} source />
      <p class="text-[12.5px]/[18px] text-faint">
        Its own first, then those of the workspace, each with its Source. The workspace's are
        changed in
        <Shell.go href={P.ws("/settings/policy")}>the workspace's Settings › Policy</Shell.go>
      </p>
    </Shell.settings>
    """
  end

  defp variables(assigns) do
    vars =
      if assigns.shop,
        do: Data.repository_variables(),
        else: Enum.drop(Data.repository_variables(), 2)

    assigns = assign(assigns, vars: vars)

    ~H"""
    <Shell.settings
      groups={@groups}
      current={:settings_variables}
      title="Variables"
      measure="list"
      readonly={@member}
    >
      <:subtitle>
        Its own values, and those it inherits from the workspace. Its own win, unless the
        workspace locked the name.
      </:subtitle>
      <:actions :if={!@member}><.button>New variable</.button></:actions>
      <.table id="repo-variables" label="Variables" rows={@vars} row_id={&"rv-#{&1.name}"}>
        <:col :let={v} label="Name" kind="title"><span class="q-title-mono">{v.name}</span></:col>
        <:col :let={v} label="Value"><span class="q-mono">{v.value}</span></:col>
        <:col :let={v} label="Source">
          <span :if={v.source == "Workspace"}>
            <.link patch={P.ws("/settings/variables")} class="hover:underline">Workspace</.link>
          </span>
          <span :if={v.source != "Workspace"}>{v.source}</span>
          <span :if={v.locked} class="inline-flex items-center gap-1 text-muted">
            · <.icon name="hero-lock-closed-micro" class="size-3.5" /> Locked by the workspace
          </span>
        </:col>
      </.table>
    </Shell.settings>
    """
  end
end
