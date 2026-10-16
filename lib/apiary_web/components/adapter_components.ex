defmodule ApiaryWeb.AdapterComponents do
  # What the pages of Instance settings › Adapters share, for the instance's admins: the
  # paths of an adapter's page (`paths/1`), the browser title of each page
  # (`page_title/2`), the line under the adapter's name, who added it and when, and its
  # public id (`adapter_meta/1`), its tabs, Overview, Access key and Settings
  # (`adapter_tabs/1`), and its state in words (`adapter_seen/1`). An adapter's page is
  # two LiveViews, `ApiaryWeb.InstanceLive.Adapter` (Overview and Settings) and
  # `ApiaryWeb.AdapterLive.AccessKey` (Access key), so both draw the same header and tabs
  # from here.
  #
  # An adapter's state is "No key yet" while it holds no active key, with the dot of a
  # state that needs someone. Once it holds one, it is a node's: when it was last seen,
  # the latest use of one of its keys (`Apiary.Adapters.last_seen/2`), or "Never seen"
  # (`ApiaryWeb.NodeComponents.node_state/1`).
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false
  use ApiaryWeb, :html

  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode}
  alias Apiary.Nodes.Node
  alias ApiaryWeb.{NodeComponents, People, SettingsComponents}

  @doc false
  # The paths of the pages of Instance settings › Adapters: the list, and the adapter's
  # (by its public id) Overview, Access key tab, command page, Settings tab, Rename and
  # Remove.
  @spec paths(Node.t() | String.t()) :: %{atom => String.t()}
  def paths(%Node{public_id: public_id}), do: paths(public_id)

  def paths(public_id) when is_binary(public_id) do
    overview = ~p"/instance/adapters/#{public_id}"

    %{
      list: ~p"/instance/adapters",
      overview: overview,
      keys: overview <> "/keys",
      new_code: overview <> "/keys/new-code",
      settings: overview <> "/settings",
      rename: overview <> "/settings/rename",
      remove: overview <> "/settings/remove"
    }
  end

  @doc false
  # The path that asks to revoke `key`, by its key id, and the one that asks to cancel
  # `code`, by its row's id, never the code: each under the adapter's Access key tab.
  @spec act_path(%{atom => String.t()}, AccessKey.t() | EnrolmentCode.t()) :: String.t()
  def act_path(paths, %AccessKey{key_id: key_id}), do: "#{paths.keys}/#{key_id}/revoke"
  def act_path(paths, %EnrolmentCode{id: id}), do: "#{paths.keys}/codes/#{id}/revoke"

  @doc false
  # The browser title of a page of Instance settings › Adapters, the most specific first:
  # the page's words (`parts`: a tab and the adapter's name, a form's act, or none for the
  # list), the section, then the level (`ApiaryWeb.SettingsComponents.page_title/3`).
  @spec page_title(Apiary.Accounts.Scope.t(), [String.t()]) :: String.t()
  def page_title(scope, parts),
    do: SettingsComponents.page_title(scope, :instance, parts ++ [gettext("Adapters")])

  attr :adapter, Node, required: true, doc: "the adapter, with the account that added it"

  @doc false
  # The line under an adapter's name: who added it and when, then its public id.
  def adapter_meta(assigns) do
    ~H"""
    <span id="adapter-meta" class="inline-flex flex-wrap items-baseline gap-x-2 gap-y-1">
      <span id="adapter-added">
        {gettext("Added by %{person}, %{date}",
          person: People.email(@adapter.created_by) || People.former_member(),
          date: Format.date(@adapter.inserted_at)
        )}
      </span>
      <span class="text-faint" aria-hidden="true">·</span>
      <span id="adapter-public-id" class="q-mono">{@adapter.public_id}</span>
    </span>
    """
  end

  attr :adapter, Node, required: true
  attr :paths, :map, required: true, doc: "the adapter's `paths/1`"
  attr :current, :atom, required: true, values: [:overview, :keys, :settings]

  @doc false
  # An adapter's tabs: Overview, Access key and Settings, the last set apart. Overview and
  # Settings are one LiveView's and Access key another's: a tab of the same LiveView is a
  # patch, the other's a navigation.
  def adapter_tabs(assigns) do
    assigns = assign(assigns, :keys?, assigns.current == :keys)

    ~H"""
    <.page_tabs id="adapter-tabs" label={@adapter.name} current={@current} place="section">
      <:tab :if={@keys?} key={:overview} navigate={@paths.overview}>{gettext("Overview")}</:tab>
      <:tab :if={!@keys?} key={:overview} patch={@paths.overview}>{gettext("Overview")}</:tab>
      <:tab :if={@keys?} key={:keys} patch={@paths.keys}>{gettext("Access key")}</:tab>
      <:tab :if={!@keys?} key={:keys} navigate={@paths.keys}>{gettext("Access key")}</:tab>
      <:tab :if={@keys?} key={:settings} navigate={@paths.settings} settings>
        {gettext("Settings")}
      </:tab>
      <:tab :if={!@keys?} key={:settings} patch={@paths.settings} settings>
        {gettext("Settings")}
      </:tab>
    </.page_tabs>
    """
  end

  attr :id, :string, required: true
  attr :adapter, Node, required: true
  attr :connected, :boolean, required: true, doc: "whether the adapter holds an active key"

  attr :seen, DateTime,
    default: nil,
    doc: "when one of its keys was last used (`Apiary.Adapters.last_seen/2`), or nil"

  @doc false
  # An adapter's state in words: "No key yet", with the dot of a state that needs someone,
  # while it holds no active key; once it holds one, "Last seen" and when, ticking in the
  # browser, or "Never seen", as a node's.
  def adapter_seen(assigns) do
    ~H"""
    <NodeComponents.node_state
      :if={@connected}
      id={@id}
      node={@adapter}
      activity={%{running: [], last: nil, used: @seen}}
    />
    <.state_word :if={!@connected} id={@id} hot>{gettext("No key yet")}</.state_word>
    """
  end
end
