defmodule ApiaryWeb.PolicyLive.Common do
  @moduledoc """
  What the workspace's policy page and a target's share: the rows of a rules table built
  from `Apiary.Policy`, the composer's state and its events, the history, the version and
  the export of a holder, and the words of a change.

  A holder is `nil` for the workspace's baseline or an `Apiary.Runs.Target`. Everything is
  read through `Apiary.Policy`; nothing here touches a schema's table.
  """
  use ApiaryWeb, :verified_routes
  use Gettext, backend: ApiaryWeb.Gettext

  import ApiaryWeb.RichText
  import Phoenix.Component, only: [assign: 2, assign: 3, to_form: 2]
  import Phoenix.LiveView

  alias Apiary.Organisations
  alias Apiary.Policy
  alias Apiary.Policy.Grammar
  alias ApiaryWeb.PolicyComponents
  alias ApiaryWeb.PolicyLive.Reading

  @week 7 * 24 * 3600
  @coalesce 250

  ## Mount

  @doc "The assigns every policy page starts from, and the one subscription."
  def mount(socket, holder) do
    scope = socket.assigns.current_scope
    if connected?(socket), do: Policy.subscribe(scope)

    socket
    |> assign(
      holder: holder,
      scope_kind: if(holder, do: :target, else: :workspace),
      base: base(holder),
      owner?: owner?(scope),
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

  def base(nil), do: ~p"/workspace/policy"
  def base(%{id: id}), do: ~p"/workspace/policy/targets/#{id}"

  def owner?(%{membership: %{level: :owner}}), do: true
  def owner?(_scope), do: false

  def since, do: DateTime.add(DateTime.utc_now(), -@week, :second)

  # user id => email, of the people of the workspace: who added a rule.
  defp people(scope) do
    for %{user: %{id: id, email: email}} <- Organisations.list_members(scope),
        into: %{},
        do: {id, email}
  end

  @doc "The local part of an email: dana of dana@example.com."
  def local(nil), do: nil
  def local(email), do: email |> String.split("@") |> hd()

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

  @doc "The host rules of the workspace's page, in the order the card's footer says."
  def workspace_rows(rules, socket, locks) do
    for rule <- rules, rule.kind == "host" do
      %{
        id: rule.id,
        action: rule.action,
        host: rule.host,
        paths: rule.paths,
        locked: rule.locked,
        source: if(rule.locked, do: :workspace_locked, else: :workspace),
        by: local(socket.assigns.people[rule.created_by_id]),
        at: rule.inserted_at,
        locked_tip: locked_tip(locks[rule.host]),
        can_change: socket.assigns.owner? or not rule.locked,
        act: nil,
        beaten: []
      }
    end
    |> sort_rows()
  end

  @doc "The credentials of a rules list, as the credentials table takes them."
  def credential_rows(rules, socket, source \\ :workspace) do
    for rule <- rules, rule.kind == "credential" do
      %{
        id: rule.id,
        action: rule.action,
        name: rule.name,
        argument: rule.argument,
        locked: rule.locked,
        source: source,
        by: local(socket.assigns.people[rule.created_by_id]),
        at: rule.inserted_at,
        can_change: socket.assigns.owner? or not rule.locked
      }
    end
  end

  @doc """
  The effective policy of a target as rows: one per host rule in force, the rules it
  beat hung under it.
  """
  def effective_rows(%Policy.Effective{entries: entries}, socket) do
    people = socket.assigns.people

    for %{kind: :host, in_force: true} = entry <- entries do
      %{
        id: entry.rule.id,
        action: to_string(entry.action),
        host: entry.host,
        paths: entry.paths,
        locked: entry.locked,
        source: source(entry),
        by: local(people[entry.rule.created_by_id]),
        at: entry.rule.inserted_at,
        locked_tip: nil,
        can_change: true,
        act: act(entry),
        beaten: Enum.map(entry.overrides, &beaten(&1, entry, people))
      }
    end
    |> sort_rows()
  end

  defp source(%{source: :workspace, locked: true}), do: :workspace_locked
  defp source(%{source: source}), do: source

  defp act(%{source: :workspace, locked: true}), do: :open
  defp act(%{source: :workspace, action: :allow}), do: :disable
  defp act(%{source: :workspace, action: :deny}), do: :allow_here

  defp act(%{source: :target, action: :deny, overrides: overrides}) do
    if Enum.any?(overrides, &(&1.source == :workspace)), do: :restore, else: :remove
  end

  defp act(%{source: :target}), do: :remove

  defp beaten(loser, winner, people) do
    kind =
      cond do
        winner.locked and loser.source == :target ->
          :lock

        winner.source == :target and loser.source == :workspace and loser.host == winner.host ->
          :override

        true ->
          :cover
      end

    %{
      id: loser.rule.id,
      action: to_string(loser.action),
      host: loser.host,
      source: loser.source,
      kind: kind,
      by: local(people[loser.rule.created_by_id]),
      at: loser.rule.inserted_at,
      winner_by: local(people[winner.rule.created_by_id]),
      winner_at: winner.rule.inserted_at
    }
  end

  # Locked rules first, then deny, then allow; inside each by the host's labels read from
  # the right, so a suffix sits beside the hosts below it.
  defp sort_rows(rows) do
    Enum.sort_by(rows, fn row ->
      {not row.locked, row.action != "deny", from_the_right(row.host)}
    end)
  end

  # A name before the suffix above it, the suffix before the hosts below it.
  defp from_the_right(host) do
    labels = host |> String.trim_leading("*.") |> String.split(".") |> Enum.reverse()
    if Grammar.wildcard?(host), do: labels ++ ["*"], else: labels
  end

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
         by: change.changed_by && change.changed_by.email,
         at: ApiaryWeb.CoreComponents.short_date(change.inserted_at)
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
        owner: socket.assigns.owner?,
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
        by: local(people[rule.created_by_id]),
        at: PolicyComponents.day(rule.inserted_at)
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

    {:halt, socket |> read(values) |> set_fields() |> focus(field)}
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
    {:halt, push_navigate(socket, to: ~p"/workspace/policy?#{%{"rule" => host}}")}
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

    result =
      if action == "deny",
        do: Policy.deny(scope, holder, attrs),
        else: Policy.allow(scope, holder, attrs)

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
  `123.example is allowed for the workspace.`, `… is denied for acme/shop.`
  """
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
    socket = socket.assigns.reload.(socket)
    version = socket.assigns[:version] && socket.assigns.version.version

    tail =
      cond do
        is_nil(version) -> ""
        version == before -> " " <> gettext("No new version: the document did not change.")
        true -> " " <> gettext("Version %{version}.", version: version)
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

  ## The words of a change (pf6)

  @doc """
  The sentence of a change, its author first: rich text. `who` is the author's email, or
  nil when the author has left.
  """
  def change_sentence(change, who) do
    who = {:b, who || gettext("Someone who has left")}
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
           [ngettext("%{count} other rule: unchanged", "%{count} other rules: unchanged", rest)]}
        ],
        else: []

    mode ++ removed ++ changed ++ added ++ context
  end

  defp mode_line("inherit"),
    do: rich_gettext("Mode %{mode}", mode: {:b, gettext("follow the workspace")})

  defp mode_line(mode), do: rich_gettext("Mode %{mode}", mode: {:b, to_string(mode)})

  defp rule_words(%{"kind" => "credential"} = rule) do
    chips = credential_chips(rule)

    if rule["locked"],
      do: rich_gettext("Credential %{credential}, locked", credential: chips),
      else: rich_gettext("Credential %{credential}", credential: chips)
  end

  defp rule_words(%{"action" => "allow"} = rule) do
    host = {:code, rule["host"]}
    paths = paths_words(rule["paths"])

    if rule["locked"],
      do: rich_gettext("Allow %{host}, %{paths}, locked", host: host, paths: paths),
      else: rich_gettext("Allow %{host}, %{paths}", host: host, paths: paths)
  end

  defp rule_words(%{"action" => "deny"} = rule) do
    host = {:code, rule["host"]}

    if rule["locked"],
      do: rich_gettext("Deny %{host}, locked", host: host),
      else: rich_gettext("Deny %{host}", host: host)
  end

  defp rule_words(rule) do
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
          [{:ctx, "      " <> gettext("… %{count} more", count: length(run) - 2)}]

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
        ngettext("%{count} line added", "%{count} lines added", added)

      added == 0 ->
        ngettext("%{count} line removed", "%{count} lines removed", removed)

      added == removed ->
        ngettext("%{count} line changed", "%{count} lines changed", added)

      true ->
        ngettext(
          "%{count} line added, %{removed} removed",
          "%{count} lines added, %{removed} removed",
          added,
          removed: removed
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

    rows =
      for change <- changes.items do
        made = made_version(versions, holder, change)
        query = if changes.page > 1, do: %{"page" => changes.page}, else: %{}

        %{
          id: change.id,
          sentence: change_sentence(change, change.changed_by && change.changed_by.email),
          origin: origin(change, made),
          who: change.changed_by && change.changed_by.email,
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
         changed_by: socket.assigns.people[configuration.changed_by_id],
         mode: document_mode(configuration.document),
         mode_source:
           if(latest.version == configuration.version,
             do: Policy.effective(scope, holder).mode_source
           ),
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
               who: socket.assigns.people[item.changed_by_id],
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
  defp change_of(_scope, _changes, %{policy_change_id: nil}), do: nil

  defp change_of(scope, changes, %{policy_change_id: id}) do
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
        "v%{version} · %{count} byte · sha256 over exactly these",
        "v%{version} · %{count} bytes · sha256 over exactly these",
        byte_size(configuration.document),
        version: configuration.version
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
