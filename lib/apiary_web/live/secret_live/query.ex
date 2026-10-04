defmodule ApiaryWeb.SecretLive.Query do
  @moduledoc """
  What narrows the two lists of Secrets and variables (`ApiaryWeb.SecretLive.Index`),
  read from the URL and written back to it: the search `q`, the filters and the order.
  Pure over the rows the page holds, which are bounded (a workspace keeps at most 128
  variables a run is given, and a few dozen secrets).

    * **Secrets**: `q` finds a secret by its name or a value id, without case;
      `values=one` or `values=several` keeps the secrets with one value or with several.
    * **Variables**: `q` finds a variable by its name or its value, without case;
      `lock=yes` keeps the locked ones and `lock=no` the others; `targets=own` keeps the
      ones a repository sets too.
    * **Sort**: `name` (the default) or `changed`, the latest change first.

  A value the page does not know is left out, never an error.
  """

  defstruct q: "", values: nil, lock: nil, targets: nil, sort: :name

  @typedoc "A list's search, filters and order."
  @type t :: %__MODULE__{
          q: String.t(),
          values: :one | :several | nil,
          lock: :yes | :no | nil,
          targets: :own | nil,
          sort: :name | :changed
        }

  @typedoc "A filter in force, as a token under the list's bar."
  @type token :: {:values, :one | :several} | {:lock, :yes | :no} | {:targets, :own}

  @doc "from_params/1 is the query of the URL's `params`."
  @spec from_params(map) :: t
  def from_params(params) when is_map(params) do
    %__MODULE__{
      q: params |> Map.get("q", "") |> text(),
      values: pick(params["values"], %{"one" => :one, "several" => :several}),
      lock: pick(params["lock"], %{"yes" => :yes, "no" => :no}),
      targets: pick(params["targets"], %{"own" => :own}),
      sort: pick(params["sort"], %{"changed" => :changed}) || :name
    }
  end

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_value), do: ""

  defp pick(value, choices) when is_binary(value), do: Map.get(choices, value)
  defp pick(_value, _choices), do: nil

  @doc "to_params/1 is the query as the URL's parameters, the defaults left out."
  @spec to_params(t) :: keyword
  def to_params(%__MODULE__{} = query) do
    [
      q: if(query.q != "", do: query.q),
      values: query.values,
      lock: query.lock,
      targets: query.targets,
      sort: if(query.sort != :name, do: query.sort)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  @doc "for_secrets/1 is the query a view of the secrets keeps: its search, its filter and its order."
  @spec for_secrets(t) :: t
  def for_secrets(%__MODULE__{} = query), do: %{query | lock: nil, targets: nil}

  @doc "for_variables/1 is the query a view of the variables keeps."
  @spec for_variables(t) :: t
  def for_variables(%__MODULE__{} = query), do: %{query | values: nil}

  @doc "tokens/1 is the filters in force, each a token the reader can take away."
  @spec tokens(t) :: [token]
  def tokens(%__MODULE__{} = query) do
    [
      query.values && {:values, query.values},
      query.lock && {:lock, query.lock},
      query.targets && {:targets, query.targets}
    ]
    |> Enum.filter(& &1)
  end

  @doc "toggle/2 is the query with `token` put in force, or taken away when it is."
  @spec toggle(t, token) :: t
  def toggle(%__MODULE__{} = query, {key, value}) do
    if Map.get(query, key) == value,
      do: Map.put(query, key, nil),
      else: Map.put(query, key, value)
  end

  @doc "clear/1 is the query with no search and no filter, its order kept."
  @spec clear(t) :: t
  def clear(%__MODULE__{sort: sort}), do: %__MODULE__{sort: sort}

  @doc "narrowed?/1 says whether a search or a filter is in force."
  @spec narrowed?(t) :: boolean
  def narrowed?(%__MODULE__{} = query), do: query.q != "" or tokens(query) != []

  @doc """
  secrets/2 is `secrets` as `query` narrows and orders them: each an
  `Apiary.Secrets.Secret` with its values.
  """
  @spec secrets([struct], t) :: [struct]
  def secrets(secrets, %__MODULE__{} = query) do
    secrets
    |> Enum.filter(&secret_matches?(&1, query))
    |> order(query.sort)
  end

  defp secret_matches?(secret, query) do
    found?(query.q, [secret.name | Enum.map(secret.values, & &1.value_id)]) and
      case query.values do
        nil -> true
        :one -> length(secret.values) == 1
        :several -> length(secret.values) > 1
      end
  end

  @doc """
  variables/3 is `variables` as `query` narrows and orders them; `targets` is, by name
  without case, the repositories that set each name too
  (`Apiary.Variables.repository_overrides/1`).
  """
  @spec variables([struct], map, t) :: [struct]
  def variables(variables, targets, %__MODULE__{} = query) do
    variables
    |> Enum.filter(&variable_matches?(&1, targets, query))
    |> order(query.sort)
  end

  defp variable_matches?(variable, targets, query) do
    found?(query.q, [variable.name, variable.value]) and
      case query.lock do
        nil -> true
        :yes -> variable.locked
        :no -> not variable.locked
      end and
      case query.targets do
        nil -> true
        :own -> Map.get(targets, String.downcase(variable.name), []) != []
      end
  end

  defp found?("", _texts), do: true

  defp found?(q, texts) do
    q = String.downcase(q)
    Enum.any?(texts, &(is_binary(&1) and String.contains?(String.downcase(&1), q)))
  end

  # By name without case, or the latest change first, the name breaking a tie.
  defp order(rows, :name), do: Enum.sort_by(rows, &{String.downcase(&1.name), &1.name})

  defp order(rows, :changed) do
    Enum.sort(rows, fn a, b ->
      case DateTime.compare(a.updated_at, b.updated_at) do
        :gt -> true
        :lt -> false
        :eq -> String.downcase(a.name) <= String.downcase(b.name)
      end
    end)
  end
end
