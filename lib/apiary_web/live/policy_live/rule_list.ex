defmodule ApiaryWeb.PolicyLive.RuleList do
  @moduledoc """
  A list of a policy's host rules on the list pattern (docs/ui.md, Lists): the query of
  the Network access section of the workspace's policy page and of a target's Policy tab,
  as the URL carries it, and what it makes of the rules the page holds. Pure: rows in, a
  page of rows out; nothing here reads the database.

    * `view`: `allowed`, `denied` or `locked`; none is every rule.
    * `q`: the search, free text found in the host, and qualifiers: `seen:yes` and
      `seen:no` (used in the last 14 days, from `Apiary.Policy.rule_activity/3`),
      `paths:held` and `paths:every`, `by:` and a person's short name, `source:` and a
      source's key. The Filter menu (`sections/2`) writes the same qualifiers; the page
      shows each as a token the reader removes.
    * `sort`: `host`, `used` or `recent`; none is the list's own order: by source (a
      target's own first on its tab), then locked, then deny, then allow, each by host
      read from the right, so a suffix sits beside the hosts below it.
    * `page`, from 1, of 50 rules.

  A value it does not know is left out, and the page writes the URL without it.

  A row is a map the page builds (`ApiaryWeb.PolicyLive.Common`): `id`, `action`
  (`"allow"`, `"deny"`), `host`, `paths`, `locked`, `by` (a person's short name, or nil),
  `at` and `source`, `%{key:, label:, rank:}`: where the rule is written, its key the
  `source:` qualifier's value, its rank its place in the list's own order, lowest first.
  The sources are the rows', never a list of this module's: an edition that adds rules of
  another holder to a list gives them a source of their own, and the Source section of
  the Filter menu, the `source:` qualifier and the order take it as they take the core's.
  """
  use Gettext, backend: ApiaryWeb.Gettext

  alias Apiary.Policy.Grammar

  @page_size 50
  @max_page 1_000

  defstruct view: :all, tokens: [], text: "", sort: :default, page: 1

  @typedoc "A qualifier the search holds."
  @type token ::
          {:seen, :yes | :no}
          | {:paths, :held | :every}
          | {:by, String.t()}
          | {:source, String.t()}

  @type t :: %__MODULE__{
          view: :all | :allow | :deny | :locked,
          tokens: [token],
          text: String.t(),
          sort: :default | :host | :used | :recent,
          page: pos_integer
        }

  @typedoc "What a page of the list shows."
  @type listing :: %{
          rows: [map],
          total: non_neg_integer,
          match: non_neg_integer | nil,
          counts: %{
            all: non_neg_integer,
            allow: non_neg_integer,
            deny: non_neg_integer,
            locked: non_neg_integer
          },
          page: pos_integer,
          pages: pos_integer,
          first: non_neg_integer,
          last: non_neg_integer,
          unseen: boolean,
          loading: boolean
        }

  @views %{"allowed" => :allow, "denied" => :deny, "locked" => :locked}
  @sorts %{"host" => :host, "used" => :used, "recent" => :recent}
  @seen %{"yes" => :yes, "no" => :no}
  @paths %{"held" => :held, "every" => :every}

  @doc "The rules a page of the list holds."
  @spec page_size() :: pos_integer
  def page_size, do: @page_size

  @doc "The orders the list is read in beyond its own, as the URL writes them."
  @spec sorts() :: [:default | :host | :used | :recent]
  def sorts, do: [:default, :host, :used, :recent]

  ## The URL

  @doc "parse/1 reads the URL's parameters."
  @spec parse(map) :: t
  def parse(params) when is_map(params) do
    {tokens, text} = parse_search(params["q"])

    %__MODULE__{
      view: Map.get(@views, params["view"], :all),
      sort: Map.get(@sorts, params["sort"], :default),
      page: page(params["page"]),
      tokens: tokens,
      text: text
    }
  end

  @doc """
  parse_search/1 splits what the reader typed into its qualifiers and its free text: a
  word `key:value` with a known key and value is a qualifier, every other word text. One
  qualifier of a kind is kept, the last.
  """
  @spec parse_search(String.t() | nil) :: {[token], String.t()}
  def parse_search(q) when is_binary(q) do
    {tokens, words} =
      q
      |> String.slice(0, 1_000)
      |> String.split()
      |> Enum.reduce({[], []}, fn word, {tokens, words} ->
        case qualifier(word) do
          nil -> {tokens, [word | words]}
          token -> {put_token(tokens, token), words}
        end
      end)

    {tokens, words |> Enum.reverse() |> Enum.join(" ")}
  end

  def parse_search(_q), do: {[], ""}

  @doc """
  pending/1 is what the reader typed without the words that look like a qualifier
  (`key:value`), known or half typed: the free text of a search sent before Enter.
  """
  @spec pending(String.t()) :: String.t()
  def pending(q) when is_binary(q) do
    q
    |> String.slice(0, 1_000)
    |> String.split()
    |> Enum.reject(&String.match?(&1, ~r/^[a-z]+:/i))
    |> Enum.join(" ")
  end

  defp qualifier(word) do
    case String.split(word, ":", parts: 2) do
      ["seen", value] -> if seen = @seen[value], do: {:seen, seen}
      ["paths", value] -> if paths = @paths[value], do: {:paths, paths}
      ["by", value] when value != "" -> {:by, String.slice(value, 0, 80)}
      ["source", value] when value != "" -> {:source, String.slice(value, 0, 80)}
      _other -> nil
    end
  end

  @doc "The parameters of the URL of `query`, without the defaults."
  @spec to_params(t) :: map
  def to_params(%__MODULE__{} = query) do
    %{}
    |> put_param("view", key_of(@views, query.view))
    |> put_param("q", search(query))
    |> put_param("sort", key_of(@sorts, query.sort))
    |> put_param("page", if(query.page > 1, do: Integer.to_string(query.page)))
  end

  @doc "Whether the parameters are those `to_params/1` writes for what they say."
  @spec canonical?(map) :: boolean
  def canonical?(params) when is_map(params),
    do: params |> parse() |> to_params() == Map.take(params, ~w(view q sort page))

  @doc "The search as the field and the URL write it: the qualifiers, then the text."
  @spec search(t) :: String.t() | nil
  def search(%__MODULE__{tokens: tokens, text: text}) do
    case Enum.map(tokens, &token_text/1) ++ if(text == "", do: [], else: [text]) do
      [] -> nil
      words -> Enum.join(words, " ")
    end
  end

  @doc "A qualifier as the search writes it: `seen:no`, `by:dana`."
  @spec token_text(token) :: String.t()
  def token_text({:seen, seen}), do: "seen:#{key_of(@seen, seen)}"
  def token_text({:paths, paths}), do: "paths:#{key_of(@paths, paths)}"
  def token_text({:by, by}), do: "by:#{by}"
  def token_text({:source, key}), do: "source:#{key}"

  @doc "Whether the query narrows the rules beyond its view."
  @spec narrowed?(t) :: boolean
  def narrowed?(%__MODULE__{tokens: tokens, text: text}), do: tokens != [] or text != ""

  @doc """
  toggle/2 is `query` with `token` added, or taken out when it is there, on its first
  page. A token replaces one of its kind: the Filter menu picks one of each.
  """
  @spec toggle(t, token) :: t
  def toggle(%__MODULE__{tokens: tokens} = query, token) do
    tokens = if token in tokens, do: List.delete(tokens, token), else: put_token(tokens, token)
    %{query | tokens: tokens, page: 1}
  end

  @doc "typed/3 is `query` with what the reader sent: its qualifiers added, its text the new text."
  @spec typed(t, [token], String.t()) :: t
  def typed(%__MODULE__{} = query, tokens, text) do
    %{query | tokens: Enum.reduce(tokens, query.tokens, &put_token(&2, &1)), text: text, page: 1}
  end

  @doc "clear/1 is `query` with no qualifier and no text, in its view and order."
  @spec clear(t) :: t
  def clear(%__MODULE__{} = query), do: %{query | tokens: [], text: "", page: 1}

  defp put_token(tokens, {kind, _value} = token),
    do: Enum.reject(tokens, &(elem(&1, 0) == kind)) ++ [token]

  ## The list

  @doc """
  list/3 is the page of `rows` that `query` shows, with the counts of the views under the
  query's other filters and its text (as the runs list counts its views), and how many
  match the query. `activity` is what `Apiary.Policy.rule_activity/3`
  answered, `:loading` or `:unavailable`: while it loads, a query that needs it (`seen:`,
  the order by use) shows no row yet and says `loading`; when it could not be counted,
  `seen:` narrows nothing and `unseen` says so. A page past the last shows the last.
  """
  @spec list([map], t, map | :loading | :unavailable) :: listing
  def list(rows, %__MODULE__{} = query, activity) do
    if activity == :loading and needs_activity?(query) do
      %{
        rows: [],
        total: 0,
        match: nil,
        counts: counts(rows),
        page: query.page,
        pages: query.page,
        first: 0,
        last: 0,
        unseen: false,
        loading: true
      }
    else
      under = narrowed(rows, query, activity)
      matched = under |> Enum.filter(&in_view?(&1, query.view)) |> order(query.sort, activity)
      total = length(matched)
      pages = max(div(total + @page_size - 1, @page_size), 1)
      page = min(query.page, pages)
      shown = Enum.slice(matched, (page - 1) * @page_size, @page_size)
      first = if shown == [], do: 0, else: (page - 1) * @page_size + 1

      %{
        rows: shown,
        total: total,
        match: if(narrowed?(query), do: total),
        counts: counts(under),
        page: page,
        pages: pages,
        first: first,
        last: first + max(length(shown) - 1, 0),
        unseen: activity == :unavailable and Enum.any?(query.tokens, &match?({:seen, _}, &1)),
        loading: false
      }
    end
  end

  @doc "Whether the query can be answered only once the use of the rules is counted."
  @spec needs_activity?(t) :: boolean
  def needs_activity?(%__MODULE__{sort: sort, tokens: tokens}),
    do: sort == :used or Enum.any?(tokens, &match?({:seen, _}, &1))

  @doc """
  landing/4 is `query` on the page that holds the rule of `host`, for `?rule=`: in the
  query's view and filters when they keep it, else in every rule in the query's order. The
  query as it was when no rule has that host, or when the page cannot be told yet.
  """
  @spec landing(t, [map], map | :loading | :unavailable, String.t() | nil) :: t
  def landing(query, _rows, _activity, nil), do: query

  def landing(%__MODULE__{} = query, rows, activity, host) do
    cond do
      not Enum.any?(rows, &(&1.host == host)) ->
        query

      activity == :loading and needs_activity?(query) ->
        query

      index = index_of(matching(rows, query, activity), host) ->
        %{query | page: div(index, @page_size) + 1}

      true ->
        all = %__MODULE__{sort: query.sort}
        %{all | page: div(index_of(matching(rows, all, activity), host), @page_size) + 1}
    end
  end

  defp index_of(rows, host), do: Enum.find_index(rows, &(&1.host == host))

  @doc "The views' counts over the rows given: all, allowed, denied and locked."
  @spec counts([map]) :: %{
          all: non_neg_integer,
          allow: non_neg_integer,
          deny: non_neg_integer,
          locked: non_neg_integer
        }
  def counts(rows) do
    %{
      all: length(rows),
      allow: Enum.count(rows, &(&1.action == "allow")),
      deny: Enum.count(rows, &(&1.action == "deny")),
      locked: Enum.count(rows, & &1.locked)
    }
  end

  defp matching(rows, query, activity) do
    rows
    |> narrowed(query, activity)
    |> Enum.filter(&in_view?(&1, query.view))
    |> order(query.sort, activity)
  end

  # The rows the query's filters and text keep, in every view: what the views count.
  defp narrowed(rows, query, activity) do
    rows
    |> Enum.filter(fn row -> Enum.all?(query.tokens, &keeps?(&1, row, activity)) end)
    |> Enum.filter(&found?(&1, query.text))
  end

  defp in_view?(_row, :all), do: true
  defp in_view?(row, :allow), do: row.action == "allow"
  defp in_view?(row, :deny), do: row.action == "deny"
  defp in_view?(row, :locked), do: row.locked

  defp keeps?({:seen, _seen}, _row, activity) when not is_map(activity), do: true
  defp keeps?({:seen, :yes}, row, activity), do: used(row, activity) > 0
  defp keeps?({:seen, :no}, row, activity), do: used(row, activity) == 0
  defp keeps?({:paths, :held}, row, _activity), do: held?(row)
  defp keeps?({:paths, :every}, row, _activity), do: not held?(row)
  defp keeps?({:by, by}, row, _activity), do: by_key(row) == String.downcase(by)
  defp keeps?({:source, key}, row, _activity), do: row.source.key == key

  defp found?(_row, ""), do: true

  defp found?(row, text),
    do: text |> String.downcase() |> String.split() |> Enum.all?(&String.contains?(row.host, &1))

  @doc "Whether a rule holds its host to paths: an allow with a list of them."
  @spec held?(map) :: boolean
  def held?(%{action: "allow", paths: paths}) when is_list(paths), do: true
  def held?(_row), do: false

  @doc "The attempts a rule decided in the window of `activity`, allowed and denied."
  @spec used(map, map) :: non_neg_integer
  def used(row, activity) when is_map(activity) do
    case Map.get(activity, row.id) do
      %{allowed: allowed, denied: denied} -> allowed + denied
      _ -> 0
    end
  end

  def used(_row, _activity), do: 0

  # The `by:` of a row: a person's short name as one word, in lower case; none for a
  # former member, whose words are not one.
  defp by_key(%{by: by}) when is_binary(by) do
    if String.contains?(by, " "), do: nil, else: String.downcase(by)
  end

  defp by_key(_row), do: nil

  ## The orders

  defp order(rows, :default, _activity), do: Enum.sort_by(rows, &own_order/1)

  defp order(rows, :host, _activity),
    do: Enum.sort_by(rows, &{String.trim_leading(&1.host, "*."), Grammar.wildcard?(&1.host)})

  defp order(rows, :used, activity),
    do: Enum.sort_by(rows, &{-used(&1, activity), own_order(&1)})

  defp order(rows, :recent, _activity) do
    Enum.sort_by(rows, &{-unix(&1.at), own_order(&1)})
  end

  defp unix(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)
  defp unix(%NaiveDateTime{} = at), do: at |> DateTime.from_naive!("Etc/UTC") |> unix()
  defp unix(_at), do: 0

  # The source, then locked, deny and allow, then the host read from the right.
  defp own_order(row) do
    {row.source.rank, if(row.locked, do: 0, else: if(row.action == "deny", do: 1, else: 2)),
     from_the_right(row.host)}
  end

  @doc """
  A host's labels read from the right, as the list's own order compares them: a name before
  the suffix above it, the suffix before the hosts below it.
  """
  @spec from_the_right(String.t()) :: [String.t()]
  def from_the_right(host) do
    labels = host |> String.trim_leading("*.") |> String.split(".") |> Enum.reverse()
    if Grammar.wildcard?(host), do: labels ++ ["*"], else: labels
  end

  ## The Filter menu

  @doc """
  The sections of the Filter menu for `rows`, each `%{key:, title:, items:}`, an item
  `%{token:, label:, count:}`: Source, where the rows have more than one; Paths; Seen in
  14 days, where the use could be counted; Added by, the people who added the rows. The
  counts are over every row.
  """
  @spec sections([map], map | :loading | :unavailable) :: [map]
  def sections(rows, activity) do
    [source_section(rows), paths_section(rows), seen_section(rows, activity), by_section(rows)]
    |> Enum.reject(&is_nil/1)
  end

  defp source_section(rows) do
    sources =
      rows
      |> Enum.group_by(& &1.source.key)
      |> Enum.map(fn {key, [row | _] = held} -> {key, row.source, length(held)} end)
      |> Enum.sort_by(fn {_key, source, _n} -> source.rank end)

    if length(sources) > 1 do
      %{
        key: "source",
        title: gettext("Source"),
        items:
          for {key, source, n} <- sources do
            %{token: {:source, key}, label: source.label, count: n}
          end
      }
    end
  end

  defp paths_section(rows) do
    held = Enum.count(rows, &held?/1)

    %{
      key: "paths",
      title: gettext("Paths"),
      items: [
        %{token: {:paths, :held}, label: gettext("Held to paths"), count: held},
        %{token: {:paths, :every}, label: gettext("Every path"), count: length(rows) - held}
      ]
    }
  end

  defp seen_section(rows, activity) when is_map(activity) do
    seen = Enum.count(rows, &(used(&1, activity) > 0))

    %{
      key: "seen",
      title: gettext("Seen in 14 days"),
      items: [
        %{token: {:seen, :yes}, label: gettext("Seen"), count: seen},
        %{token: {:seen, :no}, label: gettext("Not seen"), count: length(rows) - seen}
      ]
    }
  end

  defp seen_section(_rows, _activity), do: nil

  defp by_section(rows) do
    people =
      rows
      |> Enum.filter(&by_key/1)
      |> Enum.group_by(&by_key/1)
      |> Enum.map(fn {key, held} -> {key, hd(held).by, length(held)} end)
      |> Enum.sort_by(fn {key, _by, n} -> {-n, key} end)

    if people != [] do
      %{
        key: "by",
        title: gettext("Added by"),
        items: for({key, by, n} <- people, do: %{token: {:by, key}, label: by, count: n})
      }
    end
  end

  ## Helpers

  defp key_of(map, value), do: Enum.find_value(map, fn {k, v} -> v == value && k end)

  defp put_param(params, _key, nil), do: params
  defp put_param(params, key, value), do: Map.put(params, key, value)

  defp page(value) when is_binary(value) and byte_size(value) <= 6 do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> min(n, @max_page)
      _ -> 1
    end
  end

  defp page(_value), do: 1
end
