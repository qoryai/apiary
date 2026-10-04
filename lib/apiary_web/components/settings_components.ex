defmodule ApiaryWeb.SettingsComponents do
  @moduledoc """
  The settings of an organisation and of a workspace, GitHub's way: each kind its own
  place, reached from its own scope, one section a page with the list of that kind's
  sections beside it (`layout/1`), while the sidebar stays the scope's, its Settings the
  current entry. Configuration lives here, set up once and changed rarely; the sidebar
  holds the pages people use every day.

  - An organisation's (`/:org/settings/…`): General (its name and owners, and deleting
    it), People (its members, invitations and suspended memberships), Workspaces, Audit log
    (`ApiaryWeb.ActivityLive`), then the edition's sections
    (`c:ApiaryWeb.Edition.settings_tabs/1`), each a page of the edition's own.
  - A workspace's (`/:org/:workspace/settings/…`): General (its name, and deleting it),
    People (who reaches it, and at what level: read here, managed in the organisation's
    People), Access keys, Runs (how long it keeps runs, their events and their logs), and,
    with the `security` feature, Secrets and variables (`ApiaryWeb.SecretLive.Index`).
  - A node's (`/:org/:workspace/nodes/:node_id/settings`), the last tab of the node's page
    (`ApiaryWeb.NodeLive.Show`): General (its name, a pool's instance limit, and deleting
    it).

  A person's own settings are the person's pages, and their sidebar is their list
  (`ApiaryWeb.Layouts`). A list holds its kind's sections only: no other kind's, no link
  across. A section the reader may not open is absent from it, as a navigation entry is;
  its page still refuses them. What cannot be undone is never an entry: it is the danger
  zone at the end of its scope's General page, or of Profile (`danger_zone/1`), and its
  confirmation expands in place there, at a path of its own (`danger_action/1`).

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
  sections/2 is the sections of the organisation's (`:organisation`), the workspace's
  (`:workspace`) or a node's (`{:node, node}`) settings the reader of `scope` may open, as
  `ApiaryWeb.Nav.Entry` values, in the list's order; each entry's `section` is `:main`, or
  `:edition` for the edition's.
  """
  @spec sections(Scope.t(), :organisation | :workspace | {:node, Apiary.Nodes.Node.t()}) ::
          [Entry.t()]
  def sections(%Scope{organisation: organisation} = scope, :organisation) do
    main = [
      %Entry{
        section: :main,
        key: :organisation,
        label: gettext("General"),
        icon: "hero-adjustments-horizontal",
        path: ~p"/#{organisation}/settings",
        place: :organisation
      },
      %Entry{
        section: :main,
        key: :people,
        label: gettext("People"),
        icon: "hero-users",
        path: ~p"/#{organisation}/settings/people",
        place: :organisation,
        count: :members
      },
      can?(scope, :"workspace.delete") &&
        %Entry{
          section: :main,
          key: :workspaces,
          label: gettext("Workspaces"),
          icon: "hero-squares-2x2",
          path: ~p"/#{organisation}/settings/workspaces",
          place: :organisation
        },
      can?(scope, :"audit.read") &&
        %Entry{
          section: :main,
          key: :audit_log,
          label: gettext("Audit log"),
          icon: "hero-clipboard-document-list",
          path: ~p"/#{organisation}/settings/audit-log",
          place: :organisation
        }
    ]

    edition =
      for %Entry{} = tab <- ApiaryWeb.Edition.settings_tabs(scope), do: %{tab | section: :edition}

    Enum.filter(main ++ edition, & &1)
  end

  def sections(%Scope{organisation: organisation, workspace: workspace} = scope, :workspace) do
    [
      %Entry{
        section: :main,
        key: :general,
        label: gettext("General"),
        icon: "hero-adjustments-horizontal",
        path: ~p"/#{organisation}/#{workspace}/settings"
      },
      %Entry{
        section: :main,
        key: :people,
        label: gettext("People"),
        icon: "hero-users",
        path: ~p"/#{organisation}/#{workspace}/settings/people"
      },
      %Entry{
        section: :main,
        key: :keys,
        label: gettext("Access keys"),
        icon: "hero-key",
        path: ~p"/#{organisation}/#{workspace}/settings/keys",
        count: :keys
      },
      %Entry{
        section: :main,
        key: :runs,
        label: gettext("Runs"),
        icon: "hero-archive-box",
        path: ~p"/#{organisation}/#{workspace}/settings/runs"
      },
      Access.can?(scope, :"secret.read", workspace) &&
        %Entry{
          section: :main,
          key: :secrets,
          label: gettext("Secrets and variables"),
          icon: "hero-lock-closed",
          path: ~p"/#{organisation}/#{workspace}/settings/secrets"
        }
    ]
    |> Enum.filter(& &1)
  end

  def sections(%Scope{organisation: organisation, workspace: workspace}, {:node, node}) do
    [
      %Entry{
        section: :main,
        key: :general,
        label: gettext("General"),
        icon: "hero-adjustments-horizontal",
        path: ~p"/#{organisation}/#{workspace}/nodes/#{node}/settings"
      }
    ]
  end

  # The settings' actions are asked of the organisation: listing its workspaces, whose
  # deletion is its, and reading the audit trail.
  defp can?(%Scope{organisation: organisation} = scope, action),
    do: Access.can?(scope, action, organisation)

  @doc """
  layout/1 is a page of the settings: the settings' heading, "Organisation settings" or
  "Workspace settings" (a node's settings, a tab of its page, have the page's heading
  instead), the list of the sections beside the section (`sections/2`),
  `current` marked, and the section itself, its title, what it is for and its actions
  above its content. From 1024 px the list is a column at the page's left edge; below, it
  is a row of links above the section.

  A section of forms keeps a 720 px column (`measure="read"`); one that is a list, such
  as the people or the access keys, a 960 px one (`measure="list"`).
  """
  attr :scope, :any, required: true
  attr :kind, :atom, required: true, values: [:organisation, :workspace, :node]
  attr :sections, :list, required: true, doc: "the sections, as `sections/2` gives them"

  attr :counts, :map,
    default: nil,
    doc: "the navigation's counts (`ApiaryWeb.UserAuth.nav_counts/1`), for an entry's `count`"

  attr :current, :atom, required: true, doc: "the key of the section of the page"
  attr :measure, :string, default: "read", values: ~w(read list)
  attr :title, :string, required: true, doc: "the section's title"
  slot :subtitle, doc: "one sentence: what the section is for"
  slot :actions, doc: "at most one primary and one default action"
  slot :inner_block, required: true

  def layout(assigns) do
    ~H"""
    <div class="q-settings">
      <h1 :if={@kind != :node} class="q-settings-title outline-none" tabindex="-1">
        {if @kind == :organisation,
          do: gettext("Organisation settings"),
          else: gettext("Workspace settings")}
      </h1>

      <nav id="settings-tabs" class="q-settings-nav" aria-label={gettext("Settings")}>
        <.link
          :for={entry <- @sections}
          id={"settings-tab-#{entry.key}"}
          navigate={Entry.path(entry, @scope.organisation, @scope.workspace)}
          aria-current={entry.key == @current && "page"}
          class="q-settings-link"
        >
          <span class="truncate">{entry.label}</span>
          <span :if={count = count(@counts, entry)} class="q-settings-n">
            {Format.number(count)}
          </span>
        </.link>
      </nav>

      <%!-- Not a named region: the section's heading leads it, and a list in it is the
           region (`<.table label>`), so no two landmarks share the section's name. --%>
      <section
        id={"settings-section-#{@current}"}
        class={["q-settings-main", "q-settings-main-#{@measure}"]}
      >
        <header class="q-settings-head">
          <div class="min-w-0">
            <h2 id="settings-section-title" class="q-settings-head-title">{@title}</h2>
            <p :if={@subtitle != []} class="q-settings-head-sub">{render_slot(@subtitle)}</p>
          </div>
          <div :if={@actions != []} class="q-settings-actions">{render_slot(@actions)}</div>
        </header>
        {render_slot(@inner_block)}
      </section>
    </div>
    """
  end

  # An entry's count, where the page passed the navigation's counts and the entry has one.
  defp count(%{} = counts, %Entry{count: key}) when is_atom(key) and not is_nil(key) do
    case Map.get(counts, key) do
      n when is_integer(n) -> n
      _none -> nil
    end
  end

  defp count(_counts, _entry), do: nil

  @doc """
  part/1 is one part of a settings section, or of a person's settings page: its fields or
  its list straight on the page, no card, under a heading when the section has more than
  one part (an `<h3>` under the section's `<h2>`; an `<h2>` on a person's page, whose
  title is the `<h1>`), with a count beside it where one helps.
  """
  attr :id, :string, default: nil
  attr :title, :string, default: nil
  attr :count, :integer, default: nil
  attr :level, :atom, default: :h3, values: [:h2, :h3]
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def part(assigns) do
    assigns = assign_new(assigns, :heading_id, fn -> assigns.id && "#{assigns.id}-title" end)

    ~H"""
    <section
      id={@id}
      class={["q-part", @class]}
      aria-labelledby={@title && @heading_id}
    >
      <h2 :if={@title && @level == :h2} id={@heading_id} class="q-part-h q-part-h2">
        {@title}
        <span :if={@count} class="q-part-n">{Format.number(@count)}</span>
      </h2>
      <h3 :if={@title && @level == :h3} id={@heading_id} class="q-part-h">
        {@title}
        <span :if={@count} class="q-part-n">{Format.number(@count)}</span>
      </h3>
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc """
  save/1 is the foot of a settings form: its button, one primary per section where the
  section has one main action, and beside it one muted line of who may change it or what
  happens once it is saved.

  On a page of its own that creates or changes one thing, Cancel follows the button: a link back to the list the page was opened from (`cancel`), by `patch`
  within the list's LiveView and by `navigate` from another.
  """
  attr :id, :string, default: nil
  attr :cancel, :string, default: nil, doc: "where Cancel leads back to"

  attr :cancel_by, :string,
    default: "patch",
    values: ~w(patch navigate href),
    doc: "how Cancel leads back: `href` for a page of the storybook"

  slot :inner_block, required: true, doc: "the button"
  slot :note, doc: "the muted line"

  def save(assigns) do
    ~H"""
    <div id={@id} class="q-save">
      {render_slot(@inner_block)}
      <.button
        :if={@cancel && @cancel_by == "patch"}
        id={@id && "#{@id}-cancel"}
        patch={@cancel}
      >
        {gettext("Cancel")}
      </.button>
      <.button
        :if={@cancel && @cancel_by == "navigate"}
        id={@id && "#{@id}-cancel"}
        navigate={@cancel}
      >
        {gettext("Cancel")}
      </.button>
      <.button :if={@cancel && @cancel_by == "href"} id={@id && "#{@id}-cancel"} href={@cancel}>
        {gettext("Cancel")}
      </.button>
      <span :if={@note != []}>{render_slot(@note)}</span>
    </div>
    """
  end

  @doc """
  theme_picker/1 is Preferences' choice of the theme: Auto, Light and Dark as three radios,
  each drawn as a small picture of the theme (the theme's own tokens, set by `data-theme`
  on the picture) with its name. The theme is the account menu's, a reading preference of
  the browser that the root layout's script keeps: a choice is the same `phx:set-theme`
  event, and the script marks the one in force.
  """
  def theme_picker(assigns) do
    assigns =
      assign(assigns, :themes, [
        {"system", gettext("Auto")},
        {"light", gettext("Light")},
        {"dark", gettext("Dark")}
      ])

    ~H"""
    <fieldset id="theme-picker" class="q-themes" phx-update="ignore">
      <legend class="sr-only">{gettext("Theme")}</legend>
      <label :for={{theme, label} <- @themes} id={"theme-pick-#{theme}"} class="q-theme-opt">
        <input
          type="radio"
          name="theme"
          value={theme}
          class="q-theme-input"
          data-phx-theme={theme}
          phx-click={JS.dispatch("phx:set-theme")}
        />
        <span :if={theme != "system"} class="q-swatch" aria-hidden="true">
          <.theme_swatch theme={if theme == "dark", do: "qory-dark", else: "qory"} />
        </span>
        <span :if={theme == "system"} class="q-swatch q-swatch-two" aria-hidden="true">
          <.theme_swatch theme="qory" />
          <.theme_swatch theme="qory-dark" />
        </span>
        <span class="q-theme-name">
          {label}
          <.icon name="hero-check-circle-micro" class="q-theme-check size-4" />
        </span>
      </label>
    </fieldset>
    """
  end

  # A picture of a theme in its own colours: the sidebar, a honey bar and two lines.
  attr :theme, :string, required: true

  defp theme_swatch(assigns) do
    ~H"""
    <span class="q-swatch-pane" data-theme={@theme}>
      <i></i>
      <span><b></b><b></b><b></b></span>
    </span>
    """
  end

  @doc """
  workspace_list/1 is the Workspaces section's list: each workspace of `workspaces`, the
  organisation's in use, one row on the row spec, its name the title with its slug beside
  it, its targets where the page counted them (`targets`), when it was created, and its ⋯
  menu, the edition's items (the `:workspace_actions`
  slot) then Delete…, which opens the deletion's dialog at its own path, by `patch` from
  the organisation's settings and by `navigate` from an edition's page over the same
  list; then the note under the list, what a deletion does, or why the only workspace is
  not deleted on its own.
  """
  attr :scope, :any, required: true
  attr :workspaces, :list, required: true, doc: "the organisation's workspaces in use"

  attr :targets, :map,
    default: nil,
    doc: "how many targets each workspace has, by its id (`Apiary.Targets.count_by_workspace/1`)"

  attr :delete, :string, default: "patch", values: ~w(patch navigate)

  def workspace_list(assigns) do
    days = Apiary.Deletion.grace_days()

    assigns =
      assign(assigns,
        days: ngettext("%{number} day", "%{number} days", days, number: Format.number(days)),
        path: &delete_path(assigns.scope, &1)
      )

    ~H"""
    <.table
      id="workspaces"
      label={gettext("Workspaces")}
      rows={@workspaces}
      row_id={&"workspace-#{&1.id}"}
    >
      <:col :let={workspace} label={gettext("Workspace")} kind="title">
        <span class="q-nm">
          <.link navigate={~p"/#{@scope.organisation}/#{workspace}"} class="q-title hover:underline">
            {workspace.name}
          </.link>
          <span class="q-side q-mono">{workspace.slug}</span>
        </span>
      </:col>
      <:col :let={workspace} :if={@targets} label={gettext("Targets")} kind="num" from="sm">
        <span id={"workspace-#{workspace.id}-targets"} class="tabular-nums">
          {Format.number(Map.get(@targets, workspace.id, 0))}
        </span>
      </:col>
      <:col :let={workspace} label={gettext("Created")} from="sm">
        <span class="tabular-nums">{Format.day(workspace.inserted_at)}</span>
      </:col>
      <:action :let={workspace}>
        <.row_menu
          id={"workspace-#{workspace.id}-menu"}
          label={gettext("Actions for the workspace %{name}", name: workspace.name)}
        >
          <ApiaryWeb.Extension.slot name={:workspace_actions} scope={@scope} workspace={workspace} />
          <.menu_item
            :if={length(@workspaces) > 1}
            id={"workspace-#{workspace.id}-delete"}
            patch={if(@delete == "patch", do: @path.(workspace))}
            navigate={if(@delete == "navigate", do: @path.(workspace))}
            aria-label={gettext("Delete the workspace %{name}", name: workspace.name)}
          >
            {gettext("Delete…")}
          </.menu_item>
        </.row_menu>
      </:action>
    </.table>
    <p id="workspaces-note" class="text-[12.5px]/[18px] text-faint">
      {if length(@workspaces) > 1,
        do:
          gettext(
            "A deleted workspace is purged after %{days}; until then an owner or an admin can cancel the deletion here.",
            days: @days
          ),
        else:
          gettext(
            "The organisation's only workspace is not deleted on its own: delete the organisation instead."
          )}
    </p>
    """
  end

  defp delete_path(scope, workspace),
    do: ~p"/#{scope.organisation}/settings/workspaces/#{workspace.id}/delete"

  @doc """
  danger_zone/1 is the last part of a scope's General page, and of Profile: after a rule,
  the heading Danger zone, the page's only red words, and one line for each act that
  cannot be undone (`danger_action/1`), with whatever the page says of it under its line.
  No box: the lines rest on the page. It is absent for a reader who may do none of them.
  """
  attr :id, :string, default: "danger-zone"
  slot :inner_block, required: true

  def danger_zone(assigns) do
    ~H"""
    <section id={@id} class="q-danger" aria-labelledby={"#{@id}-title"}>
      <h2 id={"#{@id}-title"} class="q-danger-title">{gettext("Danger zone")}</h2>
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc """
  danger_action/1 is one line of a danger zone: the act's title, one muted sentence of
  what it does and what cannot be undone, and at the right its button (`button`), a
  default one in the error colour. The confirmation is inline, GitHub's way, never a
  dialog: the button is a patch to the act's own path (`open_path`), and there (`open`)
  the line expands in place under its sentence into the confirmation's form, what is lost
  (`:lost`), the field asked to confirm (`:field`), such as the slug typed, then the red
  button (`confirm`, enabled once `ready`) and Cancel. Expanded, its first field takes the
  focus, or the red button where there is no field; the button above becomes the way to
  fold it (`aria-expanded`), as Cancel does, a patch back to the page (`close_path`) that
  returns the focus to that button.

  Without a button, where the act is not there, the sentence says why; `disabled` shows
  the button but does not offer it, while something stops the act and the page says what
  under the line.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true

  attr :button, :string,
    default: nil,
    doc: "the button's words, such as Delete organisation…; none where the act is not there"

  attr :disabled, :boolean, default: false, doc: "the button shown but not offered"
  attr :open, :boolean, default: false, doc: "whether the confirmation is expanded"
  attr :open_path, :string, default: nil, doc: "the act's own path, which expands it"
  attr :close_path, :string, default: nil, doc: "the page's path, which folds it"
  attr :form, :any, default: nil, doc: "the confirmation's form, where it asks for a field"
  attr :change, :string, default: nil, doc: "the event of a change of the field"
  attr :submit, :string, default: nil, doc: "the event of the red button"
  attr :confirm, :string, default: nil, doc: "the red button's words, such as Delete node"
  attr :ready, :boolean, default: true, doc: "whether the red button is enabled"
  slot :inner_block, required: true, doc: "the sentence"
  slot :lost, doc: "what is lost, at more length than the sentence"
  slot :field, doc: "the field asked to confirm"
  slot :action, doc: "a control of the page's own in place of the button"

  def danger_action(assigns) do
    assigns =
      assigns
      |> assign(:expanded, assigns.open && is_binary(assigns.button) && !assigns.disabled)
      |> update(:form, &(&1 || to_form(%{}, as: :confirm)))

    ~H"""
    <div id={@id} class={["q-danger-line", @expanded && "q-danger-line-open"]}>
      <div class="q-danger-what">
        <h3 id={"#{@id}-title"} class="q-danger-name">{@title}</h3>
        <p class="q-danger-sub">{render_slot(@inner_block)}</p>
      </div>
      <div :if={@button || @action != []} class="q-danger-act">
        <.button :if={@button && @disabled} id={"#{@id}-button"} type="button" disabled>
          {@button}
        </.button>
        <.button
          :if={@button && !@disabled}
          id={"#{@id}-button"}
          patch={if @expanded, do: @close_path, else: @open_path}
          aria-expanded={to_string(@expanded)}
          aria-controls={@expanded && "#{@id}-form"}
        >
          {@button}
        </.button>
        {render_slot(@action)}
      </div>
      <.form
        :if={@expanded}
        for={@form}
        id={"#{@id}-form"}
        class="q-danger-confirm"
        aria-labelledby={"#{@id}-title"}
        phx-change={@change}
        phx-submit={@submit}
        phx-mounted={
          if @field != [],
            do: JS.focus_first(to: "##{@id}-field"),
            else: JS.focus(to: "##{@id}-confirm")
        }
        novalidate
      >
        <div :if={@lost != []} class="q-danger-lost">{render_slot(@lost)}</div>
        <div :if={@field != []} id={"#{@id}-field"}>{render_slot(@field)}</div>
        <div class="q-danger-buttons">
          <.button
            id={"#{@id}-confirm"}
            variant="danger"
            type="submit"
            disabled={!@ready}
            loading_text={gettext("Deleting")}
          >
            {@confirm}
          </.button>
          <.button
            id={"#{@id}-cancel"}
            type="button"
            phx-click={JS.patch(@close_path) |> JS.focus(to: "##{@id}-button")}
          >
            {gettext("Cancel")}
          </.button>
        </div>
      </.form>
    </div>
    """
  end
end
