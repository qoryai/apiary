defmodule ApiaryWeb.PolicyLive.Common do
  @moduledoc """
  What the workspace's policy page and a target's share: the rows of a rules table built
  from `Apiary.Policy`, the composer's state and its events, the history, the version and
  the export of a holder, and the words of a change.

  A holder is `nil` for the workspace's baseline or an `Apiary.Runs.Target`. Everything is
  read through `Apiary.Policy`; nothing here touches a schema's table.

  The rules of the level above the workspace (`Apiary.Policy.Above`, the `above` of the
  effective policy) are rows too (`above_rows/2`), read here and changed where the
  edition keeps them (`c:ApiaryWeb.Edition.above_policy_link/1`); their words say the
  level's name and nothing else of it.

  A page that lists rules of another holder than the workspace's or a target's gives
  `mount/3` a `writer`, the functions its composer and its rows' menu write with
  (`policy_writer/0` is the core's, `Apiary.Policy`'s), and leaves the events
  `edit_paths`, `change_action` and `remove` to `handle_event/3` here.
  """
  use ApiaryWeb, :verified_routes
  use Gettext, backend: ApiaryWeb.Gettext

  import ApiaryWeb.RichText
  import Phoenix.Component, only: [assign: 2, assign: 3, to_form: 2]
  # Phoenix.LiveView, its async work run under the page's organisation and workspace ids.
  use ApiaryWeb.Async

  alias Apiary.{Access, Organisations}
  alias Apiary.Accounts.Scope
  alias Apiary.Policy
  alias Apiary.Policy.{Above, Grammar, Rule}
  alias ApiaryWeb.{Format, People}
  alias ApiaryWeb.PolicyLive.{Reading, RuleList}

  @week 7 * 24 * 3600
  @fortnight 14 * 24 * 3600
  @coalesce 250

  ## Mount

  @doc """
  The assigns every policy page starts from, and the one subscription, to the policy of
  the scope's workspace where the scope has one. `opts`: `writer`, what the page writes
  rules with (`t:writer/0`), the core's policy by default; `base`, the path of the page's
  list of rules, the holder's policy page by default.
  """
  def mount(socket, holder, opts \\ []) do
    scope = socket.assigns.current_scope
    if connected?(socket) and scope.workspace, do: Policy.subscribe(scope)

    socket
    |> assign(
      holder: holder,
      writer: Keyword.get(opts, :writer, policy_writer()),
      scope_kind: if(holder, do: :target, else: :workspace),
      base: Keyword.get(opts, :base) || base(scope, holder),
      people: people(scope),
      fresh: %{},
      announce: nil,
      write_error: nil,
      dialog: nil,
      queue: [],
      reload_pending: false,
      touched: MapSet.new(),
      now: DateTime.utc_now()
    )
    |> reset_composer()
    |> reset_credential()
  end

  @typedoc """
  What a page writes rules with: `allow` and `deny` as `Apiary.Policy.allow/3` and
  `deny/3` (the scope, the page's holder, the attributes), `remove` as
  `Apiary.Policy.remove_rule/2` (the scope, a rule or its id) and `get` as
  `Apiary.Policy.get_rule/2` (the scope, an id), each answering `{:ok, rule}` or
  `{:error, %Apiary.Policy.Error{}}`; and `written`, the toast of a host rule written
  (the action, `"allow"` or `"deny"`, and the host), or none for the holder's own words
  (`rule_written/3`).
  """
  @type writer :: %{
          required(:allow) => (Scope.t(), term, map ->
                                 {:ok, Rule.t()} | {:error, Policy.Error.t()}),
          required(:deny) => (Scope.t(), term, map ->
                                {:ok, Rule.t()} | {:error, Policy.Error.t()}),
          required(:remove) => (Scope.t(), Rule.t() | String.t() ->
                                  {:ok, Rule.t()} | {:error, Policy.Error.t()}),
          required(:get) => (Scope.t(), String.t() ->
                               {:ok, Rule.t()} | {:error, Policy.Error.t()}),
          optional(:written) => (String.t(), String.t() -> String.t())
        }

  @doc "The core's writer: the workspace's and a target's rules, through `Apiary.Policy`."
  @spec policy_writer() :: writer
  def policy_writer do
    %{
      allow: &Policy.allow/3,
      deny: &Policy.deny/3,
      remove: &Policy.remove_rule/2,
      get: &Policy.get_rule/2
    }
  end

  @doc "The path of the holder's policy page in `scope`'s workspace."
  def base(scope, nil), do: ~p"/#{scope.organisation}/#{scope.workspace}/policy"

  def base(scope, %{system: system, path: path}),
    do: ApiaryWeb.TargetComponents.target_path(scope, system, path, ["policy"])

  @doc """
  Whether the reader of a policy page may take `action` on the workspace's security
  policy: `Apiary.Access.can?/3`, given the socket or its scope.
  """
  def may?(%Phoenix.LiveView.Socket{assigns: %{current_scope: scope}}, action),
    do: may?(scope, action)

  def may?(scope, action), do: Access.can?(scope, action, scope.workspace)

  def since, do: DateTime.add(DateTime.utc_now(), -@week, :second)

  @doc "The start of the window a list of rules counts their use in: the last 14 days."
  def use_since, do: DateTime.add(DateTime.utc_now(), -@fortnight, :second)

  # user id => email, of the people of the workspace: who added a rule.
  defp people(scope) do
    for %{user: %{id: id, email: email}} <- Organisations.list_members(scope),
        into: %{},
        do: {id, email}
  end

  @doc "The local part of an email: dana of dana@example.com."
  def local(nil), do: nil
  def local(email), do: People.short(email)

  @doc """
  Who made a rule or a change, by user id, among the page's `people`: the local part of a
  member's address, "Former member" for a person who is not one any more, their account
  deleted or their membership ended (`ApiaryWeb.People`), nil for nobody.
  """
  def person(people, id), do: people |> People.member(id) |> People.short()

  ## Coalesced reloads: one read per 250 ms however many changes land

  @doc "Asks for a reload of the page's policy, at most once per window. The page handles `:policy_reload`."
  def schedule_reload(socket, change \\ %{}) do
    # Which targets the changes of this window name; `:all` once one names the workspace.
    touched =
      case {socket.assigns.touched, change} do
        {:all, _} -> :all
        {%MapSet{} = set, %{target_id: id}} when is_binary(id) -> MapSet.put(set, id)
        _ -> :all
      end

    socket = assign(socket, :touched, touched)

    if socket.assigns.reload_pending do
      socket
    else
      case reload_window() do
        0 -> send(self(), :policy_reload)
        window -> Process.send_after(self(), :policy_reload, window)
      end

      assign(socket, :reload_pending, true)
    end
  end

  # `config :apiary, ApiaryWeb.PolicyLive, reload_window: 0` in a test makes the reload
  # the next message, so a test waits for nothing.
  defp reload_window do
    :apiary
    |> Application.get_env(ApiaryWeb.PolicyLive, [])
    |> Keyword.get(:reload_window, @coalesce)
  end

  ## Rows

  @doc """
  Where a rule of the workspace's baseline is written, as a list of rules names it
  (`ApiaryWeb.PolicyLive.RuleList`): the workspace, by its name, its slug the `source:`
  qualifier's value, after a target's own rules in the list's order.
  """
  def workspace_source(scope),
    do: %{key: scope.workspace.slug, label: scope.workspace.name, rank: 2}

  @doc """
  Where a target's own rule is written, on its Policy tab: this target, first in the
  list's order, `source:` and the word the search takes for a target.
  """
  def target_source,
    do: %{key: pgettext("qualifier", "target"), label: gettext("This target"), rank: 0}

  @doc """
  Where a rule of the level above the workspace is written (`Apiary.Policy.Above`): the
  level by its name, with its tile, its slug the `source:` qualifier's value, between a
  target's own rules and the workspace's in the list's order.
  """
  def above_source(%Above{name: name, slug: slug}),
    do: %{key: slug, label: name, rank: 1, tile: String.first(name || "?")}

  @doc """
  The host rules of the level above the workspace, one row each, on the workspace's page
  and on a target's tab: read here, never changed here (`can_change` false, `act` nil),
  the lock glyph with the level's words (`above` true), and the way to the level
  (`view`) where the edition gives one (`c:ApiaryWeb.Edition.above_policy_link/1`). One
  the holder does not hold in force (its allow a lower deny narrows) says why. Nothing
  where the effective policy has no level above it.
  """
  def above_rows(%Policy.Effective{above: %Above{} = above} = effective, socket) do
    scope = socket.assigns.current_scope
    source = above_source(above)
    link = ApiaryWeb.Edition.above_policy_link(scope)
    view = gettext("View in %{name}'s policy", name: above.name)

    for %{kind: :host, source: :organisation} = entry <- effective.entries do
      %{
        id: entry.rule.id,
        action: to_string(entry.action),
        host: entry.host,
        paths: entry.paths,
        locked: false,
        above: true,
        source: source,
        own: false,
        in_force: entry.in_force,
        off: off_words(entry, scope.workspace.name, above.name),
        by: person(socket.assigns.people, entry.rule.created_by_id),
        at: entry.rule.inserted_at,
        locked_tip: above_tip(above),
        can_change: false,
        act: nil,
        view: link && {view, link.path <> "?" <> URI.encode_query(%{"rule" => entry.host})}
      }
    end
  end

  def above_rows(_effective, _socket), do: []

  @doc "What the lock glyph of a rule of the level above says."
  def above_tip(%Above{name: name}),
    do: gettext("%{name}'s rule: it holds in every workspace.", name: name)

  @doc """
  The host rules of the workspace's page, one row each (`ApiaryWeb.PolicyComponents.rule_line/1`):
  every one the workspace's own, changed here; one the baseline does not hold in force
  (an allow a `*.` deny covers) says why. `locks` is `locks/1`'s.
  """
  def workspace_rules(rules, socket, locks) do
    scope = socket.assigns.current_scope
    source = workspace_source(scope)
    edit? = may?(scope, :"security_policy.edit")
    lock? = may?(scope, :"security_policy.lock")
    entries = entries_by_rule(socket.assigns[:effective])
    above = above_name(socket.assigns[:effective])

    for rule <- rules, rule.kind == "host" do
      entry = entries[rule.id]

      %{
        id: rule.id,
        action: rule.action,
        host: rule.host,
        paths: rule.paths,
        locked: rule.locked,
        source: source,
        own: true,
        in_force: entry == nil or entry.in_force,
        off: entry && off_words(entry, scope.workspace.name, above),
        by: person(socket.assigns.people, rule.created_by_id),
        at: rule.inserted_at,
        locked_tip: locked_tip(locks[rule.host]),
        can_change: edit? and (not rule.locked or lock?),
        act: :remove,
        view: nil
      }
    end
  end

  defp entries_by_rule(%Policy.Effective{entries: entries}),
    do: Map.new(entries, &{&1.rule.id, &1})

  defp entries_by_rule(_effective), do: %{}

  defp above_name(%Policy.Effective{above: %Above{name: name}}), do: name
  defp above_name(_effective), do: nil

  @doc """
  The host rules in force for a target, on its Policy tab, one row each: its own, changed
  here, and the workspace's, read here and changed on the workspace's page (the row's
  `view`). A rule that is not in force for the target (its own, held by a locked rule of
  the workspace; the workspace's, which the target's own decides) is kept, and says why.
  """
  def target_rules(%Policy.Effective{entries: entries} = effective, socket) do
    scope = socket.assigns.current_scope
    workspace = scope.workspace.name
    edit? = may?(scope, :"security_policy.edit")
    locks = socket.assigns[:locks] || %{}
    own_source = target_source()
    workspace_source = workspace_source(scope)
    above = above_name(effective)

    view =
      gettext("View in %{workspace}'s policy", workspace: workspace)

    for %{kind: :host, source: source} = entry <- entries, source != :organisation do
      own? = entry.source == :target

      %{
        id: entry.rule.id,
        action: to_string(entry.action),
        host: entry.host,
        paths: entry.paths,
        locked: entry.locked,
        source: if(own?, do: own_source, else: workspace_source),
        own: own?,
        in_force: entry.in_force,
        off: off_words(entry, workspace, above),
        by: person(socket.assigns.people, entry.rule.created_by_id),
        at: entry.rule.inserted_at,
        locked_tip: entry.locked && locked_tip(locks[entry.host]),
        can_change: own? and edit?,
        act: if(own?, do: act(entry), else: nil),
        view:
          if(own?,
            do: nil,
            else: {view, ApiaryWeb.ConnectionLive.Rules.rule_path(scope, nil, entry.host)}
          )
      }
    end ++ above_rows(effective, socket)
  end

  @doc """
  Why a rule is not in force, where its use would be; nil for one that is. `workspace`
  is the workspace's name, `above` the name of the level above it, or nil.
  """
  def off_words(entry, workspace, above \\ nil)

  def off_words(%{in_force: true}, _workspace, _above), do: nil

  def off_words(%{reason: :only_above_allows}, _workspace, above),
    do: gettext("Not in force: %{name} allows only its own hosts", name: above || "?")

  def off_words(%{overridden_by: %{source: :organisation, action: :deny} = winner}, _ws, above),
    do:
      gettext("Not in force: %{name}'s %{host} denies it", name: above || "?", host: winner.host)

  def off_words(%{overridden_by: %{source: :organisation} = winner}, _workspace, above),
    do: gettext("Not in force: %{name}'s %{host} holds", name: above || "?", host: winner.host)

  def off_words(
        %{overridden_by: %{source: :workspace, locked: true} = winner},
        workspace,
        _above
      ),
      do:
        gettext("Not in force: %{workspace}'s locked %{host} holds",
          workspace: workspace,
          host: winner.host
        )

  def off_words(%{source: :workspace, overridden_by: %{source: :target}}, _workspace, _above),
    do: gettext("Not in force: this target's own rule decides it")

  # The rule that wins is named by its own source: a target's own deny is the target's,
  # never the workspace's, which a reader would look for there and not find.
  def off_words(
        %{source: :organisation, overridden_by: %{source: :target, action: :deny} = winner},
        _workspace,
        _above
      ),
      do: gettext("Not in force here: this target's own %{host} denies it", host: winner.host)

  def off_words(
        %{source: :organisation, overridden_by: %{action: :deny} = winner},
        workspace,
        _above
      ),
      do:
        gettext("Not in force here: %{workspace}'s %{host} denies it",
          workspace: workspace,
          host: winner.host
        )

  def off_words(%{overridden_by: %{action: :deny} = winner}, _workspace, _above),
    do: gettext("Not in force: %{host} denies it", host: winner.host)

  def off_words(%{overridden_by: %{} = winner}, _workspace, _above),
    do: gettext("Not in force: %{host} decides it", host: winner.host)

  def off_words(_entry, _workspace, _above), do: gettext("Not in force")

  @doc """
  The credentials of the workspace's page, one row each (`ApiaryWeb.PolicyComponents.credentials_table/1`),
  every one its own.
  """
  def credential_rows(rules, socket) do
    scope = socket.assigns.current_scope
    source = workspace_source(scope)
    edit? = may?(scope, :"security_policy.edit")
    lock? = may?(scope, :"security_policy.lock")

    for rule <- rules, rule.kind == "credential" do
      %{
        id: rule.id,
        action: rule.action,
        name: rule.name,
        argument: rule.argument,
        locked: rule.locked,
        source: source,
        own: true,
        view: nil,
        by: person(socket.assigns.people, rule.created_by_id),
        at: rule.inserted_at,
        can_change: edit? and (not rule.locked or lock?)
      }
    end
  end

  @doc """
  The credentials a target's runs may use, on its Policy tab: its own, then the
  workspace's, each with where it is written; the workspace's are read here and changed
  on the workspace's page.
  """
  def target_credentials(%Policy.Effective{entries: entries}, socket) do
    scope = socket.assigns.current_scope
    edit? = may?(scope, :"security_policy.edit")
    view = gettext("View in %{workspace}'s policy", workspace: scope.workspace.name)
    path = ~p"/#{scope.organisation}/#{scope.workspace}/policy"

    for %{kind: :credential} = entry <- entries do
      own? = entry.source == :target

      %{
        id: entry.rule.id,
        action: to_string(entry.action),
        name: entry.name,
        argument: entry.argument,
        locked: entry.locked,
        in_force: entry.in_force,
        source: if(own?, do: target_source(), else: workspace_source(scope)),
        own: own?,
        view: if(own?, do: nil, else: {view, path}),
        by: person(socket.assigns.people, entry.rule.created_by_id),
        at: entry.rule.inserted_at,
        can_change: own? and edit?
      }
    end
    |> Enum.sort_by(&{not &1.own, &1.name})
  end

  # What Remove does to a target's own rule: gives the workspace's back where the target's
  # overrode it, else removes it.
  defp act(%{action: :deny, overrides: overrides}) do
    if Enum.any?(overrides, &(&1.source == :workspace)), do: :restore, else: :remove
  end

  defp act(_entry), do: :remove

  @doc """
  The path of the holder's list of rules with `query` (`ApiaryWeb.PolicyLive.RuleList`),
  and the parameters of `extra` beside it: on the page of the socket, or on `base`.
  """
  def list_path(socket_or_base, query, extra \\ %{})

  def list_path(%{assigns: %{base: base}}, query, extra), do: list_path(base, query, extra)

  def list_path(base, query, extra) when is_binary(base) do
    case Map.merge(RuleList.to_params(query), extra) do
      params when params == %{} -> base
      params -> base <> "?" <> URI.encode_query(params)
    end
  end

  @doc """
  The page of the holder's list the reader sees: `ApiaryWeb.PolicyLive.RuleList.list/3`
  of the page's rows and query, with the use counted so far.
  """
  def listing(assigns) do
    RuleList.list(assigns.rows, assigns.list_query, async_value(assigns.activity))
  end

  @doc "An async assign's value: its result, `:unavailable` when it failed, `:loading` until then."
  def async_value(%Phoenix.LiveView.AsyncResult{ok?: true, result: result}), do: result
  def async_value(%Phoenix.LiveView.AsyncResult{loading: nil}), do: :unavailable
  def async_value(_async), do: :loading

  defp locked_tip(%{by: by, at: at}) when is_binary(by),
    do:
      gettext("Locked by %{by} on %{at}. Only an owner can change or unlock it.", by: by, at: at)

  defp locked_tip(_unknown), do: gettext("Locked. Only an owner can change or unlock it.")

  @doc """
  Who locked which host, from the newest page of the workspace's changes (a page the
  caller has read already): `%{host => %{by:, at:}}`. A lock older than that page is
  shown without its author.
  """
  def locks(%{items: changes}) do
    changes
    |> Enum.filter(&(&1.action == "rule_locked"))
    |> Enum.reverse()
    |> Map.new(fn change ->
      {change.subject,
       %{
         by: People.email(change.changed_by),
         at: Format.date(change.inserted_at)
       }}
    end)
  end

  ## The composer

  def reset_composer(socket, values \\ %{}) do
    params =
      Map.merge(%{"action" => "allow", "host" => "", "paths" => "", "every" => "false"}, values)

    assign(socket,
      composer: to_form(params, as: :rule),
      composer_params: params,
      reading: Reading.hint()
    )
  end

  def reset_credential(socket) do
    params = %{"name" => "", "argument" => ""}

    assign(socket,
      credential: to_form(params, as: :credential),
      credential_params: params,
      credential_reading: nil
    )
  end

  @doc "Reads the composer again against the rules on the page. `own` and `entries` are the page's."
  def read(socket, params) do
    params =
      Map.merge(socket.assigns.composer_params, fields(params, ~w(action host paths every)))

    reading =
      Reading.host_rule(params, %{
        scope: socket.assigns.scope_kind,
        own: own_for_reading(socket),
        entries: socket.assigns.effective.entries,
        owner: may?(socket, :"security_policy.lock"),
        locked_by: socket.assigns[:locks] || %{}
      })

    assign(socket,
      composer: to_form(params, as: :rule),
      composer_params: params,
      reading: reading
    )
  end

  defp own_for_reading(socket) do
    people = socket.assigns.people

    for rule <- socket.assigns.own do
      %{
        kind: rule.kind,
        action: rule.action,
        host: rule.host,
        name: rule.name,
        argument: rule.argument,
        paths: rule.paths,
        locked: rule.locked,
        by: person(people, rule.created_by_id),
        at: Format.day(rule.inserted_at)
      }
    end
  end

  # What a client sends is a map of strings, or it is nothing: the named fields that are
  # text, cut to what a field can hold, NUL and the like taken out. Anything else is left
  # as it was, so a crafted payload changes no field and crashes no page.
  @field_max 4000
  defp fields(%{} = params, names) do
    for name <- names, is_binary(value = params[name]), into: %{} do
      {name,
       value
       |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F]/, "")
       |> String.slice(0, @field_max)}
    end
  end

  defp fields(_params, _names), do: %{}

  @doc "The shared events of the composer. Returns `{:halt, socket}` when it handled the event, `:cont` otherwise."
  def handle_event("composer_change", params, socket) when is_map(params) do
    params = fields(params["rule"], ~w(host paths))

    # Typing a host again takes back an "every path" asked for another host.
    params =
      if Map.has_key?(params, "host") and params["host"] != socket.assigns.composer_params["host"],
        do: Map.put(params, "every", "false"),
        else: params

    {:halt, read(socket, params)}
  end

  def handle_event("composer_action", %{"action" => action}, socket)
      when action in ~w(allow deny) do
    {:halt, socket |> read(%{"action" => action}) |> focus("policy-composer-host")}
  end

  def handle_event("composer_use", params, socket) when is_map(params) do
    values = params |> fields(~w(host paths action)) |> Map.put("every", "false")

    values =
      if values["action"] in [nil, "allow", "deny"],
        do: values,
        else: Map.delete(values, "action")

    field =
      if params["focus"] == "paths", do: "policy-composer-paths", else: "policy-composer-host"

    {:halt,
     socket |> assign(:composer_open, true) |> read(values) |> set_fields() |> focus(field)}
  end

  def handle_event("composer_every", _params, socket) do
    {:halt,
     socket
     |> read(%{"every" => "true", "paths" => ""})
     |> set_fields()
     |> focus("policy-composer-add")}
  end

  def handle_event("composer_paste", %{"hosts" => hosts}, socket) when is_list(hosts) do
    hosts =
      hosts
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&(&1 |> String.trim() |> String.slice(0, 300)))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.take(50)

    case hosts do
      [] ->
        {:halt, socket}

      [first | rest] ->
        {:halt,
         socket
         |> assign(:queue, rest)
         |> read(%{"host" => first, "every" => "false"})
         |> set_fields()}
    end
  end

  def handle_event("composer_save", _params, socket) do
    socket = read(socket, %{})

    if socket.assigns.reading.kind in [:ok, :note] do
      {:halt, save_rule(socket)}
    else
      {:halt, focus(socket, "policy-composer-host")}
    end
  end

  def handle_event("show_rule", %{"host" => host}, socket) when is_binary(host) do
    {:halt,
     push_patch(socket, to: socket.assigns.base <> "?" <> URI.encode_query(%{"rule" => host}))}
  end

  def handle_event("open_workspace_rule", %{"host" => host}, socket) when is_binary(host) do
    scope = socket.assigns.current_scope

    {:halt,
     push_navigate(socket,
       to: ~p"/#{scope.organisation}/#{scope.workspace}/policy?#{%{"rule" => host}}"
     )}
  end

  def handle_event("credential_change", params, socket) when is_map(params) do
    params =
      Map.merge(
        %{"name" => "", "argument" => ""},
        fields(params["credential"], ~w(name argument))
      )

    reading = Reading.credential(params, socket.assigns.own)

    {:halt,
     assign(socket,
       credential: to_form(params, as: :credential),
       credential_params: params,
       credential_reading: reading
     )}
  end

  def handle_event("credential_save", _params, socket) do
    params = socket.assigns.credential_params
    reading = Reading.credential(params, socket.assigns.own)

    if reading.kind in [:ok, :note] do
      attrs = %{kind: "credential", name: params["name"], argument: params["argument"]}

      case Policy.allow(socket.assigns.current_scope, socket.assigns.holder, attrs) do
        {:ok, rule} ->
          {:halt,
           socket
           |> reset_credential()
           |> wrote(rule, credential_named(socket, rule.name), gettext("Credential added."))
           |> focus("policy-credential-name")}

        {:error, error} ->
          {:halt, refused(socket, error)}
      end
    else
      {:halt, assign(socket, :credential_reading, reading)}
    end
  end

  def handle_event("dialog_cancel", _params, socket), do: {:halt, assign(socket, :dialog, nil)}

  # The list's search, sent as the reader types and on Enter: a qualifier they typed
  # becomes a token on Enter only, so one half typed is never applied; until then it is
  # left out of the text.
  def handle_event("rules_search", %{"q" => typed} = params, socket) when is_binary(typed) do
    {tokens, text} =
      if Map.has_key?(params, "_target"),
        do: {[], RuleList.pending(typed)},
        else: RuleList.parse_search(typed)

    query = RuleList.typed(socket.assigns.list_query, tokens, text)
    {:halt, push_patch(socket, to: list_path(socket, query))}
  end

  def handle_event("composer_open", _params, socket) do
    {:halt, socket |> assign(:composer_open, true) |> focus("policy-composer-host")}
  end

  def handle_event("composer_close", _params, socket) do
    {:halt,
     socket
     |> assign(composer_open: false, queue: [])
     |> reset_composer()
     |> set_fields()
     |> focus("policy-rules-add")}
  end

  # The rows' menu of a page whose rules are the writer's alone: a page that lists more
  # than one holder's rules answers these before asking here.
  def handle_event("edit_paths", %{"id" => id}, socket) do
    case socket.assigns.writer.get.(socket.assigns.current_scope, id) do
      {:ok, %{kind: "host", action: "allow"} = rule} ->
        {:halt,
         socket
         |> assign(:composer_open, true)
         |> read(%{
           "action" => "allow",
           "host" => rule.host,
           "paths" => Enum.join(rule.paths || [], " "),
           "every" => "false"
         })
         |> set_fields()
         |> focus("policy-composer-paths")}

      _ ->
        {:halt, socket}
    end
  end

  def handle_event("change_action", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    %{writer: writer, holder: holder} = socket.assigns

    case writer.get.(scope, id) do
      {:ok, %{kind: "host", action: action} = rule} ->
        {write, to} =
          if action == "allow", do: {writer.deny, "deny"}, else: {writer.allow, "allow"}

        case write.(scope, holder, %{host: rule.host}) do
          {:ok, written} ->
            {:halt,
             wrote(socket, written, rule_written(socket, to, rule.host), gettext("Rule changed."))}

          {:error, error} ->
            {:halt, refused(socket, error)}
        end

      _ ->
        {:halt, socket.assigns.reload.(socket)}
    end
  end

  def handle_event("remove", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    writer = socket.assigns.writer

    with {:ok, rule} <- writer.get.(scope, id),
         {:ok, rule} <- writer.remove.(scope, rule) do
      {:halt,
       socket
       |> wrote(
         nil,
         gettext("The rule %{host} is removed.", host: Rule.subject(rule)),
         gettext("Rule removed.")
       )
       |> focus("policy-composer-host")}
    else
      {:error, error} -> {:halt, refused(socket, error)}
    end
  end

  def handle_event(_event, _params, _socket), do: :cont

  defp save_rule(socket) do
    %{"action" => action, "host" => host, "paths" => paths, "every" => every} =
      socket.assigns.composer_params

    scope = socket.assigns.current_scope
    holder = socket.assigns.holder
    host = String.trim(host)
    paths = Reading.split(paths)

    attrs =
      cond do
        action == "deny" -> %{host: host}
        paths != [] -> %{host: host, paths: paths}
        every == "true" -> %{host: host, paths: nil}
        true -> %{host: host}
      end

    writer = socket.assigns.writer

    result =
      if action == "deny",
        do: writer.deny.(scope, holder, attrs),
        else: writer.allow.(scope, holder, attrs)

    case result do
      {:ok, rule} ->
        {next, queue} =
          case socket.assigns.queue do
            [next | rest] -> {%{"host" => next}, rest}
            [] -> {%{}, []}
          end

        socket
        |> assign(:queue, queue)
        |> reset_composer(Map.put(next, "action", action))
        |> wrote(rule, rule_written(socket, action, host), gettext("Rule added."))
        |> then(&if(next == %{}, do: &1, else: read(&1, %{})))
        |> set_fields()
        |> focus("policy-composer-host")

      {:error, error} ->
        refused(socket, error)
    end
  end

  def holder_name(%{assigns: %{holder: %{system: system, path: path}}}), do: "#{system}/#{path}"

  @doc """
  The toast of a host rule written on the page:
  `123.example is allowed for the workspace.`, `… is denied for acme/shop.`, or the
  writer's own words where it has them.
  """
  def rule_written(%{assigns: %{writer: %{written: written}}}, action, host)
      when is_function(written, 2),
      do: written.(action, host)

  def rule_written(%{assigns: %{holder: nil}}, "allow", host),
    do: gettext("%{host} is allowed for the workspace.", host: host)

  def rule_written(%{assigns: %{holder: nil}}, "deny", host),
    do: gettext("%{host} is denied for the workspace.", host: host)

  def rule_written(socket, "allow", host),
    do: gettext("%{host} is allowed for %{target}.", host: host, target: holder_name(socket))

  def rule_written(socket, "deny", host),
    do: gettext("%{host} is denied for %{target}.", host: host, target: holder_name(socket))

  defp credential_named(%{assigns: %{holder: nil}}, name),
    do: gettext("The credential %{name} is named for the workspace.", name: name)

  defp credential_named(socket, name),
    do:
      gettext("The credential %{name} is named for %{target}.",
        name: name,
        target: holder_name(socket)
      )

  @doc """
  After a write: the page is read again, the new rule is marked fresh, the toast and the
  polite region name the version the change made, or say that it made none.
  """
  def wrote(socket, rule, sentence, announce) do
    before = socket.assigns[:version] && socket.assigns.version.version
    before_holder = socket.assigns[:version] && socket.assigns.version.target_id
    socket = socket.assigns.reload.(socket)
    version = socket.assigns[:version] && socket.assigns.version.version
    holder = socket.assigns[:version] && socket.assigns.version.target_id

    tail =
      cond do
        is_nil(version) ->
          ""

        version == before and holder == before_holder ->
          " " <> gettext("No new version: the document did not change.")

        # A target's first version of its own: numbered from 1, not a reset of the
        # workspace's numbering it was served until now.
        is_nil(before_holder) and is_binary(holder) and not is_nil(before) ->
          " " <>
            gettext(
              "Version %{version} of this target's own policy; until now it was served the workspace's.",
              version: version
            )

        true ->
          " " <> gettext("Version %{version}.", version: version)
      end

    fresh =
      if rule && version && version != before,
        do: Map.put(socket.assigns.fresh, rule.id, version),
        else: socket.assigns.fresh

    socket
    |> assign(fresh: fresh, write_error: nil)
    |> assign(
      :announce,
      announce <>
        if(version && version != before,
          do: " " <> gettext("Version %{version}.", version: version),
          else: ""
        )
    )
    |> put_flash(:info, sentence <> tail)
  end

  @doc "A refused write: the domain's sentence above the composer, as an alert; the list is read again."
  def refused(socket, %Policy.Error{message: message}) do
    socket.assigns.reload.(socket) |> assign(:write_error, message)
  end

  def focus(socket, id), do: push_event(socket, "policy:focus", %{id: id})

  @doc """
  Puts the composer's values into its fields in the browser. A patch leaves a field that
  has focus as the reader typed it, so what the server sets (a repair, a cleared form, the
  next pasted host) is sent as well.
  """
  def set_fields(socket) do
    composer = socket.assigns.composer_params
    credential = socket.assigns.credential_params

    push_event(socket, "policy:fields", %{
      fields: %{
        "policy-composer-host" => composer["host"],
        "policy-composer-paths" =>
          if(composer["action"] == "deny", do: "", else: composer["paths"]),
        "policy-credential-name" => credential["name"],
        "policy-credential-argument" => credential["argument"]
      }
    })
  end

  ## What enforcing would deny, for a confirm

  @doc """
  The list of an enforce confirm, from the record: `%{destinations:, open:}`, the
  destinations as they were when the confirm opened, so a row stays where it is, and the
  keys of those that today's rules still do not cover. Read again after every allow made
  from the list, so "Allowed" and "none left" are what the policy says, not what was
  clicked. `nil` when it cannot be counted.
  """
  def would(scope, holder, previous \\ nil) do
    case Policy.uncovered(scope, holder, since()) do
      {:ok, fresh} ->
        shown = (previous && previous.destinations) || fresh
        known = MapSet.new(shown, &would_key/1)
        added = Enum.reject(fresh, &(would_key(&1) in known))
        %{destinations: shown ++ added, open: MapSet.new(fresh, &would_key/1)}

      _ ->
        nil
    end
  end

  @doc "The DOM-safe key of a destination of the list."
  def would_key(%{host: host, path: path}), do: ApiaryWeb.RunComponents.dom_token({host, path})

  ## The words of a change

  @doc """
  The sentence of a change, its author first: rich text. `who` is the author's email,
  "Former member" once their account is deleted (`ApiaryWeb.People`), or nil for a change
  nobody made, such as a render again after an upgrade, which Qory made. `above` is the
  name of the level above the workspace, for a change of it (`above_changed`), or nil.
  """
  def change_sentence(change, who, above \\ nil) do
    who = {:b, who || gettext("Qory")}
    diff = Policy.diff(change)

    case {change.action, diff} do
      {"mode_changed", %{mode: {from, to}}} when is_nil(change.target_id) ->
        rich_gettext("%{who} switched the workspace's default mode from %{from} to %{to}",
          who: who,
          from: from,
          to: {:b, to}
        )

      {"mode_changed", %{mode: {_from, "inherit"}}} ->
        rich_gettext("%{who} set this target to %{mode}",
          who: who,
          mode: {:b, gettext("follow the workspace")}
        )

      {"mode_changed", %{mode: {_from, to}}} ->
        rich_gettext("%{who} set this target's mode to %{mode}", who: who, mode: {:b, to})

      {"mode_changed", _} ->
        rich_gettext("%{who} set the mode", who: who)

      {"rule_added", %{added: [%{"kind" => "credential"} = rule | _]}} ->
        rich_gettext("%{who} added the credential %{credential}",
          who: who,
          credential: credential_chips(rule)
        )

      {"rule_added", %{added: [rule | _]}} ->
        added_sentence(who, rule)

      {"rule_removed", %{removed: [%{"kind" => "credential"} = rule | _]}} ->
        rich_gettext("%{who} removed the credential %{credential}",
          who: who,
          credential: credential_chips(rule)
        )

      {"rule_removed", %{removed: [%{"action" => "deny"} = rule | _]}} ->
        rich_gettext("%{who} removed the deny rule %{host}",
          who: who,
          host: {:code, rule["host"]}
        )

      {"rule_removed", %{removed: [rule | _]}} ->
        rich_gettext("%{who} removed the allow rule %{host}",
          who: who,
          host: {:code, rule["host"]}
        )

      {"rule_changed", %{changed: [{old, new} | _]}} ->
        changed_sentence(who, old, new)

      {"rule_locked", _} ->
        rich_gettext("%{who} locked %{host}", who: who, host: {:code, change.subject})

      {"rule_unlocked", _} ->
        rich_gettext("%{who} unlocked %{host}", who: who, host: {:code, change.subject})

      {"above_changed", _} when is_binary(above) ->
        rich_gettext("%{who} changed %{name}'s policy", who: who, name: {:b, above})

      {"above_changed", _} ->
        rich_gettext("%{who} changed the policy above this workspace", who: who)

      _ when is_binary(change.subject) ->
        rich_gettext("%{who} changed %{subject}", who: who, subject: {:code, change.subject})

      _ ->
        rich_gettext("%{who} changed the policy", who: who)
    end
  end

  defp added_sentence(who, %{"action" => "deny"} = rule) do
    case rule do
      %{"paths" => [_ | _] = paths} ->
        rich_gettext("%{who} denied %{host} on %{paths}",
          who: who,
          host: {:code, rule["host"]},
          paths: paths_words(paths)
        )

      _ ->
        rich_gettext("%{who} denied %{host}", who: who, host: {:code, rule["host"]})
    end
  end

  defp added_sentence(who, rule) do
    case rule do
      %{"paths" => [_ | _] = paths} ->
        rich_gettext("%{who} allowed %{host} on %{paths}",
          who: who,
          host: {:code, rule["host"]},
          paths: paths_words(paths)
        )

      _ ->
        rich_gettext("%{who} allowed %{host}", who: who, host: {:code, rule["host"]})
    end
  end

  defp changed_sentence(who, %{"kind" => "credential"}, new),
    do:
      rich_gettext("%{who} changed the argument of the credential %{credential}",
        who: who,
        credential: credential_chips(new)
      )

  defp changed_sentence(who, %{"action" => action} = old, %{"action" => action} = new) do
    cond do
      old["paths"] != new["paths"] ->
        rich_gettext("%{who} changed the paths of %{host} from %{paths} to %{new_paths}",
          who: who,
          host: {:code, new["host"]},
          paths: paths_words(old["paths"]),
          new_paths: paths_words(new["paths"])
        )

      new["locked"] ->
        rich_gettext("%{who} locked %{host}", who: who, host: {:code, new["host"]})

      true ->
        rich_gettext("%{who} unlocked %{host}", who: who, host: {:code, new["host"]})
    end
  end

  defp changed_sentence(who, _old, %{"action" => "deny"} = new),
    do:
      rich_gettext("%{who} replaced allow %{host} with deny",
        who: who,
        host: {:code, new["host"]}
      )

  defp changed_sentence(who, _old, new),
    do:
      rich_gettext("%{who} replaced deny %{host} with allow",
        who: who,
        host: {:code, new["host"]}
      )

  defp credential_chips(%{"name" => name, "argument" => argument}) when is_binary(argument),
    do: [{:code, name}, " ", {:code, argument}]

  defp credential_chips(%{"name" => name}), do: [{:code, name}]

  defp paths_words(nil), do: [gettext("every path")]
  defp paths_words([]), do: [gettext("no path")]
  defp paths_words(paths), do: paths |> Enum.map(&{:code, &1}) |> Enum.intersperse(" ")

  @doc "A change in a few plain words, for the versions list and the version's strip."
  def change_words(change) do
    diff = Policy.diff(change)

    case {change.action, diff} do
      {"mode_changed", %{mode: {_from, to}}} when is_nil(change.target_id) ->
        gettext("Workspace's default set to %{mode}", mode: to)

      {"mode_changed", %{mode: {_from, "inherit"}}} ->
        gettext("Set to follow the workspace")

      {"mode_changed", %{mode: {_from, to}}} ->
        gettext("Mode set to %{mode}", mode: to)

      {"rule_added", %{added: [%{"kind" => "credential", "name" => name} | _]}} ->
        gettext("Credential %{name}", name: name)

      {"rule_added", %{added: [%{"action" => "deny"} = rule | _]}} ->
        gettext("Denied %{host}", host: rule["host"])

      {"rule_added", %{added: [rule | _]}} ->
        gettext("Allowed %{host}", host: rule["host"])

      {"rule_removed", _} ->
        gettext("Removed %{subject}", subject: change.subject)

      {"rule_changed", %{changed: [{%{"action" => a}, %{"action" => a}} | _]}} ->
        gettext("Paths of %{subject}", subject: change.subject)

      {"rule_changed", _} ->
        gettext("Replaced %{subject}", subject: change.subject)

      {"rule_locked", _} ->
        gettext("Locked %{subject}", subject: change.subject)

      {"rule_unlocked", _} ->
        gettext("Unlocked %{subject}", subject: change.subject)

      {"above_changed", _} ->
        gettext("Changed above the workspace")

      _ ->
        gettext("Changed")
    end
  end

  @doc "The change in the page's own words, for the rules panel of a diff: `[{:add | :del | :ctx, rich}]`."
  def rule_lines(change) do
    diff = Policy.diff(change)
    rules = change.after["rules"] || []

    mode =
      case diff.mode do
        {from, to} -> [{:del, mode_line(from)}, {:add, mode_line(to)}]
        nil -> []
      end

    removed = for rule <- diff.removed, do: {:del, rule_words(rule)}
    added = for rule <- diff.added, do: {:add, rule_words(rule)}

    changed =
      Enum.flat_map(diff.changed, fn {old, new} ->
        [{:del, rule_words(old)}, {:add, rule_words(new)}]
      end)

    touched = length(diff.added) + length(diff.changed)
    rest = length(rules) - touched

    context =
      if rest > 0,
        do: [
          {:ctx,
           [
             ngettext("%{number} other rule: unchanged", "%{number} other rules: unchanged", rest,
               number: Format.number(rest)
             )
           ]}
        ],
        else: []

    mode ++ removed ++ changed ++ added ++ context
  end

  @doc """
  mode_line/1 says a mode of the policy as a line of a diff: `observe`, `enforce`, or
  `inherit`, a target's following the workspace.
  """
  @spec mode_line(String.t() | atom) :: term
  def mode_line("inherit"),
    do: rich_gettext("Mode %{mode}", mode: {:b, gettext("follow the workspace")})

  def mode_line(mode), do: rich_gettext("Mode %{mode}", mode: {:b, to_string(mode)})

  @doc """
  rule_words/1 says a rule of the policy as a line of a diff says it: a credential, an
  allow with its paths, or a deny, each marked when it is locked.
  """
  @spec rule_words(map) :: term
  def rule_words(%{"kind" => "credential"} = rule) do
    chips = credential_chips(rule)

    if rule["locked"],
      do: rich_gettext("Credential %{credential}, locked", credential: chips),
      else: rich_gettext("Credential %{credential}", credential: chips)
  end

  def rule_words(%{"action" => "allow"} = rule) do
    host = {:code, rule["host"]}
    paths = paths_words(rule["paths"])

    if rule["locked"],
      do: rich_gettext("Allow %{host}, %{paths}, locked", host: host, paths: paths),
      else: rich_gettext("Allow %{host}, %{paths}", host: host, paths: paths)
  end

  def rule_words(%{"action" => "deny"} = rule) do
    host = {:code, rule["host"]}

    if rule["locked"],
      do: rich_gettext("Deny %{host}, locked", host: host),
      else: rich_gettext("Deny %{host}", host: host)
  end

  def rule_words(rule) do
    host = {:code, rule["host"]}

    if rule["locked"],
      do: rich_gettext("%{host}, locked", host: host),
      else: [host]
  end

  ## Documents

  @doc """
  A served document indented for reading, its keys in the order served: the document,
  `security_policy` and `egress` a key per line, `allow`, `paths` and `credentials` an
  entry per line, everything below on its line. A document that is not JSON is shown as
  it is.
  """
  def pretty(document) when is_binary(document) do
    case Jason.decode(document, objects: :ordered_objects) do
      {:ok, %Jason.OrderedObject{} = object} -> object |> lines(0, nil) |> Enum.join("\n")
      _ -> document
    end
  end

  @open_objects [nil, "security_policy", "egress", "paths"]
  @open_lists ["allow", "credentials"]

  defp lines(%Jason.OrderedObject{values: [_ | _] = entries}, depth, key)
       when key in @open_objects do
    open(entries, depth, "{", "}", fn {name, value} ->
      case lines(value, depth + 1, name) do
        [single] -> ["#{Jason.encode!(name)}: #{single}"]
        [first | rest] -> ["#{Jason.encode!(name)}: #{first}" | rest]
      end
    end)
  end

  defp lines([_ | _] = list, depth, key) when key in @open_lists do
    open(list, depth, "[", "]", &[inline(&1)])
  end

  defp lines(value, _depth, _key), do: [inline(value)]

  # Every entry on lines of its own, a comma after each but the last.
  defp open(entries, depth, left, right, fun) do
    pad = String.duplicate("  ", depth + 1)
    last = length(entries) - 1

    inner =
      entries
      |> Enum.with_index()
      |> Enum.flat_map(fn {entry, index} ->
        [first | rest] = fun.(entry)
        {middle, final} = Enum.split([pad <> first | rest], -1)
        middle ++ Enum.map(final, &(&1 <> if(index == last, do: "", else: ",")))
      end)

    [left] ++ inner ++ [String.duplicate("  ", depth) <> right]
  end

  defp inline(%Jason.OrderedObject{values: entries}) do
    "{" <>
      Enum.map_join(entries, ", ", fn {k, v} -> "#{Jason.encode!(k)}: #{inline(v)}" end) <> "}"
  end

  defp inline(list) when is_list(list), do: "[" <> Enum.map_join(list, ", ", &inline/1) <> "]"
  defp inline(value), do: Jason.encode!(value)

  @doc "A line diff of two texts: `[{:add | :del | :ctx, line}]`."
  def line_diff(old, new) do
    List.myers_difference(String.split(old, "\n"), String.split(new, "\n"))
    |> Enum.flat_map(fn
      {:eq, lines} -> Enum.map(lines, &{:ctx, &1})
      {:ins, lines} -> Enum.map(lines, &{:add, &1})
      {:del, lines} -> Enum.map(lines, &{:del, &1})
    end)
  end

  @doc "Folds a long run of unchanged array items to its first two and how many more."
  def fold(lines) do
    lines
    |> Enum.chunk_by(fn {kind, text} -> kind == :ctx and String.starts_with?(text, "      ") end)
    |> Enum.flat_map(fn
      [{:ctx, "      " <> _} | _] = run when length(run) > 4 ->
        Enum.take(run, 2) ++
          [
            {:ctx,
             "      " <> gettext("… %{number} more", number: Format.number(length(run) - 2))}
          ]

      run ->
        run
    end)
  end

  @doc "How a diff reads in a few words: 1 line added, 2 lines changed."
  def diff_summary(lines) do
    added = Enum.count(lines, &(elem(&1, 0) == :add))
    removed = Enum.count(lines, &(elem(&1, 0) == :del))

    cond do
      added == 0 and removed == 0 ->
        gettext("no line changed")

      removed == 0 ->
        ngettext("%{number} line added", "%{number} lines added", added,
          number: Format.number(added)
        )

      added == 0 ->
        ngettext("%{number} line removed", "%{number} lines removed", removed,
          number: Format.number(removed)
        )

      added == removed ->
        ngettext("%{number} line changed", "%{number} lines changed", added,
          number: Format.number(added)
        )

      true ->
        ngettext(
          "%{number} line added, %{removed} removed",
          "%{number} lines added, %{removed} removed",
          added,
          removed: Format.number(removed),
          number: Format.number(added)
        )
    end
  end

  ## History

  @doc "A page of the holder's history as the rows of the change list."
  def history(socket, page) do
    scope = socket.assigns.current_scope
    holder = socket.assigns.holder
    base = socket.assigns.base
    changes = Policy.list_changes(scope, holder, page)
    # One read for the page: the versions its changes made, without their documents.
    versions = Policy.configurations_for_changes(scope, Enum.map(changes.items, & &1.id))

    above = above_name(socket.assigns[:effective])

    rows =
      for change <- changes.items do
        made = made_version(versions, holder, change)
        query = if changes.page > 1, do: %{"page" => changes.page}, else: %{}

        %{
          id: change.id,
          sentence: change_sentence(change, People.email(change.changed_by), above),
          origin: origin(change, made),
          who: People.email(change.changed_by),
          at: change.inserted_at,
          version: made && made.version,
          digest: made && made.digest,
          workspace: false,
          patch: base <> "/history?" <> URI.encode_query(Map.put(query, "change", change.id)),
          close:
            base <> "/history" <> if(query == %{}, do: "", else: "?" <> URI.encode_query(query))
        }
      end

    %{rows: rows, page: changes.page, pages: changes.pages, total: changes.total}
  end

  # The configuration a change made for the holder, or nil when the bytes stayed the same.
  defp made_version(versions, holder, change) do
    holder_id = holder && holder.id
    Enum.find(versions[change.id] || [], &(&1.target_id == holder_id))
  end

  defp origin(%{action: "mode_changed", target_id: id} = change, made) when id != nil do
    case {change.before["mode"], change.after["mode"], made} do
      {"inherit", _to, nil} ->
        gettext(
          "Its own from now on. The workspace's default is the same, so the document did not change."
        )

      {"inherit", _to, _made} ->
        gettext("Its own from now on. It followed the workspace's default.")

      {"observe", "inherit", nil} ->
        gettext(
          "It observed on its own. The workspace's default is the same, so the document did not change."
        )

      {"enforce", "inherit", nil} ->
        gettext(
          "It enforced on its own. The workspace's default is the same, so the document did not change."
        )

      {"observe", "inherit", _made} ->
        gettext("It observed on its own.")

      {"enforce", "inherit", _made} ->
        gettext("It enforced on its own.")

      _ ->
        nil
    end
  end

  defp origin(%{action: action}, nil) when action in ~w(rule_locked rule_unlocked),
    do: gettext("The lock holds against targets. The document did not change.")

  defp origin(_change, nil),
    do: gettext("The document did not list it, so its bytes did not change.")

  defp origin(_change, _made), do: nil

  @doc "The diff of one change of the holder: its rules in words, its document in lines."
  def change_diff(socket, change_id) do
    scope = socket.assigns.current_scope
    holder = socket.assigns.holder
    holder_id = holder && holder.id

    with {:ok, change} <- Policy.get_change(scope, change_id),
         true <- change.target_id == holder_id do
      # The row names the version; the diff needs its document, and the one before.
      made =
        with %{version: version} <-
               made_version(Policy.configurations_for_changes(scope, [change.id]), holder, change),
             {:ok, configuration} <- Policy.get_configuration(scope, holder, version) do
          configuration
        else
          _ -> nil
        end

      before =
        with %{version: version} when version > 1 <- made,
             {:ok, previous} <- Policy.get_configuration(scope, holder, version - 1) do
          previous
        else
          _ -> nil
        end

      document =
        if made do
          line_diff(if(before, do: pretty(before.document), else: ""), pretty(made.document))
        end

      {:ok,
       %{
         id: change.id,
         rules: rule_lines(change),
         document: document && fold(document),
         from: before,
         to: made,
         summary: if(document, do: diff_summary(document), else: gettext("no new version")),
         navigate: made && socket.assigns.base <> "/versions/#{made.version}",
         bytes: made && byte_size(made.document)
       }}
    else
      _ -> :error
    end
  end

  ## Versions

  @views ~w(changes document served)

  @doc """
  One version of the holder for the version page: the configuration, what it is compared
  with (`?compare=`, the one before by default), the view (`?view=`), the lines to show
  and the few versions around it. `:error` when the holder has no such version.
  """
  def version(socket, n, params) do
    scope = socket.assigns.current_scope
    holder = socket.assigns.holder

    with {:ok, configuration} <- Policy.get_configuration(scope, holder, n) do
      # One page of versions serves the newest, the few around this one and the ones to
      # compare with; a version further back than that page has its own page read too.
      newest = Policy.list_configurations(scope, holder, 1)
      latest = List.first(newest.items) || configuration
      size = max(length(newest.items), 1)
      at = div(max(latest.version - configuration.version, 0), size) + 1

      near =
        if at == 1,
          do: newest.items,
          else: Policy.list_configurations(scope, holder, at).items

      changes =
        Map.new(Policy.list_changes(scope, holder, 1).items, &{&1.id, &1})

      view = if params["view"] in @views, do: params["view"], else: "changes"

      compare =
        with n when n != nil <- compare_param(params["compare"], configuration.version),
             {:ok, compare} <- Policy.get_configuration(scope, holder, n) do
          compare
        else
          _ -> nil
        end

      pretty = pretty(configuration.document)

      lines =
        if compare,
          do: line_diff(pretty(compare.document), pretty),
          else: Enum.map(String.split(pretty, "\n"), &{:ctx, &1})

      change = change_of(scope, changes, configuration)

      superseded_by =
        if latest.version > configuration.version do
          Enum.find(near ++ newest.items, &(&1.version == configuration.version + 1)) ||
            case Policy.get_configuration(scope, holder, configuration.version + 1) do
              {:ok, next} -> next
              _ -> nil
            end
        end

      around =
        near
        |> Enum.filter(&(&1.version <= configuration.version + 1))
        |> Enum.take(5)
        |> then(&if(&1 == [], do: [configuration], else: &1))

      {:ok,
       %{
         configuration: configuration,
         current?: latest.version == configuration.version,
         latest: latest.version,
         superseded_by: superseded_by,
         changed_by: People.member(socket.assigns.people, configuration.changed_by_id),
         mode: document_mode(configuration.document),
         mode_source:
           if(latest.version == configuration.version,
             do: Policy.effective(scope, holder).mode_source
           ),
         mode_required_by:
           if(latest.version == configuration.version, do: above_name(socket.assigns[:effective])),
         change_words: change && change_words(change),
         view: view,
         compare: compare,
         compare_options:
           near
           |> Enum.filter(&(&1.version < configuration.version))
           |> then(fn options ->
             if compare && not Enum.any?(options, &(&1.version == compare.version)),
               do: options ++ [compare],
               else: options
           end),
         pretty: pretty,
         lines: lines,
         caption: caption(view, compare, configuration, lines),
         versions:
           for item <- around do
             change = change_of(scope, changes, item)

             %{
               version: item.version,
               digest: item.digest,
               words: (change && change_words(change)) || gettext("First render"),
               who: People.member(socket.assigns.people, item.changed_by_id),
               at: item.rendered_at,
               workspace: holder != nil and change != nil and is_nil(change.target_id)
             }
           end,
         earlier: max(List.last(around).version - 1, 0),
         total: newest.total
       }}
    else
      _ -> :error
    end
  end

  # The mode a served document says: the version's fact, not today's setting.
  defp document_mode(document) do
    case Jason.decode(document) do
      {:ok, %{"security_policy" => %{"egress" => %{"mode" => mode}}}} when is_binary(mode) -> mode
      {:ok, %{"egress" => %{"mode" => mode}}} when is_binary(mode) -> mode
      _ -> nil
    end
  end

  # The change that made a version: from the newest page of the holder's changes when it
  # is there, read by itself when it is older or the workspace's.
  defp change_of(_scope, _changes, %{audit_entry_id: nil}), do: nil

  defp change_of(scope, changes, %{audit_entry_id: id}) do
    with nil <- changes[id],
         {:ok, change} <- Policy.get_change(scope, id) do
      change
    else
      %{} = change -> change
      _ -> nil
    end
  end

  defp compare_param(nil, version) when version > 1, do: version - 1
  defp compare_param(nil, _version), do: nil

  defp compare_param(value, version) do
    case page_param(value) do
      n when n < version -> if(to_string(n) == value, do: n, else: compare_param(nil, version))
      _ -> compare_param(nil, version)
    end
  end

  defp caption("changes", nil, configuration, _lines),
    do: gettext("v%{version}", version: configuration.version)

  defp caption("changes", compare, configuration, lines),
    do:
      gettext("v%{from} → v%{version} · %{summary}",
        from: compare.version,
        version: configuration.version,
        summary: diff_summary(lines)
      )

  defp caption("document", _compare, configuration, _lines),
    do: gettext("v%{version} · indented", version: configuration.version)

  defp caption("served", _compare, configuration, _lines),
    do:
      ngettext(
        "v%{version} · %{number} byte · sha256 over exactly these",
        "v%{version} · %{number} bytes · sha256 over exactly these",
        byte_size(configuration.document),
        version: configuration.version,
        number: Format.number(byte_size(configuration.document))
      )

  @doc """
  The version a holder is served, one read and no document: `{configuration, own?}`, `own?` false when
  a target is served the workspace's baseline. Only for a workspace somebody has changed:
  before that nothing is served, and nothing is read (`nil`).
  """
  def served_version(_scope, _holder, false), do: nil

  def served_version(scope, holder, true) do
    versions = Policy.newest_versions(scope, [nil | List.wrap(holder)])
    own = holder && versions[holder.id]

    cond do
      own -> {own, true}
      versions[nil] -> {versions[nil], is_nil(holder)}
      true -> nil
    end
  end

  @doc "The export of the holder's effective policy, with the scope, version and digest as comments."
  def export(socket, configuration) do
    scope = socket.assigns.current_scope
    holder = socket.assigns.holder
    {:ok, export} = Policy.export(scope, holder)

    subject =
      case holder do
        nil -> gettext("the workspace %{name}", name: scope.workspace.name)
        %{system: system, path: path} -> "#{system}/#{path}"
      end

    slug =
      case holder do
        nil -> scope.workspace.name
        %{path: path} -> path
      end
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 48)
      |> then(&if(&1 == "", do: "qory", else: &1))

    head = export_head(subject, configuration.version, configuration.digest)

    file_name = "#{slug}-policy.yaml"

    %{
      subject: subject,
      workspace: if(is_nil(holder), do: scope.workspace.name),
      version: configuration.version,
      file_name: file_name,
      policy_file: export.policy_file && head <> export.policy_file,
      runner_file: head <> export.runner_file,
      notes: export.notes,
      command: ~s(qory run --local --policy ~/#{file_name} -- -p "…")
    }
  end

  @doc """
  The two comment lines over an exported text. The subject is a system and a path from a
  run's labels, or a workspace's name: whatever breaks a line in YAML is taken out of it,
  so nothing a runner or a person named can become a key of the text an operator pastes.
  """
  def export_head(subject, version, digest) do
    "# " <>
      gettext("Qory policy of %{subject}, version %{version}",
        subject: one_line(subject),
        version: version
      ) <> "\n# #{one_line(digest)}\n"
  end

  defp one_line(text),
    do: text |> to_string() |> String.replace(~r/[\r\n\x{85}\x{2028}\x{2029}]+/u, " ")

  ## Parameters

  @doc "A page number from a query parameter: a small positive integer, or 1."
  def page_param(value) when is_binary(value) and byte_size(value) <= 6 do
    case Integer.parse(value) do
      {page, ""} when page > 0 -> page
      _ -> 1
    end
  end

  def page_param(_value), do: 1

  @doc "A host from `?rule=`: one in the grammar, or nil."
  def rule_param(value) when is_binary(value) do
    value = String.trim(value)
    if Grammar.host?(value), do: value
  end

  def rule_param(_value), do: nil
end
