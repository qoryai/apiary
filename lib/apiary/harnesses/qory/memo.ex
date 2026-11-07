defmodule Apiary.Harnesses.Qory.Memo do
  # What `Apiary.Harnesses.Qory` decoded of a commit's stored files, by `{git, commit,
  # what}`: a commit's files never change, so an entry has no expiry. At most 1,024
  # entries; the one after them empties the table first. Reads and writes go to the table,
  # which this process owns, so it outlives the processes that fill it.
  @moduledoc false
  use GenServer

  @table __MODULE__
  @max_entries 1_024

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc false
  # fetch/2 is the value kept at `key`, else what `compute` returns: `{:ok, value}` is
  # kept and returned as `value`; `:none` is not kept, and is nil. With no table, as
  # before the process starts, `compute` runs each time.
  @spec fetch(term, (-> {:ok, term} | :none)) :: term
  def fetch(key, compute) do
    case lookup(key) do
      {:ok, value} ->
        value

      :miss ->
        case compute.() do
          {:ok, value} ->
            put(key, value)
            value

          :none ->
            nil
        end
    end
  end

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp put(key, value) do
    if :ets.info(@table, :size) >= @max_entries, do: :ets.delete_all_objects(@table)
    :ets.insert(@table, {key, value})
  rescue
    ArgumentError -> true
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, nil}
  end
end
