defmodule Apiary.Runs.RunVariables do
  @moduledoc false

  # The variables Qory sets for a run of a workspace's queue, which its run configuration
  # carries (`variables` of the contract's `run-configuration.schema.json`) and Forager's
  # deny list leaves in by these names exactly: QORY_RUN_SYSTEM, the system the run's
  # repositories are on, and QORY_RUN_REPOSITORIES, the repositories its preparation
  # fetches, comma-separated with no space, the run's target first.
  #
  # These are the software domain's run variables and its rules for a target
  # (`Apiary.Lingo.Domain.Software`), the only caller of `for_target/2`. The rules, on
  # every system alike: the system a host name, 1 to 253 of a-z, 0-9, dot and dash, with
  # no empty label: not starting or ending in a dot, no two dots together;
  # the list at most 256 bytes; every entry exactly owner/name, two segments, each of A-Z,
  # a-z, 0-9, dot, underscore and dash, not starting with a dash, and neither being `.`,
  # `..` or `.git` in any case, at most 200 characters; every entry of the first
  # entry's owner, its first segment, compared without case; and no entry twice, compared
  # without case. Both are also held to the contract's rules for any variable. A pair that
  # breaks a rule is an error, never a smaller map: a run without its repositories would
  # start in an empty folder. `check_repositories/2` says which rule further repositories
  # break, and where, for the save that refuses them (`Apiary.Targets`), so a saved list
  # keeps the same rules.
  #
  # Pure: it reads no database.

  @system "QORY_RUN_SYSTEM"
  @repositories "QORY_RUN_REPOSITORIES"

  @host ~r/\A[a-z0-9.-]{1,253}\z/
  @segment ~r/\A[A-Za-z0-9._-]+\z/
  @max_list 256
  @max_entry 200

  # The contract's rules for any variable (`run-configuration.schema.json`).
  @name ~r/\A[A-Za-z_][A-Za-z0-9_]{0,127}\z/
  @max_value 4096
  @value_refused ["\0", "\r", "\n"]

  @type variables :: %{required(String.t()) => String.t()}

  @typedoc "Why a list of further repositories breaks the rules (`check_repositories/2`)."
  @type repositories_reason ::
          :not_a_path | :too_long | :other_owner | :itself | :repeats | :too_long_together

  @doc """
  The run variables of a run whose target is `system` and `path`, with `picked` the
  further repositories, in order, after the target's path. `{:ok, variables}`, the two
  names each with its value, or `{:error, :system_invalid}` or
  `{:error, :repositories_invalid}` for the first that breaks its rule: no segment of a
  path starts with a dash, and the system has no empty label.
  """
  @spec for_target(%{system: String.t(), path: String.t()}, [String.t()]) ::
          {:ok, variables} | {:error, :system_invalid | :repositories_invalid}
  def for_target(%{system: system, path: path}, picked \\ []) when is_list(picked) do
    entries = [path | picked]

    cond do
      not system?(system) ->
        {:error, :system_invalid}

      not (entry?(path) and check_repositories(path, picked) == :ok) ->
        {:error, :repositories_invalid}

      true ->
        variables = %{@system => system, @repositories => Enum.join(entries, ",")}

        if Enum.all?(variables, &variable?/1),
          do: {:ok, variables},
          else: {:error, :repositories_invalid}
    end
  end

  @doc """
  The value of QORY_RUN_REPOSITORIES in run variables `for_target/2` made: the target's
  path first, then the further repositories, joined with commas.
  """
  @spec repositories(variables) :: String.t()
  def repositories(%{@repositories => repositories}), do: repositories

  @doc """
  Whether `picked`, the further repositories in order after the target's `path`, keep the
  rules of QORY_RUN_REPOSITORIES: `:ok`, or `{:error, {reason, index}}` for the first they
  break, its index the place in `picked` counted from 1. Each path in turn, in this order:
  `:not_a_path`, not exactly owner/name of two segments of A-Z, a-z, 0-9, dot, underscore
  and dash, neither starting with a dash nor being `.`, `..` or `.git` in any case;
  `:too_long`, more than 200 characters; `:other_owner`, its owner not `path`'s first
  segment; `:itself`, `path` again; `:repeats`, a path before it again; the last three
  compared without case. Then the list: `:too_long_together`, `path` and `picked` joined
  with commas over 256 bytes, with the index of the last path. An empty `picked` keeps
  them. Whether `path` itself is owner/name is not asked here: `for_target/2` asks it.
  """
  @spec check_repositories(String.t(), [term]) ::
          :ok | {:error, {repositories_reason, pos_integer}}
  def check_repositories(path, picked) when is_binary(path) and is_list(picked) do
    owner = owner(path)
    seen = MapSet.new([String.downcase(path)])

    found =
      picked
      |> Enum.with_index(1)
      |> Enum.reduce_while(seen, fn {entry, n}, seen ->
        cond do
          not shaped?(entry) -> {:halt, {:not_a_path, n}}
          byte_size(entry) > @max_entry -> {:halt, {:too_long, n}}
          owner(entry) != owner -> {:halt, {:other_owner, n}}
          String.downcase(entry) == String.downcase(path) -> {:halt, {:itself, n}}
          MapSet.member?(seen, String.downcase(entry)) -> {:halt, {:repeats, n}}
          true -> {:cont, MapSet.put(seen, String.downcase(entry))}
        end
      end)

    cond do
      is_tuple(found) ->
        {:error, found}

      picked == [] ->
        :ok

      byte_size(Enum.join([path | picked], ",")) > @max_list ->
        {:error, {:too_long_together, length(picked)}}

      true ->
        :ok
    end
  end

  @doc """
  The `variables` member of a run configuration for `variables`: each name, in order,
  with an object holding its value.
  """
  @spec document(variables) :: Jason.OrderedObject.t()
  def document(variables) when is_map(variables) do
    variables
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {name, value} -> {name, Jason.OrderedObject.new([{"value", value}])} end)
    |> Jason.OrderedObject.new()
  end

  # No empty label: no dot first or last, and no two together.
  defp system?(system),
    do:
      is_binary(system) and Regex.match?(@host, system) and
        not String.starts_with?(system, ".") and not String.ends_with?(system, ".") and
        not String.contains?(system, "..")

  defp entry?(entry), do: shaped?(entry) and byte_size(entry) <= @max_entry

  # Exactly two segments, so no entry can be nested inside another.
  defp shaped?(entry) when is_binary(entry) do
    case String.split(entry, "/") do
      [owner, name] -> segment?(owner) and segment?(name)
      _other -> false
    end
  end

  defp shaped?(_entry), do: false

  # Not starting with a dash, so no segment reads as an option.
  defp segment?(segment),
    do:
      Regex.match?(@segment, segment) and not String.starts_with?(segment, "-") and
        segment not in [".", ".."] and String.downcase(segment) != ".git"

  # A path's owner, its first segment, compared without case.
  defp owner(path), do: path |> String.split("/") |> hd() |> String.downcase()

  defp variable?({name, value}),
    do:
      Regex.match?(@name, name) and byte_size(value) <= @max_value and String.valid?(value) and
        not String.contains?(value, @value_refused)
end
