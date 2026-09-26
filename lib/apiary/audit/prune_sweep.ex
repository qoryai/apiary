defmodule Apiary.Audit.PruneSweep do
  @moduledoc """
  The daily sweep of the audit trail's retention: enqueues an `Apiary.Audit.PruneJob` for
  every organisation on the instance (`Apiary.Job.insert_per_organisation/3`), so one
  organisation's failure does not stop the others and each has its own retries. Oban's
  cron plugin enqueues it once a day (`config/config.exs`); it is the instance's work, and
  names no organisation.
  """
  use Apiary.Job, scope: :instance, queue: :default, max_attempts: 3

  @impl Apiary.Job
  def perform(_scope, %Oban.Job{conf: conf}) do
    {:ok, _count} =
      Apiary.Job.insert_per_organisation(Apiary.Audit.PruneJob, %{}, oban: oban(conf))

    :ok
  end

  # The Oban instance the sweep runs in, so its jobs go to the same queue.
  defp oban(%Oban.Config{name: name}), do: name
  defp oban(_conf), do: Oban
end
