defmodule Apiary.Connections.SettingsFit do
  # Whether a model provider's saved settings fit the catalogue entry of its kind
  # (`Apiary.Connections.provider/1`), kept by `{SHA-256 of the settings' bytes, the
  # entry's SHA-256}`. The check returns the same result for the same settings and entry,
  # so a kept result has no expiry. Only the results `:fit` and `:unfit` are kept;
  # `:unchecked`, a check that ran out of time or crashed, runs again at the next read.
  # The table has at most 4,096 results on each node; the insert after them empties it
  # first, and a restart empties it too. Reads and writes go to the table, which this
  # process owns, so it outlives the processes that fill it.
  #
  # The test build (`test_seam: true` in `config/test.exs`) has `put_test_check/1`, which
  # sets a function of the entry and the settings that returns the result in place of the
  # check (`fit/3`); `clear/0` empties the table. No other build reads the application
  # environment here.
  @moduledoc false
  use GenServer

  alias Apiary.Kinds.Provider

  @table __MODULE__
  @max_entries 4_096
  @test_seam Application.compile_env(:apiary, [__MODULE__, :test_seam], false)

  @type answer :: :fit | :unfit | :unchecked

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc false
  # fit/3 is whether `settings`, a provider's saved settings as their stored bytes, fit
  # `entry`: the kept result, else what `check`, a function of the entry and the decoded
  # settings, returns. With no table, as before the process starts, `check` runs each
  # time.
  @spec fit(Provider.t(), String.t(), (Provider.t(), map -> answer)) :: answer
  def fit(%Provider{sha256: entry_sha256} = entry, settings, check) when is_binary(settings) do
    key = {:crypto.hash(:sha256, settings), entry_sha256}

    case lookup(key) do
      {:ok, answer} ->
        answer

      :miss ->
        answer = checker(check).(entry, Jason.decode!(settings))
        if answer in [:fit, :unfit], do: put(key, answer)
        answer
    end
  end

  @doc false
  # clear/0 empties the table, for a test.
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  if @test_seam do
    @doc false
    # put_test_check/1 sets the function that returns the result in place of the check,
    # for every process, or removes it with nil.
    @spec put_test_check((Provider.t(), map -> answer) | nil) :: :ok
    def put_test_check(nil), do: Application.delete_env(:apiary, :settings_fit_test_check)

    def put_test_check(check) when is_function(check, 2),
      do: Application.put_env(:apiary, :settings_fit_test_check, check)

    defp checker(check), do: Application.get_env(:apiary, :settings_fit_test_check) || check
  else
    defp checker(check), do: check
  end

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, answer}] -> {:ok, answer}
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp put(key, answer) do
    if :ets.info(@table, :size) >= @max_entries, do: :ets.delete_all_objects(@table)
    :ets.insert(@table, {key, answer})
  rescue
    ArgumentError -> true
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, nil}
  end
end
