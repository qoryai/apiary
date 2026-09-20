defmodule ApiaryWeb.PolicyLive.Common do
  @moduledoc """
  What the hive's policy page and a repository's share: the rows of a rules table built
  from `Apiary.Policy`, the composer's state and its events, the history, the version and
  the export of a target, and the words of a change.

  A target is `nil` for the hive's baseline or an `Apiary.Runs.Repository`. Everything is
  read through `Apiary.Policy`; nothing here touches a schema's table.
  """
  use ApiaryWeb, :verified_routes

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
  def mount(socket, target) do
    scope = socket.assigns.current_scope
    if connected?(socket), do: Policy.subscribe(scope)

    socket
    |> assign(
      target: target,
      scope_kind: if(target, do: :repository, else: :hive),
      base: base(target),
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

  def base(nil), do: ~p"/hive/policy"
  def base(%{id: id}), do: ~p"/hive/policy/repositories/#{id}"

  def owner?(%{membership: %{level: :owner}}), do: true
  def owner?(_scope), do: false

  def since, do: DateTime.add(DateTime.utc_now(), -@week, :second)

  # user id => email, of the people of the hive: who added a rule.
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
    # Which repositories the changes of this window name; `:all` once one names the hive.
    touched =
      case {socket.assigns.touched, change} do
        {:all, _} -> :all
        {%MapSet{} = set, %{repository_id: id}} when is_binary(id) -> MapSet.put(set, id)
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

  @doc "The host rules of the hive's page, in the order the card's footer says."
  def hive_rows(rules, socket, locks) do
    for rule <- rules, rule.kind == "host" do
      %{
        id: rule.id,
        action: rule.action,
        host: rule.host,
        paths: rule.paths,
        locked: rule.locked,
        source: if(rule.locked, do: :hive_locked, else: :hive),
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
  def credential_rows(rules, socket, source \\ :hive) do
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
  The effective policy of a repository as rows: one per host rule in force, the rules it
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

  defp source(%{source: :hive, locked: true}), do: :hive_locked
  defp source(%{source: source}), do: source

  defp act(%{source: :hive, locked: true}), do: :open
  defp act(%{source: :hive, action: :allow}), do: :disable
  defp act(%{source: :hive, action: :deny}), do: :allow_here

  defp act(%{source: :repository, action: :deny, overrides: overrides}) do
    if Enum.any?(overrides, &(&1.source == :hive)), do: :restore, else: :remove
  end

  defp act(%{source: :repository}), do: :remove

  defp beaten(loser, winner, people) do
    kind =
      cond do
        winner.locked and loser.source == :repository ->
          :lock

        winner.source == :repository and loser.source == :hive and loser.host == winner.host ->
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
    do: "Locked by #{by} on #{at}. Only an owner can change or unlock it."

  defp locked_tip(_unknown), do: "Locked. Only an owner can change or unlock it."

  @doc """
  Who locked which host, from the newest page of the hive's changes (a page the caller
  has read already): `%{host =>
  %{by:, at:}}`. A lock older than that page is shown without its author.
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

  def handle_event("open_hive_rule", %{"host" => host}, socket) when is_binary(host) do
    {:halt, push_navigate(socket, to: ~p"/hive/policy?#{%{"rule" => host}}")}
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

      case Policy.allow(socket.assigns.current_scope, socket.assigns.target, attrs) do
        {:ok, rule} ->
          {:halt,
           socket
           |> reset_credential()
           |> wrote(
             rule,
             "The credential #{rule.name} is named #{for_target(socket)}.",
             "Credential added."
           )
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
    target = socket.assigns.target
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
        do: Policy.deny(scope, target, attrs),
        else: Policy.allow(scope, target, attrs)

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
        |> wrote(
          rule,
          "#{host} is #{past(action)} #{for_target(socket)}.",
          "Rule added."
        )
        |> then(&if(next == %{}, do: &1, else: read(&1, %{})))
        |> set_fields()
        |> focus("policy-composer-host")

      {:error, error} ->
        refused(socket, error)
    end
  end

  def past("allow"), do: "allowed"
  def past("deny"), do: "denied"

  def target_name(%{assigns: %{target: %{forge: forge, path: path}}}), do: "#{forge}/#{path}"

  def for_target(%{assigns: %{target: nil}}), do: "for the hive"
  def for_target(%{assigns: %{target: %{forge: forge, path: path}}}), do: "for #{forge}/#{path}"

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
        version == before -> " No new version: the document did not change."
        true -> " Version #{version}."
      end

    fresh =
      if rule && version && version != before,
        do: Map.put(socket.assigns.fresh, rule.id, version),
        else: socket.assigns.fresh

    socket
    |> assign(fresh: fresh, write_error: nil)
    |> assign(
      :announce,
      announce <> if(version && version != before, do: " Version #{version}.", else: "")
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
  def would(scope, target, previous \\ nil) do
    case Policy.uncovered(scope, target, since()) do
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

  @doc "The sentence of a change, after its author: rich text."
  def change_sentence(change) do
    diff = Policy.diff(change)

    case {change.action, diff} do
      {"mode_changed", %{mode: {from, to}}} when is_nil(change.repository_id) ->
        ["switched the hive's default mode from #{from} to ", {:b, [to]}]

      {"mode_changed", %{mode: {_from, "inherit"}}} ->
        ["set this repository to ", {:b, ["follow the hive"]}]

      {"mode_changed", %{mode: {_from, to}}} ->
        ["set this repository's mode to ", {:b, [to]}]

      {"mode_changed", _} ->
        ["set the mode"]

      {"rule_added", %{added: [%{"kind" => "credential"} = rule | _]}} ->
        ["added the credential " | credential_chips(rule)]

      {"rule_added", %{added: [rule | _]}} ->
        ["#{past(rule["action"])} ", {:code, rule["host"]} | on_paths(rule)]

      {"rule_removed", %{removed: [%{"kind" => "credential"} = rule | _]}} ->
        ["removed the credential " | credential_chips(rule)]

      {"rule_removed", %{removed: [rule | _]}} ->
        ["removed the #{rule["action"]} rule ", {:code, rule["host"]}]

      {"rule_changed", %{changed: [{old, new} | _]}} ->
        changed_sentence(old, new)

      {"rule_locked", _} ->
        ["locked ", {:code, change.subject}]

      {"rule_unlocked", _} ->
        ["unlocked ", {:code, change.subject}]

      _ ->
        ["changed ", {:code, change.subject || "the policy"}]
    end
  end

  defp changed_sentence(%{"kind" => "credential"}, new),
    do: ["changed the argument of the credential " | credential_chips(new)]

  defp changed_sentence(%{"action" => action} = old, %{"action" => action} = new) do
    if old["paths"] != new["paths"] do
      [
        "changed the paths of ",
        {:code, new["host"]},
        " from ",
        paths_words(old["paths"]),
        " to ",
        paths_words(new["paths"])
      ]
    else
      ["#{if new["locked"], do: "locked", else: "unlocked"} ", {:code, new["host"]}]
    end
  end

  defp changed_sentence(old, new),
    do: ["replaced #{old["action"]} ", {:code, new["host"]}, " with #{new["action"]}"]

  defp credential_chips(%{"name" => name, "argument" => argument}) when is_binary(argument),
    do: [{:code, name}, " ", {:code, argument}]

  defp credential_chips(%{"name" => name}), do: [{:code, name}]

  defp on_paths(%{"paths" => [_ | _] = paths}), do: [" on " | paths_words(paths)]
  defp on_paths(_rule), do: []

  defp paths_words(nil), do: ["every path"]
  defp paths_words([]), do: ["no path"]
  defp paths_words(paths), do: paths |> Enum.map(&{:code, &1}) |> Enum.intersperse(" ")

  @doc "A change in a few plain words, for the versions list and the version's strip."
  def change_words(change) do
    diff = Policy.diff(change)

    case {change.action, diff} do
      {"mode_changed", %{mode: {_from, to}}} when is_nil(change.repository_id) ->
        "Hive's default set to #{to}"

      {"mode_changed", %{mode: {_from, "inherit"}}} ->
        "Set to follow the hive"

      {"mode_changed", %{mode: {_from, to}}} ->
        "Mode set to #{to}"

      {"rule_added", %{added: [%{"kind" => "credential", "name" => name} | _]}} ->
        "Credential #{name}"

      {"rule_added", %{added: [rule | _]}} ->
        "#{String.capitalize(past(rule["action"]))} #{rule["host"]}"

      {"rule_removed", _} ->
        "Removed #{change.subject}"

      {"rule_changed", %{changed: [{%{"action" => a}, %{"action" => a}} | _]}} ->
        "Paths of #{change.subject}"

      {"rule_changed", _} ->
        "Replaced #{change.subject}"

      {"rule_locked", _} ->
        "Locked #{change.subject}"

      {"rule_unlocked", _} ->
        "Unlocked #{change.subject}"

      _ ->
        "Changed"
    end
  end

  @doc "The change in the page's own words, for the rules panel of a diff: `[{:add | :del | :ctx, rich}]`."
  def rule_lines(change) do
    diff = Policy.diff(change)
    rules = change.after["rules"] || []

    mode =
      case diff.mode do
        {from, to} ->
          [{:del, ["Mode ", {:b, [mode_words(from)]}]}, {:add, ["Mode ", {:b, [mode_words(to)]}]}]

        nil ->
          []
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
        do: [{:ctx, ["#{rest} other #{if rest == 1, do: "rule", else: "rules"}: unchanged"]}],
        else: []

    mode ++ removed ++ changed ++ added ++ context
  end

  defp mode_words("inherit"), do: "follow the hive"
  defp mode_words(mode), do: to_string(mode)

  defp rule_words(%{"kind" => "credential"} = rule),
    do: ["Credential " | credential_chips(rule)] ++ locked_words(rule)

  defp rule_words(rule) do
    [String.capitalize(rule["action"] || ""), " ", {:code, rule["host"]}] ++
      if(rule["action"] == "allow", do: [", " | paths_words(rule["paths"])], else: []) ++
      locked_words(rule)
  end

  defp locked_words(%{"locked" => true}), do: [", locked"]
  defp locked_words(_rule), do: []

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
        Enum.take(run, 2) ++ [{:ctx, "      … #{length(run) - 2} more"}]

      run ->
        run
    end)
  end

  @doc "How a diff reads in a few words: 1 line added, 2 lines changed."
  def diff_summary(lines) do
    added = Enum.count(lines, &(elem(&1, 0) == :add))
    removed = Enum.count(lines, &(elem(&1, 0) == :del))

    cond do
      added == 0 and removed == 0 -> "no line changed"
      removed == 0 -> "#{plural(added, "line")} added"
      added == 0 -> "#{plural(removed, "line")} removed"
      added == removed -> "#{plural(added, "line")} changed"
      true -> "#{plural(added, "line")} added, #{removed} removed"
    end
  end

  def plural(count, noun, plural \\ nil)
  def plural(1, noun, _plural), do: "1 #{noun}"
  def plural(n, noun, nil), do: "#{n} #{noun}s"
  def plural(n, _noun, plural), do: "#{n} #{plural}"

  ## History

  @doc "A page of the target's history as the rows of the change list."
  def history(socket, page) do
    scope = socket.assigns.current_scope
    target = socket.assigns.target
    base = socket.assigns.base
    changes = Policy.list_changes(scope, target, page)
    # One read for the page: the versions its changes made, without their documents.
    versions = Policy.configurations_for_changes(scope, Enum.map(changes.items, & &1.id))

    rows =
      for change <- changes.items do
        made = made_version(versions, target, change)
        query = if changes.page > 1, do: %{"page" => changes.page}, else: %{}

        %{
          id: change.id,
          sentence: change_sentence(change),
          origin: origin(change, made),
          who: change.changed_by && change.changed_by.email,
          at: change.inserted_at,
          version: made && made.version,
          digest: made && made.digest,
          hive: false,
          patch: base <> "/history?" <> URI.encode_query(Map.put(query, "change", change.id)),
          close:
            base <> "/history" <> if(query == %{}, do: "", else: "?" <> URI.encode_query(query))
        }
      end

    %{rows: rows, page: changes.page, pages: changes.pages, total: changes.total}
  end

  # The configuration a change made for the target, or nil when the bytes stayed the same.
  defp made_version(versions, target, change) do
    target_id = target && target.id
    Enum.find(versions[change.id] || [], &(&1.repository_id == target_id))
  end

  defp origin(%{action: "mode_changed", repository_id: id} = change, made) when id != nil do
    case {change.before["mode"], change.after["mode"], made} do
      {"inherit", _to, nil} ->
        "Its own from now on. The hive's default is the same, so the document did not change."

      {"inherit", _to, _made} ->
        "Its own from now on. It followed the hive's default."

      {from, "inherit", nil} ->
        "It #{from}d on its own. The hive's default is the same, so the document did not change."

      {from, "inherit", _made} ->
        "It #{from}d on its own."

      _ ->
        nil
    end
  end

  defp origin(%{action: action}, nil) when action in ~w(rule_locked rule_unlocked),
    do: "The lock holds against repositories. The document did not change."

  defp origin(_change, nil), do: "The document did not list it, so its bytes did not change."
  defp origin(_change, _made), do: nil

  @doc "The diff of one change of the target: its rules in words, its document in lines."
  def change_diff(socket, change_id) do
    scope = socket.assigns.current_scope
    target = socket.assigns.target
    target_id = target && target.id

    with {:ok, change} <- Policy.get_change(scope, change_id),
         true <- change.repository_id == target_id do
      # The row names the version; the diff needs its document, and the one before.
      made =
        with %{version: version} <-
               made_version(Policy.configurations_for_changes(scope, [change.id]), target, change),
             {:ok, configuration} <- Policy.get_configuration(scope, target, version) do
          configuration
        else
          _ -> nil
        end

      before =
        with %{version: version} when version > 1 <- made,
             {:ok, previous} <- Policy.get_configuration(scope, target, version - 1) do
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
         summary: if(document, do: diff_summary(document), else: "no new version"),
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
  One version of the target for the version page: the configuration, what it is compared
  with (`?compare=`, the one before by default), the view (`?view=`), the lines to show
  and the few versions around it. `:error` when the target has no such version.
  """
  def version(socket, n, params) do
    scope = socket.assigns.current_scope
    target = socket.assigns.target

    with {:ok, configuration} <- Policy.get_configuration(scope, target, n) do
      # One page of versions serves the newest, the few around this one and the ones to
      # compare with; a version further back than that page has its own page read too.
      newest = Policy.list_configurations(scope, target, 1)
      latest = List.first(newest.items) || configuration
      size = max(length(newest.items), 1)
      at = div(max(latest.version - configuration.version, 0), size) + 1

      near =
        if at == 1,
          do: newest.items,
          else: Policy.list_configurations(scope, target, at).items

      changes =
        Map.new(Policy.list_changes(scope, target, 1).items, &{&1.id, &1})

      view = if params["view"] in @views, do: params["view"], else: "changes"

      compare =
        with n when n != nil <- compare_param(params["compare"], configuration.version),
             {:ok, compare} <- Policy.get_configuration(scope, target, n) do
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
            case Policy.get_configuration(scope, target, configuration.version + 1) do
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
             do: Policy.effective(scope, target).mode_source
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
               words: (change && change_words(change)) || "First render",
               who: socket.assigns.people[item.changed_by_id],
               at: item.rendered_at,
               hive: target != nil and change != nil and is_nil(change.repository_id)
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

  # The change that made a version: from the newest page of the target's changes when it
  # is there, read by itself when it is older or the hive's.
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

  defp caption("changes", nil, configuration, _lines), do: "v#{configuration.version}"

  defp caption("changes", compare, configuration, lines),
    do: "v#{compare.version} → v#{configuration.version} · #{diff_summary(lines)}"

  defp caption("document", _compare, configuration, _lines),
    do: "v#{configuration.version} · indented"

  defp caption("served", _compare, configuration, _lines),
    do:
      "v#{configuration.version} · #{byte_size(configuration.document)} bytes · sha256 over exactly these"

  @doc """
  The version a target is served, one read and no document: `{configuration, own?}`, `own?` false when
  a repository is served the hive's baseline. Only for a hive somebody has changed: before
  that nothing is served, and nothing is read (`nil`).
  """
  def served_version(_scope, _target, false), do: nil

  def served_version(scope, target, true) do
    versions = Policy.newest_versions(scope, [nil | List.wrap(target)])
    own = target && versions[target.id]

    cond do
      own -> {own, true}
      versions[nil] -> {versions[nil], is_nil(target)}
      true -> nil
    end
  end

  @doc "The export of the target's effective policy, with the scope, version and digest as comments."
  def export(socket, configuration) do
    scope = socket.assigns.current_scope
    target = socket.assigns.target
    {:ok, export} = Policy.export(scope, target)

    subject =
      case target do
        nil -> "the hive #{scope.hive.name}"
        %{forge: forge, path: path} -> "#{forge}/#{path}"
      end

    slug =
      case target do
        nil -> scope.hive.name
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
      hive: if(is_nil(target), do: scope.hive.name),
      version: configuration.version,
      file_name: file_name,
      policy_file: export.policy_file && head <> export.policy_file,
      runner_file: head <> export.runner_file,
      notes: export.notes,
      command: ~s(qory run --local --policy ~/#{file_name} -- -p "…")
    }
  end

  @doc """
  The two comment lines over an exported text. The subject is a forge and a path from a
  run's labels, or a hive's name: whatever breaks a line in YAML is taken out of it, so
  nothing a runner or a person named can become a key of the text an operator pastes.
  """
  def export_head(subject, version, digest) do
    "# Qory policy of #{one_line(subject)}, version #{version}\n# #{one_line(digest)}\n"
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
