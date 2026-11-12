defmodule Apiary.Connections.SettingsFit do
  # Whether a model provider's saved settings fit the catalogue entry of its kind
  # (`Apiary.Connections.provider/1`), kept by `{SHA-256 of the settings' bytes, the
  # entry's SHA-256}`: the same settings and the same entry give the same answer, so an
  # entry has no expiry. Only an answer the settings decide is kept, `:fit` or `:unfit`;
  # `:unchecked`, a check that ran out of time or crashed, is checked again at the next
  # read. At most 4,096 entries; the one after them empties the table first. Reads and
  # writes go to the table, which this process owns, so it outlives the processes that
  # fill it.
  #
  # A test sets the application environment's `{:apiary, __MODULE__}` `:check` to a
  # function of the entry and the settings that returns the answer in place of the check
  # (`fit/3`), and empties the table with `clear/0`.
  @moduledoc false
  use GenServer

  alias Apiary.Kinds.Provider

  @table __MODULE__
  @max_entries 4_096

  @type answer :: :fit | :unfit | :unchecked

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc false
  # fit/3 is whether `settings`, a provider's saved settings as their stored bytes, fit
  # `entry`: the kept answer, else what `check`, a function of the entry and the decoded
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

  defp checker(check) do
    case Application.get_env(:apiary, __MODULE__, [])[:check] do
      nil -> check
      test_check when is_function(test_check, 2) -> test_check
    end
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
