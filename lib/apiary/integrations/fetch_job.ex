defmodule Apiary.Integrations.FetchJob do
  @moduledoc """
  Fetches a release a workspace asked for and records what was found
  (`Apiary.Integrations.fetch_release/2`), as the person who asked, whose
  `connection.write` is asked again. Unique per release while it waits, runs or is
  retried. Run twice, the second finds the release no longer pending and does nothing.
  """
  use Apiary.Job,
    queue: :default,
    max_attempts: 3,
    timeout: 120_000,
    unique: [
      period: :infinity,
      states: :incomplete,
      keys: [:organisation_id, :workspace_id, :release_id]
    ]

  alias Apiary.Accounts.Scope

  @impl Apiary.Job
  def perform(%Scope{} = scope, %Oban.Job{args: %{"release_id" => release_id}}) do
    case Apiary.Integrations.fetch_release(scope, release_id) do
      {:ok, _release} -> :ok
      {:error, reason} when reason in [:not_found, :forbidden] -> {:cancel, reason}
      {:error, reason} -> {:error, reason}
    end
  end
end
