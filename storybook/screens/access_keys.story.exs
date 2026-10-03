defmodule ApiaryWeb.Storybook.Screens.AccessKeys do
  @moduledoc false
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ApiaryWeb.CoreComponents

  alias ApiaryWeb.SettingsComponents
  alias ApiaryWeb.Storybook.{Mockup, Sample}

  def doc,
    do:
      "Settings › Access keys: each key's QORY_ACCESS_KEY_ID, whether its machines get the " <>
        "workspace's stored secrets, how many machines use it and who approved it. A key a " <>
        "machine asked for waits for approval; Approve and Reject lead to what follows."

  def navigation do
    [
      {:all, "All"},
      {:pending, "Pending approval"},
      {:approved, "After Approve"},
      {:rejected, "After Reject"}
    ]
  end

  def render(assigns) do
    keys =
      case assigns.tab do
        :approved -> Enum.map(Sample.access_keys(), &approve/1)
        :rejected -> Enum.reject(Sample.access_keys(), &(&1.state == :pending))
        _tab -> Sample.access_keys()
      end

    pending = Enum.filter(keys, &(&1.state == :pending))

    assigns =
      assign(assigns,
        all: length(keys),
        pending: length(pending),
        rows: if(assigns.tab == :pending, do: pending, else: keys)
      )

    ~H"""
    <Mockup.shell theme={@theme} nav={:settings}>
      <SettingsComponents.layout
        scope={Sample.scope()}
        kind={:workspace}
        sections={Mockup.settings_sections(@theme)}
        counts={Map.put(Mockup.settings_counts(), :keys, @all)}
        current={:keys}
        measure="list"
        title="Access keys"
      >
        <:subtitle>
          A key lets the machines of this workspace post their runs; one key serves as many
          machines as use it. A key a machine asks for waits for an owner's approval.
        </:subtitle>
        <:actions>
          <.button id="new-access-key" variant="primary" href="#">
            <.icon name="hero-plus-micro" class="size-4" />New access key
          </.button>
        </:actions>

        <.notice :if={@tab == :approved}>
          <strong>nightly is approved.</strong> The machine that asked for it can post runs now.
        </.notice>
        <.notice :if={@tab == :rejected}>
          <strong>nightly is rejected.</strong> The machine that asked for it cannot post runs.
        </.notice>

        <div class="grid gap-3">
          <.views id="key-views" label="Views">
            <:view
              navigate={Mockup.path("access_keys", :all, @theme)}
              count={@all}
              current={@tab != :pending}
            >
              All
            </:view>
            <:view
              navigate={Mockup.path("access_keys", :pending, @theme)}
              count={@pending}
              current={@tab == :pending}
            >
              Pending approval
            </:view>
          </.views>

          <.table id="access-keys" label="Access keys" rows={@rows} row_id={&"key-#{&1.id}"}>
            <:col :let={key} label="Name" kind="title">{key.label}</:col>
            <:col :let={key} label="QORY_ACCESS_KEY_ID" kind="faint">
              <span class="q-mono">{key.key_id}</span>
            </:col>
            <:col :let={key} label="Stored secrets" from="sm">
              {if key.stored_secrets, do: "Yes", else: "No"}
            </:col>
            <:col :let={key} label="Machines" kind="num" from="sm">
              <a
                :if={key.machines > 0}
                href={Mockup.path("machines", :all, @theme)}
                class="hover:underline"
              >
                {key.machines}
              </a>
              <span :if={key.machines == 0}>0</span>
            </:col>
            <:col :let={key} label="Approved by">
              <span :if={key.state == :active}>{key.approved_by}</span>
              <span :if={key.state == :pending} class="inline-flex flex-wrap items-baseline gap-x-2">
                <.state_word id={"key-#{key.id}-state"} hot>Pending approval</.state_word>
                <span class="q-faint">asked by {key.requested_by}</span>
              </span>
            </:col>
            <:action :let={key}>
              <.button
                :if={key.state == :pending}
                variant="link"
                href={Mockup.path("access_keys", :approved, @theme)}
                aria-label={"Approve #{key.label}"}
              >
                Approve
              </.button>
              <.button
                :if={key.state == :pending}
                variant="link"
                href={Mockup.path("access_keys", :rejected, @theme)}
                aria-label={"Reject #{key.label}"}
              >
                Reject
              </.button>
              <.row_menu
                :if={key.state == :active}
                id={"key-#{key.id}-menu"}
                label={"Actions for #{key.label}"}
              >
                <.menu_item href="#">Rotate…</.menu_item>
                <.menu_divider />
                <.menu_item href="#">Revoke…</.menu_item>
              </.row_menu>
            </:action>
          </.table>

          <p class="text-[12.5px]/[18px] text-faint">
            Stored secrets: whether the machines that use a key receive the workspace's
            secrets for their runs. A key without them runs only what needs none.
          </p>
        </div>
      </SettingsComponents.layout>
    </Mockup.shell>
    """
  end

  defp approve(%{state: :pending} = key), do: %{key | state: :active, approved_by: "dana"}
  defp approve(key), do: key
end
