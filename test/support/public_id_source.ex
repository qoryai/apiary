defmodule Apiary.PublicIdSource do
  @moduledoc """
  PublicIdSource gives `Apiary.PublicId.generate/1` its random bytes in the tests
  (`config/test.exs`). `force/1` queues ids for the calling process: the next
  `generate/1` calls in that process return them, in order, each with the prefix the
  caller gives; once the queue is empty the bytes are `:crypto`'s again. A test uses it to
  make an id collide with a row it inserted.
  """

  @alphabet ~c"0123456789abcdefghjkmnpqrstvwxyz"
  @key {__MODULE__, :queue}

  @doc """
  force/1 queues `randoms`, 16 characters of the alphabet each, as the random parts of the
  next ids made in the calling process.
  """
  @spec force([String.t()]) :: :ok
  def force(randoms) when is_list(randoms) do
    for random <- randoms do
      unless byte_size(random) == 16 and
               for(<<c <- random>>, reduce: true, do: (ok -> ok and c in @alphabet)),
             do: raise(ArgumentError, "not 16 characters of the alphabet: #{inspect(random)}")
    end

    Process.put(@key, Process.get(@key, []) ++ randoms)
    :ok
  end

  @doc "strong_rand_bytes/1 is `:crypto.strong_rand_bytes/1`, or the next queued id as bytes."
  @spec strong_rand_bytes(10) :: binary
  def strong_rand_bytes(10) do
    case Process.get(@key, []) do
      [random | rest] ->
        Process.put(@key, rest)
        for <<c <- random>>, into: <<>>, do: <<Enum.find_index(@alphabet, &(&1 == c))::5>>

      [] ->
        :crypto.strong_rand_bytes(10)
    end
  end
end
