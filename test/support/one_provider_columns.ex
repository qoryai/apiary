defmodule Apiary.OneProviderColumns do
  @moduledoc """
  A run's one-provider columns back for a test of a migration that ran while they
  existed: the migration that drops them (`DropARunSOneProviderColumns`) run down inside
  the test's transaction, which rolls it back as the test ends. That down reads the key
  rows' default credential column by its earlier name, `start`, so the later rename of
  the column (`RenameARunModelKeySStartToDefaultCredential`) runs down before it and up
  again after it. Ecto warns that an older migration ran after a newer one; a test that
  runs an older migration up after `back!/0` captures the log.
  """

  @columns {20_261_118_162_200, Apiary.Repo.Migrations.DropARunSOneProviderColumns,
            "drop_a_run_s_one_provider_columns"}
  @rename {20_261_119_161_000, Apiary.Repo.Migrations.RenameARunModelKeySStartToDefaultCredential,
           "rename_a_run_model_key_s_start_to_default_credential"}
  @options [log: false, migration_lock: false]

  @doc """
  Runs `DropARunSOneProviderColumns` down, with the rename of `start` down before it and
  up after it: the columns back, filled from the key rows, and `default_credential` as
  the schema has it.
  """
  def back! do
    for {version, migration, name} <- [@columns, @rename], not Code.ensure_loaded?(migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{version}_#{name}.exs")
      |> Code.require_file()
    end

    :ok = migrate(:down, @rename)
    :ok = migrate(:down, @columns)
    :ok = migrate(:up, @rename)
  end

  defp migrate(direction, {version, migration, _name}),
    do: apply(Ecto.Migrator, direction, [Apiary.Repo, version, migration, @options])
end
