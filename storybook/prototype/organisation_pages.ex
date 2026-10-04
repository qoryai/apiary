defmodule ApiaryWeb.Prototype.OrganisationPages do
  @moduledoc """
  The organisation and the person in the prototype (`ApiaryWeb.Prototype`): the
  organisation's operational pages, Overview and Audit log, and its Settings, General and
  People, with Invite people; and the person's own pages, all settings: Profile,
  Preferences and Organisations.
  """
  use Phoenix.Component

  import ApiaryWeb.CoreComponents

  alias ApiaryWeb.Prototype, as: P
  alias ApiaryWeb.Prototype.{Data, Shell}
  alias ApiaryWeb.SettingsComponents

  def render(assigns) do
    assigns = assign(assigns, member: assigns.role == :member, owner: assigns.role == :owner)

    ~H"""
    <.overview :if={@page.level == :organisation && @page.page == :overview} {assigns} />
    <.audit_log :if={@page.level == :organisation && @page.page == :audit_log} {assigns} />
    <.general :if={@page.level == :org_settings && @page.page == :general} {assigns} />
    <.people :if={@page.level == :org_settings && @page.page == :people} {assigns} />
    <.profile :if={@page.level == :person && @page.page == :profile} {assigns} />
    <.preferences :if={@page.level == :person && @page.page == :preferences} {assigns} />
    <.organisations :if={@page.level == :person && @page.page == :organisations} {assigns} />
    """
  end

  defp sections do
    [
      {nil,
       [
         %{key: :general, label: "General", href: P.org("/settings")},
         %{
           key: :people,
           label: "People",
           href: P.org("/settings/people"),
           count: length(Data.people())
         }
       ]}
    ]
  end

  ## Operational

  defp overview(assigns) do
    ~H"""
    <.header>
      Overview
      <:subtitle>acme's workspaces and what each is doing, and its people at a glance.</:subtitle>
    </.header>
    <section class="grid gap-2">
      <h2 class="font-semibold">Workspaces</h2>
      <.link
        patch={P.ws("")}
        class="flex flex-wrap items-center gap-3 rounded-box border border-line px-4 py-3 text-[13.5px]/5 hover:bg-base-200"
      >
        <.icon name="hero-squares-2x2" class="size-5 text-muted" />
        <span class="font-medium">shop</span>
        <span class="inline-flex items-center gap-1.5 text-muted">
          <span class="q-dot q-ripple text-info" aria-hidden="true"></span> 2 running
        </span>
        <span class="text-muted">· 1,284 runs in 14 days</span>
        <span class="flex-1"></span>
        <span class="text-accent">Open →</span>
      </.link>
    </section>
    <section class="grid gap-2">
      <h2 class="font-semibold">People</h2>
      <p class="text-[13.5px]/5">
        {length(Data.people())} people · 1 invitation waiting ·
        <Shell.go href={P.org("/settings/people")}>Settings › People</Shell.go>
      </p>
      <div class="flex -space-x-1.5">
        <.avatar :for={p <- Data.people()} name={p.email} size="sm" />
      </div>
    </section>
    """
  end

  defp audit_log(%{member: true} = assigns) do
    ~H"""
    <.empty_state title="Audit log" icon="hero-clipboard-document-list" heading="h1">
      Only owners and admins read who changed what.
    </.empty_state>
    """
  end

  defp audit_log(assigns) do
    ~H"""
    <.header>
      Audit log
      <:subtitle>Who changed what, across acme. A record you read, not a setting.</:subtitle>
    </.header>
    <div class="q-bar">
      <.list_search
        id="audit-search"
        label="Find a change"
        placeholder="Find a change, e.g. who:dana"
        live={false}
      />
    </div>
    <.table
      id="audit"
      label="Audit log"
      rows={Enum.with_index(Data.audit_log())}
      row_id={fn {_e, i} -> "audit-#{i}" end}
    >
      <:col :let={{e, _}} label="Who">
        <span class="inline-flex items-center gap-2"><.avatar name={e.who} size="xs" />{e.who}</span>
      </:col>
      <:col :let={{e, _}} label="What" kind="title">{e.what}</:col>
      <:col :let={{e, _}} label="Where" from="sm">{e.where}</:col>
      <:col :let={{e, _}} label="When" from="sm">{e.when}</:col>
    </.table>
    """
  end

  ## Settings

  defp general(assigns) do
    ~H"""
    <Shell.settings
      heading="Organisation settings"
      groups={sections()}
      current={:general}
      title="General"
      readonly={@member}
    >
      <:subtitle>The organisation's name, its address and its owners.</:subtitle>
      <form class="grid gap-4" onsubmit="return false">
        <.input id="org-name" name="name" label="Name" value="acme" disabled={@member} />
        <.input id="org-slug" name="slug" label="Address" prefix="/" value="acme" disabled={@member} />
        <div class="grid gap-1 text-[13.5px]/5">
          <span class="text-[13px] font-medium">Owners</span>
          <span>dana@example.com</span>
        </div>
        <SettingsComponents.save :if={!@member}>
          <.button
            variant="primary"
            type="button"
            phx-click="done"
            phx-value-to={P.org("/settings")}
            phx-value-say="Saved."
          >
            Save
          </.button>
        </SettingsComponents.save>
      </form>
      <SettingsComponents.danger_zone :if={!@member}>
        <SettingsComponents.danger_action id="delete-org" title="Delete organisation">
          Removes acme, its workspace and everything in it.
          <span :if={!@owner}>Only an owner deletes it.</span>
          <:action :if={@owner}>
            <.button variant="danger-ghost" disabled>Delete organisation…</.button>
          </:action>
        </SettingsComponents.danger_action>
      </SettingsComponents.danger_zone>
    </Shell.settings>
    """
  end

  defp people(assigns) do
    ~H"""
    <Shell.settings
      heading="Organisation settings"
      groups={sections()}
      current={:people}
      title="People"
      measure="list"
    >
      <:subtitle>acme's members, their levels, and invitations.</:subtitle>
      <:actions :if={!@member}>
        <.button variant="primary" patch={P.org("/settings/people/invite")}>Invite people</.button>
      </:actions>
      <.table id="org-people" label="Members" rows={Data.people()} row_id={&"member-#{&1.email}"}>
        <:col :let={p} label="Person" kind="title">
          <span class="inline-flex items-center gap-2"><.avatar name={p.email} size="sm" />{p.email}</span>
        </:col>
        <:col :let={p} label="Level">
          <select :if={@owner} class="select select-xs w-28">
            <option :for={l <- ~w(Owner Admin Member)} selected={l == p.level}>{l}</option>
          </select>
          <span :if={!@owner}>{p.level}</span>
        </:col>
        <:col :let={p} label="Since" from="sm">{p.since}</:col>
        <:action :let={p}>
          <.row_menu
            :if={!@member && p.level != "Owner"}
            id={"member-#{p.name}-menu"}
            label={"Actions for #{p.email}"}
          >
            <.menu_item>Suspend…</.menu_item>
            <.menu_item>Remove…</.menu_item>
          </.row_menu>
        </:action>
      </.table>
      <SettingsComponents.part title="Invitations" count={1}>
        <p class="text-[13.5px]/5">
          jo@example.com · Member · sent by dana, 2 days ago
        </p>
      </SettingsComponents.part>
      <p :if={!@owner} class="text-[12.5px] text-muted">Only owners change a person's level.</p>
    </Shell.settings>

    <Shell.dialog
      :if={@page.dialog == :invite}
      id="invite"
      title="Invite people"
      back={P.org("/settings/people")}
    >
      <.input
        id="invite-emails"
        name="emails"
        label="Email addresses"
        value=""
        placeholder="e.g. jo@example.com"
      />
      <.input
        id="invite-level"
        name="level"
        type="radio"
        label="Level"
        options={[{"Member", "member"}, {"Admin", "admin"}]}
        value="member"
      />
      <:footer>
        <.button patch={P.org("/settings/people")}>Cancel</.button>
        <.button
          variant="primary"
          phx-click="done"
          phx-value-to={P.org("/settings/people")}
          phx-value-say="Invitation sent."
        >
          Send invitation
        </.button>
      </:footer>
    </Shell.dialog>
    """
  end

  ## The person

  defp profile(assigns) do
    ~H"""
    <.header>
      Profile
      <:subtitle>Your name and email address.</:subtitle>
    </.header>
    <form class="grid max-w-[45rem] gap-4" onsubmit="return false">
      <.input
        id="me-name"
        name="name"
        label="Name"
        value={@role |> Shell.email() |> String.split("@") |> hd() |> String.capitalize()}
      />
      <.input id="me-email" name="email" label="Email" value={Shell.email(@role)} />
    </form>
    """
  end

  defp preferences(assigns) do
    ~H"""
    <.header>
      Preferences
      <:subtitle>How Apiary reads on this browser.</:subtitle>
    </.header>
    <div class="grid max-w-[45rem] gap-4">
      <SettingsComponents.theme_picker />
      <.input id="pref-keys" name="keys" type="checkbox" label="Single-key shortcuts" checked />
    </div>
    """
  end

  defp organisations(assigns) do
    ~H"""
    <.header>
      Organisations
      <:subtitle>The organisations you belong to.</:subtitle>
    </.header>
    <.link
      patch={P.org("")}
      class="flex max-w-[45rem] items-center gap-3 rounded-box border border-line px-4 py-3 text-[13.5px]/5 hover:bg-base-200"
    >
      <.avatar name="acme" kind="organisation" size="sm" />
      <span class="font-medium">acme</span>
      <span class="text-muted">{String.capitalize(to_string(@role))}</span>
      <span class="flex-1"></span>
      <span class="text-accent">Open →</span>
    </.link>
    """
  end
end
