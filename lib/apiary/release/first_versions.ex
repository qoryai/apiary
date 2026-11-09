defmodule Apiary.Release.FirstVersions do
  @moduledoc """
  Writes version 1 of the policy of each workspace that has none at boot
  (`Apiary.Policy.first_versions/0`), before the endpoint accepts requests.

  The application's supervisor starts this child after `Apiary.KeyCheck`, because a
  version 1 includes the hosts of the integrations that reach the workspace, and reading
  those takes the right `APIARY_ENCRYPTION_SECRET`. It starts only where
  `Apiary.Release.Migrator` does (`config :apiary, :migrate_on_boot`): with
  `MIGRATE_ON_BOOT=false` the schema may still be behind the release, and `bin/migrate`
  writes the versions (`Apiary.Release.migrate/1`).

  A workspace whose version 1 is refused, raises or exits is logged and skipped, so it
  stops no boot. The next boot tries it again. A failure to list the workspaces is logged too, and
  the boot goes on.
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
  Writes the versions, logs their totals in one line, and returns `:ignore`, so nothing
  stays in the supervision tree.
  """
  @spec start_link() :: :ignore
  def start_link do
    %{written: written, refused: refused, failed: failed} = Apiary.Policy.first_versions()

    Logger.info(
      "policy version 1 at boot: written=#{written} refused=#{refused} failed=#{failed}"
    )

    :ignore
  rescue
    error ->
      Logger.error("policy version 1 not written at boot: #{Exception.message(error)}")
      :ignore
  catch
    kind, reason ->
      banner = Exception.format_banner(kind, reason, __STACKTRACE__)
      Logger.error("policy version 1 not written at boot: #{banner}")
      :ignore
  end
end
