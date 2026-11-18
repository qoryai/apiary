defmodule Apiary.ModelKeys.LoginSweep do
  @moduledoc false

  # Refreshes the sign-ins that no run has refreshed for more than 7 days
  # (`Apiary.ModelKeys.Login.sweep_due/1`), each with the refresh reason `scheduled`, so a
  # key that runs do not use does not outlive its refresh token. Oban's cron plugin
  # enqueues it every 6 hours, from the crontab the application starts Oban with; it is
  # the instance's work and names no organisation. A pass takes at most 50 sign-ins, each
  # call limited to 15 seconds, so it ends inside the job's time; the sign-ins it leaves are
  # the next pass's. Run twice, the second run refreshes nothing more: a refreshed login is
  # no longer old, a failed one waits for its `retry_at`, and one the provider rejected for
  # good is `sign_in_needed`.
  use Apiary.Job, scope: :instance, queue: :default, max_attempts: 3

  require Logger

  alias Apiary.ModelKeys.Login

  @batch 50

  @impl Apiary.Job
  def perform(_scope, %Oban.Job{}) do
    for {provider, secret_value_id} <- Login.sweep_due(@batch) do
      refresh(provider, secret_value_id)
    end

    :ok
  end

  # One sign-in at a time: an exception of one does not end the pass for the others. It is
  # logged by its kind alone, as a refresh's arguments hold tokens.
  defp refresh(provider, secret_value_id) do
    _result = Login.access_token(provider, secret_value_id, trigger: :schedule)
    :ok
  rescue
    exception ->
      Logger.error("model key sign-in sweep: a refresh failed: #{inspect(exception.__struct__)}")
  catch
    kind, _reason ->
      Logger.error("model key sign-in sweep: a refresh failed: #{inspect(kind)}")
  end
end
