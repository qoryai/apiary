defmodule Apiary.Organisations.InvitationSweep do
  @moduledoc """
  The daily sweep of the invitations: enqueues an
  `Apiary.Organisations.OldInvitationsJob` for every organisation on the instance
  (`Apiary.Job.insert_per_organisation/3`), which deletes the invitations expired for 30
  days. An invitation holds the address of someone who agreed to nothing, and is kept no
  longer than it is needed. Oban's cron plugin enqueues it once a day, from the crontab
  the application starts Oban with; it is the instance's work, and names no organisation.
  """
  use Apiary.Job, scope: :instance, queue: :default, max_attempts: 3

  @impl Apiary.Job
  def perform(_scope, %Oban.Job{conf: conf}) do
    {:ok, _count} =
      Apiary.Job.insert_per_organisation(Apiary.Organisations.OldInvitationsJob, %{},
        oban: oban(conf)
      )

    :ok
  end

  # The Oban instance the sweep runs in, so its jobs go to the same queue.
  defp oban(%Oban.Config{name: name}), do: name
  defp oban(_conf), do: Oban
end
