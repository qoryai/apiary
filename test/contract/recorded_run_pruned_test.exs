defmodule Apiary.Contract.RecordedRunPrunedTest do
  @moduledoc """
  The record of one run of the server contract, `fixtures/run/<id>/events.jsonl`, delivered
  again after each phase of retention: nothing is stored and nothing is folded.
  """
  use Apiary.DataCase, async: true

  import Apiary.AccessKeysFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Retention
  alias Apiary.Runs.{Batch, Connection, Event, Ingest, LogChunk, Projector, Run}

  # What the runner's request says beside its body: the revision of the contract.
  @meta %{contract_version: 1}

  @moduletag :contract

  @runs (case Apiary.ContractFixtures.contract_dir() do
           nil ->
             []

           dir ->
             dir |> Path.join("fixtures/run/*/events.jsonl") |> Path.wildcard() |> Enum.sort()
         end)

  # A key of its own, not the contract's published one: `Apiary.Runs.Ingest` needs no
  # signature, and the published key id is one row every contract test inserts, on which
  # two tests at once wait for each other.
  setup do
    %{scope: scope} = sign_up_fixture()
    %{access_key: key} = access_key_fixture(scope)
    %{scope: scope, key: key}
  end

  defp deliver(key, lines) do
    for chunk <- Enum.chunk_every(lines, 100) do
      {:ok, batch} = Batch.parse("[" <> Enum.join(chunk, ",") <> "]")
      {:ok, result} = Ingest.ingest(key, batch, @meta)
      result
    end
  end

  defp state(run) do
    %{
      run:
        Run
        |> Repo.get!(run.id)
        |> Map.take([:state, :event_count, :denied_count, :projected_sequence, :last_event_at]),
      events: Repo.aggregate(from(e in Event, where: e.run_id == ^run.id), :count),
      chunks: Repo.aggregate(from(l in LogChunk, where: l.run_id == ^run.id), :count),
      connections:
        Repo.all(
          from c in Connection,
            where: c.run_id == ^run.id,
            order_by: [c.host, c.port, c.path],
            select: {c.host, c.port, c.path, c.attempts, c.allowed, c.denied, c.last_sequence}
        )
    }
  end

  for file <- @runs do
    @file_path file
    @subject file |> Path.dirname() |> Path.basename()

    test "#{@subject}: a replay after the log was pruned, then after the events were", %{
      scope: scope,
      key: key
    } do
      lines = @file_path |> File.read!() |> String.split("\n", trim: true)
      assert Enum.all?(deliver(key, lines), &(&1.status == 202))

      run =
        Repo.one!(
          from r in Run, where: r.workspace_id == ^scope.workspace.id and r.run_id == ^@subject
        )

      {:ok, run} = Projector.project(run)
      later = DateTime.add(DateTime.utc_now(), 400 * 86_400, :second)

      {:ok, workspace} = Retention.update_retention(scope, %{log_retention_days: 30})
      assert %{runs_pruned: 1} = Retention.prune_workspace(workspace, now: later)
      before = state(run)

      results = deliver(key, lines)
      assert Enum.all?(results, &(&1.status == 202 and &1.inserted == 0 and &1.conflicts == 0))
      {:ok, _run} = Projector.project(run)
      assert state(run) == before

      {:ok, workspace} =
        Retention.update_retention(scope, %{events_retention_days: 30, log_retention_days: nil})

      assert %{runs_pruned: 1} = Retention.prune_workspace(workspace, now: later)
      before = state(run)
      assert before.events == 0

      assert Enum.all?(deliver(key, lines), &(&1.status == 410))
      {:ok, _run} = Projector.project(run)
      assert state(run) == before
    end
  end
end
