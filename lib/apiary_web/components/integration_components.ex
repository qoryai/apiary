defmodule ApiaryWeb.IntegrationComponents do
  # What the pages of Organisation settings › Integrations share: the paths of the
  # section's pages (`paths/2`), the browser title of each page (`page_title/2`) and the
  # integration's mark beside its name (`mark/1`), and the install block, what Install
  # does and Install (`install_block/1`). The section is two LiveViews,
  # `ApiaryWeb.AdapterLive.Index` (the list, and Add an integration) and
  # `ApiaryWeb.AdapterLive.Show` (an integration in the organisation).
  #
  # The mark is a neutral glyph, the same for every integration: never a vendor's logo.
  #
  # The collections an installed integration reaches are a table
  # (`collections_table/1`): each one's name, its workspace or Unassigned, for an adapter
  # with items its Backlog switch and its open items, and the day it was added; where they
  # may be assigned, a checkbox on each row and one over them all. The selection's menu
  # (`assign_menu/1`) lists the workspaces to assign it to, and a list menu
  # (`workspace_filter/1`) keeps the table to one workspace. A collection's name is the
  # title its adapter sent, shown as an external system's text is
  # (`ApiaryWeb.ExternalText`): in its row, its checkbox's name and its switch's.
  #
  # The install block says that the integration brings the person back to the
  # organisation's page, that the collections it reaches are listed there, and that the
  # organisation has one installation of it, then offers Install (`install_form/1`),
  # which posts to `ApiaryWeb.AdapterInstallController`. An adapter that cannot be
  # installed yet (`ready?/1`) has Install disabled, and a line that says so.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false
  use ApiaryWeb, :html

  alias Apiary.Accounts.Scope
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Organisation
  alias ApiaryWeb.SettingsComponents

  @doc false
  # The paths of the section's pages in the scope's organisation: the list, Add an
  # integration, and, given an adapter or its public id, the integration's page and the
  # path Install posts to.
  @spec paths(Scope.t(), Node.t() | String.t() | nil) :: %{atom => String.t()}
  def paths(%Scope{organisation: organisation}, adapter \\ nil) do
    list = ~p"/#{organisation}/settings/integrations"
    paths = %{list: list, new: list <> "/new"}

    case adapter do
      nil -> paths
      %Node{public_id: public_id} -> with_adapter(paths, public_id)
      public_id when is_binary(public_id) -> with_adapter(paths, public_id)
    end
  end

  defp with_adapter(%{list: list} = paths, public_id) do
    show = list <> "/" <> public_id
    Map.merge(paths, %{show: show, install: show <> "/install"})
  end

  @doc false
  # The browser title of a page of the section, the most specific first: the page's words
  # (`parts`: the integration's name, a form's act, or none for the list), the section,
  # then the level (`ApiaryWeb.SettingsComponents.page_title/3`).
  @spec page_title(Scope.t(), [String.t()]) :: String.t()
  def page_title(scope, parts),
    do: SettingsComponents.page_title(scope, :organisation, parts ++ [gettext("Integrations")])

  attr :class, :any, default: nil

  @doc false
  # The integration's mark, beside its name; decoration only.
  def mark(assigns) do
    ~H"""
    <.icon name="hero-puzzle-piece-micro" class={["size-4 flex-none text-muted", @class]} />
    """
  end

  attr :id, :string, required: true
  attr :adapter, Node, required: true
  attr :organisation, Organisation, required: true
  attr :collections, :string, required: true, doc: "the word for many of its collections"
  attr :named, :boolean, default: true, doc: "whether the block starts with the name"
  attr :action, :string, required: true, doc: "Install's path, `paths/2`'s `install`"
  attr :ready, :boolean, required: true, doc: "whether the adapter can be installed yet"
  attr :sending, :boolean, default: false, doc: "whether Install was pressed"
  attr :cancel, :string, default: nil, doc: "where Cancel leads; no Cancel without one"
  attr :class, :any, default: nil

  @doc false
  # What Install does for `adapter` in `organisation`, then Install (`install_form/1`)
  # and, given `cancel`, Cancel. While the adapter cannot be installed yet, Install is
  # disabled and a line says why; once pressed, a line says where the person is taken.
  def install_block(assigns) do
    ~H"""
    <div
      id={@id}
      class={["max-w-[720px] rounded-box border border-line bg-base-100 px-5 pt-[18px] pb-5", @class]}
    >
      <p :if={@named} id={"#{@id}-name"} class="mb-2.5 flex items-center gap-2.5 font-semibold">
        <.mark /><span class="truncate">{@adapter.name}</span>
      </p>
      <p class="max-w-[68ch] text-[13.5px]/[21px] text-muted">
        {gettext("%{integration} then brings you back here.", integration: @adapter.name)}
        {gettext("The %{collections} it reaches are listed on this page.",
          collections: @collections
        )}
        {gettext("%{organisation} can have one installation of %{integration}.",
          organisation: @organisation.name,
          integration: @adapter.name
        )}
      </p>
      <div class="mt-[18px] flex flex-wrap items-center gap-3">
        <.install_form
          id={"#{@id}-form"}
          adapter={@adapter}
          action={@action}
          ready={@ready}
          sending={@sending}
        />
        <.button :if={@cancel && !@sending} id={"#{@id}-cancel"} variant="ghost" navigate={@cancel}>
          {gettext("Cancel")}
        </.button>
        <span :if={@sending} id={"#{@id}-sending"} role="status" class="text-[13px] text-muted">
          {gettext("Taking you to %{integration}…", integration: @adapter.name)}
        </span>
        <span
          :if={!@ready && !@sending}
          id={"#{@id}-not-ready"}
          class="text-[13px] text-primary-soft-content"
        >
          {gettext(
            "%{integration} can't be installed yet: this instance's admins are still setting it up.",
            integration: @adapter.name
          )}
        </span>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :adapter, Node, required: true
  attr :action, :string, required: true, doc: "Install's path, `paths/2`'s `install`"
  attr :ready, :boolean, required: true
  attr :sending, :boolean, default: false
  attr :variant, :string, default: "primary", values: ~w(primary default)
  attr :size, :string, default: "sm", values: ~w(xs sm)
  attr :label, :string, default: nil, doc: "the button's words; Install by default"

  @doc false
  # Install for `adapter`: a form that the page submits to `action` once pressed, with
  # the session's CSRF token, a POST that sends the person on to the integration
  # (`ApiaryWeb.AdapterInstallController`). The press tells the page first (`"install"`,
  # with the adapter's public id as `integration`), which sets `sending` and so the
  # form's `phx-trigger-action`. Disabled while the adapter cannot be installed yet.
  def install_form(assigns) do
    ~H"""
    <.form
      for={to_form(%{}, as: :install)}
      id={@id}
      action={@action}
      method="post"
      novalidate
      phx-submit="install"
      phx-trigger-action={@sending}
      class="contents"
    >
      <input type="hidden" name="integration" value={@adapter.public_id} />
      <.button
        id={"#{@id}-install"}
        type="submit"
        variant={@variant}
        size={@size}
        disabled={!@ready}
        aria-disabled={@sending && "true"}
        class={@sending && "pointer-events-none"}
      >
        <span :if={@sending} class="loading loading-spinner loading-xs" aria-hidden="true" />
        <.icon :if={!@sending} name="hero-arrow-top-right-on-square-micro" class="size-4" />{@label ||
          gettext("Install")}
      </.button>
    </.form>
    """
  end

  @doc false
  # Whether `adapter` can be installed yet: it declared where to send the person and
  # holds an access key in use, as `Apiary.Adapters.connect/2` asks.
  @spec ready?(Node.t()) :: boolean
  def ready?(%Node{connect_url: url} = adapter),
    do: is_binary(url) and Apiary.AccessKeys.active_key?(adapter)

  attr :id, :string, required: true
  attr :label, :string, required: true, doc: "the table's accessible name, the heading's words"
  attr :rows, :list, required: true, doc: "`Apiary.Adapters.Collections.list_collections/3`'s"
  attr :column, :string, required: true, doc: "the first column's head: the word for one"

  attr :open, :any,
    default: nil,
    doc: "the open items column's head; no such column without one"

  attr :backlog, :any,
    default: nil,
    doc: "the word for the source's items, for the Backlog column; no such column without one"

  attr :may_set_backlog, :boolean, default: false, doc: "whether the switches may be turned"
  attr :picks, :boolean, default: false, doc: "whether the rows may be selected"
  attr :selected, :map, default: %{}, doc: "the selected rows' names, by their ids"
  attr :every, :string, default: nil, doc: "the name of the checkbox over every row shown"
  attr :none, :string, default: nil, doc: "the line in place of the rows when there are none"

  @doc false
  # The collections of a page, a row each: the name, the workspace it is assigned to or
  # Unassigned behind a warning mark, with `backlog` its Backlog switch, how many of its
  # items are open (a faint dash for none), and the day it was added. The switch is the
  # row's `backlog` (`Apiary.Adapters.Collections.list_collections/3`), named for the
  # collection and its items, turned by a press (`"set_backlog"`, the row's public id as
  # `collection`) where `may_set_backlog`, else disabled; an assigned row with none, a
  # collection with no items, has a faint dash named for that; any other row has nothing.
  # The Backlog column, the open items and the day show from 600 px of the table's width;
  # below it, the switch goes on the name's second line, beside the column's word, which
  # screen readers skip. With `picks`, a checkbox first on each row (`"select"`, the row's
  # public id as `collection`), and one in the head over every row shown
  # (`"select_all"`), checked while all of them are. With no rows, `none` in their place.
  def collections_table(assigns) do
    ~H"""
    <div
      id={@id}
      class="q-tbl q-int-pick overflow-x-auto rounded-box border border-line bg-base-100 shadow-xs"
      tabindex="0"
      role="region"
      aria-label={@label}
    >
      <table class="table">
        <thead>
          <tr>
            <th :if={@picks} scope="col" class="q-int-cb">
              <input
                id={"#{@id}-every"}
                type="checkbox"
                class="checkbox checkbox-xs"
                checked={@rows != [] && Enum.all?(@rows, &Map.has_key?(@selected, &1.id))}
                disabled={@rows == []}
                aria-label={@every}
                phx-click="select_all"
              />
            </th>
            <th scope="col">{@column}</th>
            <th scope="col">{gettext("Workspace")}</th>
            <th :if={@backlog} scope="col" class="q-from-sm">{gettext("Backlog")}</th>
            <th :if={@open} scope="col" class="q-num q-from-sm">{@open}</th>
            <th scope="col" class="q-from-sm">{gettext("Added")}</th>
          </tr>
        </thead>
        <tbody id={"#{@id}-rows"}>
          <tr
            :for={row <- @rows}
            id={"collection-#{row.public_id}"}
            aria-selected={@picks && to_string(Map.has_key?(@selected, row.id))}
          >
            <td :if={@picks} class="q-int-cb">
              <input
                id={"collection-#{row.public_id}-pick"}
                type="checkbox"
                class="checkbox checkbox-xs"
                checked={Map.has_key?(@selected, row.id)}
                aria-label={gettext("Select %{name}", name: Apiary.ExternalText.line(row.name))}
                phx-click="select"
                phx-value-collection={row.public_id}
              />
            </td>
            <td class="q-td-title">
              <span
                class="q-title-mono block truncate"
                title={Apiary.ExternalText.line(row.name)}
              ><.external_text text={row.name} /></span>
              <span :if={@backlog && row.backlog} class="q-to-sm mt-1 flex items-center gap-2">
                <.backlog_switch
                  id={"collection-#{row.public_id}-backlog-line"}
                  row={row}
                  items={@backlog}
                  may={@may_set_backlog}
                />
                <span aria-hidden="true" class="text-xs text-muted">{gettext("Backlog")}</span>
              </span>
            </td>
            <td>
              <span :if={row.workspace}>{row.workspace.name}</span>
              <span :if={!row.workspace} class="q-int-un">
                <.icon name="hero-exclamation-triangle-micro" class="size-3.5" /><span>{gettext(
                  "Unassigned"
                )}</span>
              </span>
            </td>
            <td :if={@backlog} class="q-from-sm">
              <.backlog_switch
                :if={row.backlog}
                id={"collection-#{row.public_id}-backlog"}
                row={row}
                items={@backlog}
                may={@may_set_backlog}
              />
              <span
                :if={!row.backlog && row.workspace}
                id={"collection-#{row.public_id}-backlog-none"}
                class="q-faint"
                title={gettext("No %{items} to take in", items: @backlog)}
              >
                <span aria-hidden="true">—</span><span class="sr-only">{gettext(
                  "No %{items} to take in",
                  items: @backlog
                )}</span>
              </span>
            </td>
            <td :if={@open} class="q-num q-from-sm">
              <span :if={row.open_tickets == 0} class="q-faint">—</span>
              <span :if={row.open_tickets > 0}>{Format.number(row.open_tickets)}</span>
            </td>
            <td class="q-faint q-from-sm whitespace-nowrap">{added(row.added_at)}</td>
          </tr>
          <tr :if={@rows == [] && @none} id={"#{@id}-none"}>
            <td colspan="6" class="text-muted">{@none}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :row, :map, required: true, doc: "a row of the table, with its `backlog`"
  attr :items, :string, required: true, doc: "the word for the source's items"
  attr :may, :boolean, required: true, doc: "whether it may be turned"

  # A row's Backlog switch, the kit's track without a visible label: its name, for screen
  # readers and as its title, says whose items it takes into the Backlog.
  defp backlog_switch(assigns) do
    assigns =
      assign(
        assigns,
        :label,
        backlog_label(assigns.items, Apiary.ExternalText.line(assigns.row.name))
      )

    ~H"""
    <button
      id={@id}
      type="button"
      role="switch"
      class="q-toggle"
      aria-checked={to_string(@row.backlog.on)}
      aria-label={@label}
      title={@label}
      disabled={!@may}
      phx-click={@may && "set_backlog"}
      phx-value-collection={@row.public_id}
    ></button>
    """
  end

  defp backlog_label(items, name),
    do: gettext("Take the %{items} of %{name} into the Backlog", items: items, name: name)

  attr :id, :string, required: true
  attr :heading, :string, required: true, doc: "what is assigned: the menu's heading and name"

  attr :workspaces, :list,
    required: true,
    doc: "`{workspace, how many it holds, in words}` each"

  attr :foot, :any, default: nil, doc: "what moves with them; no line without one"
  attr :find, :boolean, default: false, doc: "whether a field finds a workspace by name"
  attr :query, :string, default: nil, doc: "what the field holds"

  @doc false
  # Assign to workspace, the selection's one action: a menu (the `Menu` hook) under its
  # heading, a workspace per item with how many it holds on the right (`"assign"`, the
  # workspace's id as `workspace`), then a rule and a faint line on what moves with them.
  # With `find`, a field under the heading narrows the workspaces (`"find_workspace"`,
  # its text as `q`); when none is left, a line says so.
  def assign_menu(assigns) do
    ~H"""
    <div
      id={@id}
      class="q-listmenu dropdown dropdown-end"
      phx-hook="Menu"
      data-float
      phx-mounted={JS.ignore_attributes(["class"])}
    >
      <button
        id={"#{@id}-button"}
        type="button"
        class="btn btn-primary btn-sm"
        aria-haspopup="menu"
        aria-expanded="false"
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
      >
        {gettext("Assign to workspace")}<.icon name="hero-chevron-down-micro" class="size-4" />
      </button>
      <ul
        class="q-rowmenu-list q-int-assign menu menu-sm dropdown-content"
        role="menu"
        aria-label={@heading}
        popover="manual"
        phx-mounted={JS.ignore_attributes(["style"])}
      >
        <.menu_heading title={@heading} />
        <li :if={@find} role="presentation">
          <form
            id={"#{@id}-find"}
            phx-change="find_workspace"
            phx-submit="find_workspace"
            novalidate
          >
            <input
              id={"#{@id}-find-input"}
              type="search"
              name="q"
              value={@query}
              class="input input-sm q-filter-search"
              placeholder={gettext("Find a workspace")}
              aria-label={gettext("Find a workspace")}
              phx-debounce="200"
              autocomplete="off"
            />
          </form>
        </li>
        <li
          :if={@workspaces == []}
          id={"#{@id}-none"}
          role="presentation"
          class="px-2 py-1.5 text-xs text-faint"
        >
          {gettext("No workspace matches.")}
        </li>
        <.menu_item
          :for={{workspace, count} <- @workspaces}
          id={"#{@id}-#{workspace.id}"}
          phx-click="assign"
          phx-value-workspace={workspace.id}
        >
          {workspace.name} <span>{count}</span>
        </.menu_item>
        <.menu_divider :if={@foot} />
        <li :if={@foot} role="presentation" class="q-int-assign-foot">{@foot}</li>
      </ul>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :options, :list, required: true, doc: "`{name, path, chosen}` per workspace"

  @doc false
  # Workspace, a list's menu (`filter_menu/1`, named Workspace) that keeps the table to
  # the collections of one workspace: each a choice of one, which leads to the list with
  # it, or, chosen already, without it. The button counts the filter while one is on.
  def workspace_filter(assigns) do
    ~H"""
    <.filter_menu
      id={@id}
      label={gettext("Workspace")}
      count={Enum.count(@options, &elem(&1, 2))}
    >
      <.menu_item
        :for={{{name, path, chosen}, n} <- Enum.with_index(@options)}
        id={"#{@id}-#{n}"}
        patch={path}
        checked={chosen}
      >
        {name}
      </.menu_item>
    </.filter_menu>
    """
  end

  # The day a collection was added: today, or the date, its year left out in the current
  # one.
  defp added(at) do
    if Format.days_back(at, DateTime.utc_now()) == 0,
      do: gettext("Today"),
      else: Format.day(at)
  end
end
