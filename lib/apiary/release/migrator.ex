defmodule Apiary.Release.Migrator do
  @moduledoc """
  Runs pending database migrations at boot, before the endpoint accepts requests: the
  core's and the edition's, then the edition's step after them
  (`Apiary.Release.migrate/1`). Version 1 of the policy of each workspace that has none is
  written later in the boot, after the key check, and every workspace is rendered again
  (`Apiary.Release.FirstVersions`).

  The application's supervisor starts this child only when `config :apiary, :migrate_on_boot`
  is true (the default for production releases; `MIGRATE_ON_BOOT=false` turns it off).
  An upgrade is a restart: the new release migrates and then serves. When a migration
  fails, this child fails to start and takes the boot down with it, so a release that
  cannot migrate never answers requests.

  `rel/overlays/bin/migrate` remains available for running the same migrations by hand.
  """

  require Logger

  @doc "Starts once, as a worker the supervisor does not restart."
  @spec child_spec(term) :: Supervisor.child_spec()
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      restart: :temporary,
      type: :worker
    }
  end

  @doc """
  Runs `Apiary.Release.migrate/1` with `first_versions: false` in a task and waits for it.
  Returns `:ignore` on success so nothing stays in the supervision tree; exits on failure.
  """
  @spec start_link() :: :ignore
  def start_link do
    Logger.info("Running pending database migrations")

    try do
      task = Task.async(fn -> Apiary.Release.migrate(first_versions: false) end)
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
