defmodule Apiary.Release.FirstVersions do
  @moduledoc """
  Brings the policy of every workspace up to the release at boot, before the endpoint
  accepts requests (`run/0`): version 1 of each workspace that has none
  (`Apiary.Policy.first_versions/0`), then a render again of every workspace that has a
  version (`Apiary.Policy.rerender_all/1`), so a version that an earlier release wrote
  gains what this release renders, such as a runtime's host. The render writes a version
  only where a holder's bytes change, so a second boot writes nothing.

  The application's supervisor starts this child after `Apiary.KeyCheck`, because a
  render includes the hosts of the integrations that reach the workspace, and reading
  those takes the right `APIARY_ENCRYPTION_SECRET`. It starts only where
  `Apiary.Release.Migrator` does (`config :apiary, :migrate_on_boot`): with
  `MIGRATE_ON_BOOT=false` the schema may still be behind the release, and `bin/migrate`
  writes the versions 1 and renders every workspace again (`Apiary.Release.migrate/1`).

  A workspace whose version 1 or whose render again is refused, raises or exits is logged
  and skipped, so it stops neither the boot nor the other workspaces. The next boot tries
  it again. A failure to list the workspaces is logged too, and the boot goes on.
  """

  require Logger

  # The worker that the audit trail records for each version the render again writes.
  @origin %{worker: "Apiary.Release.FirstVersions"}

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
  Runs both steps (`run/0`), logs the totals of the versions 1 in one line, and returns
  `:ignore`, so nothing stays in the supervision tree.
  """
  @spec start_link() :: :ignore
  def start_link do
    _totals = run()
    :ignore
  end

  @doc """
  run/0 writes the versions 1 and logs their totals in one line, then renders every
  workspace again. A step that raises or exits is logged, and the next step runs.
  `%{first_versions: totals, rerendered: totals}`, the totals of
  `Apiary.Policy.first_versions/0` and `Apiary.Policy.rerender_all/1`, nil for a step
  that raised or exited.
  """
  @spec run() :: %{first_versions: map | nil, rerendered: map | nil}
  def run do
    first_versions = step("policy version 1 not written at boot", &first_versions/0)

    rerendered =
      step("policy not rendered again at boot", fn -> Apiary.Policy.rerender_all(@origin) end)

    %{first_versions: first_versions, rerendered: rerendered}
  end

  # Writes the versions 1 and logs their totals in one line.
  defp first_versions do
    %{written: written, refused: refused, failed: failed} =
      totals = Apiary.Policy.first_versions()

    Logger.info(
      "policy version 1 at boot: written=#{written} refused=#{refused} failed=#{failed}"
    )

    totals
  end

  defp step(failure, fun) do
    fun.()
  rescue
    error ->
      Logger.error("#{failure}: #{Exception.message(error)}")
      nil
  catch
    kind, reason ->
      Logger.error("#{failure}: #{Exception.format_banner(kind, reason, __STACKTRACE__)}")
      nil
  end
end
