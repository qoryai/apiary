defmodule ApiaryWeb.AdapterComponents do
  # What the pages of Instance settings › Adapters share, for the instance's admins: the
  # paths of an adapter's page (`paths/1`), the browser title of each page
  # (`page_title/2`), the line under the adapter's name, who added it and when, and its
  # public id (`adapter_meta/1`), its tabs, Overview, Access key and Settings
  # (`adapter_tabs/1`), and its state in words (`adapter_seen/1`), and how often it pulls
  # (`pulls_every/1`, `interval_label/1`, `interval_words/1`). An adapter's page is two
  # LiveViews, `ApiaryWeb.InstanceLive.Adapter` (Overview and Settings) and
  # `ApiaryWeb.AdapterLive.AccessKey` (Access key), so both draw the same header and tabs
  # from here.
  #
  # An adapter installed with Qory Apiary (`Apiary.Adapters.Installed`) says so in place of
  # who added it and when.
  #
  # Set up (`setup_form/1`) starts an adapter's set-up at the system it reads from, a POST
  # to `ApiaryWeb.AdapterSetupController`; a page shows it only while the adapter
  # declares where to be set up (`setup_url`), holds a key in use, and, when it is
  # installed with Qory Apiary, is still listed (`settable?/3`).
  #
  # An adapter's state is "No key yet" while it holds no active key, with the dot of a
  # state that needs someone. Once it holds one, it is a node's: when it was last seen,
  # the latest use of one of its keys (`Apiary.Adapters.last_seen/2`), or "Never seen"
  # (`ApiaryWeb.NodeComponents.node_state/1`).
  #
  # An interval is said from its seconds by one rule: in hours when it is whole hours
  # ("Every hour", "Every 2 hours"), else in minutes when it is whole minutes ("Every
  # minute", "Every 15 minutes"), else in seconds; and the same in lower case, to stand
  # inside a sentence.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false
  use ApiaryWeb, :html

  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode}
  alias Apiary.Nodes.Node
  alias ApiaryWeb.{NodeComponents, People, SettingsComponents}

  @doc false
  # The paths of the pages of Instance settings › Adapters: the list, and the adapter's
  # (by its public id) Overview, Access key tab, command page, Settings tab, Rename and
  # Remove; and the path Set up posts to (`setup`).
  @spec paths(Node.t() | String.t()) :: %{atom => String.t()}
  def paths(%Node{public_id: public_id}), do: paths(public_id)

  def paths(public_id) when is_binary(public_id) do
    overview = ~p"/instance/adapters/#{public_id}"

    %{
      list: ~p"/instance/adapters",
      overview: overview,
      setup: overview <> "/setup",
      keys: overview <> "/keys",
      new_code: overview <> "/keys/new-code",
      settings: overview <> "/settings",
      rename: overview <> "/settings/rename",
      remove: overview <> "/settings/remove"
    }
  end

  @doc false
  # Whether Set up shows for `adapter`: while it declares where to be set up
  # (`setup_url`, which it declares only while it is not set up) and holds a key in use
  # (`connected`, `Apiary.AccessKeys.active_key?/1`), as `Apiary.Adapters.setup/2` asks;
  # and, for an adapter installed with Qory Apiary, while its name is still listed
  # (`listed`, `Apiary.Adapters.listed?/1`): once it is off the list, the adapter is
  # turned off there, and Set up would take the instance admin to no adapter.
  @spec settable?(Node.t(), boolean, boolean) :: boolean
  def settable?(%Node{setup_url: url, installed_as: installed_as}, connected, listed),
    do: is_binary(url) and connected == true and (is_nil(installed_as) or listed == true)

  attr :id, :string, required: true
  attr :adapter, Node, required: true
  attr :back, :string, default: nil, doc: "`list` on the list, so a refusal comes back there"
  attr :variant, :string, default: "default", values: ~w(default primary)
  attr :size, :string, default: "xs", values: ~w(xs sm md)
  attr :target, :string, default: nil, doc: "`_blank` to open the adapter in a new tab"

  @doc false
  # Set up for `adapter`: a form that posts to its set-up's path, `paths/1`'s `setup`,
  # with the session's CSRF token, and the instance admin is sent on to the adapter
  # (`ApiaryWeb.AdapterSetupController`), in a new tab with `target` `_blank`. Its button
  # is core's default one, or, with `variant` "primary", core's primary one.
  def setup_form(assigns) do
    ~H"""
    <.form
      for={to_form(%{}, as: :setup)}
      id={@id}
      action={paths(@adapter).setup}
      method="post"
      target={@target}
      novalidate
      class="contents"
    >
      <input :if={@back} type="hidden" name="back" value={@back} />
      <.button id={"#{@id}-button"} type="submit" variant={@variant} size={@size}>
        <.icon name="hero-arrow-top-right-on-square-micro" class="size-4" />{gettext("Set up")}
      </.button>
    </.form>
    """
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
  attr :reader, :string, default: nil, doc: "the reader's address"

  @doc false
  # The line under an adapter's name: who added it and when, or, for an adapter installed
  # with Qory Apiary, that it was; then its public id.
  def adapter_meta(assigns) do
    ~H"""
    <span id="adapter-meta" class="inline-flex flex-wrap items-baseline gap-x-2 gap-y-1">
      <span :if={@adapter.installed_as} id="adapter-added">
        {gettext("Installed with Qory Apiary")}
      </span>
      <span :if={!@adapter.installed_as} id="adapter-added">
        <.rich text={
          rich_gettext("Added by %{person}, %{date}",
            person: letter(People.email(@adapter.created_by) || People.former_member(), @reader),
            date: Format.date(@adapter.inserted_at)
          )
        } />
      </span>
      <span class="text-faint" aria-hidden="true">·</span>
      <span id="adapter-public-id" class="q-mono">{@adapter.public_id}</span>
    </span>
    """
  end

  # Who added the adapter, in a sentence: their first letter, with the address as its
  # tooltip (`ApiaryWeb.CoreComponents.avatar/1`).
  defp letter(email, reader) do
    assigns = %{email: email, reader: reader}
    ~H|<.avatar email={@email} reader={@reader} size="xs" />|
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

  @doc false
  # How often the adapter pulls, in seconds, from what it declared and the interval an
  # instance admin chose (`Apiary.Adapters.sync_settings/2`): the chosen one, else its
  # default, raised to its minimum, as the adapter raises it; nil before it declares.
  @spec pulls_every(map) :: pos_integer | nil
  def pulls_every(%{default: default} = sync) when is_integer(default) do
    every = sync.interval || default

    case sync.minimum do
      minimum when is_integer(minimum) and minimum > every -> minimum
      _minimum -> every
    end
  end

  def pulls_every(_sync), do: nil

  @doc false
  # How often the adapter pulls, as `Apiary.Adapters.sync_settings/2` gives it, read from
  # the adapter's row: for the list, which has the rows already.
  @spec sync_of(Node.t()) :: map
  def sync_of(%Node{} = adapter) do
    %{
      interval: adapter.sync_interval,
      default: adapter.sync_default_interval,
      minimum: adapter.sync_minimum_interval,
      sends_changes: adapter.sync_sends_changes
    }
  end

  @doc false
  # An interval of `seconds` in words: "Every hour", "Every 2 hours", "Every minute",
  # "Every 15 minutes", or "Every 90 seconds".
  @spec interval_label(pos_integer) :: String.t()
  def interval_label(seconds) when rem(seconds, 3600) == 0,
    do: ngettext("Every hour", "Every %{count} hours", div(seconds, 3600))

  def interval_label(seconds) when rem(seconds, 60) == 0,
    do: ngettext("Every minute", "Every %{count} minutes", div(seconds, 60))

  def interval_label(seconds), do: gettext("Every %{count} seconds", count: seconds)

  @doc false
  # The same in lower case, to stand inside a sentence: "every hour", "every 15 minutes".
  @spec interval_words(pos_integer) :: String.t()
  def interval_words(seconds) when rem(seconds, 3600) == 0,
    do: ngettext("every hour", "every %{count} hours", div(seconds, 3600))

  def interval_words(seconds) when rem(seconds, 60) == 0,
    do: ngettext("every minute", "every %{count} minutes", div(seconds, 60))

  def interval_words(seconds), do: gettext("every %{count} seconds", count: seconds)
end
