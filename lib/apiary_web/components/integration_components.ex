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
  # (`collections_table/1`): each one's name, its workspace or Unassigned, its open
  # items, for an adapter with items, and the day it was added.
  #
  # The install block says that the integration brings the person back to the
  # organisation's page, that the collections it reaches are listed there, and that the
  # organisation has one installation of it, then offers Install (`install_form/1`),
  # which posts to `ApiaryWeb.AdapterInstallController`. An adapter that cannot be
  # installed yet (`ready?/1`) has Install disabled, and a line that says so.
  #
  # The feature is hidden from the documentation, so the module is too.
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
        <.icon :if={!@sending} name="hero-arrow-top-right-on-square-micro" class="size-4" />{gettext(
          "Install"
        )}
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

  @doc false
  # The collections of a page, a row each: the name, the workspace it is assigned to or
  # Unassigned behind a warning mark, how many of its items are open (a faint dash for
  # none), and the day it was added. The open items and the day show from 600 px of the
  # table's width.
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
            <th scope="col">{@column}</th>
            <th scope="col">{gettext("Workspace")}</th>
            <th :if={@open} scope="col" class="q-num q-from-sm">{@open}</th>
            <th scope="col" class="q-from-sm">{gettext("Added")}</th>
          </tr>
        </thead>
        <tbody id={"#{@id}-rows"}>
          <tr :for={row <- @rows} id={"collection-#{row.public_id}"}>
            <td class="q-td-title">
              <span class="q-title-mono block truncate" title={row.name}>{row.name}</span>
            </td>
            <td>
              <span :if={row.workspace}>{row.workspace.name}</span>
              <span :if={!row.workspace} class="q-int-un">
                <.icon name="hero-exclamation-triangle-micro" class="size-3.5" /><span>{gettext(
                  "Unassigned"
                )}</span>
              </span>
            </td>
            <td :if={@open} class="q-num q-from-sm">
              <span :if={row.open_tickets == 0} class="q-faint">—</span>
              <span :if={row.open_tickets > 0}>{Format.number(row.open_tickets)}</span>
            </td>
            <td class="q-faint q-from-sm whitespace-nowrap">{added(row.added_at)}</td>
          </tr>
        </tbody>
      </table>
    </div>
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
