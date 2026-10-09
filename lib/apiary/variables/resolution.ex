defmodule Apiary.Variables.Resolution do
  @moduledoc """
  The variables in force for a holder's runs, resolved down its chain of levels: the level
  above the workspace, when the edition keeps one (`Apiary.Policy.Above`, its
  `variables`), then the workspace, then, for a repository, the repository. The holder is
  the workspace, whose chain is the first two, or a repository (a target), whose chain is
  all three.

  `resolve/1` takes the levels from the top down and gives, for each name:

    * the **value** in force: the lowest level's that sets the name, unless a level above
      it **locked** the name, and then the locking level's;
    * its **provenance**, for the pages: the level that set the value in force
      (`set_by`), the level that locked it (`locked_by`, or nil), and the levels below a
      lock whose own value was set aside (`ignored`).

  Names are compared without case: `NODE_ENV` and `node_env` are one name, and it keeps
  the spelling of the highest level that sets it. A level locks a name only against the
  levels below it; a lock of the lowest level holds nothing. A name the runner keeps for
  itself (`Apiary.Variables.Denied.refused?/1`) or that breaks the name rule is left out,
  from whichever level it comes, so a level above that sets one does not pass it on.

  `values/1` maps each name to its value, `%{NAME => value}`. Nothing puts them in the run
  configuration: a run receives only its security policy. A holder's resolved variables
  are at most #{128} names and #{65_536} bytes of names and values (`check_limits/1`), the
  limits of the run configuration's `variables`
  (`priv/contract/run-configuration.schema.json`); `Apiary.Variables` refuses a save that
  would take any holder over them.
  """

  alias Apiary.Variables.{Denied, Variable}

  @max_names 128
  @max_bytes 65_536

  @typedoc "A level of the chain."
  @type level :: :above | :workspace | :target

  @typedoc "A name as resolved, with its provenance."
  @type entry :: %{
          name: String.t(),
          value: String.t(),
          set_by: level,
          locked_by: level | nil,
          ignored: [level]
        }

  @typedoc "A holder's resolution: its entries, by name without case."
  @type t :: %__MODULE__{entries: [entry]}

  defstruct entries: []

  @doc "The most names a holder's resolution has."
  @spec max_names() :: pos_integer
  def max_names, do: @max_names

  @doc "The most bytes of names and values a holder's resolution has."
  @spec max_bytes() :: pos_integer
  def max_bytes, do: @max_bytes

  @doc """
  resolve/1 resolves `levels`, from the top down: each `{level, variables}`, the
  variables `Apiary.Variables.Variable` structs, of which only `name`, `value` and
  `locked` are read.
  """
  @spec resolve([{level, [Variable.t() | map]}]) :: t
  def resolve(levels) when is_list(levels) do
    resolved =
      Enum.reduce(levels, %{}, fn {level, variables}, acc ->
        Enum.reduce(variables, acc, &take(level, &1, &2))
      end)

    %__MODULE__{
      entries: resolved |> Enum.sort_by(fn {key, _entry} -> key end) |> Enum.map(&elem(&1, 1))
    }
  end

  defp take(level, %{name: name, value: value} = variable, acc)
       when is_binary(name) and is_binary(value) do
    if valid_name?(name) do
      key = String.downcase(name)
      locks = if Map.get(variable, :locked) == true, do: level

      case acc do
        %{^key => %{locked_by: locked_by} = entry} when not is_nil(locked_by) ->
          Map.put(acc, key, %{entry | ignored: entry.ignored ++ [level]})

        %{^key => entry} ->
          Map.put(acc, key, %{entry | value: value, set_by: level, locked_by: locks})

        _none ->
          Map.put(acc, key, %{
            name: name,
            value: value,
            set_by: level,
            locked_by: locks,
            ignored: []
          })
      end
    else
      acc
    end
  end

  defp take(_level, _variable, acc), do: acc

  defp valid_name?(name),
    do: Regex.match?(Variable.name_format(), name) and not Denied.refused?(name)

  @doc """
  values/1 is the resolution as a map of each name to its value, `%{NAME => value}`.
  """
  @spec values(t) :: %{String.t() => String.t()}
  def values(%__MODULE__{entries: entries}), do: Map.new(entries, &{&1.name, &1.value})

  @doc "entry/2 is the entry of `name`, compared without case, or nil."
  @spec entry(t, String.t()) :: entry | nil
  def entry(%__MODULE__{entries: entries}, name) when is_binary(name) do
    key = String.downcase(name)
    Enum.find(entries, &(String.downcase(&1.name) == key))
  end

  @doc "size/1 is how many names and how many bytes of names and values the resolution holds."
  @spec size(t) :: %{names: non_neg_integer, bytes: non_neg_integer}
  def size(%__MODULE__{entries: entries}) do
    %{
      names: length(entries),
      bytes: Enum.reduce(entries, 0, &(&2 + byte_size(&1.name) + byte_size(&1.value)))
    }
  end

  @doc """
  check_limits/1 is `:ok` for a resolution within the contract's limits, else
  `{:error, :too_many_names}` past #{@max_names} names, or `{:error, :too_large}` past
  #{@max_bytes} bytes of names and values.
  """
  @spec check_limits(t) :: :ok | {:error, :too_many_names | :too_large}
  def check_limits(%__MODULE__{} = resolution), do: check_size(size(resolution))

  @doc "check_size/1 is `check_limits/1` of a size as `size/1` gives it."
  @spec check_size(%{names: non_neg_integer, bytes: non_neg_integer}) ::
          :ok | {:error, :too_many_names | :too_large}
  def check_size(%{names: names, bytes: bytes}) do
    cond do
      names > @max_names -> {:error, :too_many_names}
      bytes > @max_bytes -> {:error, :too_large}
      true -> :ok
    end
  end
end
