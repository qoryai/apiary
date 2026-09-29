defmodule ApiaryWeb.SettingsComponents do
  @moduledoc """
  The settings of an organisation and of a workspace, GitHub's way: one page per section,
  and beside it the list of the sections (`layout/1`). Configuration lives here, set up
  once and changed rarely; the sidebar holds the pages people use every day.

  - An organisation's (`/:org/settings/…`): General (its name and owners), People (its
    members, invitations and suspended memberships), Workspaces, Audit log (the Activity
    page, which keeps its own path), then the edition's sections
    (`c:ApiaryWeb.Edition.settings_tabs/1`), each a page of the edition's own, then Danger
    zone (deleting the organisation).
  - A workspace's (`/:org/:workspace/settings/…`): General (its name), Access keys,
    Retention, then Danger zone (deleting the workspace).

  Each list ends with the other settings a person may want next: the organisation's or the
  workspace's, and their own. A section the reader may not open is absent from the list,
  as a navigation entry is; its page still refuses them.

  A page of the settings reads its sections when it mounts, and again when the reader's
  membership changes (`sections/2`), since an edition's section may ask the database
  whether it has anything for the reader; it renders them with `layout/1`, its own marked
  current.
  """
  use ApiaryWeb, :html

  alias Apiary.Access
  alias Apiary.Accounts.Scope
  alias ApiaryWeb.Nav.Entry

  @doc """
  sections/2 is the sections of the organisation's (`:organisation`) or the workspace's
  (`:workspace`) settings the reader of `scope` may open, as `ApiaryWeb.Nav.Entry` values,
  in the list's order; each entry's `section` is its group: `:main`, `:edition`, `:danger`
  or `:elsewhere`.
  """
  @spec sections(Scope.t(), :organisation | :workspace) :: [Entry.t()]
  def sections(%Scope{organisation: organisation} = scope, :organisation) do
    main = [
      %Entry{
        section: :main,
        key: :organisation,
        label: gettext("General"),
        icon: "hero-adjustments-horizontal-micro",
        path: ~p"/#{organisation}/settings"
      },
      %Entry{
        section: :main,
        key: :people,
        label: gettext("People"),
        icon: "hero-users-micro",
        path: ~p"/#{organisation}/settings/people"
      },
      can?(scope, :"workspace.delete") &&
        %Entry{
          section: :main,
          key: :workspaces,
          label: gettext("Workspaces"),
          icon: "hero-squares-2x2-micro",
          path: ~p"/#{organisation}/settings/workspaces"
        },
      can?(scope, :"audit.read") &&
        %Entry{
          section: :main,
          key: :audit_log,
          label: gettext("Audit log"),
          icon: "hero-clipboard-document-list-micro",
          path: ~p"/#{organisation}/activity"
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
          path: ~p"/#{organisation}/settings/danger"
        }

    elsewhere = [
      scope.workspace &&
        %Entry{
          section: :elsewhere,
          key: :workspace_settings,
          label: gettext("Workspace settings"),
          icon: "hero-cog-6-tooth-micro",
          path: ~p"/#{organisation}/#{scope.workspace}/settings"
        },
      your_settings()
    ]

    Enum.filter(main ++ edition ++ [danger] ++ elsewhere, & &1)
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
          path: ~p"/#{organisation}/#{workspace}/settings/keys"
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
            key: :danger,
            label: gettext("Danger zone"),
            icon: "hero-exclamation-triangle-micro",
            path: ~p"/#{organisation}/#{workspace}/settings/danger"
          },
        %Entry{
          section: :elsewhere,
          key: :organisation_settings,
          label: gettext("Organisation settings"),
          icon: "hero-building-office-2-micro",
          path: ~p"/#{organisation}/settings"
        },
        your_settings()
      ],
      & &1
    )
  end

  defp your_settings do
    %Entry{
      section: :elsewhere,
      key: :your_settings,
      label: gettext("Your settings"),
      icon: "hero-user-circle-micro",
      path: ~p"/users/settings"
    }
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
  layout/1 is a page of the settings: the settings' heading, the list of the sections
  beside the section (`sections/2`), `current` marked, and the section itself, its title,
  what it is for and its actions above its content. From 1024 px the list is a column at
  the page's left edge; below, it is a row of links above the section.

  A section of forms keeps a 720 px column (`measure="read"`); one that is a list, such
  as the people or the access keys, a 960 px one (`measure="list"`).
  """
  attr :scope, :any, required: true
  attr :kind, :atom, required: true, values: [:organisation, :workspace]
  attr :sections, :list, required: true, doc: "the sections, as `sections/2` gives them"
  attr :current, :atom, required: true, doc: "the key of the section of the page"
  attr :measure, :string, default: "read", values: ~w(read list)
  attr :title, :string, required: true, doc: "the section's title"
  slot :subtitle, doc: "one sentence: what the section is for"
  slot :actions, doc: "at most one primary and one default action"
  slot :inner_block, required: true

  def layout(assigns) do
    assigns =
      assign(
        assigns,
        :groups,
        assigns.sections |> Enum.chunk_by(& &1.section) |> Enum.map(&{hd(&1).section, &1})
      )

    ~H"""
    <div class="q-settings">
      <h1 class="q-settings-title">
        {if @kind == :organisation,
          do: gettext("Organisation settings"),
          else: gettext("Workspace settings")}
      </h1>

      <nav id="settings-tabs" class="q-settings-nav" aria-label={gettext("Settings")}>
        <div
          :for={{group, entries} <- @groups}
          class={["q-settings-group", "q-settings-group-#{group}"]}
        >
          <p :if={group == :elsewhere} class="q-settings-heading">{gettext("Elsewhere")}</p>
          <.link
            :for={entry <- entries}
            id={"settings-tab-#{entry.key}"}
            navigate={Entry.path(entry, @scope.organisation, @scope.workspace)}
            aria-current={entry.key == @current && "page"}
            class={["q-settings-link", entry.section == :danger && "q-settings-danger"]}
          >
            <.icon name={entry.icon} class="q-settings-icon size-4" />
            <span class="truncate">{entry.label}</span>
          </.link>
        </div>
      </nav>

      <section
        id={"settings-section-#{@current}"}
        class={["q-settings-main", "q-settings-main-#{@measure}"]}
        aria-labelledby="settings-section-title"
      >
        <header class="q-settings-head">
          <div class="min-w-0">
            <h2 id="settings-section-title" class="q-settings-head-title">{@title}</h2>
            <p :if={@subtitle != []} class="q-settings-head-sub">{render_slot(@subtitle)}</p>
          </div>
          <div :if={@actions != []} class="flex flex-none flex-wrap items-center gap-2">
            {render_slot(@actions)}
          </div>
        </header>
        {render_slot(@inner_block)}
      </section>
    </div>
    """
  end
end
