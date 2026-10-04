defmodule ApiaryWeb.Prototype.WorkspacePages do
  @moduledoc """
  The workspace's operational pages in the prototype (`ApiaryWeb.Prototype`): Overview,
  Runs and a run, Network access, Repositories and Nodes, with New node and New node pool.
  Also the lists a repository's and a node's tabs narrow (`runs_list/1`, `network_list/1`).
  Nothing here changes a setting: a state that needs one is a line with a link into
  Settings.
  """
  use Phoenix.Component

  import ApiaryWeb.CoreComponents

  alias ApiaryWeb.Prototype, as: P
  alias ApiaryWeb.Prototype.{Data, Shell}

  def render(%{page: %{level: :run}} = assigns), do: run(assigns)
  def render(%{page: %{page: :overview}} = assigns), do: overview(assigns)
  def render(%{page: %{page: :runs}} = assigns), do: runs(assigns)
  def render(%{page: %{page: :network}} = assigns), do: network(assigns)
  def render(%{page: %{page: :repositories}} = assigns), do: repositories(assigns)
  def render(%{page: %{page: :nodes}} = assigns), do: nodes(assigns)

  ## Overview

  defp overview(%{params: %{"state" => "new"}} = assigns) do
    ~H"""
    <.header>
      Overview
      <:subtitle>shop has no run yet. Set it up in this order.</:subtitle>
    </.header>

    <section id="setup" class="grid gap-3 rounded-box border border-line p-5">
      <h2 class="text-base/6 font-semibold">Set up shop</h2>
      <ol class="grid gap-3 text-[13.5px]/5">
        <.setup_step n={1} state={:done} title="Add a node">
          build-01 · key approved ·
          <Shell.go href={P.node("build-01", "/settings/keys")}>Access keys</Shell.go>
        </.setup_step>
        <.setup_step n={2} state={:now} title="Connect a model provider">
          Runs need an AI model.
          <Shell.go href={P.ws("/settings/integrations/add")}>Settings › Integrations</Shell.go>
        </.setup_step>
        <.setup_step n={3} state={:todo} title="Connect your forge (optional)">
          Give runs tokens for their repositories.
          <Shell.go href={P.ws("/settings/integrations/add?tab=release")}>Add</Shell.go>
        </.setup_step>
        <.setup_step n={4} state={:todo} title="Start a run">
          On build-01: <code class="q-mono">qory run …</code>
        </.setup_step>
        <.setup_step n={5} state={:todo} title="Review what runs reached, then choose Enforce">
          <Shell.go href={P.ws("/network")}>Network access</Shell.go>
        </.setup_step>
      </ol>
    </section>
    <p class="text-[12.5px]/[18px] text-faint">
      Prototype: this is the Overview before the first run.
      <Shell.go href={P.ws("")}>See the Overview of a working workspace</Shell.go>
    </p>
    """
  end

  defp overview(assigns) do
    assigns =
      assign(assigns,
        member: assigns.role == :member,
        repos: Enum.take(Data.repositories(), 3),
        back: P.ws("")
      )

    ~H"""
    <.header>
      Overview
      <:subtitle>What needs you in shop, then what its agents did.</:subtitle>
    </.header>

    <div class="grid grid-cols-2 gap-3 lg:grid-cols-4">
      <.tile value="2" label="running now" href={P.ws("/runs?view=running")} link="Runs" />
      <.tile value="1,284" label="runs in 14 days" href={P.ws("/runs")} link="Runs" />
      <.tile
        value="31"
        label="ended badly"
        href={P.ws("/runs?view=failed")}
        link="Runs · Ended badly"
      />
      <.tile
        value="22"
        label="refused attempts"
        href={P.ws("/network?view=refused")}
        link="Network access · Refused"
      />
    </div>

    <section id="needs-attention" class="grid gap-2">
      <div class="flex items-baseline justify-between">
        <h2 class="text-base/6 font-semibold">Needs attention</h2>
        <span class="text-[12.5px] text-faint">5 of 5</span>
      </div>
      <div class="divide-y divide-line rounded-box border border-line">
        <.attention
          what="registry.example.com"
          state="refused 14×"
          where="acme/shop"
          why="no rule allows it"
          ago="2 min"
          href={
            P.new_rule(host: "registry.example.com", path: "/npm/*", repo: "acme/shop", back: @back)
          }
          link="Allow…"
        />
        <.attention
          what="build-02"
          state="a key is waiting"
          where="node"
          why="enrolled with dana's code"
          ago="2 h"
          href={!@member && P.node("build-02", "/settings/keys")}
          link="Review"
        />
        <.attention
          what="Slack"
          state="needs a secret"
          where="output"
          why="used by 3 repositories"
          ago="1 d"
          href={P.integration("slack")}
          link="Link it"
        />
        <.attention
          what="Add rate limiter"
          state="ended badly"
          where="acme/shop"
          why="a tool timed out"
          ago="3 h"
          href={P.run("0191f27e")}
          link="Open"
        />
        <.attention
          what="mac-mini"
          state="not seen for 3 days"
          where="node"
          why="its last run ended well"
          ago="3 d"
          href={P.node("mac-mini")}
          link="Open"
        />
      </div>
    </section>

    <div class="grid gap-6 lg:grid-cols-[minmax(0,1fr)_22rem]">
      <section class="grid content-start gap-4">
        <div class="grid gap-2">
          <h2 class="text-base/6 font-semibold">Activity</h2>
          <div class="flex items-end gap-3 rounded-box border border-line p-4">
            <.sparkline
              values={[12, 18, 22, 30, 41, 52, 47, 39, 44, 58, 63, 51, 40, 27]}
              class="h-16 flex-1"
            />
            <span class="text-[12.5px] text-muted">runs a day, 14 days</span>
          </div>
        </div>
        <div class="grid gap-2">
          <h2 class="text-base/6 font-semibold">Active repositories</h2>
          <.table
            id="active-repos"
            label="Active repositories"
            rows={@repos}
            row_id={&"active-#{&1.path}"}
          >
            <:col :let={r} label="Repository" kind="title">
              <.link patch={P.repo(r.path)} class="q-title hover:underline">{r.path}</.link>
            </:col>
            <:col :let={r} label="Last run"><Shell.run_state state={r.state} /> · {r.last}</:col>
            <:col :let={r} label="Runs, 14 d" kind="num">{r.runs}</:col>
          </.table>
        </div>
      </section>

      <section id="at-a-glance" class="grid content-start gap-2">
        <h2 class="text-base/6 font-semibold">Settings at a glance</h2>
        <dl class="divide-y divide-line rounded-box border border-line text-[13px]/5">
          <.glance label="Policy" href={P.ws("/settings/policy")}>Enforce · v12</.glance>
          <.glance label="Integrations" href={P.ws("/settings/integrations")}>
            8 ·
            <.state_word hot>1 needs a secret</.state_word>
          </.glance>
          <.glance label="Repositories" href={P.ws("/settings/policy/repositories")}>
            3 set their own
          </.glance>
          <.glance label="Nodes" href={P.ws("/nodes")}>
            3 running ·
            <.state_word hot>1 key waiting</.state_word>
          </.glance>
          <.glance label="Retention" href={P.ws("/settings/retention")}>
            runs 90 days, logs 30
          </.glance>
        </dl>
        <p class="text-[12.5px]/[18px] text-faint">
          Each line leads into Settings or a list; nothing is changed on this page.
        </p>
      </section>
    </div>

    <p class="text-[12.5px]/[18px] text-faint">
      Prototype:
      <Shell.go href={P.ws("?state=new")}>see the Overview before the first run</Shell.go>
    </p>
    """
  end

  attr :value, :string, required: true
  attr :label, :string, required: true
  attr :href, :string, required: true
  attr :link, :string, required: true

  defp tile(assigns) do
    ~H"""
    <.link
      patch={@href}
      class="group grid gap-0.5 rounded-box border border-line p-4 hover:bg-base-200"
    >
      <span class="text-2xl/8 font-semibold tabular-nums">{@value}</span>
      <span class="text-[13px] text-muted">{@label}</span>
      <span class="text-[12.5px] text-accent group-hover:underline">{@link} →</span>
    </.link>
    """
  end

  attr :what, :string, required: true
  attr :state, :string, required: true
  attr :where, :string, required: true
  attr :why, :string, required: true
  attr :ago, :string, required: true
  attr :href, :any, required: true
  attr :link, :string, required: true

  defp attention(assigns) do
    ~H"""
    <div class="grid grid-cols-[auto_minmax(0,1fr)_auto] items-center gap-x-3 px-4 py-2.5 text-[13.5px]/5 md:grid-cols-[auto_12rem_10rem_8rem_minmax(0,1fr)_3rem_6rem]">
      <span class="q-dot text-warning" aria-hidden="true"></span>
      <span class="truncate font-medium">{@what}</span>
      <span class="text-muted max-md:hidden">{@state}</span>
      <span class="truncate text-muted max-md:hidden">{@where}</span>
      <span class="truncate text-faint max-md:hidden">{@why}</span>
      <span class="text-faint max-md:hidden">{@ago}</span>
      <span class="text-right">
        <Shell.go :if={@href} href={@href}>{@link}</Shell.go>
        <span :if={!@href} class="text-faint">{@state}</span>
      </span>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :href, :string, required: true
  slot :inner_block, required: true

  defp glance(assigns) do
    ~H"""
    <.link patch={@href} class="flex items-center gap-3 px-4 py-2.5 hover:bg-base-200">
      <dt class="w-24 flex-none text-muted">{@label}</dt>
      <dd class="min-w-0 flex-1">{render_slot(@inner_block)}</dd>
      <span class="text-accent" aria-hidden="true">→</span>
    </.link>
    """
  end

  attr :n, :integer, required: true
  attr :state, :atom, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  defp setup_step(assigns) do
    ~H"""
    <li class="grid grid-cols-[1.5rem_1.5rem_16rem_minmax(0,1fr)] items-baseline gap-2">
      <span :if={@state == :done} class="text-success">✓</span>
      <span :if={@state == :now} class="q-dot text-warning"></span>
      <span :if={@state == :todo} class="text-faint">○</span>
      <span class="text-faint tabular-nums">{@n}</span>
      <span class="font-medium">{@title}</span>
      <span class="text-muted">{render_slot(@inner_block)}</span>
    </li>
    """
  end

  ## Runs

  defp runs(assigns) do
    ~H"""
    <.header>
      Runs
      <:subtitle>The run history of shop: every run of an agent.</:subtitle>
    </.header>
    <.runs_list
      runs={Data.runs()}
      view={@params["view"]}
      base={P.ws("/runs")}
      total="1,284"
    />
    <p class="text-[12.5px]/[18px] text-faint">
      There is no primary action: runs start on nodes.
    </p>
    """
  end

  @doc """
  runs_list/1 is the run history: views by state, the search bar, and the table. `fixed`
  is the level a tab narrows it to, `{"repo", "acme/shop"}` or `{"node", "build-01"}`: a
  token that can't be taken away, and that level's column left out.
  """
  attr :runs, :list, required: true
  attr :view, :string, default: nil
  attr :base, :string, required: true, doc: "the list's path, for its views"
  attr :fixed, :any, default: nil
  attr :total, :string, required: true

  def runs_list(assigns) do
    runs = assigns.runs

    shown =
      case assigns.view do
        "running" -> Enum.filter(runs, &(&1.state == :running))
        "failed" -> Enum.filter(runs, &(&1.state == :failed))
        "refused" -> Enum.filter(runs, &(&1.refused > 0))
        _ -> runs
      end

    assigns =
      assign(assigns,
        shown: shown,
        running: Enum.count(runs, &(&1.state == :running)),
        failed: Enum.count(runs, &(&1.state == :failed)),
        refused: Enum.count(runs, &(&1.refused > 0)),
        kind: assigns.fixed && elem(assigns.fixed, 0)
      )

    ~H"""
    <div class="grid gap-3">
      <.views id="run-views" label="Views">
        <:view patch={@base} count={@total} current={@view in [nil, "all"]}>All</:view>
        <:view patch={@base <> "?view=running"} count={@running} current={@view == "running"}>
          Running
        </:view>
        <:view patch={@base <> "?view=failed"} count={@failed} current={@view == "failed"}>
          Ended badly
        </:view>
        <:view patch={@base <> "?view=refused"} count={@refused} current={@view == "refused"}>
          With refusals
        </:view>
      </.views>
      <div class="q-bar">
        <.list_search
          id="runs-search"
          label="Find a run"
          placeholder="Find a run, e.g. repo:acme/shop node:build-01 fix"
          live={false}
        />
      </div>
      <.fixed_token :if={@fixed} fixed={@fixed} count={length(@shown)} />
      <.table id="runs" label="Runs" rows={@shown} row_id={&"run-#{&1.id}"}>
        <:col :let={r} label="Task" kind="title">
          <.link patch={P.run(r.id)} class="q-title hover:underline">{r.task}</.link>
        </:col>
        <:col :let={r} label="State"><Shell.run_state state={r.state} /></:col>
        <:col :let={r} :if={@kind != "repo"} label="Repository" from="sm">
          <.link patch={P.repo(r.repo)} class="hover:underline">{r.repo}</.link>
        </:col>
        <:col :let={r} :if={@kind != "node"} label="Node" from="md">
          <.link patch={P.node(r.node)} class="hover:underline">{r.node}</.link>
        </:col>
        <:col :let={r} label="Started" from="md">{r.started}</:col>
        <:col :let={r} label="Took" kind="num" from="md">{r.took}</:col>
        <:col :let={r} label="Refused" kind="num">
          <span :if={r.refused > 0} class="text-error">{r.refused}</span>
        </:col>
      </.table>
      <p class="text-[12.5px] text-faint">1–{length(@shown)} of {@total}</p>
    </div>
    """
  end

  attr :fixed, :any, required: true
  attr :count, :integer, required: true

  defp fixed_token(assigns) do
    ~H"""
    <div class="q-tokens">
      <span class="q-tok q-tok-q" title="This tab is narrowed to it; the filter can't be removed">
        <span class="q-tok-k">{elem(@fixed, 0)}:</span>{elem(@fixed, 1)}
        <.icon name="hero-lock-closed-micro" class="size-3.5 text-faint" />
      </span>
      <span class="text-[12.5px] text-faint">Fixed by this tab · {@count} shown</span>
    </div>
    """
  end

  ## A run

  defp run(assigns) do
    run = assigns.page.run
    tab = assigns.page.page

    assigns =
      assign(assigns,
        run: run,
        tab: tab,
        conns: run_connections(run),
        back: P.run(run.id, if(tab == :timeline, do: "", else: "/#{tab}"))
      )

    ~H"""
    <div class="grid gap-6 xl:grid-cols-[minmax(0,1fr)_18rem]">
      <div class="grid content-start gap-4">
        <header class="flex flex-wrap items-start gap-3">
          <div class="min-w-0 flex-1">
            <h1 class="text-xl/7 font-semibold">{@run.task}</h1>
            <p class="flex flex-wrap items-center gap-x-2 text-[13px] text-muted">
              <Shell.run_state state={@run.state} /> · {@run.took} ·
              <.link patch={P.repo(@run.repo)} class="hover:underline">{@run.repo}</.link>
              · {@run.runtime} ·
              <.link patch={P.node(@run.node)} class="hover:underline">{@run.node}</.link>
              · started {@run.started}
              <span :if={@run.refused > 0} class="text-error">· {@run.refused} refused</span>
            </p>
          </div>
          <.button
            :if={@run.state == :running}
            phx-click="done"
            phx-value-to={@back}
            phx-value-say="Run closed. Its record stays in Runs."
          >
            Close run
          </.button>
        </header>

        <nav class="q-tabs" aria-label="Run">
          <.link patch={P.run(@run.id)} aria-current={@tab == :timeline && "page"}>
            <.icon name="hero-queue-list" class="size-4" /> Timeline
          </.link>
          <.link patch={P.run(@run.id, "/terminal")} aria-current={@tab == :terminal && "page"}>
            <.icon name="hero-command-line" class="size-4" /> Terminal
          </.link>
          <.link patch={P.run(@run.id, "/network")} aria-current={@tab == :network && "page"}>
            <.icon name="hero-globe-alt" class="size-4" /> Network access
            <span :if={@run.refused > 0} class="q-tabs-n q-tabs-bad">{@run.refused}</span>
          </.link>
          <.link
            patch={P.run(@run.id, "/details")}
            aria-current={@tab == :details && "page"}
            class="xl:hidden"
          >
            <.icon name="hero-information-circle" class="size-4" /> Details
          </.link>
        </nav>

        <ol :if={@tab == :timeline} class="grid gap-1.5 text-[13px]/5">
          <.event at="14:02:01" mark="▸">Task received: {@run.task}</.event>
          <.event at="14:02:03" mark="▸">Read src/auth/redirect.ts</.event>
          <.event at="14:02:09" mark="↗">
            api.github.com <span class="text-success">allowed</span>
          </.event>
          <.event :if={@run.refused > 0} at="14:02:15" mark="⊘">
            registry.example.com <span class="text-error">refused</span>
            <Shell.go
              href={
                P.new_rule(host: "registry.example.com", path: "/npm/*", repo: @run.repo, back: @back)
              }
              class="ml-2"
            >
              Allow…
            </Shell.go>
          </.event>
          <.event at="14:02:40" mark="▸">Edit src/auth/redirect.ts</.event>
          <.event at="14:03:12" mark="▸">Run the tests: 48 passed</.event>
        </ol>

        <pre
          :if={@tab == :terminal}
          class="overflow-x-auto rounded-box bg-neutral p-4 font-mono text-[12.5px]/5 text-neutral-content"
        ><code>$ npm test
    PASS  src/auth/redirect.test.ts
    PASS  src/orders/totals.test.ts
    Tests: 48 passed, 48 total
    $ npm install @acme/ui
    npm ERR! request to https://registry.example.com/npm/@acme%2fui failed: refused by policy</code></pre>

        <.network_list
          :if={@tab == :network}
          conns={@conns}
          back={@back}
          repo={@run.repo}
          compact
        />

        <.details :if={@tab == :details} run={@run} />
      </div>

      <aside class="max-xl:hidden">
        <.details run={@run} />
      </aside>
    </div>
    """
  end

  defp run_connections(run) do
    Data.connections(run.repo)
    |> Enum.filter(&(run.refused > 0 or &1.state == :allowed))
    |> Enum.take(4)
  end

  attr :at, :string, required: true
  attr :mark, :string, required: true
  slot :inner_block, required: true

  defp event(assigns) do
    ~H"""
    <li class="grid grid-cols-[5rem_1.25rem_minmax(0,1fr)] items-baseline">
      <span class="q-mono text-faint">{@at}</span>
      <span class="text-faint">{@mark}</span>
      <span>{render_slot(@inner_block)}</span>
    </li>
    """
  end

  attr :run, :map, required: true

  defp details(assigns) do
    ~H"""
    <div class="grid gap-4 text-[13px]/5">
      <section class="grid gap-1.5">
        <h2 class="font-semibold">Run</h2>
        <.kv k="Repository">
          <Shell.go href={P.repo(@run.repo)}>{@run.repo}</Shell.go>
        </.kv>
        <.kv k="Node">
          <Shell.go href={P.node(@run.node)}>{@run.node}</Shell.go>
        </.kv>
        <.kv k="Instance"><span class="q-mono">m_4F7KQ2…</span></.kv>
        <.kv k="Runtime">{@run.runtime}</.kv>
        <.kv k="Model">Anthropic</.kv>
      </section>
      <section class="grid gap-1.5">
        <h2 class="font-semibold">Policy in force</h2>
        <p>
          <Shell.go href={P.ws("/settings/policy")}>Enforce · v12</Shell.go>
        </p>
        <p :if={@run.repo == "acme/shop"}>
          acme/shop has 3 own rules
          <Shell.go href={P.repo(@run.repo, "/settings/policy")}>Its policy</Shell.go>
        </p>
      </section>
      <section class="grid gap-1.5">
        <h2 class="font-semibold">Labels</h2>
        <span class="q-mono">repo={@run.repo}</span>
      </section>
    </div>
    """
  end

  attr :k, :string, required: true
  slot :inner_block, required: true

  defp kv(assigns) do
    ~H"""
    <div class="grid grid-cols-[6rem_minmax(0,1fr)] gap-2">
      <span class="text-muted">{@k}</span><span class="min-w-0 truncate">{render_slot(@inner_block)}</span>
    </div>
    """
  end

  ## Network access

  defp network(assigns) do
    ~H"""
    <.header>
      Network access
      <:subtitle>
        Every host the runs reached in the last 14 days, and whether it was allowed.
      </:subtitle>
    </.header>
    <p class="-mt-3 text-[13px] text-muted">
      Policy: Enforce · {length(Data.rules())} rules ·
      <.link patch={P.ws("/settings/policy")} class="text-accent hover:underline">Settings ›</.link>
    </p>
    <.network_list
      conns={Data.connections()}
      view={@params["view"]}
      base={P.ws("/network")}
      back={P.ws("/network")}
    />
    <p class="text-[12.5px]/[18px] text-faint">
      Allow… and Deny… open Settings › Policy's New rule, filled in, and come back here once
      it is saved.
    </p>
    """
  end

  @doc """
  network_list/1 is Network access's list: views, the search bar and the hosts, refused
  first, each refused one with Allow… into Settings › Policy's New rule, filled in, which
  returns to `back`. `repo` fixes the list to one repository.
  """
  attr :conns, :list, required: true
  attr :view, :string, default: nil
  attr :base, :string, default: nil
  attr :back, :string, required: true
  attr :repo, :string, default: nil
  attr :fixed, :boolean, default: false
  attr :compact, :boolean, default: false

  def network_list(assigns) do
    conns = assigns.conns

    shown =
      case assigns.view do
        "refused" -> Enum.filter(conns, &(&1.state == :refused))
        "allowed" -> Enum.filter(conns, &(&1.state == :allowed))
        _ -> conns
      end

    assigns =
      assign(assigns,
        shown: Enum.with_index(shown),
        refused: Enum.count(conns, &(&1.state == :refused)),
        allowed: Enum.count(conns, &(&1.state == :allowed))
      )

    ~H"""
    <div class="grid gap-3">
      <.views :if={@base} id="network-views" label="Views">
        <:view patch={@base} count={length(@conns)} current={@view in [nil, "all"]}>All</:view>
        <:view patch={@base <> "?view=refused"} count={@refused} current={@view == "refused"}>
          Refused
        </:view>
        <:view patch={@base <> "?view=allowed"} count={@allowed} current={@view == "allowed"}>
          Allowed
        </:view>
      </.views>
      <div :if={!@compact} class="q-bar">
        <.list_search
          id="network-search"
          label="Find a host"
          placeholder="Find a host, e.g. host:registry repo:acme/shop"
          live={false}
        />
      </div>
      <.fixed_token :if={@fixed} fixed={{"repo", @repo}} count={length(@shown)} />
      <.table id="hosts" label="Hosts" rows={@shown} row_id={fn {_c, i} -> "host-#{i}" end}>
        <:col :let={{c, _i}} label="Host" kind="title">
          <span class="q-mono">{c.host}:443</span>
          <span class="q-mono text-faint">{c.path}</span>
        </:col>
        <:col :let={{c, _i}} label="Attempts" kind="num">
          <span class={c.state == :refused && "text-error"}>
            {ApiaryWeb.Format.number(c.count)} {if c.state == :refused, do: "refused", else: "allowed"}
          </span>
        </:col>
        <:col :let={{c, _i}} label="Why" from="md">
          <.link :if={c.rule} patch={P.ws("/settings/policy")} class="text-muted hover:underline">
            {c.why}
          </.link>
          <span :if={!c.rule} class="text-muted">{c.why}</span>
        </:col>
        <:col :let={{c, _i}} label="Last" from="sm">{c.last}</:col>
        <:action :let={{c, i}}>
          <span class="inline-flex items-center gap-2">
            <Shell.go
              :if={c.state == :refused && !c.rule}
              id={"allow-#{i}"}
              href={rule_link(c, @repo, @back, "allow")}
            >
              Allow…
            </Shell.go>
            <.row_menu id={"host-#{i}-menu"} label={"Actions for #{c.host}"}>
              <.menu_item :if={c.state == :refused} patch={rule_link(c, @repo, @back, "allow")}>
                Allow… →
              </.menu_item>
              <.menu_item :if={c.state == :allowed} patch={rule_link(c, @repo, @back, "deny")}>
                Deny… →
              </.menu_item>
              <.menu_item :if={c.rule} patch={P.ws("/settings/policy")}>Show the rule →</.menu_item>
              <.menu_item patch={P.ws("/runs?view=refused")}>Show its runs</.menu_item>
            </.row_menu>
          </span>
        </:action>
      </.table>
    </div>
    """
  end

  defp rule_link(c, repo, back, action) do
    P.new_rule(
      host: c.host,
      path: c.path,
      repo: repo || List.first(c.repos),
      action: action,
      back: back
    )
  end

  ## Repositories

  defp repositories(assigns) do
    assigns = assign(assigns, repos: Data.repositories())

    ~H"""
    <.header>
      Repositories
      <:subtitle>
        The repositories shop's agents work in. Apiary learns of one from its first run.
      </:subtitle>
    </.header>
    <div class="grid gap-3">
      <.views id="repo-views" label="Views">
        <:view patch={P.ws("/targets")} count={length(@repos)} current>All</:view>
        <:view patch={P.ws("/targets")} count={3}>Active this week</:view>
        <:view patch={P.ws("/targets")} count={3}>Set their own</:view>
      </.views>
      <div class="q-bar">
        <.list_search
          id="repo-search"
          label="Find a repository"
          placeholder="Find a repository, e.g. acme/shop"
          live={false}
        />
      </div>
      <.table id="repositories" label="Repositories" rows={@repos} row_id={&"repo-#{&1.path}"}>
        <:col :let={r} label="Repository" kind="title">
          <span class="inline-flex items-center gap-2">
            <.icon
              name={if r.pinned, do: "hero-star-solid", else: "hero-star"}
              class={["size-4", if(r.pinned, do: "text-primary", else: "text-faint")]}
            />
            <.link patch={P.repo(r.path)} class="q-title hover:underline">{r.path}</.link>
          </span>
        </:col>
        <:col :let={r} label="Last run"><Shell.run_state state={r.state} /> · {r.last}</:col>
        <:col :let={r} label="Runs, 14 d" from="md">
          <span class="inline-flex items-center gap-2">
            <.sparkline values={r.spark} class="h-4 w-16" /> {r.runs}
          </span>
        </:col>
        <:col :let={r} label="Ended well" kind="num" from="md">{r.well}</:col>
        <:col :let={r} label="Refused" kind="num" from="sm">
          <span :if={r.refused > 0} class="text-error">{r.refused}</span>
        </:col>
        <:col :let={r} label="Own settings" from="sm">
          <span class="inline-flex flex-wrap gap-x-2">
            <.link
              :for={what <- r.own}
              patch={own_link(r.path, what)}
              class="text-accent hover:underline"
            >
              {what}
            </.link>
          </span>
        </:col>
      </.table>
      <p class="text-[12.5px]/[18px] text-faint">
        "Own settings" names only what differs from the workspace, and leads to that
        repository's Settings.
      </p>
    </div>
    """
  end

  defp own_link(path, "Policy"), do: P.repo(path, "/settings/policy")
  defp own_link(path, "Integrations"), do: P.repo(path, "/settings")
  defp own_link(path, "Variables"), do: P.repo(path, "/settings/variables")

  ## Nodes

  defp nodes(assigns) do
    nodes = Data.nodes()
    view = assigns.params["view"]

    shown =
      case view do
        "running" -> Enum.filter(nodes, &(&1.instances != []))
        "not-running" -> Enum.filter(nodes, &(&1.instances == []))
        _ -> nodes
      end

    assigns =
      assign(assigns,
        member: assigns.role == :member,
        view: view,
        all: length(nodes),
        running: Enum.count(nodes, &(&1.instances != [])),
        rows:
          Enum.flat_map(shown, fn
            %{kind: :pool} = n -> [{:node, n} | for(i <- n.instances, do: {:instance, i})]
            n -> [{:node, n}]
          end)
      )

    ~H"""
    <.header>
      Nodes
      <:subtitle>
        Where shop's runs execute. A node is one permanent machine; a node pool is a fleet of
        short-lived instances that share one key.
      </:subtitle>
      <:actions :if={!@member}>
        <.button id="new-node-pool" patch={P.ws("/nodes/new-pool")}>
          <.icon name="hero-plus-micro" class="size-4" />New node pool
        </.button>
        <.button id="new-node" variant="primary" patch={P.ws("/nodes/new")}>
          <.icon name="hero-plus-micro" class="size-4" />New node
        </.button>
      </:actions>
    </.header>

    <div class="grid gap-3">
      <p :if={@member} class="text-[12.5px]/[18px] text-muted">
        Only owners and admins manage nodes and their keys.
      </p>
      <.views id="node-views" label="Views">
        <:view patch={P.ws("/nodes")} count={@all} current={@view in [nil, "all"]}>All</:view>
        <:view patch={P.ws("/nodes?view=running")} count={@running} current={@view == "running"}>
          Running
        </:view>
        <:view
          patch={P.ws("/nodes?view=not-running")}
          count={@all - @running}
          current={@view == "not-running"}
        >
          Not running
        </:view>
      </.views>
      <div class="q-bar">
        <.list_search
          id="nodes-search"
          label="Find a node"
          placeholder="Find a node or an instance, e.g. build-01"
          live={false}
        />
      </div>
      <.table id="nodes" label="Nodes" rows={@rows} row_id={&node_row_id/1}>
        <:col :let={row} label="Name" kind="title"><.node_name row={row} /></:col>
        <:col :let={row} label="Kind" from="sm">
          <span :if={elem(row, 0) == :node && elem(row, 1).kind == :pool}>Pool</span>
        </:col>
        <:col :let={row} label="State"><.node_state row={row} /></:col>
        <:col :let={row} label="Needs">
          <span :if={elem(row, 0) == :node && Data.key_waiting?(elem(row, 1))}>
            <span :if={@member} class="text-muted">A key is waiting</span>
            <Shell.go :if={!@member} href={P.node(elem(row, 1), "/settings/keys")}>
              A key is waiting · Review
            </Shell.go>
          </span>
        </:col>
        <:col :let={row} label="Runs, 14 d" kind="num" from="sm">
          <span :if={elem(row, 0) == :node}>{elem(row, 1).runs}</span>
        </:col>
      </.table>
    </div>

    <Shell.dialog
      :if={@page.dialog == :new_node}
      id="new-node-dialog"
      title="New node"
      back={P.ws("/nodes")}
    >
      <.input id="new-node-name" name="name" label="Name" value="build-03" />
      <p class="text-[13px] text-muted">
        A node is one permanent machine, running one instance at a time. You can't change the
        kind later.
      </p>
      <:footer>
        <.button patch={P.ws("/nodes")}>Cancel</.button>
        <.button
          variant="primary"
          phx-click="done"
          phx-value-to={P.node("build-02", "/settings/keys/new")}
          phx-value-say="Prototype: a new node lands on its Settings › Access keys, with Enrol a new key open. build-02 stands in for it."
        >
          Make node
        </.button>
      </:footer>
    </Shell.dialog>

    <Shell.dialog
      :if={@page.dialog == :new_pool}
      id="new-pool-dialog"
      title="New node pool"
      back={P.ws("/nodes")}
    >
      <.input id="new-pool-name" name="name" label="Name" value="spot-runners-2" />
      <.input
        id="new-pool-limit"
        name="limit"
        label="Instance limit"
        value="10"
        hint="Empty means no limit."
      />
      <p class="text-[13px] text-muted">
        A node pool is a fleet of short-lived instances that share one key. You can't change
        the kind later.
      </p>
      <:footer>
        <.button patch={P.ws("/nodes")}>Cancel</.button>
        <.button
          variant="primary"
          phx-click="done"
          phx-value-to={P.node("spot-runners", "/settings/keys/new")}
          phx-value-say="Prototype: a new pool lands on its Settings › Access keys, with Enrol a new key open. spot-runners stands in for it."
        >
          Make node pool
        </.button>
      </:footer>
    </Shell.dialog>
    """
  end

  defp node_row_id({:node, n}), do: "node-#{n.id}"
  defp node_row_id({:instance, i}), do: "instance-#{i.id}"

  attr :row, :any, required: true

  defp node_name(%{row: {:node, node}} = assigns) do
    assigns = assign(assigns, :node, node)

    ~H"""
    <span class="q-nm">
      <.link patch={P.node(@node)} class="q-title hover:underline">{@node.name}</.link>
      <span class="q-side q-mono">{@node.id}</span>
    </span>
    """
  end

  defp node_name(%{row: {:instance, instance}} = assigns) do
    assigns = assign(assigns, :instance, instance)

    ~H"""
    <span class="inline-flex items-center gap-1.5 pl-4 font-normal">
      <.icon name="hero-arrow-turn-down-right-micro" class="size-3.5 text-faint" />
      {@instance.name} <span class="q-mono text-[12.5px] text-faint">{@instance.id}</span>
    </span>
    """
  end

  attr :row, :any, required: true

  defp node_state(%{row: {:instance, instance}} = assigns) do
    assigns = assign(assigns, :instance, instance)

    ~H"""
    <span class="inline-flex items-center gap-1.5">
      <span class="q-dot text-success" aria-hidden="true"></span>
      Running since {@instance.since} ·
      <.link patch={P.run(@instance.run)} class="q-mono hover:underline">run {@instance.run}</.link>
    </span>
    """
  end

  defp node_state(%{row: {:node, node}} = assigns) do
    assigns = assign(assigns, :node, node)

    ~H"""
    <span :if={@node.instances != []} class="inline-flex items-center gap-1.5">
      <span class="q-dot text-success" aria-hidden="true"></span>
      <span :if={@node.kind == :node}>Running</span>
      <span :if={@node.kind == :pool && @node.limit}>
        {length(@node.instances)} of {@node.limit} running
      </span>
      <span :if={@node.kind == :pool && !@node.limit}>{length(@node.instances)} running</span>
    </span>
    <span :if={@node.instances == []} class="text-muted">Last seen {@node.seen}</span>
    """
  end
end
