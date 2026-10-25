defmodule Apiary.Adapters.CallClock do
  # The `time` of Qory Apiary's calls to each adapter on this node
  # (`Apiary.Adapters.Calls`): whole seconds in UTC that strictly increase per adapter.
  #
  # An adapter refuses a call whose signature it has already seen, and keeps each
  # signature until the call's `time` is more than 300 seconds behind its clock (the
  # integration contract's `definitions.schema.json`). Two calls to one adapter with the
  # same members in the same second would sign the same bytes, and the adapter would
  # refuse the second with an unsigned 401. So each call takes the later of the clock's
  # second and one second after the adapter's previous call on this node (`take/2`).
  #
  # The adapter also refuses a `time` more than 300 seconds ahead of its clock. A taken
  # time stays at most `ahead/0` seconds (60) ahead of this node's clock: `Calls` waits
  # until it is, within the call's time, and fails the call `:timeout` when it cannot.
  #
  # Kept in ETS on this node: two nodes of Qory Apiary keep separate times. This process
  # owns the table and drops, every minute, the adapters whose last time is more than
  # 600 seconds behind the clock, which the clock's second passes anyway.
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
  # take/2 is the `time` of the next call to the adapter `adapter_id`, in Unix seconds:
  # the later of `now`, the clock's second, and one second after the time the adapter's
  # previous call on this node took. Two callers at once never take the same time: the
  # table's row changes only from the time a caller read (a compare and swap).
  @spec take(Ecto.UUID.t(), integer) :: integer
  def take(adapter_id, now) when is_binary(adapter_id) and is_integer(now) do
    case :ets.lookup(@table, adapter_id) do
      [] ->
        if :ets.insert_new(@table, {adapter_id, now}), do: now, else: take(adapter_id, now)

      [{^adapter_id, last}] ->
        next = max(now, last + 1)
        swap = [{{adapter_id, last}, [], [{{{:const, adapter_id}, next}}]}]

        case :ets.select_replace(@table, swap) do
          1 -> next
          0 -> take(adapter_id, now)
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
