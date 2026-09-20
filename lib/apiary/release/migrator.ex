defmodule Apiary.Release.Migrator do
  @moduledoc """
  Runs pending database migrations at boot, before the endpoint accepts requests.

  The application's supervisor starts this child only when `config :apiary, :migrate_on_boot`
  is true (the default for production releases; `MIGRATE_ON_BOOT=false` turns it off).
  An upgrade is a restart: the new release migrates and then serves. When a migration
  fails, this child fails to start and takes the boot down with it, so a release that
  cannot migrate never answers requests.

  `rel/overlays/bin/migrate` remains available for running the same migrations by hand.
  """

  require Logger

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      restart: :temporary,
      type: :worker
    }
  end

  @doc """
  Runs `Apiary.Release.migrate/0` in a task and waits for it. Returns `:ignore` on
  success so nothing stays in the supervision tree; exits on failure.
  """
  def start_link do
    Logger.info("Running pending database migrations")

    try do
      task = Task.async(&Apiary.Release.migrate/0)
      Task.await(task, :infinity)

      Logger.info("Database migrations are up to date")
      :ignore
    catch
      :exit, reason ->
        Logger.error("Database migration failed; refusing to boot")
        exit(reason)
    end
  end
end
