defmodule Apiary.StagesDeclaredStub do
  @moduledoc """
  A stand-in for `Apiary.Processes.declared_snapshot/1` and `record_declared/2` while
  they are built on another branch: each workspace's snapshot of its harness's workflow
  names, kept in an ETS table by workspace. Configured for the tests in
  `config/test.exs`; it goes once the functions are merged.
  """

  @table __MODULE__

  @doc "declared_snapshot/1 is the workspace's newest snapshot, nil for none."
  def declared_snapshot(%{id: id}) do
    table()

    case :ets.lookup(@table, id) do
      [{^id, snapshot}] -> snapshot
      [] -> nil
    end
  end

  @doc "record_declared/2 stores `names` as the workspace's snapshot, read now."
  def record_declared(%{id: id}, names) do
    table()
    snapshot = %{names: names, read_at: DateTime.utc_now()}
    true = :ets.insert(@table, {id, snapshot})
    {:ok, snapshot}
  end

  # The table, made once by a process that lives as long as the test run.
  defp table do
    if :ets.whereis(@table) == :undefined do
      parent = self()

      spawn(fn ->
        try do
          :ets.new(@table, [:named_table, :public, :set])
        rescue
          ArgumentError -> :ok
        end

        send(parent, :table_ready)
        Process.sleep(:infinity)
      end)

      receive do
        :table_ready -> :ok
      after
        5_000 -> :ok
      end
    end

    :ok
  end
end
