defmodule Apiary.Deletion.PurgeSweep do
  @moduledoc """
  The daily sweep of the deletions whose grace period is over: enqueues an
  `Apiary.Deletion.PurgeOrganisationJob` for every organisation marked for deletion and
  due (`Apiary.Deletion.page_organisations_due/2`), and an
  `Apiary.Deletion.PurgeWorkspaceJob` for every workspace marked and due of an
  organisation that is not (`Apiary.Deletion.page_workspaces_due/2`), so one purge's
  failure does not stop the others and each has its own retries. Oban's cron plugin
  enqueues it once a day, from the crontab the application starts Oban with; it is the
  instance's work, and names no organisation.
  """
  use Apiary.Job, scope: :instance, queue: :default, max_attempts: 3

  alias Apiary.Deletion

  @impl Apiary.Job
  def perform(_scope, %Oban.Job{conf: conf}) do
    oban = oban(conf)

    {:ok, _count} =
      Apiary.Job.insert_per_organisation(Deletion.PurgeOrganisationJob, %{},
        oban: oban,
        page: &Deletion.page_organisations_due/2
      )

    {:ok, _count} =
      Apiary.Job.insert_per_workspace(Deletion.PurgeWorkspaceJob, %{},
        oban: oban,
        page: &Deletion.page_workspaces_due/2
      )

    :ok
  end

  # The Oban instance the sweep runs in, so its jobs go to the same queue.
  defp oban(%Oban.Config{name: name}), do: name
  defp oban(_conf), do: Oban
end
