defmodule Apiary.Registry.Grant do
  @moduledoc false

  # What a registry token grants, with the `registry` feature, which the documentation
  # leaves out: the scopes a token request lists, cut to what the run may use.
  #
  # A request lists its scopes in `scope` parameters, one scope a parameter,
  # `repository:<name>:<actions>`: the type ends at the first colon and the actions start
  # after the last one, the actions separated by commas. A parameter with a space or any
  # other whitespace is a malformed scope and grants nothing. More than 16 `scope`
  # parameters in one request is `{:error, {:too_many_scopes, count}}`.
  #
  # The run's rights (`t:rights/0`) are exact names of the instance with their actions.
  # Every run may pull any name under `shared/` and under `upstream/` for one of the 4
  # upstream hosts (`Apiary.Registry.Names`), and push on none of them: no run of a
  # workspace pushes there, and Qory Apiary starts no build of the instance's operator.
  # Each requested name gets the actions it asks for that the run has on it, of `pull`
  # and `push` alone: a scope of another type,
  # a name outside the run, another action, and a name that is not of the layout
  # (`Apiary.Registry.Names.layout?/1`) are left out. The entries keep the order of the
  # names' first scope, one entry per name, its actions in the order `pull`, `push`.

  alias Apiary.Registry.Names

  @max_scopes 16
  @actions ~w(pull push)

  @typedoc "A run's rights: each exact name with the actions the run has on it."
  @type rights :: %{String.t() => [String.t()]}

  @typedoc "One entry of a token's `access` claim."
  @type entry :: %{type: String.t(), name: String.t(), actions: [String.t(), ...]}

  @doc false
  @spec max_scopes() :: pos_integer
  def max_scopes, do: @max_scopes

  @doc false
  # grant/2 is the entries `rights` grant of the `scope` parameters `params`, one scope
  # each: `{:ok, entries}`, possibly none, or `{:error, {:too_many_scopes, count}}`.
  @spec grant(rights, [String.t()]) ::
          {:ok, [entry]} | {:error, {:too_many_scopes, pos_integer}}
  def grant(rights, params) when is_map(rights) and is_list(params) do
    if length(params) > @max_scopes do
      {:error, {:too_many_scopes, length(params)}}
    else
      {:ok, params |> Enum.flat_map(&parse/1) |> entries(rights)}
    end
  end

  defp parse(scope) do
    with false <- String.match?(scope, ~r/\s/),
         [type, rest] <- String.split(scope, ":", parts: 2),
         [name, actions] <- split_last(rest) do
      [{type, name, String.split(actions, ",")}]
    else
      _other -> []
    end
  end

  defp split_last(rest) do
    case :binary.matches(rest, ":") do
      [] ->
        []

      matches ->
        {at, 1} = List.last(matches)
        [binary_part(rest, 0, at), binary_part(rest, at + 1, byte_size(rest) - at - 1)]
    end
  end

  defp entries(scopes, rights) do
    {order, granted} =
      Enum.reduce(scopes, {[], %{}}, fn {type, name, actions}, {order, granted} ->
        allowed = if type == "repository", do: allowed(rights, name), else: []
        actions = Enum.filter(@actions, &(&1 in actions and &1 in allowed))

        cond do
          actions == [] ->
            {order, granted}

          Map.has_key?(granted, name) ->
            {order, Map.update!(granted, name, &merge(&1, actions))}

          true ->
            {[name | order], Map.put(granted, name, actions)}
        end
      end)

    for name <- Enum.reverse(order),
        do: %{type: "repository", name: name, actions: Map.fetch!(granted, name)}
  end

  defp merge(held, actions), do: Enum.filter(@actions, &(&1 in held or &1 in actions))

  # The actions the run has on `name`: none for a name outside the layout.
  defp allowed(rights, name) do
    cond do
      not Names.layout?(name) -> []
      Names.shared?(name) or Names.upstream?(name) -> ["pull"]
      true -> Enum.filter(@actions, &(&1 in Map.get(rights, name, [])))
    end
  end
end
