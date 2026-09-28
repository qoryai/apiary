defmodule Apiary.Runs.RateLimit do
  @moduledoc """
  The rate limit of the events endpoint: a token bucket per access key, in ETS.

  A key may deliver `rate` batches per second and `burst` at once; the defaults
  are 50 and 100, under `config :apiary, Apiary.Runs.RateLimit`. A bucket lives on
  this node only: on several nodes a key gets the limit on each.

  `check/2` runs in the caller: the bucket is read, refilled by the time passed
  and written back with a compare-and-swap, so two requests never spend the same
  token and no process is a bottleneck. This process owns the table and drops
  the buckets nobody has touched for a while, which are full again anyway.
  """
  use GenServer

  @table __MODULE__
  @sweep_every :timer.minutes(1)
  @idle :timer.minutes(10)
  # Tokens are counted in thousandths, in integers.
  @unit 1000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Spends one token of `key`'s bucket: `:ok`, or `{:error, retry_after_seconds}`
  when it is empty. `opts` overrides `:rate` and `:burst` of the configuration.
  """
  def check(key, opts \\ []) do
    config = Keyword.merge(Application.get_env(:apiary, __MODULE__, []), opts)
    rate = Keyword.get(config, :rate, 50)
    burst = Keyword.get(config, :burst, 100)
    spend(key, rate, burst * @unit, System.monotonic_time(:millisecond))
  end

  defp spend(key, rate, capacity, now) do
    case :ets.lookup(@table, key) do
      [] ->
        if :ets.insert_new(@table, {key, capacity - @unit, now}),
          do: :ok,
          else: spend(key, rate, capacity, now)

      [{^key, tokens, at} = old] ->
        # `rate` tokens a second is `rate` thousandths a millisecond.
        tokens = min(capacity, tokens + max(now - at, 0) * rate)

        cond do
          tokens < @unit -> {:error, retry_after(tokens, rate)}
          swap(old, {key, tokens - @unit, now}) -> :ok
          true -> spend(key, rate, capacity, now)
        end
    end
  end

  defp swap(old, new), do: :ets.select_replace(@table, [{old, [], [{:const, new}]}]) == 1

  defp retry_after(_tokens, rate) when rate <= 0, do: 1
  defp retry_after(tokens, rate), do: max(1, ceil((@unit - tokens) / rate / 1000))

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    Process.send_after(self(), :sweep, @sweep_every)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    before = System.monotonic_time(:millisecond) - @idle
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", before}], [true]}])
    Process.send_after(self(), :sweep, @sweep_every)
    {:noreply, state}
  end
end
