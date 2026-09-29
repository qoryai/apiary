defmodule ApiaryWeb.TargetLive.Query do
  @moduledoc """
  The query of the targets' index (`ApiaryWeb.TargetLive.Index`) as its URL carries it,
  read into what `Apiary.Targets.page/3` asks for and written back.

    * `view`: `active` or `never`; none is every target.
    * `q`: the search, free text found anywhere in `system/path`, and qualifiers: the
      system (`system:`, or the domain's word for it, `forge:` in the software domain),
      the policy (`mode:follows`, `mode:observes`, `mode:enforces`), the activity
      (`activity:quiet-30d`, `activity:quiet-90d`) and `is:pinned`. The Filter menu writes
      the same qualifiers; the page shows each as a token the reader removes.
    * `sort`: `name`, `runs` or `denials`; none is by last run.
    * `page`, from 1.

  A value it does not know is left out, and the URL is written without it.
  """
  use Gettext, backend: ApiaryWeb.Gettext

  defstruct view: :all, sort: :last_run, page: 1, tokens: [], text: ""

  @typedoc "A qualifier the search holds."
  @type token ::
          {:system, String.t()}
          | {:mode, :follows | :observes | :enforces}
          | {:activity, :quiet_30 | :quiet_90}
          | {:pinned, true}

  @type t :: %__MODULE__{
          view: :all | :active | :never,
          sort: :last_run | :name | :runs | :denials,
          page: pos_integer,
          tokens: [token],
          text: String.t()
        }

  @views %{"active" => :active, "never" => :never}
  @sorts %{"name" => :name, "runs" => :runs, "denials" => :denials}
  @modes %{"follows" => :follows, "observes" => :observes, "enforces" => :enforces}
  @activities %{"quiet-30d" => :quiet_30, "quiet-90d" => :quiet_90}
  @max_page 1_000

  @doc "parse/1 reads the URL's parameters."
  @spec parse(map) :: t
  def parse(params) when is_map(params) do
    {tokens, text} = parse_search(params["q"])

    %__MODULE__{
      view: Map.get(@views, params["view"], :all),
      sort: Map.get(@sorts, params["sort"], :last_run),
      page: page(params["page"]),
      tokens: tokens,
      text: text
    }
  end

  @doc """
  parse_search/1 splits what the reader typed into its qualifiers and its free text: a
  word `key:value` with a known key and value is a qualifier, every other word text.
  """
  @spec parse_search(String.t() | nil) :: {[token], String.t()}
  def parse_search(q) when is_binary(q) do
    {tokens, words} =
      q
      |> String.split()
      |> Enum.reduce({[], []}, fn word, {tokens, words} ->
        case qualifier(word) do
          nil -> {tokens, [word | words]}
          token -> {[token | tokens], words}
        end
      end)

    {tokens |> Enum.reverse() |> Enum.uniq(), words |> Enum.reverse() |> Enum.join(" ")}
  end

  def parse_search(_q), do: {[], ""}

  @doc """
  pending/1 is what the reader typed without the words that look like a qualifier
  (`key:value`), known or half typed: the free text of a search sent before Enter.
  """
  @spec pending(String.t()) :: String.t()
  def pending(q) when is_binary(q) do
    q
    |> String.split()
    |> Enum.reject(&String.match?(&1, ~r/^[a-z]+:/i))
    |> Enum.join(" ")
  end

  defp qualifier(word) do
    system = system_key()

    case String.split(word, ":", parts: 2) do
      [key, value] when value != "" and key in [system, "system"] -> {:system, value}
      ["mode", value] -> if mode = @modes[value], do: {:mode, mode}
      ["activity", value] -> if activity = @activities[value], do: {:activity, activity}
      ["is", "pinned"] -> {:pinned, true}
      _other -> nil
    end
  end

  @doc """
  The word the search takes for a target's system: the domain's (`forge` in the software
  domain), which the page shows.
  """
  def system_key, do: pgettext("qualifier", "system")

  @doc "What `Apiary.Targets.page/3` is asked."
  @spec to_targets(t) :: Apiary.Targets.query()
  def to_targets(%__MODULE__{} = query) do
    %{
      view: query.view,
      sort: query.sort,
      page: query.page,
      text: if(query.text == "", do: nil, else: query.text),
      systems: for({:system, system} <- query.tokens, do: system),
      modes: for({:mode, mode} <- query.tokens, do: mode),
      activity:
        Enum.find_value(query.tokens, fn t -> match?({:activity, _}, t) && elem(t, 1) end),
      pinned: {:pinned, true} in query.tokens
    }
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

  @doc "The search as the field and the URL write it: the qualifiers, then the text."
  @spec search(t) :: String.t() | nil
  def search(%__MODULE__{tokens: tokens, text: text}) do
    case Enum.map(tokens, &token_text/1) ++ if(text == "", do: [], else: [text]) do
      [] -> nil
      words -> Enum.join(words, " ")
    end
  end

  @doc "A qualifier as the search writes it: `forge:github.example`, `is:pinned`."
  @spec token_text(token) :: String.t()
  def token_text({:system, system}), do: "#{system_key()}:#{system}"
  def token_text({:mode, mode}), do: "mode:#{key_of(@modes, mode)}"
  def token_text({:activity, activity}), do: "activity:#{key_of(@activities, activity)}"
  def token_text({:pinned, true}), do: "is:pinned"

  @doc "Whether the query narrows the targets beyond its view."
  @spec narrowed?(t) :: boolean
  def narrowed?(%__MODULE__{tokens: tokens, text: text}), do: tokens != [] or text != ""

  @doc """
  toggle/2 is `query` with `token` added, or taken out when it is there, on its first
  page. A system, an activity and a mode replace one of their kind: the Filter menu picks
  one of each.
  """
  @spec toggle(t, token) :: t
  def toggle(%__MODULE__{tokens: tokens} = query, token) do
    tokens =
      if token in tokens,
        do: List.delete(tokens, token),
        else: Enum.reject(tokens, &(elem(&1, 0) == elem(token, 0))) ++ [token]

    %{query | tokens: tokens, page: 1}
  end

  defp key_of(map, value), do: Enum.find_value(map, fn {k, v} -> v == value && k end)

  defp put_param(params, _key, nil), do: params
  defp put_param(params, key, value), do: Map.put(params, key, value)

  defp page(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> min(n, @max_page)
      _ -> 1
    end
  end

  defp page(_value), do: 1
end
