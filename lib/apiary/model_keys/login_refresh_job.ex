defmodule Apiary.ModelKeys.LoginRefreshJob do
  @moduledoc false

  # Refreshes one sign-in in the background, for a claim that found its access token
  # expiring before the end of a run's time limit (`Apiary.ModelKeys.claim_keys/4`,
  # `blocked: :due`). The claim calls no provider: it enqueues this job, and the run waits
  # for it (`Apiary.Runs.Waiting`). The job calls `Apiary.ModelKeys.Login.access_token/3`
  # with `expires_before:` the time the claim gave, with the refresh reason of a sweep
  # (`proactive_expiry`), so the one refresh call a sign-in has is the lease's, and a
  # second job for the same key waits for it or finds the token fresh. The job holds no
  # token: its arguments are the key's row id and a time, and a failure is logged by its
  # kind alone. A refresh that fails leaves the key with `retry_at`, which a later claim
  # reads (`Apiary.ModelKeys.Login.status/2`); the next claim enqueues another job once
  # `retry_at` has passed.
  #
  # One job per key at a time: it is unique by the key's row id while one is available,
  # scheduled or executing.
  use Apiary.Job,
    scope: :organisation,
    queue: :default,
    max_attempts: 1,
    unique: [period: :infinity, keys: [:organisation_id, :secret_value_id], states: :incomplete]

  require Logger

  alias Apiary.Connections.Connection
  alias Apiary.ModelKeys.Login
  alias Apiary.Repo

  @doc """
  Enqueues the refresh of the sign-in `secret_value_id` of `provider` for a run that needs
  its access token until `expires_before`. Returns `:ok`, also when a job for the key
  exists. Runs inside the claim's transaction, so a claim that rolls back enqueues nothing.
  """
  @spec enqueue(Connection.t(), Ecto.UUID.t(), DateTime.t()) :: :ok
  def enqueue(%Connection{} = provider, secret_value_id, %DateTime{} = expires_before) do
    args = %{
      "organisation_id" => provider.organisation_id,
      "workspace_id" => nil,
      "provider_id" => provider.id,
      "secret_value_id" => secret_value_id,
      "expires_before" => DateTime.to_iso8601(expires_before)
    }

    case args |> new() |> Oban.insert() do
      {:ok, _job} -> :ok
      {:error, _changeset} -> Logger.error("model key sign-in refresh: the job was not enqueued")
    end

    :ok
  end

  @impl Apiary.Job
  def perform(_scope, %Oban.Job{args: args}) do
    with %Connection{} = provider <- Repo.get(Connection, args["provider_id"]),
         {:ok, before, _offset} <- DateTime.from_iso8601(args["expires_before"]) do
      refresh(provider, args["secret_value_id"], before)
    end

    :ok
  end

  defp refresh(provider, secret_value_id, before) do
    unless Login.stopping?() do
      _result =
        Login.access_token(provider, secret_value_id, trigger: :schedule, expires_before: before)
    end

    :ok
  rescue
    exception ->
      Logger.error("model key sign-in refresh: a job failed: #{inspect(exception.__struct__)}")
  catch
    kind, _reason ->
      Logger.error("model key sign-in refresh: a job failed: #{inspect(kind)}")
  end
end
