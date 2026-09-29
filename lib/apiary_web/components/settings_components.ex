defmodule ApiaryWeb.SettingsComponents do
  @moduledoc """
  The settings, in one place (`docs/ui.md`, Settings): an organisation's, a workspace's and
  a person's own, one section a page. Configuration lives here, set up once and changed
  rarely; the sidebar holds the pages people use every day.

  - An organisation's (`/:org/settings/…`): General (its name and owners), People (its
    members, invitations and suspended memberships), Workspaces, Audit log (the Activity
    page, which keeps its own path), then the edition's sections
    (`c:ApiaryWeb.Edition.settings_tabs/1`), each a page of the edition's own, then Danger
    zone (deleting the organisation).
  - A workspace's (`/:org/:workspace/settings/…`): General (its name), Access keys,
    Retention, then Danger zone (deleting the workspace).
  - A person's own (`/users/settings…`, `/users/organisations`): Profile, Preferences and
    Organisations, the entries of the person's pages (`ApiaryWeb.Layouts.nav_entries/1`).

  On a page of any of them the sidebar lists all three kinds the reader may change, each
  under its kind and place, in place of the scope's pages (`nav/1`, given to
  `ApiaryWeb.Layouts.app/1` as `settings`): the organisation's, the workspace's, then the
  person's. A section the reader may not open is absent from the list, as a navigation
  entry is; its page still refuses them. A section's key names it among all three kinds,
  and gives its entry's DOM id, `settings-tab-<key>`.

  A page of the settings reads the list when it mounts, and again when the reader's
  membership changes, since an edition's section may ask the database whether it has
  anything for the reader; it renders its section with `layout/1`.
  """
  use ApiaryWeb, :html

  alias Apiary.Access
  alias Apiary.Accounts.Scope
  alias ApiaryWeb.Nav.Entry

  @type kind :: :organisation | :workspace | :person

  @doc """
  nav/1 is what the reader of `scope` may change, by kind, as the sidebar lists it on a page
  of settings: the organisation's sections when the scope has an organisation, the
  workspace's when it has a workspace, each only when the reader may open one of them, then
  the person's own, always. The person's own pages carry the workspace last opened
  (`ApiaryWeb.UserAuth.on_mount/4`, `:load_organisation`), so theirs show all three kinds
  too.
  """
  @spec nav(Scope.t()) :: [{kind, [Entry.t()]}]
  def nav(%Scope{} = scope) do
    for kind <- [:organisation, :workspace, :person],
        entries = kind_sections(scope, kind),
        entries != [],
        do: {kind, entries}
  end

  defp kind_sections(%Scope{organisation: nil}, kind) when kind in [:organisation, :workspace],
    do: []

  defp kind_sections(%Scope{workspace: nil}, :workspace), do: []
  defp kind_sections(scope, kind), do: sections(scope, kind)

  @doc """
  sections/2 is the sections of the organisation's (`:organisation`), the workspace's
  (`:workspace`) or the person's own (`:person`) settings the reader of `scope` may open,
  as `ApiaryWeb.Nav.Entry` values, in the list's order; each entry's `section` is its
  group: `:main`, `:edition` or `:danger`.
  """
  @spec sections(Scope.t(), kind) :: [Entry.t()]
  def sections(%Scope{organisation: organisation} = scope, :organisation) do
    main = [
      %Entry{
        section: :main,
        key: :organisation,
        label: gettext("General"),
        icon: "hero-adjustments-horizontal-micro",
        path: ~p"/#{organisation}/settings",
        place: :organisation
      },
      %Entry{
        section: :main,
        key: :people,
        label: gettext("People"),
        icon: "hero-users-micro",
        path: ~p"/#{organisation}/settings/people",
        place: :organisation,
        count: :members
      },
      can?(scope, :"workspace.delete") &&
        %Entry{
          section: :main,
          key: :workspaces,
          label: gettext("Workspaces"),
          icon: "hero-squares-2x2-micro",
          path: ~p"/#{organisation}/settings/workspaces",
          place: :organisation
        },
      can?(scope, :"audit.read") &&
        %Entry{
          section: :main,
          key: :audit_log,
          label: gettext("Audit log"),
          icon: "hero-clipboard-document-list-micro",
          path: ~p"/#{organisation}/activity",
          place: :organisation
        }
    ]

    edition =
      for %Entry{} = tab <- ApiaryWeb.Edition.settings_tabs(scope), do: %{tab | section: :edition}

    danger =
      danger_zone?(scope) &&
        %Entry{
          section: :danger,
          key: :danger,
          label: gettext("Danger zone"),
          icon: "hero-exclamation-triangle-micro",
          path: ~p"/#{organisation}/settings/danger",
          place: :organisation
        }

    Enum.filter(main ++ edition ++ [danger], & &1)
  end

  def sections(%Scope{organisation: organisation, workspace: workspace} = scope, :workspace) do
    Enum.filter(
      [
        %Entry{
          section: :main,
          key: :general,
          label: gettext("General"),
          icon: "hero-adjustments-horizontal-micro",
          path: ~p"/#{organisation}/#{workspace}/settings"
        },
        %Entry{
          section: :main,
          key: :keys,
          label: gettext("Access keys"),
          icon: "hero-key-micro",
          path: ~p"/#{organisation}/#{workspace}/settings/keys",
          count: :keys
        },
        %Entry{
          section: :main,
          key: :retention,
          label: gettext("Retention"),
          icon: "hero-archive-box-micro",
          path: ~p"/#{organisation}/#{workspace}/settings/retention"
        },
        can?(scope, :"workspace.delete") &&
          %Entry{
            section: :danger,
            key: :workspace_danger,
            label: gettext("Danger zone"),
            icon: "hero-exclamation-triangle-micro",
            path: ~p"/#{organisation}/#{workspace}/settings/danger"
          }
      ],
      & &1
    )
  end

  def sections(%Scope{} = scope, :person) do
    for %Entry{place: :person} = entry <- ApiaryWeb.Layouts.nav_entries(scope),
        is_nil(entry.filter) or entry.filter.(scope, nil),
        do: %{entry | section: :main}
  end

  # The organisation's danger zone: deleting it, for whoever may; and for an owner of the
  # instance's organisation, which cannot be deleted, the sentence that says why.
  defp danger_zone?(%Scope{organisation: organisation} = scope) do
    can?(scope, :"organisation.delete") or
      (can?(scope, :"organisation.rename") and
         Access.refused_on?(:"organisation.delete", organisation))
  end

  # The settings' actions are asked of the organisation: deleting a workspace, reading the
  # audit trail and deleting the organisation are its.
  defp can?(%Scope{organisation: organisation} = scope, action),
    do: Access.can?(scope, action, organisation)

  @doc """
  layout/1 is a section of the settings, which is the page: one faint line that names the
  kind of settings and its place ("Workspace settings · Main", "Your account"), the
  section's title as the page's `<h1>`, one sentence of what it is for, at most one
  primary and one default action, then its content. The list of the sections is the
  sidebar's (`nav/1`).

  A section of forms keeps a 720 px column (`measure="read"`); one that is a list, such
  as the people or the access keys, a 960 px one (`measure="list"`).
  """
  attr :scope, :any, required: true
  attr :kind, :atom, required: true, values: [:organisation, :workspace, :person]
  attr :current, :atom, required: true, doc: "the key of the section, which gives its DOM id"
  attr :measure, :string, default: "read", values: ~w(read list)
  attr :title, :string, required: true, doc: "the section's title"
  slot :subtitle, doc: "one sentence: what the section is for"
  slot :actions, doc: "at most one primary and one default action"
  slot :inner_block, required: true

  def layout(assigns) do
    ~H"""
    <section
      id={"settings-section-#{@current}"}
      class={["q-settings", "q-settings-#{@measure}"]}
      aria-labelledby="settings-section-title"
    >
      <header>
        <p id="settings-kind" class="q-settings-kind">{kind_line(@kind, @scope)}</p>
        <div class="q-settings-head">
          <div class="min-w-0">
            <h1 id="settings-section-title" class="q-settings-title">{@title}</h1>
            <p :if={@subtitle != []} class="q-settings-sub">{render_slot(@subtitle)}</p>
          </div>
          <div :if={@actions != []} class="q-settings-actions">{render_slot(@actions)}</div>
        </div>
      </header>
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc """
  heading/2 is the name of a kind of settings where the sidebar lists it: the kind, then
  its place's name ("Organisation · 8wonders", "Workspace · Main"), and "Your account" for
  the person's own.
  """
  @spec heading(kind, Scope.t()) :: String.t()
  def heading(:organisation, scope),
    do: gettext("Organisation · %{name}", name: scope.organisation.name)

  def heading(:workspace, scope), do: gettext("Workspace · %{name}", name: scope.workspace.name)
  def heading(:person, _scope), do: gettext("Your account")

  defp kind_line(:organisation, scope),
    do: gettext("Organisation settings · %{name}", name: scope.organisation.name)

  defp kind_line(:workspace, scope),
    do: gettext("Workspace settings · %{name}", name: scope.workspace.name)

  defp kind_line(:person, _scope), do: gettext("Your account")
end
