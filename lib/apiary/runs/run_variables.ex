defmodule Apiary.Runs.RunVariables do
  @moduledoc false

  # The variables Qory sets for a run of a workspace's queue, which its run configuration
  # carries (`variables` of the contract's `run-configuration.schema.json`) and Forager's
  # deny list leaves in by these names exactly: QORY_RUN_SYSTEM, the system the run's
  # repositories are on, and QORY_RUN_REPOSITORIES, the repositories its preparation
  # fetches, comma-separated with no space, the run's target first.
  #
  # The rules, on every system alike: the system a host name, 1 to 253 of a-z, 0-9, dot
  # and dash, not ending in a dot; the list at most 256 bytes; every entry exactly
  # owner/name, two segments, each of A-Z, a-z, 0-9, dot, underscore and dash and neither
  # being `.`, `..` or `.git` in any case, at most 200 characters; every entry of the first
  # entry's owner, its first segment, compared without case; and no entry twice, compared
  # without case. Both are also held to the contract's rules for any variable. A pair that
  # breaks a rule is an error, never a smaller map: a run without its repositories would
  # start in an empty folder.
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

  @doc """
  The run variables of a run whose target is `system` and `path`, with `picked` the
  further repositories, in order, after the target's path. `{:ok, variables}`, the two
  names each with its value, or `{:error, :system_invalid}` or
  `{:error, :repositories_invalid}` for the first that breaks its rule.
  """
  @spec for_target(%{system: String.t(), path: String.t()}, [String.t()]) ::
          {:ok, variables} | {:error, :system_invalid | :repositories_invalid}
  def for_target(%{system: system, path: path}, picked \\ []) when is_list(picked) do
    entries = [path | picked]

    cond do
      not system?(system) ->
        {:error, :system_invalid}

      not repositories?(entries) ->
        {:error, :repositories_invalid}

      true ->
        variables = %{@system => system, @repositories => Enum.join(entries, ",")}

        if Enum.all?(variables, &variable?/1),
          do: {:ok, variables},
          else: {:error, :repositories_invalid}
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

  defp system?(system),
    do:
      is_binary(system) and Regex.match?(@host, system) and
        not String.ends_with?(system, ".")

  defp repositories?(entries) do
    Enum.all?(entries, &entry?/1) and
      byte_size(Enum.join(entries, ",")) <= @max_list and
      once_each?(entries) and
      one_owner?(entries)
  end

  defp entry?(entry) when is_binary(entry) and byte_size(entry) <= @max_entry do
    # Exactly two segments, so no entry can be nested inside another.
    case String.split(entry, "/") do
      [owner, name] -> segment?(owner) and segment?(name)
      _other -> false
    end
  end

  defp entry?(_entry), do: false

  defp segment?(segment),
    do:
      Regex.match?(@segment, segment) and segment not in [".", ".."] and
        String.downcase(segment) != ".git"

  defp once_each?(entries) do
    lowered = Enum.map(entries, &String.downcase/1)
    length(Enum.uniq(lowered)) == length(lowered)
  end

  defp one_owner?([first | _] = entries) do
    owner = &(&1 |> String.split("/") |> hd() |> String.downcase())
    Enum.all?(entries, &(owner.(&1) == owner.(first)))
  end

  defp variable?({name, value}),
    do:
      Regex.match?(@name, name) and byte_size(value) <= @max_value and String.valid?(value) and
        not String.contains?(value, @value_refused)
end
