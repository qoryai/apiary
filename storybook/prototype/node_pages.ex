defmodule ApiaryWeb.Prototype.NodePages do
  @moduledoc """
  A node or a node pool in the prototype (`ApiaryWeb.Prototype`), a level of its own: its
  operational tabs, Overview (its instance or running instances, Clear instance) and Runs;
  and ⚙ Settings at the right end of the tab bar, with General and Access keys, and the
  dialogs Enrol a new key, Approve, Reject, Revoke and Delete.
  """
  use Phoenix.Component

  import ApiaryWeb.CoreComponents

  alias ApiaryWeb.Prototype, as: P
  alias ApiaryWeb.Prototype.{Data, Live, Shell, WorkspacePages}
  alias ApiaryWeb.SettingsComponents

  def render(assigns) do
    node = Live.with_approvals(assigns.page.node, assigns.approved)

    assigns =
      assign(assigns,
        node: node,
        tab: assigns.page.page,
        member: assigns.role == :member,
        pool: node.kind == :pool,
        waiting: Data.key_waiting?(node),
        runs: Enum.filter(Data.runs(), &(&1.node == node.name))
      )

    ~H"""
    <Shell.level_header
      icon="hero-server-stack"
      id={@node.id}
      tabs_label={@node.name}
      settings_href={P.node(@node, "/settings")}
      settings_current={@tab in [:settings_general, :settings_keys]}
    >
      <:name>{@node.name}</:name>
      <:meta>
        <span>{if @pool, do: "Node pool", else: "Node"}</span>
        <span class="q-tgt-meta-sep" aria-hidden="true">·</span>
        <.state node={@node} />
        <span class="q-tgt-meta-sep" aria-hidden="true">·</span>
        <span>made by {@node.made}</span>
      </:meta>
      <:tab href={P.node(@node)} current={@tab == :overview} icon="hero-book-open">Overview</:tab>
      <:tab
        href={P.node(@node, "/runs")}
        current={@tab == :runs}
        icon="hero-play-circle"
        count={@node.runs}
      >
        Runs
      </:tab>
    </Shell.level_header>

    <Shell.needs
      :if={@waiting && @tab in [:overview, :runs]}
      id="key-waiting"
      href={!@member && P.node(@node, "/settings/keys")}
      link="Review"
    >
      A key is waiting. {@node.name} can't run anything until an owner or admin approves it.
    </Shell.needs>

    <.overview :if={@tab == :overview} {assigns} />
    <WorkspacePages.runs_list
      :if={@tab == :runs}
      runs={@runs}
      view={@params["view"]}
      base={P.node(@node, "/runs")}
      fixed={{"node", @node.name}}
      total={to_string(@node.runs)}
    />
    <.general :if={@tab == :settings_general} {assigns} />
    <.keys :if={@tab == :settings_keys} {assigns} />
    """
  end

  attr :node, :map, required: true

  defp state(assigns) do
    ~H"""
    <span :if={@node.instances != []} class="inline-flex items-center gap-1.5">
      <span class="q-dot text-success" aria-hidden="true"></span>
      <span :if={@node.kind == :node}>Running</span>
      <span :if={@node.kind == :pool}>
        {length(@node.instances)}{if @node.limit, do: " of #{@node.limit}"} running
      </span>
    </span>
    <span :if={@node.instances == []}>Last seen {@node.seen}</span>
    """
  end

  ## Overview

  defp overview(assigns) do
    assigns = assign(assigns, rows: Enum.with_index(assigns.node.instances))

    ~H"""
    <section class="grid gap-2">
      <h2 class="font-semibold">
        {if @pool, do: "Running instances", else: "Instance"}
        <span :if={@pool} class="font-normal text-muted">
          {length(@node.instances)}{if @node.limit, do: " of #{@node.limit}"}
        </span>
      </h2>
      <.table
        :if={@node.instances != []}
        id="instances"
        label="Instances"
        rows={@rows}
        row_id={fn {i, _} -> "instance-#{i.id}" end}
      >
        <:col :let={{i, _}} label="Instance" kind="title">
          {i.name} <span class="q-mono text-[12.5px] text-faint">{i.id}</span>
        </:col>
        <:col :let={{i, _}} label="State">
          <span class="inline-flex items-center gap-1.5">
            <span class="q-dot text-success" aria-hidden="true"></span> Running since {i.since}
          </span>
        </:col>
        <:col :let={{i, _}} label="Run">
          <Shell.go href={P.run(i.run)}><span class="q-mono">run {i.run}</span></Shell.go>
        </:col>
        <:col :let={{_i, _}} label="Runner" from="md"><span class="q-mono">0.7.0</span></:col>
        <:action :let={{i, n}}>
          <.row_menu :if={@pool && !@member} id={"instance-#{n}-menu"} label={"Actions for #{i.name}"}>
            <.menu_item patch={P.node(@node, "/clear")}>Clear instance…</.menu_item>
          </.row_menu>
        </:action>
      </.table>
      <p :if={@node.instances == [] && !@pool} class="text-[13px] text-muted">
        No instance running. Last seen {@node.seen}.
      </p>
      <p :if={@node.instances == [] && @pool} class="text-[13px] text-muted">
        None running. An instance shows here only while it runs.
      </p>
      <div :if={!@pool} class="flex flex-wrap items-center gap-3 text-[12.5px] text-muted">
        A node runs one instance at a time.
        <.button :if={!@member && @node.instances != []} size="xs" patch={P.node(@node, "/clear")}>
          Clear instance…
        </.button>
      </div>
      <p :if={@pool} class="text-[12.5px] text-muted">
        An instance shows here only while it runs. 4 starts were refused at the limit in 24 h.
      </p>
    </section>

    <section class="grid gap-2">
      <h2 class="font-semibold">Latest runs</h2>
      <div :for={r <- Enum.take(@runs, 3)} class="flex items-center gap-3 text-[13.5px]/5">
        <.link patch={P.run(r.id)} class="min-w-0 flex-1 truncate hover:underline">{r.task}</.link>
        <.link patch={P.repo(r.repo)} class="text-muted hover:underline">{r.repo}</.link>
        <Shell.run_state state={r.state} />
        <span class="w-10 text-right text-faint">{r.took}</span>
      </div>
      <p :if={@runs == []} class="text-[13px] text-muted">No run yet.</p>
      <Shell.go href={P.node(@node, "/runs")} class="text-[13px]">All {@node.runs} runs</Shell.go>
    </section>

    <section class="grid gap-1 text-[13px]/5">
      <h2 class="font-semibold">About</h2>
      <p class="text-muted">
        Kind {if @pool, do: "Node pool", else: "Node"} (fixed) · Instance limit {@node.limit || "none"} ·
        Key <span class="q-mono">{String.slice(List.last(@node.keys).id, 0, 7)}…</span>
        {key_word(List.last(@node.keys).state)} · Stored secrets {if List.last(@node.keys).stored,
          do: "allowed",
          else: "not allowed"}
      </p>
      <Shell.go href={P.node(@node, "/settings")}>Settings</Shell.go>
    </section>

    <Shell.dialog
      :if={@page.dialog == :clear}
      id="clear-instance"
      title="Clear this instance?"
      back={P.node(@node)}
      size="sm"
    >
      <p>
        Clear this instance if it stopped without saying so. Its open runs are closed, and
        another instance can start at once.
      </p>
      <:footer>
        <.button patch={P.node(@node)} data-cancel-button>Cancel</.button>
        <.button
          variant="danger"
          phx-click="done"
          phx-value-to={P.node(@node)}
          phx-value-say="Instance cleared."
        >
          Clear instance
        </.button>
      </:footer>
    </Shell.dialog>
    """
  end

  defp key_word(:approved), do: "approved"
  defp key_word(:pending), do: "awaiting approval"
  defp key_word(:revoked), do: "revoked"

  ## Settings

  defp groups(node) do
    [
      {nil,
       [
         %{key: :settings_general, label: "General", href: P.node(node, "/settings")},
         %{
           key: :settings_keys,
           label: "Access keys",
           href: P.node(node, "/settings/keys"),
           count: length(node.keys),
           hot: Data.key_waiting?(node) && "A key is waiting"
         }
       ]}
    ]
  end

  defp general(assigns) do
    ~H"""
    <Shell.settings
      groups={groups(@node)}
      current={:settings_general}
      title="General"
      readonly={@member}
    >
      <:subtitle>{@node.name}'s name, its kind and its limit.</:subtitle>
      <form class="grid gap-4" onsubmit="return false">
        <.input id="node-name" name="name" label="Name" value={@node.name} disabled={@member} />
        <div class="grid gap-1 text-[13.5px]/5">
          <span class="text-[13px] font-medium">Kind</span>
          <span :if={!@pool}>Node: one permanent machine. Fixed.</span>
          <span :if={@pool}>Node pool: short-lived instances that share one key. Fixed.</span>
        </div>
        <.input
          :if={@pool}
          id="node-limit"
          name="limit"
          label="Instance limit"
          value={@node.limit && to_string(@node.limit)}
          hint="Empty means no limit. Lowering it stops nothing running now; new instances wait until fewer run."
          disabled={@member}
        />
        <div :if={!@pool} class="grid gap-1 text-[13.5px]/5">
          <span class="text-[13px] font-medium">Instance limit</span>
          <span>1: a node runs one instance at a time.</span>
        </div>
        <SettingsComponents.save :if={!@member}>
          <.button
            variant="primary"
            type="button"
            phx-click="done"
            phx-value-to={P.node(@node, "/settings")}
            phx-value-say="Saved."
          >
            Save
          </.button>
        </SettingsComponents.save>
      </form>
      <SettingsComponents.danger_zone :if={!@member}>
        <SettingsComponents.danger_action
          id="delete-node"
          title={if @pool, do: "Delete node pool", else: "Delete node"}
        >
          {if @pool,
            do:
              "Revokes its key; its instances stop at their next request. Its runs stay in the record.",
            else: "Revokes every key. Its runs stay in the record."}
          <:action>
            <.button variant="danger-ghost" patch={P.node(@node, "/settings/delete")}>
              {if @pool, do: "Delete node pool…", else: "Delete node…"}
            </.button>
          </:action>
        </SettingsComponents.danger_action>
      </SettingsComponents.danger_zone>
    </Shell.settings>

    <Shell.dialog
      :if={@page.dialog == :delete}
      id="delete-node-dialog"
      title={"Delete #{@node.name}?"}
      back={P.node(@node, "/settings")}
      size="sm"
    >
      <p>Every key of {@node.name} is revoked. Its runs stay in the record.</p>
      <:footer>
        <.button patch={P.node(@node, "/settings")} data-cancel-button>Cancel</.button>
        <.button
          variant="danger"
          phx-click="done"
          phx-value-to={P.ws("/nodes")}
          phx-value-say={"Prototype: #{@node.name} would be deleted."}
        >
          Delete
        </.button>
      </:footer>
    </Shell.dialog>
    """
  end

  defp keys(assigns) do
    assigns = assign(assigns, key: assigns.page[:key])

    ~H"""
    <Shell.settings groups={groups(@node)} current={:settings_keys} title="Access keys" measure="list">
      <:subtitle>
        The keys {@node.name} uses to connect to Apiary. A key that arrives with an enrolment
        code waits for approval.
      </:subtitle>
      <:actions :if={!@member}>
        <.button patch={P.node(@node, "/settings/keys/new")}>Enrol a new key…</.button>
      </:actions>
      <p :if={@member} class="text-[12.5px] text-muted">
        Only owners and admins approve, reject and revoke keys. Enrolment codes are shown only to
        the admin who made them.
      </p>

      <div
        :for={k <- @node.keys}
        id={"key-#{k.id}"}
        class="grid gap-2 rounded-box border border-line p-4"
      >
        <div class="flex flex-wrap items-center gap-3">
          <span class="q-mono font-medium">{k.id}</span>
          <.state_word :if={k.state == :approved}>Approved</.state_word>
          <.state_word :if={k.state == :pending} hot>Awaiting approval</.state_word>
          <span class="flex-1"></span>
          <span :if={k.state == :pending && !@member} class="inline-flex gap-2">
            <.button variant="primary" patch={P.node(@node, "/settings/keys/#{k.id}/approve")}>
              Approve…
            </.button>
            <.button patch={P.node(@node, "/settings/keys/#{k.id}/reject")}>Reject…</.button>
          </span>
          <.button
            :if={k.state == :approved && !@member}
            variant="danger-ghost"
            patch={P.node(@node, "/settings/keys/#{k.id}/revoke")}
          >
            Revoke…
          </.button>
        </div>
        <dl class="grid gap-1 text-[13px]/5">
          <div class="grid grid-cols-[8rem_minmax(0,1fr)] gap-2">
            <dt class="text-muted">Fingerprint</dt>
            <dd class="q-mono break-all">{k.fingerprint}</dd>
          </div>
          <div class="grid grid-cols-[8rem_minmax(0,1fr)] gap-2">
            <dt class="text-muted">Arrived</dt>
            <dd>{k.arrived}</dd>
          </div>
          <div :if={k.approved} class="grid grid-cols-[8rem_minmax(0,1fr)] gap-2">
            <dt class="text-muted">Approved by</dt>
            <dd>{k.approved}</dd>
          </div>
          <div class="grid grid-cols-[8rem_minmax(0,1fr)] gap-2">
            <dt class="text-muted">Stored secrets</dt>
            <dd>
              {if k.stored, do: "Allowed", else: "Not allowed"} · fixed when the key was created
            </dd>
          </div>
        </dl>
        <p :if={k.state == :pending} class="text-[12.5px] text-muted">
          Compare the fingerprint with the one {@node.name} printed when it enrolled.
        </p>
      </div>

      <p class="text-[13px] text-muted">Enrolment codes: none outstanding.</p>
      <details :if={@node.revoked != []} class="text-[13px]">
        <summary class="cursor-pointer text-muted">Revoked keys ({length(@node.revoked)})</summary>
        <p :for={k <- @node.revoked} class="mt-2 pl-4">
          <span class="q-mono">{k.id}</span> · {k.arrived} · {k.approved}
        </p>
      </details>
      <p :if={@pool} class="text-[12.5px]/[18px] text-faint">
        An instance is what a runner using this key reports itself as; anyone with the key can
        report any instance. To cut one machine off, give it a node of its own.
      </p>
      <p class="text-[12.5px]/[18px] text-faint">
        To replace a key or change stored secrets: enrol a new key, approve it, move the machine
        to it, then revoke the old one.
      </p>
    </Shell.settings>

    <Shell.dialog
      :if={@page.dialog == :enrol}
      id="enrol-key"
      title="Enrol a new key"
      back={P.node(@node, "/settings/keys")}
    >
      <.input
        id="enrol-how"
        name="how"
        type="radio"
        label="How"
        options={[
          {"Enrolment code: shown once, valid 15 minutes", "code"},
          {"Paste a public key: the output of qory access-key create", "paste"}
        ]}
        value="code"
      />
      <p class="text-[13px] text-muted">
        On the machine, run <code class="q-mono">qory access-key enrol &lt;url&gt; &lt;code&gt;</code>
      </p>
      <.input
        id="enrol-stored"
        name="stored"
        type="checkbox"
        label="Allow stored secrets. This can't be changed later; enrol another key to change it."
      />
      <:footer>
        <.button patch={P.node(@node, "/settings/keys")}>Cancel</.button>
        <.button
          variant="primary"
          phx-click="done"
          phx-value-to={P.node(@node, "/settings/keys")}
          phx-value-say="Enrolment code made: QX7-48K-PL2. It is shown once and valid for 15 minutes."
        >
          Make enrolment code
        </.button>
      </:footer>
    </Shell.dialog>

    <Shell.dialog
      :if={@page.dialog == :approve && @key}
      id="approve-key"
      title={"Approve #{@key.id}?"}
      back={P.node(@node, "/settings/keys")}
    >
      <p>Compare this fingerprint with the one {@node.name} printed when it enrolled.</p>
      <p class="q-mono break-all rounded-box bg-base-200 px-3 py-2 text-[13px]">{@key.fingerprint}</p>
      <p class="text-[13px] text-muted">{@key.arrived}.</p>
      <:footer>
        <.button patch={P.node(@node, "/settings/keys")}>Cancel</.button>
        <.button
          variant="primary"
          phx-click="approve"
          phx-value-key={@key.id}
          phx-value-node={@node.name}
          phx-value-to={P.node(@node, "/settings/keys")}
        >
          The fingerprints match · Approve
        </.button>
      </:footer>
    </Shell.dialog>

    <Shell.dialog
      :if={@page.dialog in [:reject, :revoke] && @key}
      id="end-key"
      title={"#{if @page.dialog == :reject, do: "Reject", else: "Revoke"} #{@key.id}?"}
      back={P.node(@node, "/settings/keys")}
      size="sm"
    >
      <p>
        {@node.name} can't connect with this key any more. {if @page.dialog == :revoke,
          do: "Its runs stay in the record.",
          else: ""}
      </p>
      <:footer>
        <.button patch={P.node(@node, "/settings/keys")} data-cancel-button>Cancel</.button>
        <.button
          variant="danger"
          phx-click="done"
          phx-value-to={P.node(@node, "/settings/keys")}
          phx-value-say={"Prototype: the key would be #{if @page.dialog == :reject, do: "rejected", else: "revoked"}."}
        >
          {if @page.dialog == :reject, do: "Reject key", else: "Revoke key"}
        </.button>
      </:footer>
    </Shell.dialog>
    """
  end
end
