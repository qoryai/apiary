defmodule Apiary.Adapters.CallClock do
  # The `time` of Qory Apiary's calls to the adapters on this node
  # (`Apiary.Adapters.Calls`): whole seconds in UTC that strictly increase for identical
  # calls, one adapter's calls to one path with the same members (`key/3`).
  #
  # An adapter refuses a call whose signature it has already seen, and keeps each
  # signature until the call's `time` is more than 300 seconds behind its clock (the
  # integration contract's `definitions.schema.json`). Two identical calls in the same
  # second would sign the same bytes, and the adapter would refuse the second with an
  # unsigned 401. So a call takes the later of the clock's second and one second after
  # the previous identical call on this node (`take/3`). Calls that differ sign different
  # bytes, so they share the clock's second.
  #
  # The adapter also refuses a `time` more than 300 seconds ahead of its clock. `Calls`
  # takes a time at most `ahead/0` seconds (60), plus the seconds the call has left,
  # ahead of this node's clock, and waits until it is no more than `ahead/0` ahead. A
  # call that would need a later time takes none and fails `:timeout` unsent.
  #
  # Kept in ETS on this node: two nodes of Qory Apiary keep separate times. This process
  # owns the table and drops, every minute, the calls whose last time is more than 600
  # seconds behind the clock, which the clock's second passes anyway.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false
  use GenServer

  @table __MODULE__
  @ahead 60
  @keep 600
  @sweep_every :timer.minutes(1)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc false
  # ahead/0 is the most seconds a taken time may be ahead of this node's clock before a
  # call waits for it.
  @spec ahead() :: pos_integer
  def ahead, do: @ahead

  @doc false
  # key/3 is the key of a call to the adapter `adapter_id` at `path` with `bytes`, its
  # body without `time`: the adapter's id and a SHA-256 of the path and the bytes.
  @spec key(Ecto.UUID.t(), String.t(), binary) :: {Ecto.UUID.t(), binary}
  def key(adapter_id, path, bytes) when is_binary(adapter_id) and is_binary(path),
    do: {adapter_id, :crypto.hash(:sha256, [path, 0, bytes])}

  @doc false
  # take/3 is the `time` of the next call with `key`, in Unix seconds: the later of
  # `now`, the clock's second, and one second after the time the previous call with that
  # key took on this node; `:late` when that time is after `latest`, and then the call
  # takes no time. Two callers at once never take the same time: the table's row changes
  # only from the time a caller read (a compare and swap).
  @spec take(term, integer, integer) :: {:ok, integer} | :late
  def take(key, now, latest) when is_integer(now) and is_integer(latest) do
    case :ets.lookup(@table, key) do
      [] when now > latest ->
        :late

      [] ->
        if :ets.insert_new(@table, {key, now}), do: {:ok, now}, else: take(key, now, latest)

      [{^key, last}] ->
        next = max(now, last + 1)
        swap = [{{key, last}, [], [{{{:const, key}, next}}]}]

        cond do
          next > latest -> :late
          :ets.select_replace(@table, swap) == 1 -> {:ok, next}
          true -> take(key, now, latest)
        end
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    Process.send_after(self(), :sweep, @sweep_every)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    before = System.os_time(:second) - @keep
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:<, :"$1", before}], [true]}])
    Process.send_after(self(), :sweep, @sweep_every)
    {:noreply, state}
  end
end
