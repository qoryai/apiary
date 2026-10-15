defmodule Apiary.Adapters.SeenRequestsPurge do
  @moduledoc false

  # Deletes the signatures of adapters' requests kept past their time
  # (`Apiary.Adapters.SeenRequests.purge/1`). Oban's cron plugin enqueues it every ten
  # minutes, from the crontab the application starts Oban with; it is the instance's work
  # and names no organisation. Run twice, the second run deletes nothing more.
  use Apiary.Job, scope: :instance, queue: :default, max_attempts: 3

  @impl Apiary.Job
  def perform(_scope, %Oban.Job{}) do
    _count = Apiary.Adapters.SeenRequests.purge(DateTime.utc_now())
    :ok
  end
end
