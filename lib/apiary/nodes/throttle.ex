defmodule Apiary.Nodes.Throttle do
  @moduledoc """
  The throttle of `Apiary.Nodes.seen/3`: at most one write per node and instance id in
  each #{15} seconds, kept in ETS on this server.

  `due?/3` runs in the caller and answers whether a write is due for the key at `now`,
  marking it written when it is; two requests at once may both be told yes, which costs
  one write more and nothing else. A key lives on this server only: on several servers
  each writes once a window. This process owns the table and drops the keys older than a
  window, which would be due again anyway.
  """
  use GenServer

  @table __MODULE__
  @window_ms :timer.seconds(15)
  @sweep_every :timer.minutes(1)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "window_ms/0 is the throttle's window, in milliseconds."
  @spec window_ms() :: pos_integer
  def window_ms, do: @window_ms

  @doc """
  due?/2 says whether a write for `key` is due at `now`: none was let through in the
  window before it. When one is, `now` is remembered as the key's last write.
  """
  @spec due?(term, DateTime.t()) :: boolean
  def due?(key, %DateTime{} = now) do
    at = DateTime.to_unix(now, :millisecond)

    case :ets.lookup(@table, key) do
      [{^key, last}] when at - last < @window_ms and at >= last ->
        false

      _none_or_old ->
        :ets.insert(@table, {key, at})
        true
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
    before = System.os_time(:millisecond) - @window_ms
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:<, :"$1", before}], [true]}])
    Process.send_after(self(), :sweep, @sweep_every)
    {:noreply, state}
  end
end
