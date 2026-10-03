defmodule ApiaryWeb.Storybook.Screens.Node do
  @moduledoc false
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ApiaryWeb.CoreComponents

  alias ApiaryWeb.{RunComponents, SettingsComponents}
  alias ApiaryWeb.Storybook.{Mockup, Sample}

  def doc,
    do:
      "A node's or a pool's page, under Nodes: Overview, Runs, Access key and Settings. " <>
        "Access key holds its key: approved, awaiting approval or revoked, its fingerprint " <>
        "and stored secrets, a new key by enrolment code or a pasted public key, and a " <>
        "replacement beside the current key until that one is revoked."

  # The pages of each node and pool, by the suffix of their tab: its Overview has none.
  @pages [
    {nil, ""},
    {"runs", " › Runs"},
    {"key", " › Access key"},
    {"key_enrol", " › Access key › New key"},
    {"key_code", " › Access key › Enrolment code"},
    {"settings", " › Settings"}
  ]

  # The variations drawn on one node: a member's view, a replacement beside the current
  # key, and what Approve and Reject lead to.
  @variations %{
    "build_01" => [
      {"member", ", as a member"},
      {"key_replacement", " › Access key › Replacement awaiting approval"},
      {"key_replaced", " › Access key › Replacement approved"}
    ],
    "build_02" => [
      {"key_approved", " › Access key › After Approve"},
      {"key_rejected", " › Access key › After Reject"},
      {"key_member", " › Access key, as a member"}
    ]
  }

  def navigation do
    for node <- Sample.nodes(),
        {page, label} <- @pages ++ Map.get(@variations, node.id, []),
        do: {tab(node, page), node.name <> label}
  end

  defp tab(node, nil), do: String.to_atom(node.id)
  defp tab(node, page), do: String.to_atom("#{node.id}_#{page}")

  def render(assigns) do
    {node, page} = find(assigns.tab)
    {view, variant} = view(page)

    assigns =
      assign(assigns,
        node: vary(node, variant),
        view: view,
        variant: variant,
        member: variant == :member,
        to: &Mockup.node_path(node, &1, assigns.theme)
      )

    ~H"""
    <Mockup.shell
      theme={@theme}
      nav={:nodes}
      width="work"
      account={if @member, do: "sam@example.com", else: "dana@example.com"}
    >
      <:crumb href={Mockup.path("nodes", :all, @theme)}>Nodes</:crumb>
      <:crumb>{@node.name}</:crumb>

      <.header>
        <span class="inline-flex items-center gap-2">
          <.icon name="hero-server-stack" class="size-5 flex-none text-muted" />{@node.name}
        </span>
        <:subtitle>
          <span class="inline-flex flex-wrap items-baseline gap-x-2 gap-y-1">
            <span>{Mockup.kind_label(@node.kind)}</span>
            <span class="text-faint" aria-hidden="true">·</span>
            <Mockup.node_state node={@node} id="node-state" />
            <span class="text-faint" aria-hidden="true">·</span>
            <span>made by {@node.created}</span>
          </span>
        </:subtitle>
      </.header>

      <RunComponents.tabs id="node-tabs" label={@node.name}>
        <:tab
          id="node-tab-overview"
          navigate={@to.(nil)}
          current={@view == :overview}
          icon="hero-book-open"
        >
          Overview
        </:tab>
        <:tab
          id="node-tab-runs"
          navigate={@to.("runs")}
          current={@view == :runs}
          icon="hero-play-circle"
          count={@node.runs}
        >
          Runs
        </:tab>
        <:tab
          id="node-tab-key"
          navigate={@to.("key")}
          current={@view in [:key, :enrol, :code]}
          icon="hero-key"
        >
          Access key
        </:tab>
        <:tab
          id="node-tab-settings"
          navigate={@to.("settings")}
          current={@view == :settings}
          icon="hero-adjustments-horizontal"
        >
          Settings
        </:tab>
      </RunComponents.tabs>

      <.overview :if={@view == :overview} {assigns} />
      <.runs :if={@view == :runs} {assigns} />
      <.key :if={@view == :key} {assigns} />
      <.enrol :if={@view == :enrol} {assigns} />
      <.code :if={@view == :code} {assigns} />
      <.settings :if={@view == :settings} {assigns} />
    </Mockup.shell>
    """
  end

  ## Overview

  defp overview(assigns) do
    assigns =
      assign(assigns,
        key: current_key(assigns.node),
        pending: Enum.find(assigns.node.keys, &(&1.state == :pending)),
        instances:
          case assigns.node do
            %{kind: :node, instances: [], last: last} -> [{:last, last}]
            node -> for i <- node.instances, do: {:running, i}
          end
      )

    ~H"""
    <.notice :if={@pending} kind={:warning}>
      <strong>A key of {@node.name} awaits approval.</strong>
      It cannot post runs with it until an owner or an admin approves it.
      <a :if={!@member} href={@to.("key")} class="font-medium underline">Review the key</a>
    </.notice>
    <.notice :if={!@key && !@pending} kind={:warning}>
      <strong>{@node.name} has no key it may use.</strong>
      Its key is revoked, so it cannot post runs until it has a new one.
      <a :if={!@member} href={@to.("key_enrol")} class="font-medium underline">Add key</a>
    </.notice>

    <SettingsComponents.part id="node-about" title="About">
      <dl class="grid grid-cols-[max-content_minmax(0,1fr)] gap-x-4 gap-y-2 text-[13px]/5">
        <dt class="text-faint">Kind</dt>
        <dd>
          {if @node.kind == :node,
            do: "Node: permanent, with its own key.",
            else: "Node pool: ephemeral instances that share its key."}
          <span class="text-muted">Fixed when it was made.</span>
        </dd>
        <dt class="text-faint">Instances</dt>
        <dd id="node-limit">{Mockup.limit_rule(@node)}</dd>
        <dt class="text-faint">Access key</dt>
        <dd>
          <a href={@to.("key")} class="inline-flex flex-wrap items-baseline gap-x-2 hover:underline">
            <span class="q-mono">{List.last(@node.keys).id}</span>
            <Mockup.key_state key={List.last(@node.keys)} />
          </a>
        </dd>
        <dt class="text-faint">Made</dt>
        <dd>by {@node.created}</dd>
      </dl>
    </SettingsComponents.part>

    <SettingsComponents.part
      id="node-instances"
      title={if @node.kind == :node, do: "Instance", else: "Running instances"}
      count={if @node.kind == :pool, do: length(@node.instances)}
    >
      <p :if={@instances == []} id="node-instances-none" class="text-[13px]/5 text-muted">
        Nothing running. An instance appears here while it runs; <Mockup.seen at={@node.seen} />.
      </p>
      <.table
        :if={@instances != []}
        id="instances"
        label={"Instances of #{@node.name}"}
        rows={@instances}
        row_id={fn {_state, i} -> "instance-#{i.id}" end}
      >
        <:col :let={{_state, instance}} label="Instance" kind="title">
          <span class="q-title-mono">{instance.id}</span>
        </:col>
        <:col :let={{state, instance}} label="State">
          <Mockup.since :if={state == :running} at={instance.since} />
          <Mockup.seen :if={state == :last} at={@node.seen} />
        </:col>
        <:col :let={{_state, instance}} label="Runs" kind="num" from="sm">{instance.runs}</:col>
        <:col :let={{_state, instance}} label="Qory" kind="faint" from="sm">
          <span class="q-mono">{instance.version}</span>
        </:col>
        <:action :let={{state, instance}}>
          <.button
            :if={@node.kind == :node && state == :running && !@member}
            variant="link"
            href="#"
            aria-label={"Clear instance #{instance.id}"}
            aria-describedby="clear-instance-hint"
          >
            Clear instance
          </.button>
        </:action>
      </.table>
      <p
        :if={@node.kind == :node && Mockup.running?(@node) && !@member}
        id="clear-instance-hint"
        class="text-[12.5px]/[18px] text-faint"
      >
        Clear instance: use when the instance stopped without saying so; a new one may start
        at once.
      </p>
      <Mockup.members_note :if={@member} id="node-members-note" />
    </SettingsComponents.part>
    """
  end

  ## Runs

  defp runs(assigns) do
    ids =
      case assigns.node do
        %{instances: [], last: %{id: id}} -> [id]
        %{instances: []} -> ["i_5R2HM8KD1XC99cx1dk8mh2"]
        node -> Enum.map(node.instances, & &1.id)
      end

    assigns =
      assign(assigns,
        rows:
          Sample.runs()
          |> Enum.with_index()
          |> Enum.map(fn {run, i} ->
            Map.put(run, :instance, Enum.at(ids, rem(i, length(ids))))
          end)
      )

    ~H"""
    <p :if={@node.runs == 0} id="node-runs-none" class="text-[13px]/5 text-muted">
      No runs in the last 14 days. A run appears here once one of its instances posts it.
    </p>
    <.table
      :if={@node.runs > 0}
      id="node-runs"
      label={"Runs of #{@node.name}"}
      rows={@rows}
      row_id={&"run-#{&1.id}"}
    >
      <:col :let={run} label="Run" kind="title">
        <span :if={run.task}>{run.task}</span>
        <span :if={!run.task} class="q-faint">Waiting for its task</span>
      </:col>
      <:col :let={run} label="Target" from="sm">
        <span class="q-mono">{run.target_path}</span>
      </:col>
      <:col :let={run} label="Instance" kind="faint" from="md">
        <span class="q-mono">{run.instance}</span>
      </:col>
      <:col :let={run} label="State"><RunComponents.run_state state={run.state} /></:col>
      <:col :let={run} label="Started" from="sm"><.time_ago at={run.started_at} /></:col>
    </.table>
    <p :if={@node.runs > 0} class="text-[12.5px]/[18px] text-faint">
      The last runs of {@node.runs} in 14 days. Runs lists them all, with node:{@node.name}.
    </p>
    """
  end

  ## Access key

  defp key(assigns) do
    keys = assigns.node.keys

    assigns =
      assign(assigns,
        keys: keys,
        usable: Enum.any?(keys, &(&1.state == :approved)),
        waiting: Enum.any?(keys, &(&1.state == :pending))
      )

    ~H"""
    <.notice :if={@variant == :replacement}>
      <strong>A replacement awaits approval.</strong>
      {@node.name} keeps its current key until you revoke it, so its runs go on meanwhile.
    </.notice>
    <.notice :if={@variant == :replaced}>
      <strong>The replacement is approved.</strong>
      Revoke the old key once {@node.name} posts with the new one.
    </.notice>
    <.notice :if={@variant == :approved}>
      <strong>The key is approved.</strong> {@node.name} can post runs now.
    </.notice>
    <.notice :if={@variant == :rejected}>
      <strong>The key is rejected.</strong>
      {@node.name} cannot post runs until it has a key. Its enrolment code is spent.
    </.notice>

    <div class="flex flex-wrap items-start justify-between gap-3">
      <p class="max-w-[72ch] text-[13px]/[18px] text-muted">
        {if @node.kind == :pool,
          do: "The key the instances of #{@node.name} share to post their runs.",
          else: "The key #{@node.name} posts its runs with."} A new key comes from an enrolment code or a public key you paste; one that arrives with a code waits for an owner's or an admin's approval.
      </p>
      <div :if={!@member && !@waiting} class="flex flex-none gap-2">
        <.button :if={@usable} id="enrol-replacement" href={@to.("key_enrol")}>
          Enrol a replacement
        </.button>
        <.button :if={!@usable} id="add-key" variant="primary" href={@to.("key_enrol")}>
          <.icon name="hero-plus-micro" class="size-4" />Add key
        </.button>
      </div>
    </div>

    <p :if={@keys == []} id="node-no-key" class="text-[13px]/5 text-muted">
      No key. {@node.name} cannot post runs until it has one.
    </p>

    <.key_card
      :for={key <- @keys}
      key={key}
      node={@node}
      member={@member}
      label={label(key, @keys)}
      approve={approve_to(@node.id, @to)}
      reject={reject_to(@node.id, @to)}
    />

    <Mockup.members_note :if={@member} id="key-members-note" />
    """
  end

  attr :key, :map, required: true
  attr :node, :map, required: true
  attr :member, :boolean, required: true
  attr :label, :string, default: nil, doc: "Current key or Replacement, beside another"
  attr :approve, :string, required: true
  attr :reject, :string, required: true

  # A key: its id and state, its fingerprint, who approved, made or revoked it, and its
  # stored secrets, a fact fixed when it was made; then what its state asks for.
  defp key_card(assigns) do
    ~H"""
    <section
      id={"key-#{@key.id}"}
      class="grid gap-3 rounded-box border border-line bg-base-100 p-4"
      aria-labelledby={"key-#{@key.id}-title"}
    >
      <h3 id={"key-#{@key.id}-title"} class="flex flex-wrap items-baseline gap-x-3 gap-y-1">
        <span :if={@label} class="text-[13px]/5 font-medium">{@label}</span>
        <span class="q-mono text-[13.5px]/5 font-medium">{@key.id}</span>
        <Mockup.key_state key={@key} id={"key-#{@key.id}-state"} />
      </h3>

      <dl class="grid grid-cols-[max-content_minmax(0,1fr)] gap-x-4 gap-y-2 text-[13px]/5">
        <dt class="text-faint">Fingerprint</dt>
        <dd class="q-mono break-all">{@key.fingerprint}</dd>
        <dt :if={@key.state == :approved} class="text-faint">Approved</dt>
        <dd :if={@key.state == :approved}>by {@key.by}, {@key.on}</dd>
        <dt :if={@key.state == :pending} class="text-faint">Arrived</dt>
        <dd :if={@key.state == :pending}>
          with an enrolment code {@key.by} made, <.time_ago at={@key.asked} />
        </dd>
        <dt :if={@key.state == :revoked} class="text-faint">Revoked</dt>
        <dd :if={@key.state == :revoked}>by {@key.by}, {@key.on}</dd>
        <dt class="text-faint">Stored secrets</dt>
        <dd>
          {if @key.stored_secrets, do: "Allowed", else: "Not allowed"}
          <span class="text-muted">
            · fixed when the key was created; changing it means enrolling a new key.
          </span>
        </dd>
      </dl>

      <div :if={@key.state == :pending && !@member} class="grid gap-3">
        <p class="max-w-[72ch] text-[13px]/[18px] text-muted">
          Compare the fingerprint with the one {@node.name} printed when it enrolled.
          Approve only if they match.
        </p>
        <div class="flex flex-wrap gap-2">
          <.button variant="primary" href={@approve} aria-label={"Approve #{@key.id}"}>
            Approve
          </.button>
          <.button href={@reject} aria-label={"Reject #{@key.id}"}>Reject</.button>
        </div>
      </div>

      <div :if={@key.state == :approved && !@member}>
        <.button href="#" aria-label={"Revoke #{@key.id}"}>Revoke…</.button>
      </div>
    </section>
    """
  end

  # Beside another key, which is the current one and which replaces it.
  defp label(key, keys) do
    cond do
      length(keys) < 2 -> nil
      key == hd(keys) -> "Current key"
      true -> "Replacement"
    end
  end

  # Where Approve and Reject of a key awaiting approval lead: for build-01's replacement,
  # to both keys approved or back to its one; for build-02's first key, to what follows.
  defp approve_to("build_01", to), do: to.("key_replaced")
  defp approve_to(_id, to), do: to.("key_approved")

  defp reject_to("build_01", to), do: to.("key")
  defp reject_to(_id, to), do: to.("key_rejected")

  ## Enrol

  defp enrol(assigns) do
    assigns = assign(assigns, :replacing, current_key(assigns.node) != nil)

    ~H"""
    <div class="grid max-w-[45rem] gap-5">
      <div class="grid gap-1">
        <h2 class="text-[15px]/6 font-semibold">
          {if @replacing, do: "Enrol a replacement", else: "Add key"}
        </h2>
        <p class="text-[13px]/[18px] text-muted">
          {if @replacing,
            do:
              "A new key for #{@node.name}. Its current key keeps working until you revoke it, so its runs go on meanwhile.",
            else: "A key for #{@node.name}, so it can post runs."}
        </p>
      </div>

      <form id="new-key" class="grid gap-5" novalidate>
        <.input
          id="new-key-stored-secrets"
          name="stored_secrets"
          type="radio"
          label="Stored secrets"
          options={[
            {"Allowed: its runs receive the workspace's secrets", "allowed"},
            {"Not allowed: its runs get only what needs no secret", "none"}
          ]}
          value="allowed"
          hint="Fixed for the key it enrols; changing it later means enrolling a new key."
        />

        <SettingsComponents.part id="new-key-code" title="With an enrolment code">
          <p class="text-[13px]/[18px] text-muted">
            {@node.name} makes its own key and sends the public half with the code. The code
            is valid for 15 minutes, for one key, and the key arrives awaiting approval.
          </p>
          <div>
            <.button variant="primary" href={@to.("key_code")}>Create enrolment code</.button>
          </div>
        </SettingsComponents.part>

        <SettingsComponents.part id="new-key-paste" title="Or paste a public key">
          <.input
            id="new-key-public"
            name="public_key"
            type="textarea"
            label="Public key"
            value=""
            rows="3"
            placeholder="The public key the node printed"
            hint="Its fingerprint is shown before you add it. A key you paste is approved as you add it."
          />
          <div class="flex flex-wrap gap-2">
            <.button type="button">Add public key</.button>
            <.button variant="ghost" href={@to.("key")}>Cancel</.button>
          </div>
        </SettingsComponents.part>
      </form>
    </div>
    """
  end

  ## Enrolment code

  defp code(assigns) do
    assigns =
      assign(assigns,
        code: "qec_" <> code_of(assigns.node.id),
        until: DateTime.add(DateTime.utc_now(), 15 * 60),
        next:
          if(assigns.node.id == "build_01",
            do: assigns.to.("key_replacement"),
            else: assigns.to.("key")
          )
      )

    ~H"""
    <div class="grid max-w-[45rem] gap-4">
      <.notice kind={:warning}>
        <strong>This code is shown once.</strong>
        Copy it now. It is valid for 15 minutes, for one key.
      </.notice>

      <dl class="grid grid-cols-[max-content_minmax(0,1fr)] items-center gap-x-4 gap-y-2 text-[13px]/5">
        <dt class="text-faint">Enrolment code</dt>
        <dd class="flex min-w-0 items-center gap-2">
          <code class="block select-all break-all rounded-field border border-line bg-code px-2.5 py-1 font-mono text-[12.5px]/5">
            {@code}
          </code>
          <.copy_button id="copy-enrolment-code" text={@code} label="Copy code" icon_only />
        </dd>
        <dt class="text-faint">Valid</dt>
        <dd>for 15 minutes, until {ApiaryWeb.Format.time(@until)}</dd>
        <dt class="text-faint">Stored secrets</dt>
        <dd>Allowed, for the key it enrols</dd>
      </dl>

      <p class="text-[13px]/[18px] text-muted">
        On {@node.name}, enrol with this code. The key it makes arrives on Access key awaiting
        approval: compare its fingerprint with the one {@node.name} prints before you approve
        it.
      </p>
      <div><.button href={@next}>Done</.button></div>
    </div>
    """
  end

  defp code_of(id),
    do: :crypto.hash(:sha256, id) |> Base.encode32(padding: false) |> binary_part(0, 16)

  ## Settings

  defp settings(assigns) do
    ~H"""
    <form id="node-settings" class="grid max-w-[45rem] gap-4" novalidate>
      <.input id="node-name" name="name" label="Name" value={@node.name} />
      <.input
        id="node-kind"
        name="kind"
        label="Kind"
        value={Mockup.kind_label(@node.kind)}
        readonly
        hint="Chosen when it was made; it can't be changed."
      />
      <div :if={@node.kind == :pool} class="grid gap-2">
        <.input
          id="node-limit-field"
          name="limit"
          type="number"
          label="Instances at once"
          value={@node.limit}
          min="1"
          hint="At most this many run at once; one more is refused at run start."
        />
        <.input
          id="node-no-limit"
          name="no_limit"
          type="checkbox"
          label="No limit"
          checked={is_nil(@node.limit)}
        />
      </div>
      <SettingsComponents.save>
        <.button variant="primary" type="button">Save</.button>
        <:note>A run that starts after it is held to it.</:note>
      </SettingsComponents.save>
    </form>

    <SettingsComponents.danger_zone id="node-danger">
      <SettingsComponents.danger_action id="delete-node" title={"Delete #{@node.name}"}>
        Its keys are revoked at once and no instance of it posts again. Its runs stay in the
        record.
        <:action>
          <.button href="#">Delete {String.downcase(Mockup.kind_label(@node.kind))}…</.button>
        </:action>
      </SettingsComponents.danger_action>
    </SettingsComponents.danger_zone>
    """
  end

  ## The node and the page

  defp current_key(node), do: Enum.find(node.keys, &(&1.state == :approved))

  # The node and the page of it that `tab` names; the first node's Overview without one.
  defp find(tab) do
    name = to_string(tab || "")
    nodes = Sample.nodes()

    Enum.find_value(nodes, {hd(nodes), nil}, fn node ->
      cond do
        name == node.id ->
          {node, nil}

        String.starts_with?(name, node.id <> "_") ->
          {node, String.replace_prefix(name, node.id <> "_", "")}

        true ->
          nil
      end
    end)
  end

  defp view(nil), do: {:overview, nil}
  defp view("member"), do: {:overview, :member}
  defp view("runs"), do: {:runs, nil}
  defp view("key"), do: {:key, nil}
  defp view("key_enrol"), do: {:enrol, nil}
  defp view("key_code"), do: {:code, nil}
  defp view("settings"), do: {:settings, nil}
  defp view("key_replacement"), do: {:key, :replacement}
  defp view("key_replaced"), do: {:key, :replaced}
  defp view("key_approved"), do: {:key, :approved}
  defp view("key_rejected"), do: {:key, :rejected}
  defp view("key_member"), do: {:key, :member}

  # The node as a variation leaves it: a replacement beside its key, approved or awaiting
  # approval, or its key awaiting approval approved or rejected.
  defp vary(node, :replacement), do: %{node | keys: node.keys ++ [Sample.replacement_key()]}

  defp vary(node, :replaced),
    do: %{node | keys: node.keys ++ [approved(Sample.replacement_key())]}

  defp vary(node, :approved), do: %{node | keys: Enum.map(node.keys, &approved/1)}

  defp vary(node, :rejected),
    do: %{node | keys: Enum.reject(node.keys, &(&1.state == :pending))}

  defp vary(node, _variant), do: node

  defp approved(%{state: :pending} = key), do: %{key | state: :approved, by: "dana", on: "today"}
  defp approved(key), do: key
end
