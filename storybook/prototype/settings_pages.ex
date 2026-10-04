defmodule ApiaryWeb.Prototype.SettingsPages do
  @moduledoc """
  The workspace's Settings in the prototype (`ApiaryWeb.Prototype`), the sidebar's foot: a
  section list in two groups, "Workspace" (General, People, Retention) and "What runs are
  given" (Policy, Integrations, Secrets and variables), with the dialogs at their own
  paths: New rule (filled in by the link that opened it), New secret, New variable and
  Delete workspace.
  """
  use Phoenix.Component

  import ApiaryWeb.CoreComponents

  alias ApiaryWeb.Prototype, as: P
  alias ApiaryWeb.Prototype.{Data, Shell}
  alias ApiaryWeb.SettingsComponents

  def render(assigns) do
    page = assigns.page

    assigns =
      assign(assigns,
        sections: Shell.workspace_sections(),
        member: assigns.role == :member,
        owner: assigns.role == :owner,
        current:
          if(page.page in [:integration, :add_integration], do: :integrations, else: page.page)
      )

    ~H"""
    <.general :if={@page.page == :general} {assigns} />
    <.people :if={@page.page == :people} {assigns} />
    <.retention :if={@page.page == :retention} {assigns} />
    <.policy :if={@page.page == :policy} {assigns} />
    <.integrations :if={@page.page == :integrations} {assigns} />
    <.integration :if={@page.page == :integration} {assigns} />
    <.add_integration :if={@page.page == :add_integration} {assigns} />
    <.secrets :if={@page.page == :secrets} {assigns} />
    """
  end

  ## Workspace: General, People, Retention

  defp general(assigns) do
    ~H"""
    <Shell.settings
      heading="Workspace settings"
      groups={@sections}
      current={:general}
      title="General"
      readonly={@member}
    >
      <:subtitle>The workspace's name and its address.</:subtitle>
      <form id="workspace-general" class="grid gap-4" onsubmit="return false" novalidate>
        <.input id="ws-name" name="name" label="Name" value="shop" disabled={@member} />
        <.input
          id="ws-slug"
          name="slug"
          label="Address"
          prefix="acme/"
          value="shop"
          disabled={@member}
        />
        <SettingsComponents.save :if={!@member}>
          <.button
            variant="primary"
            type="button"
            phx-click="done"
            phx-value-to={P.ws("/settings")}
            phx-value-say="Saved."
          >
            Save
          </.button>
        </SettingsComponents.save>
      </form>
      <SettingsComponents.danger_zone :if={!@member}>
        <SettingsComponents.danger_action id="delete-workspace" title="Delete workspace">
          Removes shop, its nodes, rules, integrations, secrets and its run history. It can't be undone.
          <:action>
            <.button variant="danger-ghost" patch={P.ws("/settings/delete")}>Delete workspace…</.button>
          </:action>
        </SettingsComponents.danger_action>
      </SettingsComponents.danger_zone>
    </Shell.settings>

    <Shell.dialog
      :if={@page.dialog == :delete_workspace}
      id="delete-workspace-dialog"
      title="Delete shop?"
      back={P.ws("/settings")}
      size="sm"
    >
      <p>Every node's key is revoked and the run history is removed. Type shop to confirm.</p>
      <.input id="confirm-ws" name="confirm" label="Workspace name" value="" />
      <:footer>
        <.button patch={P.ws("/settings")} data-cancel-button>Cancel</.button>
        <.button variant="danger" disabled>Delete workspace</.button>
      </:footer>
    </Shell.dialog>
    """
  end

  defp people(assigns) do
    ~H"""
    <Shell.settings
      heading="Workspace settings"
      groups={@sections}
      current={:people}
      title="People"
      measure="list"
    >
      <:subtitle>Who reaches this workspace, and at what level.</:subtitle>
      <p class="text-[13px] text-muted">
        Everyone in acme reaches this workspace. People are managed in
        <Shell.go href={P.org("/settings/people")}>acme's Settings › People</Shell.go>
      </p>
      <.table id="ws-people" label="People" rows={Data.people()} row_id={&"person-#{&1.email}"}>
        <:col :let={p} label="Person" kind="title">
          <span class="inline-flex items-center gap-2"><.avatar name={p.email} size="sm" />{p.email}</span>
        </:col>
        <:col :let={p} label="Level">{p.level}</:col>
        <:col :let={p} label="Since" from="sm">{p.since}</:col>
      </.table>
    </Shell.settings>
    """
  end

  defp retention(assigns) do
    ~H"""
    <Shell.settings
      heading="Workspace settings"
      groups={@sections}
      current={:retention}
      title="Retention"
      readonly={@member}
    >
      <:subtitle>
        How long the run history is kept: runs, their events and their terminal logs. Older
        ones are removed each night.
      </:subtitle>
      <div class="q-form-two">
        <.input
          id="keep-runs"
          name="runs"
          type="select"
          label="Runs and their events"
          options={["30 days", "90 days", "1 year", "Always"]}
          value="90 days"
          disabled={@member}
        />
        <.input
          id="keep-logs"
          name="logs"
          type="select"
          label="Terminal logs"
          options={["7 days", "30 days", "90 days", "Always"]}
          value="30 days"
          disabled={@member}
        />
      </div>
      <SettingsComponents.save>
        <.button
          :if={!@member}
          variant="primary"
          type="button"
          phx-click="done"
          phx-value-to={P.ws("/settings/retention")}
          phx-value-say="Saved. Runs are kept 90 days, terminal logs 30."
        >
          Save
        </.button>
        <:note>
          The run history itself is in
          <Shell.go href={P.ws("/runs")}>Runs</Shell.go>
        </:note>
      </SettingsComponents.save>
    </Shell.settings>
    """
  end

  ## What runs are given: Policy

  defp policy(assigns) do
    assigns = assign(assigns, view: assigns.page.view, rules: Data.rules())

    ~H"""
    <Shell.settings
      heading="Workspace settings"
      groups={@sections}
      current={:policy}
      title="Policy"
      measure="list"
    >
      <:subtitle>
        Which hosts the runs of shop may reach, and whether that is only watched or enforced.
      </:subtitle>

      <div class="flex flex-wrap items-center gap-x-4 gap-y-2 text-[13px]/5">
        <span class="font-medium">Mode</span>
        <span :if={@role == :member} class="font-medium">Enforce</span>
        <span :if={@role != :member} class="join">
          <button type="button" class="btn btn-sm join-item">Observe</button>
          <button type="button" class="btn btn-sm btn-primary join-item">Enforce</button>
        </span>
        <span class="text-muted">
          Every repository follows it unless it sets its own. 22 refused attempts in 14 days
          <Shell.go href={P.ws("/network?view=refused")}>Network access</Shell.go>
        </span>
      </div>
      <p :if={@member} class="text-[12.5px] text-muted">
        Only owners and admins change the mode. You may add and change rules that aren't locked.
      </p>

      <.views id="policy-views" label="Policy">
        <:view patch={P.ws("/settings/policy")} count={length(@rules)} current={@view == :rules}>
          Rules
        </:view>
        <:view
          patch={P.ws("/settings/policy/repositories")}
          count={3}
          current={@view == :repositories}
        >
          Repositories
        </:view>
        <:view patch={P.ws("/settings/policy/history")} count={12} current={@view == :history}>
          History
        </:view>
        <:view patch={P.ws("/settings/policy/document")} current={@view == :document}>
          Document
        </:view>
      </.views>

      <div :if={@view == :rules} class="grid gap-3">
        <div class="q-bar">
          <.list_search id="rule-search" label="Find a host" placeholder="Find a host" live={false} />
          <.button
            id="add-rule"
            variant="primary"
            patch={P.new_rule(back: P.ws("/settings/policy"))}
          >
            Add rule
          </.button>
        </div>
        <.rules_table rules={@rules} owner={@owner} id="rules" />
      </div>

      <div :if={@view == :repositories} class="grid gap-3">
        <p class="text-[13px] text-muted">
          The repositories that set their own policy. Each one's difference is changed in its
          own Settings › Policy.
        </p>
        <.table
          id="policy-repos"
          label="Repositories with their own policy"
          rows={[
            %{path: "acme/shop", mode: "Follows the workspace (Enforce)", own: "3 own rules"},
            %{path: "acme/mobile-app", mode: "Observe", own: "1 own rule"},
            %{path: "acme/billing", mode: "Follows the workspace (Enforce)", own: "Variables only"}
          ]}
          row_id={&"policy-repo-#{&1.path}"}
        >
          <:col :let={r} label="Repository" kind="title">{r.path}</:col>
          <:col :let={r} label="Mode">{r.mode}</:col>
          <:col :let={r} label="Its own">{r.own}</:col>
          <:action :let={r}>
            <Shell.go href={P.repo(r.path, "/settings/policy")}>Its Settings › Policy</Shell.go>
          </:action>
        </.table>
      </div>

      <div :if={@view == :history} class="grid gap-3">
        <.table id="policy-history" label="History" rows={Data.policy_history()} row_id={&"v-#{&1.v}"}>
          <:col :let={h} label="Version" kind="num">v{h.v}</:col>
          <:col :let={h} label="Change" kind="title">{h.what}</:col>
          <:col :let={h} label="By">{h.by}</:col>
          <:col :let={h} label="When">{h.when}</:col>
        </.table>
      </div>

      <div :if={@view == :document} class="grid gap-3">
        <p class="text-[13px] text-muted">The policy as one document, version 12.</p>
        <pre class="overflow-x-auto rounded-box border border-line bg-base-200 p-4 font-mono text-[12.5px]/5"><code>mode: enforce
    rules:
      - allow: api.github.com
        paths: ["/*"]
      - allow: registry.npmjs.org
        paths: ["/*"]
      - allow: api.anthropic.com
        paths: ["/v1/*"]
        locked: true
      - allow: docs.example.com
        paths: ["/*"]
      - deny: "*.example.net"
        locked: true</code></pre>
      </div>
    </Shell.settings>

    <.new_rule :if={@page.dialog == :new_rule} rule={@page.rule} />
    """
  end

  @doc "A policy's rules as a table: action, host and path, use, who, the lock, its source."
  attr :id, :string, required: true
  attr :rules, :list, required: true
  attr :owner, :boolean, default: false
  attr :source, :boolean, default: false

  def rules_table(assigns) do
    assigns = assign(assigns, rows: Enum.with_index(assigns.rules))

    ~H"""
    <.table id={@id} label="Rules" rows={@rows} row_id={fn {_r, i} -> "#{@id}-#{i}" end}>
      <:col :let={{r, _}} label="Action">
        <span class={if r.action == "Deny", do: "font-medium text-error", else: "font-medium"}>{r.action}</span>
      </:col>
      <:col :let={{r, _}} label="Host" kind="title">
        <span class="q-mono">{r.host}</span> <span class="q-mono text-faint">{r.path}</span>
      </:col>
      <:col :let={{r, _}} :if={@source} label="Source">{r.source}</:col>
      <:col :let={{r, _}} label="Used, 14 d" kind="num" from="sm">{r.used}</:col>
      <:col :let={{r, _}} label="By" from="md">{r.by}</:col>
      <:col :let={{r, _}} label="" from="sm">
        <span
          :if={r.locked}
          title="Locked: only an owner changes it, and a repository can't override it"
        >
          <.icon name="hero-lock-closed-micro" class="size-4 text-faint" />
        </span>
      </:col>
      <:action :let={{r, i}}>
        <.row_menu id={"#{@id}-#{i}-menu"} label={"Actions for #{r.host}"}>
          <.menu_item disabled={r.locked && !@owner}>Edit…</.menu_item>
          <.menu_item :if={@owner}>{if r.locked, do: "Unlock", else: "Lock"}</.menu_item>
          <.menu_item patch={P.ws("/network")}>Show its connections</.menu_item>
          <.menu_divider />
          <.menu_item disabled={r.locked && !@owner}>Remove…</.menu_item>
        </.row_menu>
      </:action>
    </.table>
    """
  end

  attr :rule, :map, required: true

  # The New rule dialog, over Settings › Policy, filled in by the link that opened it, and
  # returning to it once saved.
  defp new_rule(assigns) do
    rule = assigns.rule
    host = rule.host || ""
    back = rule.back || P.ws("/settings/policy")
    allow = rule.action != "deny"

    assigns =
      assign(assigns,
        host: host,
        back: back,
        allow: allow,
        title:
          case {allow, host} do
            {true, ""} -> "New rule"
            {true, h} -> "Allow #{h}"
            {false, h} -> "Deny #{h}"
          end,
        from: back_label(back)
      )

    ~H"""
    <Shell.dialog id="new-rule" title={@title} back={@back} size="lg">
      <div class="grid gap-3">
        <.input
          id="rule-action"
          name="action"
          type="radio"
          label="Action"
          options={[{"Allow", "allow"}, {"Deny", "deny"}]}
          value={if @allow, do: "allow", else: "deny"}
        />
        <.input
          id="rule-host"
          name="host"
          label="Host"
          value={@host}
          placeholder="e.g. registry.example.com"
        />
        <.input
          id="rule-paths"
          name="paths"
          type="radio"
          label="Paths"
          options={[{"All", "all"}, {@rule.path || "/npm/*", "path"}]}
          value={if @rule.path && @rule.path != "/*", do: "path", else: "all"}
        />
        <.input
          id="rule-for"
          name="for"
          type="radio"
          label="For"
          options={[
            {"Every repository in shop", "workspace"},
            {"#{@rule.repo || "acme/shop"} only: goes into #{@rule.repo || "acme/shop"}'s own rules",
             "repo"}
          ]}
          value="workspace"
        />
        <p :if={@host != ""} class="rounded-box bg-base-200 px-3 py-2 text-[13px]/5 text-muted">
          Refused 14 times in 14 days, last 2 min ago, in {@rule.repo || "acme/shop"}. The policy
          is in Enforce: the next run that asks for it is {if @allow, do: "allowed", else: "refused"}.
        </p>
        <p class="text-[12.5px] text-faint">After saving you go back to {@from}.</p>
      </div>
      <:footer>
        <.button patch={@back}>Cancel</.button>
        <.button
          variant="primary"
          phx-click="done"
          phx-value-to={@back}
          phx-value-say={
            if @host == "",
              do: "Rule added.",
              else:
                "#{if @allow, do: "Allowed", else: "Denied"} #{@host} for every repository in shop."
          }
        >
          {if @allow, do: "Allow host", else: "Deny host"}
        </.button>
      </:footer>
    </Shell.dialog>
    """
  end

  defp back_label(back) do
    cond do
      String.ends_with?(back, "/settings/policy") -> "Settings › Policy"
      String.contains?(back, "/-/settings/policy") -> "the repository's Settings › Policy"
      String.contains?(back, "/-/network") -> "the repository's Network access"
      String.ends_with?(back, "/network") -> "Network access"
      String.contains?(back, "/runs/") -> "the run"
      String.contains?(back, "/targets/") -> "the repository"
      true -> "the Overview"
    end
  end

  ## Integrations

  defp integrations(assigns) do
    all = Data.integrations()
    job = Enum.find(~w(task_source model_provider service output), &(&1 == assigns.params["job"]))

    assigns =
      assign(assigns,
        all: all,
        job: job,
        shown: if(job, do: Enum.filter(all, &(String.to_atom(job) in &1.jobs)), else: all),
        count: fn j -> Enum.count(all, &(j in &1.jobs)) end
      )

    ~H"""
    <Shell.settings
      heading="Workspace settings"
      groups={@sections}
      current={:integrations}
      title="Integrations"
      measure="list"
      readonly={@member}
    >
      <:subtitle>
        The outside systems shop's runs connect to: where tasks come from, the AI models, the
        services the agent may use, and where results go.
      </:subtitle>
      <:actions :if={!@member}>
        <.button variant="primary" patch={P.ws("/settings/integrations/add")}>Add integration</.button>
      </:actions>
      <.views id="integration-views" label="Integrations">
        <:view patch={P.ws("/settings/integrations")} count={length(@all)} current={!@job}>All</:view>
        <:view
          :for={j <- [:task_source, :model_provider, :service, :output]}
          patch={P.ws("/settings/integrations?job=#{j}")}
          count={@count.(j)}
          current={@job == to_string(j)}
        >
          {Data.job_label(j)}s
        </:view>
      </.views>
      <.table id="integrations" label="Integrations" rows={@shown} row_id={&"integration-#{&1.id}"}>
        <:col :let={i} label="Name" kind="title">
          <span class="grid">
            <.link patch={P.integration(i.id)} class="q-title hover:underline">{i.name}</.link>
            <.source source={i.source} />
          </span>
        </:col>
        <:col :let={i} label="Does">
          <span class="inline-flex flex-wrap gap-1">
            <.badge :for={j <- i.jobs}>{Data.job_label(j)}</.badge>
          </span>
        </:col>
        <:col :let={i} label="Used by" from="sm">
          <.link :if={i.needs_secret} patch={P.integration(i.id)}>
            <.state_word hot>Needs a secret</.state_word>
          </.link>
          <span :if={!i.needs_secret}>{i.repos}</span>
        </:col>
        <:action :let={i}>
          <.row_menu id={"integration-#{i.id}-menu"} label={"Actions for #{i.name}"}>
            <.menu_item patch={P.integration(i.id)}>Open</.menu_item>
            <.menu_divider :if={!@member} />
            <.menu_item :if={!@member} disabled>Remove…</.menu_item>
          </.row_menu>
        </:action>
      </.table>
      <p class="text-[12.5px]/[18px] text-faint">
        The views are in the order a run meets them; an integration with several jobs counts
        under each.
      </p>
    </Shell.settings>
    """
  end

  attr :source, :any, required: true

  defp source(%{source: :built_in} = assigns),
    do: ~H"""
    <span class="text-[12.5px] text-faint">Built in</span>
    """

  defp source(%{source: {:url, url}} = assigns) do
    assigns = assign(assigns, url: url)

    ~H"""
    <span class="q-mono truncate text-[12px] text-faint">{@url}</span>
    """
  end

  defp source(%{source: {:release, repo, version, host}} = assigns) do
    assigns = assign(assigns, repo: repo, version: version, host: host)

    ~H"""
    <span class="text-[12.5px] text-faint">
      <span class="q-mono">{@repo} {@version}</span> · {@host}
    </span>
    """
  end

  defp integration(assigns) do
    i = assigns.page.integration
    assigns = assign(assigns, i: i)

    ~H"""
    <Shell.settings
      heading="Workspace settings"
      groups={@sections}
      current={:integrations}
      title={@i.name}
      readonly={@member}
    >
      <:back>
        <.link patch={P.ws("/settings/integrations")} class="text-accent hover:underline">
          ← Integrations
        </.link>
      </:back>
      <:subtitle>
        <span :if={@i.source == :built_in}>Built in · Ships inside Apiary.</span>
        <span :if={@i.source != :built_in}>
          <.source source={@i.source} /> · This program runs on your nodes with the secrets you
          link to it.
        </span>
        Added by dana, 2 Sept 2026.
      </:subtitle>

      <SettingsComponents.part id="what-it-does" title="What it does">
        <dl class="grid gap-2 text-[13.5px]/5">
          <div :for={{job, words} <- @i.what} class="grid grid-cols-[9rem_minmax(0,1fr)] gap-2">
            <dt class="text-muted">{Data.job_label(job)}</dt>
            <dd>
              {words}
              <span :if={job == :service && @i.ways != []} class="mt-1 flex flex-wrap gap-4">
                <span class="text-faint">Default ways:</span>
                <.input
                  :if={:api in @i.ways}
                  id="way-api"
                  name="ways[api]"
                  type="checkbox"
                  label="Calls its API"
                  checked
                  disabled={@member}
                />
                <.input
                  :if={:mcp in @i.ways}
                  id="way-mcp"
                  name="ways[mcp]"
                  type="checkbox"
                  label="Uses it as a tool (MCP)"
                  checked
                  disabled={@member}
                />
              </span>
            </dd>
          </div>
        </dl>
      </SettingsComponents.part>

      <SettingsComponents.part id="integration-settings" title="Settings">
        <div class="grid gap-3">
          <div :for={{label, kind, value} <- @i.settings} class="grid gap-1">
            <.input
              :if={kind == :plain}
              id={"setting-#{label}"}
              name={label}
              label={label}
              value={value}
              disabled={@member}
            />
            <div :if={kind == :secret} class="grid gap-1">
              <span class="inline-flex items-center gap-1.5 text-[13px]/[18px] font-medium">
                <.icon name="hero-lock-closed-micro" class="size-3.5" /> {label}
              </span>
              <span :if={value} class="flex items-center gap-2 text-[13px]">
                <span class="q-mono rounded border border-line px-2 py-1">{value}</span>
                <span class="text-muted">linked · the value is never shown</span>
              </span>
              <span :if={!value} class="flex items-center gap-2 text-[13px]">
                <.state_word hot>Needs a secret</.state_word>
                <Shell.go :if={!@member} href={P.ws("/settings/secrets/new")}>New secret</Shell.go>
              </span>
            </div>
          </div>
        </div>
      </SettingsComponents.part>

      <SettingsComponents.part id="integration-repos" title="Repositories">
        <.input
          id="integration-scope"
          name="scope"
          type="radio"
          options={[{"All repositories", "all"}, {"Only the ones I choose", "some"}]}
          value={if @i.repos == "All repositories", do: "all", else: "some"}
          disabled={@member}
        />
        <p class="text-[12.5px] text-muted">
          {@i.repos}. A repository can narrow its ways in its own
          <Shell.go href={P.repo("acme/shop", "/settings")}>Settings › Integrations</Shell.go>
        </p>
      </SettingsComponents.part>

      <SettingsComponents.save :if={!@member}>
        <.button
          variant="primary"
          type="button"
          phx-click="done"
          phx-value-to={P.integration(@i.id)}
          phx-value-say="Saved. The next run uses it."
        >
          Save
        </.button>
      </SettingsComponents.save>

      <SettingsComponents.danger_zone :if={!@member}>
        <SettingsComponents.danger_action id="remove-integration" title="Remove integration">
          Runs stop using it at their next start.
          <:action><.button variant="danger-ghost" disabled>Remove integration…</.button></:action>
        </SettingsComponents.danger_action>
      </SettingsComponents.danger_zone>
    </Shell.settings>
    """
  end

  defp add_integration(assigns) do
    assigns = assign(assigns, tab: assigns.params["tab"] || "built-in")

    ~H"""
    <Shell.settings
      heading="Workspace settings"
      groups={@sections}
      current={:integrations}
      title="Add integration"
    >
      <:back>
        <.link patch={P.ws("/settings/integrations")} class="text-accent hover:underline">
          ← Integrations
        </.link>
      </:back>
      <:subtitle>
        Built in, or from a release on any forge (GitHub, GitLab, Forgejo or Gitea), or from an
        https URL to its description.json.
      </:subtitle>
      <nav class="q-tabs" aria-label="Where it comes from">
        <.link patch={P.ws("/settings/integrations/add")} aria-current={@tab == "built-in" && "page"}>
          Built in
        </.link>
        <.link
          patch={P.ws("/settings/integrations/add?tab=release")}
          aria-current={@tab == "release" && "page"}
        >
          From a release
        </.link>
      </nav>

      <div :if={@tab == "built-in"} class="grid gap-2">
        <p class="text-[13px] text-muted">
          The model providers and services that ship inside Apiary.
        </p>
        <.table
          id="built-in"
          label="Built in"
          rows={[
            %{name: "Anthropic", job: "Model provider", added: true},
            %{name: "OpenAI", job: "Model provider", added: false},
            %{name: "Model gateway", job: "Model provider · Service", added: true},
            %{name: "Package registry", job: "Service", added: true},
            %{name: "API service", job: "Service", added: false}
          ]}
          row_id={&"builtin-#{&1.name}"}
        >
          <:col :let={b} label="Name" kind="title">{b.name}</:col>
          <:col :let={b} label="Does">{b.job}</:col>
          <:action :let={b}>
            <span :if={b.added} class="text-[12.5px] text-faint">Added</span>
            <.button
              :if={!b.added}
              size="xs"
              phx-click="done"
              phx-value-to={P.ws("/settings/integrations")}
              phx-value-say={"#{b.name} added. Link its secret to use it."}
            >
              Add
            </.button>
          </:action>
        </.table>
      </div>

      <form :if={@tab == "release"} class="grid gap-4" onsubmit="return false">
        <.input
          id="release-forge"
          name="forge"
          type="radio"
          label="Where is it published?"
          options={[{"GitHub", "github"}, {"GitLab", "gitlab"}, {"Forgejo or Gitea", "forgejo"}]}
          value="gitlab"
        />
        <div class="q-form-two">
          <.input id="release-host" name="host" label="Host" value="gitlab.example.com" />
          <.input id="release-repo" name="repo" label="Repository" value="acme/qory-jira" />
        </div>
        <.input
          id="release-version"
          name="release"
          type="select"
          label="Release"
          options={["latest", "1.2.0", "1.1.0"]}
          value="latest"
        />
        <.input
          id="release-url"
          name="url"
          label="or URL"
          placeholder="https://example.com/…/description.json"
          value=""
        />
        <p class="rounded-box bg-base-200 px-3 py-2 text-[13px]/5">
          Preview: Jira 1.2.0 · Published by acme · Task source · Settings it asks for: 3
        </p>
        <SettingsComponents.save>
          <.button
            variant="primary"
            type="button"
            phx-click="done"
            phx-value-to={P.integration("jira")}
            phx-value-say="Jira added."
          >
            Add integration
          </.button>
          <:note>This program runs on your nodes with the secrets you link to it.</:note>
        </SettingsComponents.save>
      </form>
    </Shell.settings>
    """
  end

  ## Secrets and variables

  defp secrets(assigns) do
    assigns = assign(assigns, view: assigns.page.view)

    ~H"""
    <Shell.settings
      heading="Workspace settings"
      groups={@sections}
      current={:secrets}
      title="Secrets and variables"
      measure="list"
      readonly={@member}
    >
      <:subtitle>
        Values runs are given. A secret is never shown again once saved; a variable is plain
        text.
      </:subtitle>
      <:actions :if={!@member}>
        <.button patch={P.ws("/settings/variables/new")}>New variable</.button>
        <.button variant="primary" patch={P.ws("/settings/secrets/new")}>New secret</.button>
      </:actions>
      <.views id="value-views" label="Secrets and variables">
        <:view
          patch={P.ws("/settings/secrets")}
          count={length(Data.secrets())}
          current={@view == :secrets}
        >
          Secrets
        </:view>
        <:view
          patch={P.ws("/settings/variables")}
          count={length(Data.variables())}
          current={@view == :variables}
        >
          Variables
        </:view>
      </.views>

      <.table
        :if={@view == :secrets}
        id="secrets"
        label="Secrets"
        rows={Data.secrets()}
        row_id={&"secret-#{&1.name}"}
      >
        <:col :let={s} label="Name" kind="title"><span class="q-title-mono">{s.name}</span></:col>
        <:col :let={s} label="Values">{s.values}</:col>
        <:col :let={s} label="Used by">
          <span :if={!s.used} class="text-faint">Not linked</span>
          <span :if={s.used}>{s.used}</span>
        </:col>
        <:col :let={s} label="Changed" from="sm">{s.changed}</:col>
        <:action :let={s}>
          <.row_menu :if={!@member} id={"secret-#{s.name}-menu"} label={"Actions for #{s.name}"}>
            <.menu_item>Change value…</.menu_item>
            <.menu_divider />
            <.menu_item>Delete…</.menu_item>
          </.row_menu>
        </:action>
      </.table>

      <div :if={@view == :variables} class="grid gap-2">
        <.table
          id="variables"
          label="Variables"
          rows={Data.variables()}
          row_id={&"variable-#{&1.name}"}
        >
          <:col :let={v} label="Name" kind="title"><span class="q-title-mono">{v.name}</span></:col>
          <:col :let={v} label="Value"><span class="q-mono">{v.value}</span></:col>
          <:col :let={v} label="Level">
            {v.note}
            <span :if={v.locked} class="inline-flex items-center gap-1 text-muted">
              · <.icon name="hero-lock-closed-micro" class="size-3.5" /> locked
            </span>
          </:col>
          <:action :let={v}>
            <.row_menu :if={!@member} id={"variable-#{v.name}-menu"} label={"Actions for #{v.name}"}>
              <.menu_item>Change value…</.menu_item>
              <.menu_item>{if v.locked, do: "Unlock", else: "Lock"}</.menu_item>
            </.row_menu>
          </:action>
        </.table>
        <p class="text-[12.5px]/[18px] text-faint">
          A repository may add to or override these in its own Settings › Variables, unless a
          name is locked. Apiary leads: a node can't change a name Apiary sets.
        </p>
      </div>
    </Shell.settings>

    <Shell.dialog
      :if={@page.dialog == :new_secret}
      id="new-secret"
      title="New secret"
      back={P.ws("/settings/secrets")}
    >
      <.input id="secret-name" name="name" label="Name" value="SLACK_BOT_TOKEN" />
      <.input
        id="secret-value-id"
        name="value_id"
        label="Value ID"
        value=""
        optional
        hint="Name it when the secret will hold several values."
      />
      <.input id="secret-value" name="value" type="textarea" label="Value" value="" />
      <p class="text-[12.5px] text-muted">It is never shown again once saved.</p>
      <:footer>
        <.button patch={P.ws("/settings/secrets")}>Cancel</.button>
        <.button
          variant="primary"
          phx-click="done"
          phx-value-to={P.ws("/settings/secrets")}
          phx-value-say="Secret saved."
        >
          Save secret
        </.button>
      </:footer>
    </Shell.dialog>

    <Shell.dialog
      :if={@page.dialog == :new_variable}
      id="new-variable"
      title="New variable"
      back={P.ws("/settings/variables")}
    >
      <.input id="variable-name" name="name" label="Name" value="" placeholder="e.g. TEST_COMMAND" />
      <.input id="variable-value" name="value" label="Value" value="" />
      <.input
        id="variable-lock"
        name="lock"
        type="checkbox"
        label="Lock: repositories can't override it"
      />
      <:footer>
        <.button patch={P.ws("/settings/variables")}>Cancel</.button>
        <.button
          variant="primary"
          phx-click="done"
          phx-value-to={P.ws("/settings/variables")}
          phx-value-say="Variable saved."
        >
          Save variable
        </.button>
      </:footer>
    </Shell.dialog>
    """
  end
end
