defmodule Apiary.TestDatabase do
  @moduledoc """
  TestDatabase drops the database of a partitioned test run when the run ends.

  A run with MIX_TEST_PARTITION set uses the database `apiary_test` followed by the value
  (config/test.exs), which the `test` alias creates. Without a drop, each value leaves one
  database behind. A run without a partition uses `apiary_test`, which every such run
  reuses: it is kept.

  `drop_at_exit/0` registers a hook that runs as the VM exits, after the suite has passed
  or failed, and after its last repeat under `mix test --repeat-until-failure`. The hook
  stops the application, which closes the repository's connections, then drops the
  database with `WITH (FORCE)` (Postgres 13 or later), which closes any connection left.
  A failed drop writes one warning line to stderr and leaves the run's exit code as it is.

  A run stopped by a signal ends without the hook, and so does one stopped by SIGKILL.
  `scripts/test-run.sh` drops the database after a signal too.
  """

  @doc """
  drop_at_exit/0 registers the drop for the end of the run (the moduledoc). Call it once,
  before the suite starts. `:ok`.
  """
  @spec drop_at_exit() :: :ok
  def drop_at_exit do
    System.at_exit(fn _status -> drop() end)
  end

  @doc """
  drop/0 stops the application and drops the run's database when `to_drop/2` returns
  `{:drop, database}`: `:ok` once the database is gone, `:kept` for a run that keeps it,
  `:error` after a failed drop, which writes one warning line to stderr. It never raises.
  """
  @spec drop() :: :ok | :kept | :error
  def drop do
    config = Apiary.Repo.config()

    case to_drop(System.get_env("MIX_TEST_PARTITION"), config[:database]) do
      :keep -> :kept
      {:drop, database} -> drop(database, config)
    end
  end

  defp drop(database, config) do
    _ = Application.stop(:apiary)
    options = Keyword.merge(config, force_drop: true, timeout: 15_000)

    case Apiary.Repo.__adapter__().storage_down(options) do
      :ok -> :ok
      {:error, :already_down} -> :ok
      {:error, reason} -> warn(database, reason)
    end
  rescue
    error -> warn(database, error)
  catch
    kind, reason -> warn(database, {kind, reason})
  end

  defp warn(database, reason) do
    partition = String.replace_prefix(database, "apiary_test", "")

    IO.puts(
      :stderr,
      "warning: drop the test database #{database} with `MIX_ENV=test " <>
        "MIX_TEST_PARTITION=#{partition} mix ecto.drop --force-drop`: the drop at the end " <>
        "of the run failed: #{first_line(message(reason))}"
    )

    :error
  end

  defp message(%{__exception__: true} = error), do: Exception.message(error)
  defp message(reason) when is_binary(reason), do: reason
  defp message(reason), do: inspect(reason)

  # Postgrex adds the query on the lines after the error; the warning is one line.
  defp first_line(text), do: text |> String.split("\n", trim: true) |> List.first("")

  @doc """
  to_drop/2 is what the end of a run does with its database, given the value of
  MIX_TEST_PARTITION and the database the repository is configured with:
  `{:drop, database}` when the partition is set and not empty and the database is
  `apiary_test` followed by it, and `:keep` otherwise.
  """
  @spec to_drop(String.t() | nil, String.t() | nil) :: {:drop, String.t()} | :keep
  def to_drop(partition, database)
      when is_binary(partition) and partition != "" and database == "apiary_test" <> partition,
      do: {:drop, database}

  def to_drop(_partition, _database), do: :keep
end
