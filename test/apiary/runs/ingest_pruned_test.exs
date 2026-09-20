defmodule Apiary.Runs.IngestPrunedTest do
  @moduledoc """
  A batch delivered again after retention pruned the run stores nothing and folds
  nothing: through `Apiary.Runs.Ingest`, and through the events endpoint for the status
  and the headers.
  """
  use ApiaryWeb.ConnCase, async: true

  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures, only: [record: 0]
  import Ecto.Query

  alias Apiary.Repo
  alias Apiary.Retention
  alias Apiary.Runs.{Batch, Connection, Delivery, Event, Ingest, LogChunk, Projector, Run}

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope, key: published_key_fixture(scope)}
  end

  # The synthetic record as it is on the wire, with ids that stay the same over a replay.
  defp wire(subject) do
    for event <- record() do
      {sequence, type, data} =
        case event do
          {sequence, type, data} -> {sequence, type, data}
          {sequence, type, data, _opts} -> {sequence, type, data}
        end

      wire_event(subject, sequence, type, data)
    end
  end

  defp deliver(key, events) do
    {:ok, batch} = Batch.parse(Jason.encode!(events))
    {:ok, result} = Ingest.ingest(key, batch)
    result
  end

  defp received(scope, key) do
    subject = Ecto.UUID.generate()
    events = wire(subject)
    assert %{status: 202, inserted: 14} = deliver(key, events)
    run = Repo.one!(from r in Run, where: r.hive_id == ^scope.hive.id and r.run_id == ^subject)
    {:ok, run} = Projector.project(run)
    {run, events}
  end

  defp prune(scope, setting) do
    {:ok, hive} = Retention.update_retention(scope, setting)
    now = DateTime.add(DateTime.utc_now(), 400 * 86_400, :second)
    assert %{runs_pruned: 1} = Retention.prune_hive(hive, now: now)
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
            order_by: [c.host, c.port],
            select: {c.host, c.attempts, c.allowed, c.denied}
        )
    }
  end

  test "after the events were pruned the run takes nothing more: 410, as a closed run", %{
    scope: scope,
    key: key
  } do
    {run, events} = received(scope, key)
    prune(scope, %{events_retention_days: 30})
    before = state(run)
    assert before.events == 0

    assert %{status: 410, inserted: 0} = deliver(key, events)
    assert %{status: 410} = deliver(key, Enum.take(events, 3))

    # A new event of the run is no more welcome than an old one.
    assert %{status: 410} = deliver(key, [wire_event(run.run_id, 15, "run.heartbeat", %{})])

    {:ok, _run} = Projector.project(run)
    assert state(run) == before

    # The delivery is recorded, like a closed run's.
    assert Repo.exists?(from d in Delivery, where: d.run_id == ^run.run_id and d.status == 410)
  end

  test "after the log was pruned a replay of the whole record stores and folds nothing", %{
    scope: scope,
    key: key
  } do
    {run, events} = received(scope, key)
    prune(scope, %{log_retention_days: 30})
    before = state(run)
    assert %{events: 12, chunks: 0} = before

    assert %{status: 202, inserted: 0, duplicates: 14, conflicts: 0} = deliver(key, events)

    {:ok, _run} = Projector.project(run)
    assert state(run) == before

    # A log event the run never sent is not kept either; another event still is.
    late = [
      wire_event(run.run_id, 15, "run.log", %{"stream" => "stdout", "bytes" => "bGF0ZQo="}),
      wire_event(run.run_id, 16, "run.heartbeat", %{"elapsed_seconds" => 90})
    ]

    assert %{status: 202, inserted: 1, duplicates: 1} = deliver(key, late)
    {:ok, _run} = Projector.project(run)
    assert %{events: 13, chunks: 0} = state(run)
  end

  test "the endpoint answers 410 with the digests in force and an empty body", %{
    conn: conn,
    scope: scope,
    key: key
  } do
    {_run, events} = received(scope, key)
    prune(scope, %{events_retention_days: 30})

    conn = signed_post(conn, published_key_id(), published_secret(), Jason.encode!(events))

    assert response(conn, 410) == ""
    assert [<<"sha256=", _::binary>>] = get_resp_header(conn, "x-qory-configuration")
  end
end
