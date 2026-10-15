defmodule ApiaryWeb.AdapterComponents do
  # The pieces the pages of an organisation's integrations share: Organisation settings
  # › Integrations (`ApiaryWeb.AdapterLive.Index`), an integration's page and its tabs
  # (`ApiaryWeb.AdapterLive.Show`, `ApiaryWeb.AdapterLive.AccessKey`). In code an
  # integration is an adapter, a node of kind `:adapter` at its organisation
  # (`Apiary.Adapters`); on the page it is an integration.
  #
  # What the pages say of an integration is read from one summary each, `%{adapter, key,
  # connected?, collections, unassigned, last_change_at}`: whether it holds an active
  # access key, whether it is connected, how many repositories or projects it has
  # connected, how many of those have no workspace, and when it last sent a change. Its
  # state follows from it: no access key yet, not connected, or connected.
  #
  # The paths are written out here, not with `~p`, until the router holds them.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false
  use ApiaryWeb, :html

  alias Apiary.{AccessKeys, Adapters}
  alias Apiary.Accounts.Scope
  alias Apiary.Nodes.Node

  @typedoc false
  @type summary :: %{
          adapter: Node.t(),
          key: :active | :none,
          connected?: boolean,
          collections: non_neg_integer,
          unassigned: non_neg_integer,
          last_change_at: DateTime.t() | nil
        }

  ## Reads

  @doc false
  # The scope's organisation's integrations, by name, each with its summary.
  @spec summaries(Scope.t()) :: [summary]
  def summaries(%Scope{} = scope), do: Enum.map(Adapters.list_adapters(scope), &summary/1)

  @doc false
  # An integration's summary. Whether it holds an active key is its access keys'; what it
  # has connected comes with its repositories and projects, which it has none of yet, so
  # it reads as not connected.
  @spec summary(Node.t()) :: summary
  def summary(%Node{kind: :adapter} = adapter) do
    %{
      adapter: adapter,
      key: if(AccessKeys.active_key?(adapter), do: :active, else: :none),
      connected?: false,
      collections: 0,
      unassigned: 0,
      last_change_at: nil
    }
  end

  @doc false
  # An integration's state: no access key yet, not connected, or connected.
  @spec state(summary) :: :no_key | :not_connected | :connected
  def state(%{key: :none}), do: :no_key
  def state(%{connected?: false}), do: :not_connected
  def state(%{connected?: true}), do: :connected

  ## Paths

  @doc false
  # Organisation settings › Integrations.
  @spec index_path(Scope.t()) :: String.t()
  def index_path(%Scope{organisation: organisation}),
    do: "/#{organisation.slug}/settings/integrations"

  @doc false
  # Add an integration.
  @spec new_path(Scope.t()) :: String.t()
  def new_path(scope), do: index_path(scope) <> "/new"

  @doc false
  # An integration's page and each of its tabs and acts, by its public id.
  @spec paths(Scope.t(), Node.t() | String.t()) :: %{atom => String.t()}
  def paths(scope, %Node{public_id: public_id}), do: paths(scope, public_id)

  def paths(scope, public_id) when is_binary(public_id) do
    base = index_path(scope) <> "/" <> public_id

    %{
      collections: base,
      pools: base <> "/node-pools",
      access_key: base <> "/access-key",
      new_code: base <> "/access-key/new-code",
      settings: base <> "/settings",
      rename: base <> "/settings/rename",
      remove: base <> "/settings/remove"
    }
  end

  ## Hidden

  @doc false
  # The pages' gate of their acts, `acts`, the names of the events that change something:
  # an act asked once the integrations are hidden from the reader changes nothing, and the
  # page leaves (`ApiaryWeb.UserAuth.reload_scope/1`), as a node's page does
  # (`ApiaryWeb.NodeComponents.leave_when_hidden/2`).
  @spec leave_when_hidden(Phoenix.LiveView.Socket.t(), [String.t()]) ::
          Phoenix.LiveView.Socket.t()
  def leave_when_hidden(socket, acts) do
    Phoenix.LiveView.attach_hook(socket, :integrations_hidden, :handle_event, fn
      event, _params, socket ->
        if event in acts and hidden_now?(socket.assigns.current_scope),
          do: {:halt, ApiaryWeb.UserAuth.reload_scope(socket)},
          else: {:cont, socket}
    end)
  end

  # Whether the integrations are hidden from the person of `scope` as the database has it
  # now (`Apiary.Access.reload/2`).
  defp hidden_now?(scope),
    do: not Apiary.Features.visible?(Apiary.Access.reload(scope), :factory)

  ## Words

  @doc false
  # Whom the integrations' pages name as the ones who change them, the edition's words
  # where it has any.
  @spec only_admins(Scope.t(), atom) :: String.t()
  def only_admins(scope, action \\ :"adapter.edit"),
    do:
      ApiaryWeb.Access.who_may(
        scope,
        action,
        gettext("Only organisation owners and admins change integrations.")
      )

  @doc false
  # The browser's title of a page of an integration: its words, then the section's, then
  # the level's (`ApiaryWeb.SettingsComponents.page_title/3`).
  @spec page_title(Scope.t(), [String.t()]) :: String.t()
  def page_title(scope, parts),
    do: ApiaryWeb.SettingsComponents.page_title(scope, :organisation, parts ++ [section_title()])

  @doc false
  # The section's title: the list's heading and its table's name.
  @spec section_title() :: String.t()
  def section_title, do: gettext("Integrations")

  @doc false
  # The changeset of an integration's name with its refusals in the page's words: a name
  # left empty, and one another integration of the organisation has. Any other refusal is
  # the core's.
  @spec name_errors(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def name_errors(%Ecto.Changeset{errors: errors} = changeset) do
    name = Ecto.Changeset.get_field(changeset, :name)

    errors =
      Enum.map(errors, fn
        {:name, {_message, opts}} = error ->
          cond do
            opts[:validation] == :required ->
              {:name, {dgettext_noop("errors", "Give it a name."), []}}

            opts[:constraint] == :unique ->
              {:name,
               {dgettext_noop(
                  "errors",
                  "This organisation already has an integration named %{name}."
                ), [name: name]}}

            true ->
              error
          end

        error ->
          error
      end)

    %{changeset | errors: errors}
  end

  ## Components

  attr :id, :string, required: true
  attr :summary, :map, required: true

  @doc false
  # An integration's state as a dot and its word.
  def state_mark(assigns) do
    assigns = assign(assigns, :state, state(assigns.summary))

    ~H"""
    <span
      id={@id}
      class={[
        "q-sdot",
        @state == :connected && "q-sdot-completed",
        @state != :connected && "q-sdot-pending"
      ]}
    >
      <i aria-hidden="true"></i><span>{state_words(@state)}</span>
    </span>
    """
  end

  defp state_words(:connected), do: gettext("Connected")
  defp state_words(:not_connected), do: gettext("Not connected")
  defp state_words(:no_key), do: gettext("No access key yet")

  attr :id, :string, required: true
  attr :count, :integer, required: true
  attr :class, :any, default: nil

  @doc false
  # How many of an integration's connected repositories or projects have no workspace, in
  # the warning's colour, its icon beside it.
  def without_workspace(assigns) do
    ~H"""
    <span
      id={@id}
      class={["inline-flex items-center gap-1.5 text-primary-soft-content", @class]}
    >
      <.icon name="hero-exclamation-triangle-micro" class="size-3.5 flex-none" />
      <span>
        {ngettext("%{number} without a workspace", "%{number} without a workspace", @count,
          number: Format.number(@count)
        )}
      </span>
    </span>
    """
  end

  attr :summary, :map, required: true

  @doc false
  # The integration's page's state line: connected, with when it last sent a change and
  # how many of its repositories or projects have no workspace; not connected; or no
  # access key yet.
  def state_line(assigns) do
    assigns = assign(assigns, :state, state(assigns.summary))

    ~H"""
    <span id="adapter-state" class="inline-flex flex-wrap items-center gap-x-1.5 gap-y-1">
      <span class={[
        "q-sdot",
        @state == :connected && "q-sdot-completed",
        @state != :connected && "q-sdot-pending"
      ]}>
        <i aria-hidden="true"></i>
        <span :if={@state == :connected and @summary.last_change_at}>
          <.rich text={rich_gettext("Connected · last update %{ago}", ago: {:part, :ago})}>
            <:part name={:ago}><.time_ago at={@summary.last_change_at} /></:part>
          </.rich>
        </span>
        <span :if={@state != :connected or is_nil(@summary.last_change_at)}>
          {state_words(@state)}
        </span>
      </span>
      <span
        :if={@state == :connected and @summary.unassigned > 0}
        class="text-faint"
        aria-hidden="true"
      >
        ·
      </span>
      <.without_workspace
        :if={@state == :connected and @summary.unassigned > 0}
        id="adapter-state-unassigned"
        count={@summary.unassigned}
      />
    </span>
    """
  end

  attr :scope, :any, required: true
  attr :adapter, Node, required: true
  attr :current, :atom, required: true, values: [:collections, :pools, :access_key, :settings]

  attr :live, :atom,
    required: true,
    values: [:show, :access_key],
    doc: "the LiveView the tabs are drawn in: a tab of the same one is a patch"

  @doc false
  # An integration's tabs: its repositories and projects, the node pools it serves, its
  # access key, and its settings, last and set apart. The tabs of
  # `ApiaryWeb.AdapterLive.Show` are patches of one another; Access key is another
  # LiveView's.
  def tabs(assigns) do
    assigns = assign(assigns, :paths, paths(assigns.scope, assigns.adapter))

    ~H"""
    <.page_tabs id="adapter-tabs" label={@adapter.name} current={@current}>
      <:tab
        key={:collections}
        patch={if(@live == :show, do: @paths.collections)}
        navigate={if(@live != :show, do: @paths.collections)}
      >
        {gettext("Repositories and projects")}
      </:tab>
      <:tab
        key={:pools}
        patch={if(@live == :show, do: @paths.pools)}
        navigate={if(@live != :show, do: @paths.pools)}
      >
        {gettext("Node pools")}
      </:tab>
      <:tab
        key={:access_key}
        patch={if(@live == :access_key, do: @paths.access_key)}
        navigate={if(@live != :access_key, do: @paths.access_key)}
      >
        {gettext("Access key")}
      </:tab>
      <:tab
        key={:settings}
        patch={if(@live == :show, do: @paths.settings)}
        navigate={if(@live != :show, do: @paths.settings)}
        settings
      >
        {gettext("Settings")}
      </:tab>
    </.page_tabs>
    """
  end
end
