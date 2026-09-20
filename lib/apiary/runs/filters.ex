defmodule Apiary.Runs.Filters do
  @moduledoc """
  What the runs list and the hive's connections page are filtered by, read from query
  parameters and written back to them, so that every view is a URL.

  `parse/2` never fails: a value it does not know is dropped, and `to_params/1` of the
  result is the canonical query, which the page patches to when it differs from what it was
  given. Nothing here becomes an atom from input, and nothing is interpolated into a query:
  the values are compared as strings by `Apiary.Runs`.

  The defaults (group by repository, the last seven days, page 1) are left out of the URL.
  On the runs list `since=all` is the way to say "no time range", which removing the range
  chip writes. The hive's connections are an aggregate over every connection in range, so
  their range is bounded: `since=90d` is the widest, and dates cover at most
  90 days, counted back from `to` (or on from `from` when only it is given).

  A repository is two parameters, `forge` and `repo` (the path), because either may hold
  any character, a colon included; `repo=none` without a forge is "no repository".
  `repo_params/2` writes them, for every link to a filtered page.

  A value that is present and refused (not one the page offers, not a string, longer than
  the column it is compared with, or holding a control character, which Postgres would
  refuse) is named in `dropped`, so the page can say that the link was not read in full
  instead of silently showing an unfiltered list. A state under a name it no longer has
  (`state=exited`, from before the state was called `succeeded`) is read as the state and
  not refused; the canonical query says the current name.
  """

  alias Apiary.Runs.Run

  @groups ~w(repository task none)
  @ranges %{runs: ~w(1h 24h 7d 30d all), connections: ~w(1h 24h 7d 30d 90d)}
  @max_window_days 90
  @decisions ~w(allowed denied)
  # A state's former name, read from a link written before the rename and canonicalised, so
  # the link keeps working and the page patches to the word the state has now.
  @state_aliases %{"exited" => "succeeded"}
  @default_since "7d"
  # What the fold stores of a label, a runtime or a host, in bytes.
  @max_text 1024
  @max_page 100_000

  defstruct kind: :runs,
            group: "repository",
            states: [],
            repo: nil,
            task: nil,
            runtime: nil,
            host: nil,
            since: @default_since,
            from: nil,
            to: nil,
            denials: false,
            decision: nil,
            page: 1,
            dropped: []

  @type t :: %__MODULE__{
          kind: :runs | :connections,
          group: String.t(),
          states: [String.t()],
          repo: nil | :none | {String.t(), String.t()},
          task: nil | :none | String.t(),
          runtime: nil | String.t(),
          host: nil | String.t(),
          since: nil | String.t(),
          from: nil | Date.t(),
          to: nil | Date.t(),
          denials: boolean(),
          decision: nil | String.t(),
          page: pos_integer(),
          dropped: [String.t()]
        }

  @doc "The widest window the hive's connections are aggregated over, in days."
  def max_window_days, do: @max_window_days

  @doc "The time ranges a page offers, as `{label, value}`."
  def ranges(kind \\ :runs)

  def ranges(:runs),
    do: [
      {"Last hour", "1h"},
      {"Last 24 hours", "24h"},
      {"Last 7 days", "7d"},
      {"Last 30 days", "30d"}
    ]

  def ranges(:connections), do: ranges(:runs) ++ [{"Last 90 days", "90d"}]

  @doc "Reads the parameters of the runs list (`:runs`) or the hive's connections (`:connections`)."
  @spec parse(map(), :runs | :connections) :: t()
  def parse(params, kind \\ :runs) when is_map(params) and kind in [:runs, :connections] do
    {from, d1} = read(params, "from", &date/1)
    {to, d2} = read(params, "to", &date/1)
    {from, to} = if from && to && Date.compare(from, to) == :gt, do: {to, from}, else: {from, to}
    {from, to} = clamp(from, to, kind)

    {repo, d3} = repo(params)
    {host, d4} = read(params, "host", &text/1)
    {since, d5} = read(params, "since", &one_of(&1, @ranges[kind]))
    {page, d6} = read(params, "page", &page/1)

    filters = %__MODULE__{
      kind: kind,
      repo: repo,
      host: host,
      from: from,
      to: to,
      since: if(from || to, do: nil, else: since || @default_since),
      page: page || 1,
      dropped: d1 ++ d2 ++ d3 ++ d4 ++ d5 ++ d6
    }

    case kind do
      :runs ->
        {group, d7} = read(params, "group", &one_of(&1, @groups))
        {states, d8} = states(params)
        {task, d9} = read(params, "task", &none_or_text/1)
        {runtime, d10} = read(params, "runtime", &text/1)
        {denials, d11} = read(params, "denials", &if(&1 == "1", do: true))

        %{
          filters
          | group: group || "repository",
            states: states,
            task: task,
            runtime: runtime,
            denials: denials == true,
            dropped: filters.dropped ++ d7 ++ d8 ++ d9 ++ d10 ++ d11
        }

      :connections ->
        {decision, d7} = read(params, "decision", &one_of(&1, @decisions))
        %{filters | decision: decision, dropped: filters.dropped ++ d7}
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
  def to_params(%__MODULE__{} = f) do
    [
      {"group", f.group != "repository" && f.kind == :runs && f.group},
      {"state", f.states != [] && Enum.join(f.states, ",")},
      {"forge", match?({_forge, _path}, f.repo) && elem(f.repo, 0)},
      {"repo", repo_path(f.repo)},
      {"task", if(f.task == :none, do: "none", else: f.task)},
      {"runtime", f.runtime},
      {"host", f.host},
      {"since", f.since not in [nil, @default_since] && f.since},
      {"from", f.from && Date.to_iso8601(f.from)},
      {"to", f.to && Date.to_iso8601(f.to)},
      {"denials", f.denials && "1"},
      {"decision", f.decision},
      {"page", f.page > 1 && Integer.to_string(f.page)}
    ]
    |> Enum.filter(fn {_key, value} -> is_binary(value) end)
    |> Map.new()
  end

  @doc "Whether anything narrows the list: the range counts when it is not the default."
  def any?(%__MODULE__{} = f) do
    f.states != [] or f.repo != nil or f.task != nil or f.runtime != nil or f.host != nil or
      f.since != @default_since or f.denials or f.decision != nil
  end

  @doc "The filters with no filter set: the grouping stays, the page and the rest go."
  def clear(%__MODULE__{kind: kind, group: group}), do: %__MODULE__{kind: kind, group: group}

  @doc "Sets fields and returns to page 1, which every change of a filter does."
  def put(%__MODULE__{} = f, changes), do: struct!(%{f | page: 1, dropped: []}, changes)

  @doc "The filters without what `parse/2` noted: what two views are compared by."
  def same?(%__MODULE__{} = a, %__MODULE__{} = b), do: %{a | dropped: []} == %{b | dropped: []}

  @doc """
  The filters after a change in a filter's menu: `form` is what the menu's form sends, the
  name of the filter in `_filter` and its fields. Read through `parse/2` like a URL, so a
  value the page did not offer is dropped all the same. Returns to page 1.
  """
  @spec change(t(), map()) :: t()
  def change(%__MODULE__{} = f, %{"_filter" => name} = form) do
    current = f |> to_params() |> Map.delete("page")

    changed =
      case name do
        "state" ->
          states = form["state"] |> List.wrap() |> Enum.filter(&is_binary/1) |> Enum.join(",")
          Map.put(current, "state", states)

        "since" ->
          if form["_target"] in [["from"], ["to"]] do
            current |> Map.delete("since") |> Map.merge(Map.take(form, ["from", "to"]))
          else
            current |> Map.drop(["from", "to"]) |> Map.merge(Map.take(form, ["since"]))
          end

        "repo" ->
          current |> Map.drop(["forge", "repo"]) |> Map.merge(repo_from_value(form["repo"]))

        name when name in ~w(task runtime host) ->
          Map.merge(current, Map.take(form, [name]))

        _other ->
          current
      end

    parse(changed, f.kind)
  end

  def change(%__MODULE__{} = f, _form), do: f

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
        "30d" -> 30 * 86_400
        "90d" -> 90 * 86_400
        _all -> nil
      end

    {seconds && DateTime.add(now, -seconds, :second), nil}
  end

  @doc "The range in words, for the chip: \"last 7 days\", \"14 Sep to 20 Sep\"."
  def range_label(%__MODULE__{from: nil, to: nil, since: since}) do
    case since do
      "1h" -> "last hour"
      "24h" -> "last 24 hours"
      "7d" -> "last 7 days"
      "30d" -> "last 30 days"
      "90d" -> "last 90 days"
      _all -> nil
    end
  end

  def range_label(%__MODULE__{from: from, to: nil}), do: "from #{day(from)}"
  def range_label(%__MODULE__{from: nil, to: to}), do: "to #{day(to)}"
  def range_label(%__MODULE__{from: same, to: same}), do: day(same)
  def range_label(%__MODULE__{from: from, to: to}), do: "#{day(from)} to #{day(to)}"

  defp day(date), do: Calendar.strftime(date, "%-d %b %Y")

  @doc """
  The two parameters of a repository, for a link to a filtered page:
  `%{"forge" => forge, "repo" => path}`; `%{"repo" => "none"}` for runs without one.
  """
  @spec repo_params(String.t() | nil, String.t() | nil) :: %{String.t() => String.t()}
  def repo_params(forge, path) when is_binary(forge) and is_binary(path),
    do: %{"forge" => forge, "repo" => path}

  def repo_params(_forge, _path), do: %{"repo" => "none"}

  @doc """
  A repository as the one value of a menu's option: `none`, or the JSON of `[forge, path]`,
  which no forge or path can be mistaken for. `change/2` reads it back.
  """
  def repo_value(nil), do: nil
  def repo_value(:none), do: "none"
  def repo_value({forge, path}), do: Jason.encode!([forge, path])

  defp repo_from_value("none"), do: %{"repo" => "none"}

  defp repo_from_value(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, [forge, path]} when is_binary(forge) and is_binary(path) -> repo_params(forge, path)
      _ -> %{"repo" => value}
    end
  end

  defp repo_from_value(_value), do: %{}

  defp repo_path(nil), do: nil
  defp repo_path(:none), do: "none"
  defp repo_path({_forge, path}), do: path

  # `repo=none` alone is "no repository"; otherwise both parts, or neither.
  defp repo(params) do
    case {Map.fetch(params, "forge"), Map.fetch(params, "repo")} do
      {:error, :error} ->
        {nil, []}

      {:error, {:ok, "none"}} ->
        {:none, []}

      {{:ok, forge}, {:ok, path}} ->
        if text(forge) && text(path), do: {{forge, path}, []}, else: {nil, ["repo"]}

      _one_without_the_other ->
        {nil, ["repo"]}
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
          |> Enum.map(&Map.get(@state_aliases, &1, &1))
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
end
