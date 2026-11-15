defmodule Apiary.TestDatabase do
  @moduledoc """
  TestDatabase drops the database of a partitioned test run when the run ends.

  A run with MIX_TEST_PARTITION set uses the database `apiary_test` followed by the value
  (config/test.exs), which the `test` alias creates. Without a drop, each value leaves one
  database behind. A run without a partition uses `apiary_test`, which every such run
  reuses: it is kept.

  `drop_at_exit/0` registers a hook that runs as the VM exits, after the suite has passed
  or failed, and after its last repeat under `mix test --repeat-until-failure`. The `test`
  alias registers the same hook before `ecto.create` (mix.exs), so the database is also
  dropped after a failed migration or a test helper that raises before
  `Apiary.TestSetup.start!/1`. The key `{Apiary.TestDatabase, :drop_at_exit}` in
  `:persistent_term` marks the hook as registered, so it is registered once per VM.

  The hook stops the application, which closes the repository's connections, then drops
  the database with `WITH (FORCE)` (Postgres 13 or later), which closes any connection
  left. A failed drop writes one warning line to stderr and leaves the run's exit code as
  it is.

  A run stopped by a signal ends without the hook, and so does one stopped by SIGKILL or
  a break of the VM, and one under `iex -S mix test`, where the VM does not halt.
  `scripts/test-run.sh` drops the database after INT, TERM or HUP too.
  """

  @registered {__MODULE__, :drop_at_exit}

  @doc """
  drop_at_exit/0 registers the drop for the end of the run (the moduledoc), unless the
  `test` alias or an earlier call registered it. `:ok`.
  """
  @spec drop_at_exit() :: :ok
  def drop_at_exit do
    if not :persistent_term.get(@registered, false) do
      :persistent_term.put(@registered, true)
      System.at_exit(fn _status -> drop() end)
    end

    :ok
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
  rescue
    error -> warn(nil, error)
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

  # The command is suggested only for a database that `to_drop/2` let drop: a name it keeps,
  # such as apiary_test, never appears in it.
  defp warn(nil, reason) do
    IO.puts(
      :stderr,
      "warning: the drop of the test database at the end of the run failed before it " <>
        "read the database's name: #{first_line(message(reason))}"
    )

    :error
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
  to_drop/2 decides whether the end of a run drops its database. Its arguments are the
  value of MIX_TEST_PARTITION and the configured database. It returns `{:drop, database}`
  when the partition contains only letters, digits and underscores and the database is
  `apiary_test` followed by the partition, and `:keep` in every other case. Ecto puts the
  name into `DROP DATABASE` without escaping it, so no other character is allowed.
  """
  @spec to_drop(String.t() | nil, String.t() | nil) :: {:drop, String.t()} | :keep
  def to_drop(partition, database) when is_binary(partition) and is_binary(database) do
    if partition =~ ~r/\A[A-Za-z0-9_]+\z/ and database == "apiary_test" <> partition,
      do: {:drop, database},
      else: :keep
  end

  def to_drop(_partition, _database), do: :keep
end
