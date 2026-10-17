defmodule Apiary.Adapters.SeenRequestsPurge do
  @moduledoc false

  # Deletes the signatures of adapters' requests kept past their time
  # (`Apiary.Adapters.SeenRequests.purge/1`), and the bookkeeping of listings of
  # collections kept past a day (`Apiary.Adapters.Collections.purge_listings/1`). Oban's
  # cron plugin enqueues it every ten
  # minutes, from the crontab the application starts Oban with; it is the instance's work
  # and names no organisation. Run twice, the second run deletes nothing more.
  use Apiary.Job, scope: :instance, queue: :default, max_attempts: 3

  @impl Apiary.Job
  def perform(_scope, %Oban.Job{}) do
    now = DateTime.utc_now()
    _count = Apiary.Adapters.SeenRequests.purge(now)
    _listings = Apiary.Adapters.Collections.purge_listings(now)
    :ok
  end
end
