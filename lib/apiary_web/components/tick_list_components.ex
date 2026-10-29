defmodule ApiaryWeb.TickListComponents do
  # The tick lists of a workspace, Work sources and Destinations, which no page shows:
  # `load/4` reads a list and who may act on it, `tick_list/1` renders it, `rows/1` one
  # adapter's rows and `notes/1` the lines under the list, and `put_tick_flash/3` puts
  # the flash of a tick (`Apiary.WorkspaceSetup.tick/5`) that changed nothing.
  #
  # The list's collections are grouped by adapter (`Apiary.WorkspaceSetup.collections/3`),
  # each with a checkbox, ticked as `Apiary.WorkspaceSetup.ticked?/3` counts it. For a
  # person whom `collection.assign` does not allow, the checkboxes are disabled, with the
  # line of who may. A collection in another workspace shows that workspace's name and has
  # no checkbox. In Destinations, a collection whose tickets come in to the workspace shows
  # "tickets come in", with a line under the list that unticking it stops them. With no
  # collection, `tick_list/1` shows that the organisation has nothing connected for it,
  # with a link to the set-up's step that connects one for a person whom `adapter.connect`
  # allows, and the line of who may connect for anyone else.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  use ApiaryWeb, :html

  alias Apiary.{Access, Adapters, WorkspaceSetup}
  alias ApiaryWeb.{IntegrationComponents, SetUpComponents, SourceComponents}

  @doc false
  # load/4 is the assigns of the tick list `list` for the scope's workspace of the type
  # `domain`: `groups`, the rows (`Apiary.WorkspaceSetup.collections/3`); `may`, whether
  # the person may tick, with `who_may`; `may_connect`, whether they may connect, with
  # `who_connects`; and `connect_path`, the step that connects one, nil for none.
  @spec load(Apiary.Accounts.Scope.t(), module, :sources | :destinations, String.t() | nil) ::
          keyword
  def load(scope, domain, list, connect_path) do
    groups = WorkspaceSetup.collections(scope, domain, list)
    nouns = Enum.map(groups, fn {adapter, _rows} -> Adapters.collection_noun(adapter) end)

    [
      groups: groups,
      may: Access.can?(scope, :"collection.assign", scope.organisation),
      may_connect: Access.can?(scope, :"adapter.connect", scope.organisation),
      who_may:
        ApiaryWeb.Access.who_may(
          scope,
          :"collection.assign",
          gettext(
            "Only owners and admins of %{organisation} assign %{collections} to workspaces.",
            organisation: scope.organisation.name,
            collections: SourceComponents.collections(nouns, :and)
          )
        ),
      who_connects:
        ApiaryWeb.Access.who_may(
          scope,
          :"adapter.connect",
          gettext("Only owners and admins change the integrations of the organisation.")
        ),
      connect_path: connect_path
    ]
  end

  @doc false
  # put_tick_flash/3 is `socket` with the flash for a tick's answer (`result`): none where
  # the tick changed a collection, or where the list read for the tick did not have the
  # collection (`:unlisted`) or had it in another workspace (`:elsewhere`), which the list
  # shows once read again; `who_may` where it was refused; else, for any other refusal,
  # such as a collection that ended after the read, that nothing changed.
  @spec put_tick_flash(Phoenix.LiveView.Socket.t(), :ok | {:error, term}, String.t()) ::
          Phoenix.LiveView.Socket.t()
  def put_tick_flash(socket, :ok, _who_may), do: socket

  def put_tick_flash(socket, {:error, reason}, _who_may) when reason in [:unlisted, :elsewhere],
    do: socket

  def put_tick_flash(socket, {:error, :forbidden}, who_may),
    do: Phoenix.LiveView.put_flash(socket, :error, who_may)

  def put_tick_flash(socket, {:error, _reason}, _who_may),
    do: Phoenix.LiveView.put_flash(socket, :error, gettext("Nothing was changed. Try again."))

  attr :id, :string, required: true, doc: "the prefix of the list's ids"
  attr :list, :atom, required: true, values: [:sources, :destinations]
  attr :groups, :list, required: true, doc: "the rows, as `load/4` reads them"
  attr :workspace, :any, required: true
  attr :organisation, :any, required: true
  attr :may, :boolean, required: true
  attr :who_may, :string, required: true
  attr :may_connect, :boolean, required: true
  attr :who_connects, :string, required: true
  attr :connect_path, :string, default: nil

  attr :connect_by, :string,
    default: "patch",
    values: ~w(patch navigate),
    doc: "how the link to the step that connects one leads: `navigate` from another page"

  @doc false
  # tick_list/1 is a tick list, each checkbox sending `tick` with the collection's id.
  def tick_list(assigns) do
    ~H"""
    <div :if={@groups != []} id={"#{@id}-ticks"} class="grid gap-3">
      <section
        :for={{adapter, rows} <- @groups}
        id={"#{@id}-ticks-#{adapter.public_id}"}
        class="grid gap-1 rounded-box border border-line bg-base-100 px-4 py-3"
      >
        <h2 class="flex items-center gap-2 font-medium">
          <IntegrationComponents.mark class="size-5" />{Adapters.title(adapter)}
        </h2>
        <.rows id={@id} list={@list} adapter={adapter} rows={rows} workspace={@workspace} may={@may} />
      </section>
    </div>

    <.notes
      id={@id}
      list={@list}
      groups={@groups}
      workspace={@workspace}
      may={@may}
      who_may={@who_may}
    />

    <div
      :if={@groups == []}
      id={"#{@id}-none"}
      class="grid gap-1 rounded-box bg-base-200 px-4 py-3 text-[13.5px]/5 text-muted"
    >
      <p :if={@list == :sources}>
        {gettext("%{organisation} has no work source connected yet.",
          organisation: @organisation.name
        )}
      </p>
      <p :if={@list == :destinations}>
        {gettext("%{organisation} has no work destination connected yet.",
          organisation: @organisation.name
        )}
      </p>
      <p :if={@may_connect and @connect_path}>
        <.link
          id={"#{@id}-none-connect"}
          patch={if @connect_by == "patch", do: @connect_path}
          navigate={if @connect_by == "navigate", do: @connect_path}
          class="q-link"
        >
          {SetUpComponents.step_label(@list)}
        </.link>
      </p>
      <p :if={!@may_connect} id={"#{@id}-none-who"}>{@who_connects}</p>
    </div>
    """
  end

  attr :id, :string, required: true, doc: "the prefix of the rows' ids"
  attr :list, :atom, required: true, values: [:sources, :destinations]
  attr :adapter, :any, required: true
  attr :rows, :list, required: true, doc: "the adapter's rows, as `load/4` reads them"
  attr :workspace, :any, required: true
  attr :may, :boolean, required: true

  @doc false
  # rows/1 is the rows of one adapter of a tick list, each checkbox sending `tick` with the
  # collection's id. A collection in another workspace shows that workspace's name and has
  # no checkbox.
  def rows(assigns) do
    ~H"""
    <ul :if={@rows != []} class="grid gap-1 pl-7">
      <li
        :for={row <- @rows}
        id={"#{@id}-tick-#{row.collection.public_id}"}
        class="flex items-center gap-2 text-[13.5px]/5"
      >
        <label
          :if={is_nil(row.workspace) or row.workspace.id == @workspace.id}
          class="flex min-w-0 flex-1 items-center gap-2"
        >
          <input
            type="checkbox"
            class="checkbox checkbox-sm"
            checked={WorkspaceSetup.ticked?(@list, row, @workspace)}
            disabled={!@may}
            phx-click="tick"
            phx-value-id={row.collection.id}
          />
          <span class="truncate">{row.collection.title}</span>
        </label>
        <span
          :if={row.workspace && row.workspace.id != @workspace.id}
          class="flex min-w-0 flex-1 items-center gap-2 text-muted"
        >
          <span class="inline-block size-4" aria-hidden="true"></span>
          <span class="truncate">{row.collection.title}</span>
        </span>
        <span
          :if={row.workspace && row.workspace.id != @workspace.id}
          id={"#{@id}-tick-#{row.collection.public_id}-elsewhere"}
          class="text-[12.5px]/4 text-muted"
        >
          {gettext("In %{workspace} (cannot be ticked)", workspace: row.workspace.name)}
        </span>
        <span
          :if={@list == :destinations and tickets_in?(row, @adapter, @workspace)}
          id={"#{@id}-tick-#{row.collection.public_id}-tickets"}
          class="text-[12.5px]/4 text-muted"
        >
          {gettext("tickets come in")}
        </span>
      </li>
    </ul>
    """
  end

  attr :id, :string, required: true, doc: "the prefix of the lines' ids"
  attr :list, :atom, required: true, values: [:sources, :destinations]
  attr :groups, :list, required: true, doc: "the rows, as `load/4` reads them"
  attr :workspace, :any, required: true
  attr :may, :boolean, required: true
  attr :who_may, :string, required: true

  @doc false
  # notes/1 is the lines under a tick list: in Destinations, that unticking a collection
  # whose tickets come in stops them; for a person whom `collection.assign` does not allow,
  # who may.
  def notes(assigns) do
    assigns =
      assign(assigns,
        tickets?:
          assigns.list == :destinations and
            Enum.any?(assigns.groups, fn {adapter, rows} ->
              Enum.any?(rows, &tickets_in?(&1, adapter, assigns.workspace))
            end)
      )

    ~H"""
    <p :if={@tickets?} id={"#{@id}-untick"} class="text-[13px]/5 text-muted">
      {gettext("Unticking also stops its tickets coming in.")}
    </p>

    <p
      :if={!@may and @groups != []}
      id={"#{@id}-who-may"}
      class="rounded-box bg-base-200 px-4 py-3 text-[13.5px]/5 text-muted"
    >
      {@who_may}
    </p>
    """
  end

  # Whether `row`'s tickets come in to `workspace`: it is the workspace's, with its
  # Backlog on, and it and its adapter have items.
  defp tickets_in?(%{collection: c}, adapter, workspace),
    do: c.workspace_id == workspace.id and c.backlog and c.items and Adapters.items?(adapter)
end
