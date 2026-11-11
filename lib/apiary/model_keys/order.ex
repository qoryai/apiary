defmodule Apiary.ModelKeys.Order do
  @moduledoc """
  The order of one model provider's keys at a run's claim, and the keys the run gets.
  Pure: keys and a time in, keys out.

  A key here is a map with:

    * `id`: the key's row id (`secret_values.id`);
    * `named`: true for the key the model choice names, at most one;
    * `default`: true for the provider's default key, at most one;
    * `inserted_at`: when the key was added;
    * `known_reset`: its known reset, nil for none;
    * `cooldown_until`: the end of its cooldown, the latest across its windows, nil for
      none.

  A claim reads them with `Apiary.ModelKeys.claim_keys/3`.

  At `now`, a key is **in cooldown** while its `cooldown_until` is after `now`, and
  **free** otherwise. `order/2` puts the free keys first:

    1. the named key;
    2. then the keys with no known reset, or one at or before `now`, in tie order;
    3. then the keys by their known reset, the closest first; two resets in the same
       minute go in tie order.

  **Tie order:** the default key first, then the others by `inserted_at`, then by `id`.

  The keys in cooldown follow, the earliest `cooldown_until` first, ties in tie order: a
  named key in cooldown takes its place among them. Of the result, a run gets the first
  `max_keys/0`; the others serve later runs. The run's start key is its first free key
  (`start/2`): never a key in cooldown.
  """

  # A run's model keys, within the 8 credentials of a run configuration, which also has
  # the registry's and the work credentials.
  @max_keys 6

  @typedoc "A key as the order reads it (the moduledoc)."
  @type key :: %{
          required(:id) => term,
          required(:named) => boolean,
          required(:default) => boolean,
          required(:inserted_at) => DateTime.t(),
          required(:known_reset) => DateTime.t() | nil,
          required(:cooldown_until) => DateTime.t() | nil,
          optional(atom) => term
        }

  @doc "The most model keys a run gets: 6."
  @spec max_keys() :: pos_integer
  def max_keys, do: @max_keys

  @doc """
  The keys a run gets at `now`, in their order (the moduledoc): at most `max_keys/0`,
  the free keys first.
  """
  @spec order([key], DateTime.t()) :: [key]
  def order(keys, %DateTime{} = now) do
    {cooling, free} = Enum.split_with(keys, &cooling?(&1, now))
    {named, free} = Enum.split_with(free, & &1.named)
    {unknown, known} = Enum.split_with(free, &unknown_reset?(&1, now))

    free =
      named ++
        Enum.sort_by(unknown, &tie/1) ++
        Enum.sort_by(known, &{minute(&1.known_reset), tie(&1)})

    cooling = Enum.sort_by(cooling, &{usec(&1.cooldown_until), tie(&1)})

    Enum.take(free ++ cooling, @max_keys)
  end

  @doc "The first free key of `keys` at `now`, nil when every key is in cooldown."
  @spec start([key], DateTime.t()) :: key | nil
  def start(keys, %DateTime{} = now), do: Enum.find(keys, &(not cooling?(&1, now)))

  @doc "Whether `key` is in cooldown at `now`: its `cooldown_until` is after `now`."
  @spec cooling?(key, DateTime.t()) :: boolean
  def cooling?(%{cooldown_until: %DateTime{} = until}, %DateTime{} = now),
    do: DateTime.compare(until, now) == :gt

  def cooling?(_key, _now), do: false

  defp unknown_reset?(%{known_reset: %DateTime{} = reset}, now),
    do: DateTime.compare(reset, now) != :gt

  defp unknown_reset?(_key, _now), do: true

  defp tie(key), do: {if(key.default, do: 0, else: 1), usec(key.inserted_at), key.id}

  defp minute(%DateTime{} = time), do: div(DateTime.to_unix(time, :second), 60)

  defp usec(%DateTime{} = time), do: DateTime.to_unix(time, :microsecond)
end
