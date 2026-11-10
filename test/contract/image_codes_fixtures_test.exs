defmodule Apiary.Contract.ImageCodesFixturesTest do
  @moduledoc """
  Projects the contract's batches of a session whose check of its image ended with one of
  Forager's image codes, `fixtures/link/link-batch-session-image-<code>.json`: the run is
  failed, and the session's code is a reason that a starter's outcome may not give
  (`Apiary.Runs.Outcome.reserved_reasons/0`).
  """
  use Apiary.DataCase, async: true

  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures, only: [run_fixture: 1]

  alias Apiary.Runs.{Batch, Event, Outcome, Projector}

  @moduletag :contract

  for {file, code} <- [
        {"link-batch-session-image-access-denied.json", "image_access_denied"},
        {"link-batch-session-image-rate-limited.json", "image_rate_limited"},
        {"link-batch-session-image-registry-unreachable.json", "image_registry_unreachable"}
      ] do
    test "#{file} projects a failed run, and #{code} is a reserved reason" do
      scope = scope_fixture()
      run = run_fixture(scope)

      # The batch of a session's events has no sequence: the gateway numbers them.
      events = contract_json!("link/" <> unquote(file))

      for {event, sequence} <- Enum.with_index(events, 2) do
        {:ok, time} = Batch.time(event["time"])

        Repo.insert!(%Event{
          organisation_id: run.organisation_id,
          workspace_id: run.workspace_id,
          run_id: run.id,
          sequence: sequence,
          node_event_id: Ecto.UUID.generate(),
          type: event["type"],
          time: time,
          data: event["data"],
          received_at: time
        })
      end

      assert [unquote(code)] =
               for(
                 %{"type" => "dev.qory.session.exited", "data" => data} <- events,
                 do: data["reason"]
               )

      assert {:ok, %{state: "failed"}} = Projector.project(run)
      assert unquote(code) in Outcome.reserved_reasons()
    end
  end
end
