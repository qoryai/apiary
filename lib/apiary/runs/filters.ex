defmodule Apiary.Runs.Filters do
  @moduledoc """
  What the runs list and the workspace's connections page are filtered by, read from query
  parameters and written back to them, so that every view is a URL; and the query a reader
  types, qualifiers and free text, read into the same filters.

  `parse/2` never fails: a value it does not know is dropped, and `to_params/1` of the
  result is the canonical query, which the page patches to when it differs from what it was
  given. Nothing here becomes an atom from input, and nothing is interpolated into a query:
  the values are compared as strings by `Apiary.Runs`.

  The defaults are left out of the URL (`new/1`). The runs list has no time range unless
  the reader sets one (`since` is `all`), sorts newest first and shows 50 runs a page. The
  workspace's connections are an aggregate over every connection in range, so their range is
  bounded: the last fourteen days unless set, which is said as a token (`seen:14d`) like
  any other range, `since=90d` the widest, which taking the range away sets, and dates
  cover at most 90 days, counted back from `to` (or on from `from` when only it is given);
  they sort the denied destinations first. The connections take `tools=1` for tool invocations only:
  requests that name a tool and were allowed (`Apiary.Runs.tool_invocation?/2`), never one
  a path rule refused.

  A target is two parameters, `system` and `target` (the path), because either may
  hold any character, a colon included; `target=none` without a `system` is "no target",
  and a `target` without a `system` is that path on every system the workspace has it on.
  `target_params/2` writes them, for every link to a filtered page.

  `q` is the free text of the query: the runs whose id starts with it, or whose task or
  target holds it; the destinations whose host or path holds it. `apply_query/3` reads what
  the reader typed: `qualifier:value` words set the filters the URL carries (`repo:` or
  `target:`, `state:`, `task:`, `runtime:`, `host:`, `key:`, `node:`, `started:` and
  `denied:` on the runs list; `repo:`, `host:`, `decision:`, `tools:` and `seen:` on the connections), and
  the other words are `q`. A value in double quotes may hold spaces. A word whose qualifier
  the page does not know is free text; a qualifier it knows with a value it cannot read is
  refused and named. `tokens/2` writes the filters back as those words.

  A value that is present and refused (not one the page offers, not a string, longer than
  the column it is compared with, or holding a control character, which Postgres would
  refuse) is named in `dropped`, so the page can say that the link was not read in full
  instead of silently showing an unfiltered list.
  """

  use Gettext, backend: ApiaryWeb.Gettext

  alias Apiary.Runs.Run

  # The three families every surface reads the states as, in the order they are shown.
  # `closed` is stopped by the workspace, not a failure of the run, and sits with the bad
  # endings for scanning. Only their states go in a URL:
  # `state=failed,timed_out,lost,closed`. The three families every surface counts runs in
  # (`Apiary.Runs.Run`): one definition.
  @families [
    %{key: "alive", label: gettext_noop("Alive"), states: Run.alive_states()},
    %{key: "ended_well", label: gettext_noop("Ended well"), states: Run.ended_well_states()},
    %{key: "ended_badly", label: gettext_noop("Ended badly"), states: Run.ended_badly_states()}
  ]
  @family_keys Enum.map(@families, & &1.key)
  @ranges %{runs: ~w(1h 24h 7d 14d 30d all), connections: ~w(1h 24h 7d 14d 30d 90d)}
  @default_since %{runs: "all", connections: "14d"}
  # The widest window of the connections: taking their range away sets it.
  @widest_since "90d"
  @sorts %{runs: ~w(newest oldest longest denials), connections: ~w(denied recent runs attempts)}
  @pers [25, 50, 100]
  @default_per 50
  @max_window_days 90
  @decisions ~w(allowed denied)
  # What the fold stores of a label, a runtime or a host, in bytes.
  @max_text 1024
  # The free text of a query: what `Apiary.Runs.like/1` matches.
  @max_q 256
  @max_page 100_000

  # The qualifiers a page reads, by the word typed; `repo` is the software domain's word,
  # `target` the engine's, and both are read on every page.
  @qualifiers %{
    runs: %{
      "repo" => :target,
      "repository" => :target,
      "target" => :target,
      "state" => :state,
      "task" => :task,
      "runtime" => :runtime,
      "host" => :host,
      "key" => :key,
      "node" => :node,
      "started" => :started,
      "denied" => :denied,
      "denials" => :denied
    },
    connections: %{
      "repo" => :target,
      "repository" => :target,
      "target" => :target,
      "host" => :host,
      "decision" => :decision,
      "tools" => :tools,
      "tool" => :tools,
      "seen" => :started
    }
  }

  defstruct kind: :runs,
            states: [],
            target: nil,
            task: nil,
            runtime: nil,
            host: nil,
            key: nil,
            node: nil,
            q: nil,
            since: "all",
            from: nil,
            to: nil,
            denials: false,
            decision: nil,
            tools: false,
            sort: "newest",
            per: @default_per,
            page: 1,
            dropped: []

  @type target :: nil | :none | {String.t(), String.t()} | {nil, String.t()}

  @type t :: %__MODULE__{
          kind: :runs | :connections,
          states: [String.t()],
          target: target(),
          task: nil | :none | String.t(),
          runtime: nil | String.t(),
          host: nil | String.t(),
          key: nil | String.t(),
          node: nil | String.t(),
          q: nil | String.t(),
          since: nil | String.t(),
          from: nil | Date.t(),
          to: nil | Date.t(),
          denials: boolean(),
          decision: nil | String.t(),
          tools: boolean(),
          sort: String.t(),
          per: pos_integer(),
          page: pos_integer(),
          dropped: [String.t()]
        }

  @doc "The filters of a page with nothing set: its defaults."
  @spec new(:runs | :connections) :: t()
  def new(kind \\ :runs) when kind in [:runs, :connections] do
    %__MODULE__{kind: kind, since: @default_since[kind], sort: hd(@sorts[kind])}
  end

  @doc "The widest window the workspace's connections are aggregated over, in days."
  def max_window_days, do: @max_window_days

  @doc "The page sizes the runs list offers."
  def pers, do: @pers

  @doc "The orders a page offers, the default first: `newest`, `oldest`, `longest`, `denials` on the runs list; `denied`, `recent`, `runs`, `attempts` on the connections."
  def sorts(kind \\ :runs), do: @sorts[kind]

  @typedoc "A family of states: its key, the heading it is shown under and its states."
  @type family :: %{key: String.t(), label: String.t(), states: [String.t()]}

  @doc """
  The three families the states read as, in the order they are shown: alive (`pending`,
  `running`), ended well (`succeeded`) and ended badly (`failed`, `timed_out`, `lost`,
  `closed`). Every state is in exactly one. The labels are in the domain's words:
  translated here, at call time, because the list is made at compile time.
  """
  @spec families() :: [family()]
  def families,
    do: Enum.map(@families, &%{&1 | label: Gettext.gettext(ApiaryWeb.Gettext, &1.label)})

  @doc "The states of a family, by its key; nil for a key that is not one."
  @spec family_states(String.t()) :: [String.t()] | nil
  def family_states(key), do: Enum.find_value(@families, &(&1.key == key and &1.states))

  @doc """
  The keys of the families these states are, in the families' order, when the states are
  exactly one or more whole families; nil otherwise (a part of a family, or nothing). This
  is what lets a token and the empty state say "ended badly" for the four states.
  """
  @spec families_of([String.t()]) :: [String.t()] | nil
  def families_of(states) when is_list(states) do
    chosen = MapSet.new(states)
    whole = Enum.filter(@families, fn family -> Enum.all?(family.states, &(&1 in chosen)) end)
    covered = whole |> Enum.flat_map(& &1.states) |> MapSet.new()

    if whole != [] and MapSet.equal?(chosen, covered), do: Enum.map(whole, & &1.key)
  end

  @doc "The time ranges a page offers, as `{label, value}`; the runs list's first is every run."
  def ranges(kind \\ :runs)

  def ranges(:runs),
    do: [
      {gettext("Any time"), "all"},
      {gettext("Last hour"), "1h"},
      {gettext("Last 24 hours"), "24h"},
      {gettext("Last 7 days"), "7d"},
      {gettext("Last 14 days"), "14d"},
      {gettext("Last 30 days"), "30d"}
    ]

  def ranges(:connections),
    do: tl(ranges(:runs)) ++ [{gettext("Last 90 days"), "90d"}]

  @doc "Reads the parameters of the runs list (`:runs`) or the workspace's connections (`:connections`)."
  @spec parse(map(), :runs | :connections) :: t()
  def parse(params, kind \\ :runs) when is_map(params) and kind in [:runs, :connections] do
    {from, d1} = read(params, "from", &date/1)
    {to, d2} = read(params, "to", &date/1)
    {from, to} = if from && to && Date.compare(from, to) == :gt, do: {to, from}, else: {from, to}
    {from, to} = clamp(from, to, kind)

    {target, d3} = target(params)
    {host, d4} = read(params, "host", &text/1)
    {since, d5} = read(params, "since", &one_of(&1, @ranges[kind]))
    {page, d6} = read(params, "page", &page/1)
    {q, d7} = read(params, "q", &query_text/1)
    {sort, d8} = read(params, "sort", &one_of(&1, @sorts[kind]))

    filters = %__MODULE__{
      new(kind)
      | target: target,
        host: host,
        from: from,
        to: to,
        since: if(from || to, do: nil, else: since || @default_since[kind]),
        q: q,
        sort: sort || hd(@sorts[kind]),
        page: page || 1,
        dropped: d1 ++ d2 ++ d3 ++ d4 ++ d5 ++ d6 ++ d7 ++ d8
    }

    case kind do
      :runs ->
        {states, d9} = states(params)
        {task, d10} = read(params, "task", &none_or_text/1)
        {runtime, d11} = read(params, "runtime", &text/1)
        {denials, d12} = read(params, "denials", &if(&1 == "1", do: true))
        {key, d13} = read(params, "key", &text/1)
        {per, d14} = read(params, "per", &per/1)
        {node, d15} = read(params, "node", &text/1)

        %{
          filters
          | states: states,
            task: task,
            runtime: runtime,
            denials: denials == true,
            key: key,
            node: node,
            per: per || @default_per,
            dropped: filters.dropped ++ d9 ++ d10 ++ d11 ++ d12 ++ d13 ++ d14 ++ d15
        }

      :connections ->
        {decision, d9} = read(params, "decision", &one_of(&1, @decisions))
        {tools, d10} = read(params, "tools", &if(&1 == "1", do: true))

        %{
          filters
          | decision: decision,
            tools: tools == true,
            dropped: filters.dropped ++ d9 ++ d10
        }
    end
  end

  # The value of a parameter as `reader` reads it, and the parameter's name when it was
  # there and was refused.
  defp read(params, name, reader) do
    case Map.fetch(params, name) do
      :error ->
        {nil, []}

      {:ok, raw} ->
        case reader.(raw) do
          nil -> {nil, [name]}
          value -> {value, []}
        end
    end
  end

  @doc "The canonical query of the filters: string keys, defaults left out."
  @spec to_params(t()) :: %{optional(String.t()) => String.t()}
  def to_params(%__MODULE__{kind: kind} = f) do
    [
      {"state", f.states != [] && Enum.join(f.states, ",")},
      {"system", system_param(f.target)},
      {"target", target_param(f.target)},
      {"task", if(f.task == :none, do: "none", else: f.task)},
      {"runtime", f.runtime},
      {"host", f.host},
      {"key", f.key},
      {"node", f.node},
      {"q", f.q},
      {"since", f.since not in [nil, @default_since[kind]] && f.since},
      {"from", f.from && Date.to_iso8601(f.from)},
      {"to", f.to && Date.to_iso8601(f.to)},
      {"denials", f.denials && "1"},
      {"decision", f.decision},
      {"tools", f.tools && "1"},
      {"sort", f.sort != hd(@sorts[kind]) && f.sort},
      {"per", f.per != @default_per && Integer.to_string(f.per)},
      {"page", f.page > 1 && Integer.to_string(f.page)}
    ]
    |> Enum.filter(fn {_key, value} -> is_binary(value) end)
    |> Map.new()
  end

  @doc """
  Whether anything narrows the list: a range counts when it is not the page's default. The
  order and the page size narrow nothing.
  """
  def any?(%__MODULE__{kind: kind} = f) do
    f.states != [] or f.target != nil or f.task != nil or f.runtime != nil or f.host != nil or
      f.key != nil or f.node != nil or f.q != nil or f.since != @default_since[kind] or f.denials or
      f.decision != nil or f.tools
  end

  @doc "Whether the range is one the reader set: not the page's default window."
  @spec any_range?(t()) :: boolean
  def any_range?(%__MODULE__{kind: kind} = f),
    do: f.from != nil or f.to != nil or f.since != @default_since[kind]

  @doc "The filters with no filter set: the order and the page size stay, the page and the rest go."
  def clear(%__MODULE__{kind: kind, sort: sort, per: per}),
    do: %{new(kind) | sort: sort, per: per}

  @doc "Sets fields and returns to page 1, which every change of a filter does."
  def put(%__MODULE__{} = f, changes), do: struct!(%{f | page: 1, dropped: []}, changes)

  @doc "The filters without what `parse/2` noted: what two views are compared by."
  def same?(%__MODULE__{} = a, %__MODULE__{} = b), do: %{a | dropped: []} == %{b | dropped: []}

  @doc """
  The filters after a change in a section of the Filter menu: `form` is what the section's
  form sends, the name of the filter in `_filter` and its fields. Read through `parse/2` like
  a URL, so a value the page did not offer is dropped all the same. Returns to page 1.

  The State section's headings are checkboxes named `family_<key>` (value `1`). When the
  change came from one (`_target`), the states are the form's `state` boxes plus the
  family's states if the heading is checked, minus them if not; so the heading works
  without JavaScript, and the same when the page's script has already ticked the family's
  boxes. The URL still says the states and never a family.
  """
  @spec change(t(), map()) :: t()
  def change(%__MODULE__{} = f, %{"_filter" => name} = form) do
    current = f |> to_params() |> Map.delete("page")

    changed =
      case name do
        "state" ->
          states = form["state"] |> List.wrap() |> Enum.filter(&is_binary/1)

          states =
            case form["_target"] do
              ["family_" <> key] when key in @family_keys ->
                toggle_family(states, key, form["family_#{key}"] in ["1", "on", "true"])

              _state_box ->
                states
            end

          Map.put(current, "state", Enum.join(states, ","))

        "since" ->
          if form["_target"] in [["from"], ["to"]] do
            current |> Map.delete("since") |> Map.merge(Map.take(form, ["from", "to"]))
          else
            current |> Map.drop(["from", "to"]) |> Map.merge(Map.take(form, ["since"]))
          end

        "target" ->
          current
          |> Map.drop(["system", "target"])
          |> Map.merge(target_from_value(form["target"]))

        name when name in ~w(task runtime host key) ->
          Map.merge(current, Map.take(form, [name]))

        name when name in ~w(denials tools) ->
          if form[name] in ["1", "on", "true"],
            do: Map.put(current, name, "1"),
            else: Map.delete(current, name)

        _other ->
          current
      end

    parse(changed, f.kind)
  end

  def change(%__MODULE__{} = f, _form), do: f

  defp toggle_family(states, key, true), do: Enum.uniq(states ++ family_states(key))
  defp toggle_family(states, key, false), do: states -- family_states(key)

  ## The query

  @doc """
  The filters after the reader's query: each `qualifier:value` word sets its filter in
  place of what it held, and the rest of the words, joined by one space, are `q` (none when
  there are none). Returns `{filters, refused}`: `refused` holds the words whose qualifier
  the page knows and whose value it could not read, as they were typed. Back to page 1.

  `resolve:` is how a `repo:` value becomes a target: a function of the text that answers
  `{system, path}`, `{nil, path}` (the path on every system) or nil (refused); without it
  the text is a path on every system. `Apiary.Runs.resolve_target/2` is the page's.
  """
  @spec apply_query(t(), String.t(), keyword) :: {t(), [String.t()]}
  def apply_query(%__MODULE__{kind: kind} = f, text, opts \\ []) when is_binary(text) do
    resolve = Keyword.get(opts, :resolve, &path_everywhere/1)
    current = f |> to_params() |> Map.drop(["page", "q"])

    {params, free, refused} =
      text
      |> words()
      |> Enum.reduce({current, [], []}, fn word, {params, free, refused} ->
        case qualifier(word, kind) do
          {qualifier, value} ->
            case query_params(qualifier, value, kind, resolve) do
              {:ok, drop, put} ->
                {params |> Map.drop(drop) |> Map.merge(put), free, refused}

              :error ->
                {params, free, [word | refused]}
            end

          nil ->
            {params, [unquote_word(word) | free], refused}
        end
      end)

    free = free |> Enum.reverse() |> Enum.reject(&(&1 == "")) |> Enum.join(" ")
    params = if free == "", do: params, else: Map.put(params, "q", free)
    filters = parse(params, kind)

    # The qualifiers were read as the parse reads them; what it may still refuse is free
    # text too long for a query, named by its start.
    refused =
      if "q" in filters.dropped,
        do: Enum.reverse(refused) ++ [String.slice(free, 0, 24) <> "…"],
        else: Enum.reverse(refused)

    {%{filters | dropped: []}, refused}
  end

  # The words of a query: runs of anything but white space, a stretch in double quotes kept
  # whole, so `task:"Fix the build"` is one word.
  defp words(text) do
    ~r/(?:"[^"]*"?|[^\s"])+/u
    |> Regex.scan(String.slice(text, 0, 2048))
    |> Enum.map(&hd/1)
  end

  defp qualifier(word, kind) do
    with [_, name, value] <- Regex.run(~r/\A([A-Za-z]+):(.*)\z/su, word),
         qualifier when not is_nil(qualifier) <- @qualifiers[kind][String.downcase(name)] do
      {qualifier, unquote_word(value)}
    else
      _ -> nil
    end
  end

  defp unquote_word(word), do: word |> String.replace("\"", "") |> String.trim()

  # What a qualifier does to the parameters: those it drops, and those it puts.
  defp query_params(_qualifier, "", _kind, _resolve), do: {:ok, [], %{}}

  defp query_params(:target, value, _kind, resolve) do
    target =
      if String.downcase(value) == "none", do: :none, else: text(value) && resolve.(value)

    case target do
      nil -> :error
      target -> {:ok, ["system", "target"], target_params(target)}
    end
  end

  defp query_params(:state, value, _kind, _resolve) do
    states =
      value
      |> String.split(",", trim: true)
      |> Enum.map(&(&1 |> String.downcase() |> String.replace(~r/[\s-]/, "_")))
      |> Enum.map(fn word ->
        cond do
          word in Run.states() -> [word]
          states = family_states(word) -> states
          true -> nil
        end
      end)

    if states != [] and Enum.all?(states),
      do: {:ok, ["state"], %{"state" => states |> List.flatten() |> Enum.uniq() |> order()}},
      else: :error
  end

  defp query_params(:task, value, _kind, _resolve) do
    if String.downcase(value) == "none" or text(value),
      do:
        {:ok, ["task"],
         %{"task" => if(String.downcase(value) == "none", do: "none", else: value)}},
      else: :error
  end

  defp query_params(name, value, _kind, _resolve) when name in [:runtime, :host, :key, :node] do
    if text(value),
      do: {:ok, [Atom.to_string(name)], %{Atom.to_string(name) => value}},
      else: :error
  end

  defp query_params(:started, value, kind, _resolve) do
    case range(String.downcase(value), kind) do
      nil -> :error
      put -> {:ok, ["since", "from", "to"], put}
    end
  end

  defp query_params(name, value, _kind, _resolve) when name in [:denied, :tools] do
    param = if name == :denied, do: "denials", else: "tools"

    case yes_no(value) do
      true -> {:ok, [param], %{param => "1"}}
      false -> {:ok, [param], %{}}
      nil -> :error
    end
  end

  defp query_params(:decision, value, _kind, _resolve) do
    case String.downcase(value) do
      decision when decision in @decisions -> {:ok, ["decision"], %{"decision" => decision}}
      "all" -> {:ok, ["decision"], %{}}
      _other -> :error
    end
  end

  # The states in the order every page lists them.
  defp order(states), do: Run.states() |> Enum.filter(&(&1 in states)) |> Enum.join(",")

  defp yes_no(value) do
    case String.downcase(value) do
      yes when yes in ~w(yes true 1 y) -> true
      no when no in ~w(no false 0 n) -> false
      _other -> nil
    end
  end

  # A range as a qualifier writes it: a preset (`7d`), a day (`2026-09-01`), from a day
  # on (`>=2026-09-01`, or `>2026-08-31`), up to a day (`<=2026-09-01`, `<2026-09-02`),
  # or two days (`2026-09-01..2026-09-07`, either side `*` for open).
  defp range(value, kind) do
    cond do
      value in @ranges[kind] ->
        %{"since" => value}

      String.contains?(value, "..") ->
        case String.split(value, "..", parts: 2) do
          [a, b] ->
            with {:ok, from} <- open_date(a),
                 {:ok, to} <- open_date(b),
                 true <- not is_nil(from) or not is_nil(to) do
              dates(from, to)
            else
              _ -> nil
            end
        end

      true ->
        case Regex.run(~r/\A(>=|<=|>|<)?(.+)\z/, value) do
          [_, op, day] ->
            case {op, date(day)} do
              {_op, nil} -> nil
              {"", d} -> dates(d, d)
              {">=", d} -> dates(d, nil)
              {">", d} -> dates(Date.add(d, 1), nil)
              {"<=", d} -> dates(nil, d)
              {"<", d} -> dates(nil, Date.add(d, -1))
            end

          nil ->
            nil
        end
    end
  end

  defp open_date("*"), do: {:ok, nil}
  defp open_date(""), do: {:ok, nil}

  defp open_date(value) do
    case date(value) do
      nil -> :error
      d -> {:ok, d}
    end
  end

  defp dates(from, to) do
    %{"from" => from && Date.to_iso8601(from), "to" => to && Date.to_iso8601(to)}
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp path_everywhere(value), do: {nil, value}

  @typedoc "One filter as the query writes it, and the filters without it."
  @type token :: %{key: atom(), value: String.t(), without: t() | nil}

  @doc """
  The filters as the query writes them, one token each, in the order the page shows them:
  `%{key:, value:, without:}`, `key` the qualifier (`:target`, `:state`, `:task`,
  `:runtime`, `:host`, `:key`, `:node`, `:started`, `:denied`, `:decision`, `:tools`), `value` what
  follows it (quoted when it holds a space), `without` the filters with it removed, nil
  for the connections' widest window, which cannot be. The free text is not a token, nor
  is a default but the connections' window, which is always said. `target_text:` writes a target (by default
  its path, after its system when it has one); `except:` leaves out the tokens of these
  qualifiers, which a view already says.
  """
  @spec tokens(t(), keyword) :: [token()]
  def tokens(%__MODULE__{} = f, opts \\ []) do
    target_text = Keyword.get(opts, :target_text, &default_target_text/1)
    except = Keyword.get(opts, :except, [])

    [
      {:target, f.target && target_text.(f.target), [target: nil]},
      {:state, f.states != [] && states_text(f.states), [states: []]},
      {:task, f.task && if(f.task == :none, do: "none", else: f.task), [task: nil]},
      {:runtime, f.runtime, [runtime: nil]},
      {:host, f.host, [host: nil]},
      {:key, f.key, [key: nil]},
      {:node, f.node, [node: nil]},
      {:decision, f.decision, [decision: nil]},
      {:started, range_text(f), range_without(f)},
      {:denied, f.denials && "yes", [denials: false]},
      {:tools, f.tools && "yes", [tools: false]}
    ]
    |> Enum.filter(fn {key, value, _changes} -> is_binary(value) and key not in except end)
    |> Enum.map(fn {key, value, changes} ->
      %{key: key, value: quote_value(value), without: changes && put(f, changes)}
    end)
  end

  # What taking the range away leaves: the runs list's every run; the connections' widest
  # window, whose own token cannot be taken away (nil), since their aggregate is bounded.
  defp range_without(%__MODULE__{kind: :connections, from: nil, to: nil, since: @widest_since}),
    do: nil

  defp range_without(%__MODULE__{kind: :connections}),
    do: [since: @widest_since, from: nil, to: nil]

  defp range_without(%__MODULE__{kind: kind}),
    do: [since: @default_since[kind], from: nil, to: nil]

  defp default_target_text(:none), do: "none"
  defp default_target_text({nil, path}), do: path
  defp default_target_text({system, path}), do: "#{system}/#{path}"

  defp states_text(states) do
    case families_of(states) do
      nil -> Enum.join(states, ",")
      keys -> Enum.join(keys, ",")
    end
  end

  # The connections' window is always said, their default too (`seen:14d`); the runs
  # list's default, every run, is not a range.
  defp range_text(%__MODULE__{from: nil, to: nil, since: since, kind: :connections}), do: since

  defp range_text(%__MODULE__{from: nil, to: nil, since: since, kind: kind}),
    do: if(since != @default_since[kind], do: since)

  defp range_text(%__MODULE__{from: same, to: same}), do: Date.to_iso8601(same)
  defp range_text(%__MODULE__{from: from, to: nil}), do: ">=" <> Date.to_iso8601(from)
  defp range_text(%__MODULE__{from: nil, to: to}), do: "<=" <> Date.to_iso8601(to)

  defp range_text(%__MODULE__{from: from, to: to}),
    do: Date.to_iso8601(from) <> ".." <> Date.to_iso8601(to)

  defp quote_value(value) do
    if String.match?(value, ~r/[\s"]/u),
      do: ~s("#{String.replace(value, "\"", "")}"),
      else: value
  end

  ## Ranges

  @doc "The instants the range covers, `{from, to}`, either of them nil for open."
  @spec bounds(t(), DateTime.t()) :: {DateTime.t() | nil, DateTime.t() | nil}
  def bounds(%__MODULE__{from: from, to: to}, _now) when not is_nil(from) or not is_nil(to) do
    {from && DateTime.new!(from, ~T[00:00:00.000000], "Etc/UTC"),
     to && DateTime.new!(Date.add(to, 1), ~T[00:00:00.000000], "Etc/UTC")}
  end

  def bounds(%__MODULE__{since: since}, now) do
    seconds =
      case since do
        "1h" -> 3600
        "24h" -> 86_400
        "7d" -> 7 * 86_400
        "14d" -> 14 * 86_400
        "30d" -> 30 * 86_400
        "90d" -> 90 * 86_400
        _all -> nil
      end

    {seconds && DateTime.add(now, -seconds, :second), nil}
  end

  @doc """
  The range in words, for the Started section: "last 7 days", "14 Sept 2026 to 20 Sept
  2026"; nil for every run. The dates are UTC days (`bounds/2`).
  """
  def range_label(%__MODULE__{from: nil, to: nil, since: since}) do
    case since do
      "1h" -> gettext("last hour")
      "24h" -> gettext("last 24 hours")
      "7d" -> gettext("last 7 days")
      "14d" -> gettext("last 14 days")
      "30d" -> gettext("last 30 days")
      "90d" -> gettext("last 90 days")
      _all -> nil
    end
  end

  def range_label(%__MODULE__{from: from, to: nil}), do: gettext("from %{date}", date: day(from))
  def range_label(%__MODULE__{from: nil, to: to}), do: gettext("to %{date}", date: day(to))
  def range_label(%__MODULE__{from: same, to: same}), do: day(same)

  def range_label(%__MODULE__{from: from, to: to}),
    do: gettext("%{from} to %{to}", from: day(from), to: day(to))

  @doc """
  The range as the end of a sentence, a phrase whole in itself: "in the last 7 days",
  "up to 20 Sept 2026", "from 14 Sept 2026 to 20 Sept 2026"; nil when there is no range.
  """
  def range_phrase(%__MODULE__{from: nil, to: nil, since: since}) do
    case since do
      "1h" -> gettext("in the last hour")
      "24h" -> gettext("in the last 24 hours")
      "7d" -> gettext("in the last 7 days")
      "14d" -> gettext("in the last 14 days")
      "30d" -> gettext("in the last 30 days")
      "90d" -> gettext("in the last 90 days")
      _all -> nil
    end
  end

  def range_phrase(%__MODULE__{from: from, to: nil}), do: gettext("from %{date}", date: day(from))
  def range_phrase(%__MODULE__{from: nil, to: to}), do: gettext("up to %{date}", date: day(to))
  def range_phrase(%__MODULE__{from: same, to: same}), do: gettext("on %{date}", date: day(same))

  def range_phrase(%__MODULE__{from: from, to: to}),
    do: gettext("from %{from} to %{to}", from: day(from), to: day(to))

  defp day(date), do: ApiaryWeb.Format.date(date)

  ## Targets

  @doc """
  The parameters of a target, for a link to a filtered page:
  `%{"system" => system, "target" => path}`; `%{"target" => path}` for the path on every
  system; `%{"target" => "none"}` for runs without one.
  """
  @spec target_params(String.t() | nil, String.t() | nil) :: %{String.t() => String.t()}
  def target_params(system, path) when is_binary(system) and is_binary(path),
    do: %{"system" => system, "target" => path}

  def target_params(nil, path) when is_binary(path), do: %{"target" => path}
  def target_params(_system, _path), do: %{"target" => "none"}

  @doc """
  The parameters of a target as the console's links write them (question 9, answer A): its
  path, `%{"target" => "acme/shop"}`, and its system only where the path is `shared` by
  another target of the workspace, `%{"system" => "gitlab.com", "target" => "acme/shop"}`.
  `shared` is a boolean, or the workspace's shared paths (`Apiary.Runs.shared_paths/2`).
  """
  @spec target_params(String.t() | nil, String.t(), boolean | MapSet.t(String.t())) :: %{
          String.t() => String.t()
        }
  def target_params(system, path, shared) when is_binary(path) do
    shared? =
      case shared do
        %MapSet{} -> MapSet.member?(shared, path)
        shared -> shared == true
      end

    target_params(if(shared?, do: system), path)
  end

  defp target_params(:none), do: %{"target" => "none"}
  defp target_params({system, path}), do: target_params(system, path)

  @doc """
  A target as the one value of a menu's option: `none`, or the JSON of `[system, path]`
  (`[null, path]` for the path on every system), which no system or path can be mistaken
  for. `change/2` reads it back.
  """
  def target_value(nil), do: nil
  def target_value(:none), do: "none"
  def target_value({system, path}), do: Jason.encode!([system, path])

  defp target_from_value("none"), do: %{"target" => "none"}

  defp target_from_value(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, [system, path]} when (is_binary(system) or is_nil(system)) and is_binary(path) ->
        target_params(system, path)

      _ ->
        %{"target" => value}
    end
  end

  defp target_from_value(_value), do: %{}

  defp system_param({system, _path}) when is_binary(system), do: system
  defp system_param(_target), do: nil

  defp target_param(nil), do: nil
  defp target_param(:none), do: "none"
  defp target_param({_system, path}), do: path

  # `target=none` alone is "no target", `target` alone a path on every system; a `system`
  # needs its path.
  defp target(params) do
    case {Map.fetch(params, "system"), Map.fetch(params, "target")} do
      {:error, :error} ->
        {nil, []}

      {:error, {:ok, "none"}} ->
        {:none, []}

      {:error, {:ok, path}} ->
        if text(path), do: {{nil, path}, []}, else: {nil, ["target"]}

      {{:ok, system}, {:ok, path}} ->
        if text(system) && text(path), do: {{system, path}, []}, else: {nil, ["target"]}

      _one_without_the_other ->
        {nil, ["target"]}
    end
  end

  # A window of dates no wider than the page's bound.
  defp clamp(from, to, :connections) when not is_nil(from) or not is_nil(to) do
    case {from, to} do
      {from, nil} ->
        {from, Date.add(from, @max_window_days - 1)}

      {nil, to} ->
        {Date.add(to, -(@max_window_days - 1)), to}

      {from, to} ->
        earliest = Date.add(to, -(@max_window_days - 1))
        {if(Date.compare(from, earliest) == :lt, do: earliest, else: from), to}
    end
  end

  defp clamp(from, to, _kind), do: {from, to}

  defp states(params) do
    case Map.fetch(params, "state") do
      :error ->
        {[], []}

      {:ok, value} when is_binary(value) ->
        chosen =
          value
          |> String.split(",", trim: true)
          |> Enum.uniq()

        known = Enum.filter(Run.states(), &(&1 in chosen))
        {known, if(length(known) == length(chosen) and chosen != [], do: [], else: ["state"])}

      {:ok, _other} ->
        {[], ["state"]}
    end
  end

  defp one_of(value, allowed) when is_binary(value), do: if(value in allowed, do: value)
  defp one_of(_value, _allowed), do: nil

  defp none_or_text("none"), do: :none
  defp none_or_text(value), do: text(value)

  defp text(value) when is_binary(value) do
    if value != "" and fits?(value), do: value
  end

  defp text(_value), do: nil

  # The free text as the query field keeps it: trimmed, one line, what `Runs.like/1` reads.
  defp query_text(value) when is_binary(value) do
    value = String.trim(value)
    if value != "" and byte_size(value) <= @max_q and fits?(value), do: value
  end

  defp query_text(_value), do: nil

  # Postgres refuses a NUL in text, and no label, runtime or host a reader would filter by
  # holds a control character: a value with one is refused here, not by the database.
  defp fits?(value) do
    byte_size(value) <= @max_text and String.valid?(value) and
      not String.match?(value, ~r/[\x00-\x1F\x7F]/)
  end

  defp date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, %Date{year: year} = date} when year in 2000..2999 -> date
      _ -> nil
    end
  end

  defp date(_value), do: nil

  defp page(value) when is_binary(value) do
    case Integer.parse(value) do
      {page, ""} when page in 1..@max_page -> page
      _ -> nil
    end
  end

  defp page(_value), do: nil

  defp per(value) when is_binary(value) do
    case Integer.parse(value) do
      {per, ""} when per in @pers -> per
      _ -> nil
    end
  end

  defp per(_value), do: nil
end
