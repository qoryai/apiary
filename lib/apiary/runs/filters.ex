defmodule Apiary.Runs.Filters do
  @moduledoc """
  What the runs list and the hive's connections page are filtered by, read from query
  parameters and written back to them, so that every view is a URL.

  `parse/2` never fails: a value it does not know is dropped, and `to_params/1` of the
  result is the canonical query, which the page patches to when it differs from what it was
  given. Nothing here becomes an atom from input, and nothing is interpolated into a query:
  the values are compared as strings by `Apiary.Runs`.

  The defaults (group by repository, the last seven days, page 1) are left out of the URL.
  `since=all` is the way to say "no time range", which removing the range chip writes.
  """

  alias Apiary.Runs.Run

  @groups ~w(repository task none)
  @ranges ~w(1h 24h 7d 30d all)
  @decisions ~w(allowed denied)
  @default_since "7d"
  @max_text 256
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
            page: 1

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
          page: pos_integer()
        }

  @doc "The time ranges a page offers, as `{label, value}`."
  def ranges,
    do: [
      {"Last hour", "1h"},
      {"Last 24 hours", "24h"},
      {"Last 7 days", "7d"},
      {"Last 30 days", "30d"}
    ]

  @doc "Reads the parameters of the runs list (`:runs`) or the hive's connections (`:connections`)."
  @spec parse(map(), :runs | :connections) :: t()
  def parse(params, kind \\ :runs) when is_map(params) and kind in [:runs, :connections] do
    from = date(params["from"])
    to = date(params["to"])
    {from, to} = if from && to && Date.compare(from, to) == :gt, do: {to, from}, else: {from, to}

    filters = %__MODULE__{
      kind: kind,
      repo: repo(params["repo"]),
      host: text(params["host"]),
      from: from,
      to: to,
      since: if(from || to, do: nil, else: since(params["since"])),
      page: page(params["page"])
    }

    case kind do
      :runs ->
        %{
          filters
          | group: one_of(params["group"], @groups) || "repository",
            states: states(params["state"]),
            task: none_or_text(params["task"]),
            runtime: text(params["runtime"]),
            denials: params["denials"] == "1"
        }

      :connections ->
        %{filters | decision: one_of(params["decision"], @decisions)}
    end
  end

  @doc "The canonical query of the filters: string keys, defaults left out."
  @spec to_params(t()) :: %{optional(String.t()) => String.t()}
  def to_params(%__MODULE__{} = f) do
    [
      {"group", f.group != "repository" && f.kind == :runs && f.group},
      {"state", f.states != [] && Enum.join(f.states, ",")},
      {"repo", repo_param(f.repo)},
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
  def put(%__MODULE__{} = f, changes), do: struct!(%{f | page: 1}, changes)

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

        name when name in ~w(repo task runtime host) ->
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
      _all -> nil
    end
  end

  def range_label(%__MODULE__{from: from, to: nil}), do: "from #{day(from)}"
  def range_label(%__MODULE__{from: nil, to: to}), do: "to #{day(to)}"
  def range_label(%__MODULE__{from: same, to: same}), do: day(same)
  def range_label(%__MODULE__{from: from, to: to}), do: "#{day(from)} to #{day(to)}"

  defp day(date), do: Calendar.strftime(date, "%-d %b %Y")

  @doc "`{forge}:{path}` of a repository, `none` for unassigned."
  def repo_param(nil), do: nil
  def repo_param(:none), do: "none"
  def repo_param({forge, path}), do: forge <> ":" <> path

  defp repo("none"), do: :none

  defp repo(value) when is_binary(value) do
    # A forge is a host name and holds no colon; a path may.
    with [forge, path] when forge != "" and path != "" <- String.split(value, ":", parts: 2),
         true <- fits?(forge) and fits?(path) do
      {forge, path}
    else
      _ -> nil
    end
  end

  defp repo(_value), do: nil

  defp states(value) when is_binary(value) do
    chosen = value |> String.split(",", trim: true) |> Enum.uniq()
    Enum.filter(Run.states(), &(&1 in chosen))
  end

  defp states(_value), do: []

  defp since(value), do: one_of(value, @ranges) || @default_since

  defp one_of(value, allowed) when is_binary(value), do: if(value in allowed, do: value)
  defp one_of(_value, _allowed), do: nil

  defp none_or_text("none"), do: :none
  defp none_or_text(value), do: text(value)

  defp text(value) when is_binary(value) do
    if value != "" and fits?(value), do: value
  end

  defp text(_value), do: nil

  defp fits?(value), do: byte_size(value) <= @max_text and String.valid?(value)

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
      _ -> 1
    end
  end

  defp page(_value), do: 1
end
