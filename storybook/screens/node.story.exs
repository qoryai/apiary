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
        "Access key holds its keys: with none, the two ways to connect it, its kind's way " <>
        "first, each as numbered steps; then each key, active or revoked, its ID and how it " <>
        "was added, Add a key, the same two ways, for a new key beside the current one " <>
        "until that one is revoked, and Configure a machine, what a machine is set with."

  # The keys a node or pool holds at a time, as the limit line says: its current key and a
  # replacement.
  @key_limit 2

  # The pages of each node and pool, by the suffix of their tab: its Overview has none.
  @pages [
    {nil, ""},
    {"runs", " › Runs"},
    {"key", " › Access key"},
    {"key_generate", " › Access key › Generate a key"},
    {"key_command", " › Access key › Command"},
    {"settings", " › Settings"}
  ]

  # The variations drawn on one node: a member's view, and a replacement beside the
  # current key.
  @variations %{
    "build_01" => [
      {"member", ", as a member"},
      {"key_replacement", " › Access key › Replacement"}
    ],
    "build_02" => [
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
          current={@view in [:key, :generate, :command]}
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
      <.generate :if={@view == :generate} {assigns} />
      <.command :if={@view == :command} {assigns} />
      <.settings :if={@view == :settings} {assigns} />
    </Mockup.shell>
    """
  end

  ## Overview

  defp overview(assigns) do
    assigns =
      assign(assigns,
        key: current_key(assigns.node),
        instances:
          case assigns.node do
            %{kind: :node, instances: [], last: last} -> [{:last, last}]
            node -> for i <- node.instances, do: {:running, i}
          end
      )

    ~H"""
    <.notice :if={!@key} kind={:warning}>
      <strong>{@node.name} has no key it may use.</strong>
      Its key is revoked, so it cannot post runs until it has a new one.
      <a :if={!@member} href={@to.("key")} class="font-medium underline">Connect it</a>
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
    keys = Enum.with_index(assigns.node.keys, &Map.put(&1, :label, label(assigns.node, &2)))
    active = Enum.count(keys, &(&1.state == :active))

    assigns =
      assign(assigns,
        keys: keys,
        active: active,
        full: active >= @key_limit,
        ways: ways(assigns.node),
        server_pin: server_pin(),
        server_yaml: server_yaml()
      )

    ~H"""
    <.notice :if={@variant == :replacement}>
      <strong>The new key is active.</strong> Revoke the old one once {@node.name} uses the new one.
    </.notice>

    <SettingsComponents.part
      :if={@active == 0 and !@member}
      id="node-connect"
      title={"How do you want to connect #{@node.name}?"}
      level={:h2}
    >
      <p class="text-[13px]/5 text-muted">
        {if @node.kind == :pool,
          do:
            "#{@node.name} needs a key before it can start runs; its instances share one. Choose one of two ways to give it one.",
          else:
            "#{@node.name} needs a key before it can start runs. Choose one of two ways to give it one."}
      </p>
      <div class="grid items-stretch gap-3 md:grid-cols-2">
        <.way_card
          :for={{way, index} <- Enum.with_index(@ways)}
          way={way}
          primary={index == 0}
          node={@node}
          to={@to}
        />
      </div>
    </SettingsComponents.part>

    <SettingsComponents.part
      :if={@active == 0 and @member}
      id="node-connect"
      title={"Connect #{@node.name}"}
      level={:h2}
    >
      <p class="text-[13px]/5 text-muted">
        {@node.name} has no key yet, so it can't start runs. An owner or admin connects it.
      </p>
    </SettingsComponents.part>

    <SettingsComponents.part
      :if={@keys != []}
      id="node-keys"
      title="Keys"
      count={length(@keys)}
      level={:h2}
    >
      <p class="text-[13px]/5 text-muted">
        {if @node.kind == :pool,
          do:
            "The instances of #{@node.name} sign every request with the pool's key. Qory Apiary keeps only the public half.",
          else:
            "#{@node.name} signs every request with its key. Qory Apiary keeps only the public half."}
      </p>
      <Mockup.members_note :if={@member and @active > 0} id="key-members-note" />
      <.key_card :for={key <- @keys} key={key} node={@node} member={@member} to={@to} />
    </SettingsComponents.part>

    <SettingsComponents.part
      :if={@active > 0 and !@member}
      id="node-add"
      title="Add a key"
      level={:h2}
    >
      <p :if={@full} class="text-[13px]/5 text-muted">
        {@node.name} holds two keys, the most a {if @node.kind == :pool, do: "node pool", else: "node"} can. Revoke the one it no longer uses to add another.
      </p>
      <p :if={!@full} class="text-[13px]/5 text-muted">
        To move {@node.name} to a new key, add it the same way as the first, or the other way, then revoke the old one once the new one is in use. A {if @node.kind ==
                                                                                                                                                           :pool,
                                                                                                                                                         do:
                                                                                                                                                           "node pool",
                                                                                                                                                         else:
                                                                                                                                                           "node"} holds two keys at most.
      </p>
      <div
        :if={!@full}
        class="grid rounded-box border border-line bg-base-100 text-[13px]/5 shadow-xs"
      >
        <div
          :for={{way, index} <- Enum.with_index(@ways)}
          class={["flex items-center gap-3 px-4 py-3", index > 0 && "border-t border-line"]}
        >
          <.icon name={way_icon(way)} class="size-4.5 flex-none text-muted" />
          <div class="grid min-w-0 flex-1 gap-0.5">
            <p class="font-medium">{way_title(way)}</p>
            <p class="text-muted">{way_when(way, @node)}</p>
          </div>
          <.button href={way_to(way, @to)} class="flex-none">{way_button(way)}</.button>
        </div>
      </div>
    </SettingsComponents.part>

    <SettingsComponents.part
      :if={@active > 0}
      id="node-configure"
      title="Configure a machine"
      level={:h2}
    >
      <div class="grid max-w-[46rem] gap-4 text-[13px]/5">
        <div class="grid gap-1 text-muted">
          <p>
            A machine connected with the command needs nothing more: qory saved all of this on it. Don't set these again there; qory refuses a value set twice.
          </p>
          <p>With a generated key, set these where the machine runs qory.</p>
        </div>
        <ol class="q-steps">
          <li>
            <span class="q-step-disc" aria-hidden="true">1</span>
            <div class="grid min-w-0 gap-2">
              <p class="text-[13.5px]/6 font-medium">Point qory at Qory Apiary.</p>
              <p class="text-muted">
                In the runner file. It is required: without it, qory ignores the three variables below.
              </p>
              <.code_block
                id="node-configure-yaml"
                label="runner.yaml"
                code={@server_yaml}
                copy_label="Copy lines"
              />
            </div>
          </li>
          <li>
            <span class="q-step-disc" aria-hidden="true">2</span>
            <div class="grid min-w-0 gap-2">
              <p class="text-[13.5px]/6 font-medium">Set Qory Apiary's public key.</p>
              <p class="text-muted">
                QORY_APIARY_PUBLIC_KEY, a plain setting. The same for every machine connected to this Qory Apiary.
              </p>
              <.value_field id="node-configure-pin" name="QORY_APIARY_PUBLIC_KEY" value={@server_pin} />
            </div>
          </li>
          <li>
            <span class="q-step-disc" aria-hidden="true">3</span>
            <div class="grid min-w-0 gap-2">
              <p class="text-[13.5px]/6 font-medium">Set the key's ID.</p>
              <%= case Enum.filter(@keys, &(&1.state == :active)) do %>
                <% [key] -> %>
                  <p class="text-muted">QORY_ACCESS_KEY_ID, a plain setting.</p>
                  <.value_field id="node-configure-key-id" name="QORY_ACCESS_KEY_ID" value={key.id} />
                <% _keys -> %>
                  <p class="text-muted">
                    QORY_ACCESS_KEY_ID, a plain setting: the ID of the key the machine uses, on its card above.
                  </p>
              <% end %>
            </div>
          </li>
          <li>
            <span class="q-step-disc" aria-hidden="true">4</span>
            <div class="grid min-w-0 gap-2">
              <p class="text-[13.5px]/6 font-medium">Keep the key's secret in a secret store.</p>
              <p class="text-muted">
                QORY_ACCESS_KEY_SECRET. It was shown once, when the key was generated, and is never shown here. If it is lost, generate a new key and revoke the old one.
              </p>
            </div>
          </li>
        </ol>
      </div>
    </SettingsComponents.part>
    """
  end

  attr :way, :atom, required: true
  attr :primary, :boolean, required: true
  attr :node, :map, required: true
  attr :to, :any, required: true

  # A way to connect the node, as one of two equal options: when to choose it, what
  # happens, the same four facts as the other's, and one button at its foot.
  defp way_card(assigns) do
    ~H"""
    <div class="flex min-w-0 flex-col gap-3 rounded-box border border-line bg-base-100 p-4 text-[13px]/5 shadow-xs">
      <div class="flex items-center gap-3">
        <span class="grid size-8 flex-none place-items-center rounded-field bg-base-200 text-muted">
          <.icon name={way_icon(@way)} class="size-4.5" />
        </span>
        <h3 class="text-[14px]/5 font-medium">{way_title(@way)}</h3>
      </div>
      <p>{way_when(@way, @node)}</p>
      <p class="text-muted">{way_happens(@way, @node)}</p>
      <dl class="grid grid-cols-[max-content_minmax(0,1fr)] gap-x-4 gap-y-1">
        <%= for {label, value} <- way_facts(@way, @node) do %>
          <dt class="text-faint">{label}</dt>
          <dd class="min-w-0">{value}</dd>
        <% end %>
      </dl>
      <div class="mt-auto pt-1">
        <.button variant={if @primary, do: "primary", else: "default"} href={way_to(@way, @to)}>
          {way_button(@way)}
        </.button>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :string, required: true

  # A value alone, with Copy: its name is said in the line above it.
  defp value_field(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <code
        id={@id}
        class="block min-w-0 flex-1 select-all break-all rounded-field border border-line bg-code px-2.5 py-1 font-mono text-[12.5px]/5"
      >{@value}</code>
      <.copy_button
        id={"#{@id}-copy"}
        target={"##{@id}"}
        label={"Copy #{@name}"}
        placement="left"
        icon_only
      />
    </div>
    """
  end

  defp way_when(:command, node),
    do:
      "Choose it when you can open a terminal on #{node.name}: a laptop, or a server of your own."

  defp way_when(:generate, node),
    do:
      "Choose it when #{node.name} runs in a CI job, or on a machine you can't open a terminal on."

  defp way_happens(:command, node),
    do:
      "You get one command to run on #{node.name}. It carries a one-time code, not a key, which works once within 15 minutes. qory makes the key on #{node.name}, sends Qory Apiary only its public half, and saves everything else there itself."

  defp way_happens(:generate, node),
    do:
      "This browser makes the key, and Qory Apiary receives only its public half. The next page shows the secret once, with everything else the machine needs, for you to set where #{node.name} runs."

  defp way_facts(:command, node),
    do: [
      {"Key made", "On #{node.name}, by qory"},
      {"Secret", "Stays on #{node.name}; it is never shown"},
      {"By hand", "Nothing"},
      {"Needs", "A terminal on #{node.name}"}
    ]

  defp way_facts(:generate, _node),
    do: [
      {"Key made", "In this browser"},
      {"Secret", "Shown to you once, for the machine's or the CI's secret store"},
      {"By hand", "The key's ID, its secret, Qory Apiary's public key and address"},
      {"Needs", "This page open over HTTPS"}
    ]

  # Qory Apiary's values, the same for every node: a sample public key and address.
  defp server_pin,
    do: ~s([{"alg":"ed25519","public_key":"q3Vd9xGm2LkR7tYbW4nE8sJpZ1cH6uFaT0oKiNvXyBe"}])

  defp server_yaml, do: "server:\n  url: https://apiary.example.com\n"

  # The two ways, the kind's own first: a machine runs a command, a pool's shared key is
  # generated in the browser.
  defp ways(%{kind: :pool}), do: [:generate, :command]
  defp ways(_node), do: [:command, :generate]

  defp way_icon(:command), do: "hero-command-line"
  defp way_icon(:generate), do: "hero-key"

  defp way_title(:command), do: "Connect with a command"
  defp way_title(:generate), do: "Generate a key in the browser"

  defp way_button(:command), do: "Get the command"
  defp way_button(:generate), do: "Generate a key"

  defp way_to(:command, to), do: to.("key_command")
  defp way_to(:generate, to), do: to.("key_generate")

  attr :key, :map, required: true
  attr :node, :map, required: true
  attr :member, :boolean, required: true
  attr :to, :any, required: true

  # A key: its name and state, its ID with Copy, how it was added and where its secret is,
  # who revoked it, its fingerprint and stored secrets; then Revoke… while it is active.
  defp key_card(assigns) do
    ~H"""
    <section
      id={"key-#{@key.id}"}
      class="grid gap-3 rounded-box border border-line bg-base-100 p-4"
      aria-labelledby={"key-#{@key.id}-title"}
    >
      <h3 id={"key-#{@key.id}-title"} class="flex flex-wrap items-baseline gap-x-2 gap-y-1">
        <span class="text-[13.5px]/5 font-medium">{@key.label}</span>
        <span class="text-faint" aria-hidden="true">·</span>
        <Mockup.key_state key={@key} id={"key-#{@key.id}-state"} />
      </h3>

      <dl class="grid grid-cols-[max-content_minmax(0,1fr)] gap-x-4 gap-y-2 text-[13px]/5">
        <dt class="text-faint">Key ID</dt>
        <dd class="flex min-w-0 items-center gap-2">
          <span class="q-mono break-all">{@key.id}</span>
          <.copy_button
            id={"key-#{@key.id}-id-copy"}
            text={@key.id}
            label={"Copy the key ID of #{@key.label}"}
            icon_only
          />
        </dd>
        <dt :if={@key.state == :active} class="text-faint">Added</dt>
        <dd :if={@key.state == :active && @key.way == :code}>
          Connected with a command by {@key.by}, {@key.on}
        </dd>
        <dd :if={@key.state == :active && @key.way == :browser}>
          Generated in a browser by {@key.by}, {@key.on}
        </dd>
        <dt :if={@key.state == :active} class="text-faint">Secret</dt>
        <dd :if={@key.state == :active && @key.way == :code}>
          On {@node.name}, saved there by the command
        </dd>
        <dd :if={@key.state == :active && @key.way == :browser}>
          Shown once when it was generated; kept where you put it, such as your CI's secret store
        </dd>
        <dt :if={@key.state == :revoked} class="text-faint">Revoked</dt>
        <dd :if={@key.state == :revoked}>by {@key.by}, {@key.on}</dd>
        <dt class="text-faint">Fingerprint</dt>
        <dd class="q-mono break-all">{@key.fingerprint}</dd>
        <dt class="text-faint">Stored secrets</dt>
        <dd>{if @key.stored_secrets, do: "Allowed", else: "Not allowed"}</dd>
      </dl>

      <div :if={@key.state == :active} class="flex flex-wrap gap-2">
        <.button href="#">Runner file</.button>
        <.button :if={!@member} href="#" aria-label={"Revoke #{@key.label}"}>Revoke…</.button>
      </div>
    </section>
    """
  end

  # A key's name: the node's for the first, then the node's with -2, -3 and on.
  defp label(node, 0), do: node.name
  defp label(node, index), do: "#{node.name}-#{index + 1}"

  ## Generate a key

  defp generate(assigns) do
    ~H"""
    <div class="grid max-w-[45rem] gap-5">
      <div class="grid gap-1">
        <h2 class="text-[15px]/6 font-semibold">Generate a key for {@node.name}</h2>
        <p class="text-[13px]/[18px] text-muted">
          This browser makes a key for {@node.name}. You see its secret once, to copy into your CI's secret store, or the settings of {if @node.kind ==
                                                                                                                                            :pool,
                                                                                                                                          do:
                                                                                                                                            "whatever runs the instances",
                                                                                                                                          else:
                                                                                                                                            "the system that runs it"}; Qory Apiary receives only the public half. The key's ID stays on the Access key tab.
        </p>
      </div>

      <form id="new-key" class="grid gap-5" novalidate>
        <.input
          id="new-key-label"
          name="label"
          label="Name of the key"
          value={@node.name}
          hint="Shown on the Access key tab, so you can tell its keys apart."
        />
        <div class="flex flex-wrap gap-2">
          <.button variant="primary" href={@to.("key")}>Generate key</.button>
          <.button variant="ghost" href={@to.("key")}>Cancel</.button>
        </div>
      </form>
    </div>
    """
  end

  ## The command

  defp command(assigns) do
    assigns =
      assign(assigns,
        command:
          "qory access-key enrol https://apiary.example.com qec_" <> code_of(assigns.node.id),
        until: DateTime.add(DateTime.utc_now(), 15 * 60),
        next:
          if(assigns.node.id == "build_01",
            do: assigns.to.("key_replacement"),
            else: assigns.to.("key")
          )
      )

    ~H"""
    <div class="grid max-w-[45rem] gap-4">
      <div class="grid gap-1">
        <h2 class="text-[15px]/6 font-semibold">Connect {@node.name} with a command</h2>
        <p class="text-[13px]/[18px] text-muted">
          The command connects {@node.name} by itself: it makes the machine's key there, saves it, and writes Qory Apiary's address and public key into the runner file. The secret never leaves the machine.
        </p>
      </div>

      <p class="text-[13px]/5">On {@node.name}, run:</p>
      <.code_block id="command" code={@command} copy_label="Copy command" wrap />
      <.listening id="command-waiting">
        Waiting for {@node.name} to run it. This page shows when it is connected.
      </.listening>
      <p class="text-[13px]/5 text-muted">
        It works once, until {ApiaryWeb.Format.time(@until)}, 15 minutes from when you got it. This is the only time it is shown.
      </p>
      <div class="flex flex-wrap items-center gap-3">
        <.button variant="primary" href={@next}>Done</.button>
        <span class="text-[12.5px]/[18px] text-muted">
          Once you leave this page, the command is not shown again. Cancel it from the Access key tab if you won't run it.
        </span>
      </div>
    </div>
    """
  end

  defp code_of(id),
    do:
      :crypto.hash(:sha256, id)
      |> Base.encode32(padding: false)
      |> binary_part(0, 26)
      |> String.replace(~r/[ILOU]/, "X")

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

  defp current_key(node), do: Enum.find(node.keys, &(&1.state == :active))

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
  defp view("key_generate"), do: {:generate, nil}
  defp view("key_command"), do: {:command, nil}
  defp view("settings"), do: {:settings, nil}
  defp view("key_replacement"), do: {:key, :replacement}
  defp view("key_member"), do: {:key, :member}

  # The node as a variation leaves it: a replacement beside its key, both active.
  defp vary(node, :replacement), do: %{node | keys: node.keys ++ [Sample.replacement_key()]}
  defp vary(node, _variant), do: node
end
