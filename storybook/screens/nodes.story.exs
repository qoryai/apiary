defmodule ApiaryWeb.Storybook.Screens.Nodes do
  @moduledoc false
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ApiaryWeb.CoreComponents

  alias ApiaryWeb.SettingsComponents
  alias ApiaryWeb.Storybook.Mockup

  def doc,
    do:
      "Nodes, a page of the sidebar: every node and node pool with its state, Running or " <>
        "when it was last seen, a pool's running instances beneath it, and its access key. " <>
        "New node and New node pool choose the kind, which never changes."

  def navigation do
    [
      {:all, "All"},
      {:running, "Running"},
      {:not_running, "Not running"},
      {:member, "As a member"},
      {:new_node, "New node"},
      {:new_pool, "New node pool"}
    ]
  end

  def render(%{tab: tab} = assigns) when tab in [:new_node, :new_pool] do
    assigns = assign(assigns, :kind, if(tab == :new_node, do: :node, else: :pool))

    ~H"""
    <Mockup.shell theme={@theme} nav={:nodes} width="read">
      <:crumb href={Mockup.path("nodes", :all, @theme)}>Nodes</:crumb>
      <:crumb>{if @kind == :node, do: "New node", else: "New node pool"}</:crumb>

      <.header>
        {if @kind == :node, do: "New node", else: "New node pool"}
        <:subtitle>Name it and choose its kind. You add its access key next.</:subtitle>
      </.header>

      <form id="new-node-form" class="grid gap-5" novalidate>
        <fieldset id="new-node-kind" class="fieldset gap-2" aria-describedby="new-node-kind-hint">
          <legend class="mb-1 text-[13px]/[18px] font-medium">Kind</legend>
          <div class="grid gap-2 sm:grid-cols-2">
            <.kind
              id="kind-node"
              href={Mockup.path("nodes", :new_node, @theme)}
              current={@kind == :node}
              title="Node"
            >
              Permanent. One instance at a time, with its own key.
            </.kind>
            <.kind
              id="kind-pool"
              href={Mockup.path("nodes", :new_pool, @theme)}
              current={@kind == :pool}
              title="Node pool"
            >
              Ephemeral instances that share one key, up to a limit you set or none.
            </.kind>
          </div>
          <p id="new-node-kind-hint" class="text-[12.5px]/[18px] text-muted">
            The kind is chosen now and can't be changed later.
          </p>
        </fieldset>

        <.input
          id="new-node-name"
          name="name"
          label="Name"
          value=""
          placeholder={if @kind == :node, do: "build-03", else: "ci-runners"}
          hint="Lowercase letters, digits and hyphens. Runs name it."
        />

        <div :if={@kind == :pool} class="grid gap-2">
          <.input
            id="new-node-limit"
            name="limit"
            type="number"
            label="Instances at once"
            value="10"
            min="1"
            hint="At most this many run at once; one more is refused at run start."
          />
          <.input
            id="new-node-no-limit"
            name="no_limit"
            type="checkbox"
            label="No limit"
            checked={false}
          />
        </div>

        <SettingsComponents.save>
          <.button variant="primary" type="button">
            {if @kind == :node, do: "Create node", else: "Create node pool"}
          </.button>
          <:note>
            Then connect it: run one command on the machine, or generate a key for a CI or another system.
          </:note>
        </SettingsComponents.save>
      </form>
    </Mockup.shell>
    """
  end

  def render(assigns) do
    member = assigns.tab == :member

    assigns =
      assign(assigns,
        member: member,
        view: if(member or is_nil(assigns.tab), do: :all, else: assigns.tab)
      )

    ~H"""
    <Mockup.shell
      theme={@theme}
      nav={:nodes}
      account={if @member, do: "sam@example.com", else: "dana@example.com"}
    >
      <Mockup.nodes theme={@theme} view={@view} member={@member} />
    </Mockup.shell>
    """
  end

  attr :id, :string, required: true
  attr :href, :string, required: true
  attr :current, :boolean, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  # One kind to choose, a link to the form of that kind: the storybook runs no script.
  defp kind(assigns) do
    ~H"""
    <a
      id={@id}
      href={@href}
      aria-current={@current && "true"}
      class={[
        "grid gap-1 rounded-box border p-3",
        if(@current, do: "border-primary bg-primary-soft", else: "border-line hover:bg-base-200")
      ]}
    >
      <span class="inline-flex items-center gap-2 text-[13.5px]/5 font-medium">
        <.icon :if={@current} name="hero-check-circle-mini" class="size-4 text-primary" />
        <span
          :if={!@current}
          class="size-4 rounded-full border border-line-strong"
          aria-hidden="true"
        ></span>
        {@title}
      </span>
      <span class="text-[12.5px]/[18px] text-muted">{render_slot(@inner_block)}</span>
    </a>
    """
  end
end
