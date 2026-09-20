defmodule Apiary.Runs.ProjectorTest do
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures
  import ExUnit.CaptureLog

  alias Apiary.Runs
  alias Apiary.Runs.{Connection, Event, LogChunk, Projector, Repository, Run}

  setup do
    scope = scope_fixture()
    %{scope: scope, run: run_fixture(scope)}
  end

  # Everything the projector writes, in a shape two runs can be compared by.
  defp projection(%Run{id: id}) do
    run = Repo.get!(Run, id)

    %{
      run:
        Map.drop(run, [
          :__meta__,
          :id,
          :run_id,
          :organisation_id,
          :hive_id,
          :inserted_at,
          :updated_at,
          :organisation,
          :hive,
          :access_key,
          :repository_record,
          :closed_by,
          :events,
          :log_chunks,
          :connections
        ]),
      connections:
        Repo.all(
          from c in Connection,
            where: c.run_id == ^id,
            order_by: [c.host, c.port, c.path],
            select:
              map(c, [
                :organisation_id,
                :hive_id,
                :host,
                :port,
                :path,
                :method,
                :attempts,
                :allowed,
                :denied,
                :last_decision,
                :last_rule,
                :last_outcome,
                :last_sequence,
                :first_seen_at,
                :last_seen_at
              ])
        ),
      log_chunks:
        Repo.all(
          from l in LogChunk,
            where: l.run_id == ^id,
            order_by: l.sequence,
            select: {l.sequence, l.stream, l.bytes}
        ),
      unprojected:
        Repo.aggregate(from(e in Event, where: e.run_id == ^id), :count, :id) -
          Repo.aggregate(
            from(e in Event, where: e.run_id == ^id and not is_nil(e.projected_at)),
            :count,
            :id
          )
    }
  end

  describe "project/1" do
    test "folds the whole record", %{run: run} do
      events_fixture(run, record())

      assert {:ok, %Run{} = projected} = Projector.project(run)

      assert projected.state == "exited"
      assert projected.runner_version == "v0.4.0"
      assert projected.contract_version == 1
      assert projected.runtime == "claude"
      assert projected.args == ["-p", "fix the build"]
      assert projected.host == "dev-laptop"
      assert projected.task == "issue-12"
      assert projected.forge == "git.example.com"
      assert projected.repository == "acme/shop"
      assert projected.labels["repository"] == "acme/shop"
      assert projected.started_at == at(2)
      assert projected.exited_at == at(61.5)
      assert projected.exit_code == 0
      assert projected.duration_ms == 61_500
      # The heartbeat with the highest sequence, at the time this server received it.
      assert projected.last_heartbeat_at == at(130)
      assert projected.elapsed_seconds == 60
      assert projected.heartbeat_interval_seconds == 20
      assert projected.policy_digest == String.duplicate("2b", 32)
      assert projected.run_configuration_digest == "sha256=" <> String.duplicate("3c", 32)
      assert projected.projected_sequence == 14

      assert %{unprojected: 0, log_chunks: chunks, connections: connections} = projection(run)
      assert chunks == [{5, "stdout", "building\n"}, {9, "stderr", <<255, 0, 10>>}]

      assert [
               %{
                 host: "api.example.com",
                 port: 443,
                 path: "",
                 attempts: 2,
                 allowed: 2,
                 denied: 0,
                 last_outcome: "dial_failed"
               } = api,
               %{host: "tracker.example.net", attempts: 1, allowed: 0, denied: 1}
             ] = connections

      assert api.first_seen_at == at(6)
      assert api.last_seen_at == at(6)
      assert api.last_sequence == 8
      assert api.hive_id == run.hive_id
      assert api.organisation_id == run.organisation_id
    end

    test "creates the repository once per hive, and only from both labels", %{
      scope: scope,
      run: run
    } do
      events_fixture(run, [{1, "run.started", started_data()}])
      {:ok, first} = Projector.project(run)

      again = run_fixture(scope)
      events_fixture(again, [{1, "run.started", started_data()}])
      {:ok, second} = Projector.project(again)

      assert first.repository_id && first.repository_id == second.repository_id

      assert [%Repository{forge: "git.example.com", path: "acme/shop"} = repository] =
               Repo.all(Repository)

      assert repository.hive_id == run.hive_id
      assert repository.organisation_id == run.organisation_id

      half = run_fixture(scope)

      events_fixture(half, [
        {1, "run.started", started_data(%{"labels" => %{"repository" => "acme/other"}})}
      ])

      {:ok, half} = Projector.project(half)
      assert half.repository == "acme/other"
      assert half.repository_id == nil
      assert Repo.aggregate(Repository, :count) == 1
    end

    test "the same forge and path in another hive is another repository", %{run: run} do
      other = run_fixture(scope_fixture())

      for run <- [run, other] do
        events_fixture(run, [{1, "run.started", started_data()}])
        Projector.project(run)
      end

      assert Repo.aggregate(Repository, :count) == 2
    end

    test "is idempotent: a second pass folds nothing", %{run: run} do
      events_fixture(run, record())
      {:ok, _run} = Projector.project(run)
      before = projection(run)

      assert {:ok, _run} = Projector.project(run)
      assert projection(run) == before
    end

    test "an egress event is counted exactly once, across passes", %{run: run} do
      event_fixture(run, 1, "run.egress", egress_data())
      {:ok, _} = Projector.project(run)
      event_fixture(run, 2, "run.egress", egress_data(%{"decision" => "denied"}))
      {:ok, _} = Projector.project(run)
      {:ok, _} = Projector.project(run)

      assert [%{attempts: 2, allowed: 1, denied: 1, last_decision: "denied"}] =
               projection(run).connections
    end

    test "an earlier egress event arriving later does not take over the last columns", %{
      run: run
    } do
      event_fixture(run, 5, "run.egress", egress_data(%{"outcome" => "dial_failed"}))
      {:ok, _} = Projector.project(run)
      event_fixture(run, 2, "run.egress", egress_data())
      {:ok, _} = Projector.project(run)

      assert [connection] = projection(run).connections
      assert connection.attempts == 2
      assert connection.last_outcome == "dial_failed"
      assert connection.first_seen_at == at(2)
      assert connection.last_seen_at == at(5)
    end

    test "at equal times the higher sequence is the last, whichever arrives first", %{
      scope: scope
    } do
      events = [
        {4, "run.egress", egress_data(%{"outcome" => "connected"}), time: at(9)},
        {5, "run.egress", egress_data(%{"outcome" => "dial_failed"}), time: at(9)}
      ]

      for order <- [events, Enum.reverse(events)] do
        run = run_fixture(scope)

        for event <- order do
          events_fixture(run, [event])
          {:ok, _} = Projector.project(run)
        end

        assert [%{attempts: 2, last_outcome: "dial_failed", last_sequence: 5}] =
                 projection(run).connections
      end
    end

    test "the later of ping and run.started says the runner's version, in any order", %{
      scope: scope
    } do
      events = [
        {1, "ping", %{"runner_version" => "v0.4.0", "contract_version" => 1}},
        {2, "run.started", started_data(%{"runner_version" => "v0.4.1"})}
      ]

      for order <- [events, Enum.reverse(events)] do
        run = run_fixture(scope)

        for event <- order do
          events_fixture(run, [event])
          {:ok, _} = Projector.project(run)
        end

        assert Repo.get!(Run, run.id).runner_version == "v0.4.1"
      end
    end

    test "a late run.started revives a lost run and clears lost_at", %{scope: scope} do
      run = run_fixture(scope, %{state: "lost", lost_at: at(500)})
      events_fixture(run, [{2, "run.started", started_data()}])

      assert {:ok, %Run{state: "running", lost_at: nil}} = Projector.project(run)
    end

    test "a late lower sequence is projected and never regresses the run", %{run: run} do
      [ping, started | rest] = record()
      events_fixture(run, rest)
      {:ok, run} = Projector.project(run)

      assert run.state == "exited"
      assert run.projected_sequence == 0

      events_fixture(run, [started])
      {:ok, run} = Projector.project(run)

      assert run.state == "exited"
      assert run.runtime == "claude"
      assert run.projected_sequence == 0

      events_fixture(run, [ping])
      {:ok, run} = Projector.project(run)
      assert run.projected_sequence == 14
    end

    test "projected_sequence stops before a gap and moves on when it fills", %{run: run} do
      log = %{"stream" => "stdout", "bytes" => Base.encode64("x")}

      events_fixture(run, [{1, "run.log", log}, {2, "run.log", log}, {4, "run.log", log}])
      assert {:ok, %Run{projected_sequence: 2}} = Projector.project(run)

      events_fixture(run, [{6, "run.log", log}])
      assert {:ok, %Run{projected_sequence: 2}} = Projector.project(run)

      events_fixture(run, [{3, "run.log", log}])
      assert {:ok, %Run{projected_sequence: 4}} = Projector.project(run)

      events_fixture(run, [{5, "run.log", log}])
      assert {:ok, %Run{projected_sequence: 6}} = Projector.project(run)
    end

    test "any order of arrival, in any batching, gives the same projection", %{scope: scope} do
      in_order = run_fixture(scope)
      events_fixture(in_order, record())
      {:ok, _} = Projector.project(in_order)
      expected = projection(in_order)

      for seed <- 1..12 do
        :rand.seed(:exsss, {seed, seed + 1, seed + 2})
        run = run_fixture(scope)

        record()
        |> Enum.shuffle()
        |> Enum.chunk_every(Enum.random(1..5))
        |> Enum.each(fn batch ->
          events_fixture(run, batch)
          {:ok, _} = Projector.project(run)
        end)

        assert projection(run) == expected
      end
    end

    test "session events and unknown types are marked projected and fold nothing", %{run: run} do
      events_fixture(run, [
        {1, "session.started", %{"session_id" => "session-1"}},
        {2, "something.unheard_of", %{"anything" => true}}
      ])

      {:ok, projected} = Projector.project(run)

      assert projected.state == "pending"
      assert projected.projected_sequence == 2
      assert projection(run).unprojected == 0
    end

    test "log bytes that are not base64 are skipped, counted, and never logged", %{run: run} do
      events_fixture(run, [
        {1, "run.log", %{"stream" => "stdout", "bytes" => "%%not-base64-marker%%"}},
        {2, "run.log", %{"stream" => "stdout", "bytes" => Base.encode64("kept")}}
      ])

      log = capture_log(fn -> assert {:ok, _} = Projector.project(run) end)

      assert log =~ "log chunks skipped"
      assert log =~ "count=1"
      refute log =~ "not-base64-marker"
      assert [{2, "stdout", "kept"}] = projection(run).log_chunks
      assert projection(run).unprojected == 0
    end

    test "data that does not follow its schema never fails the projection", %{run: run} do
      events_fixture(run, [
        {1, "run.started", %{"args" => "not a list", "labels" => [1, 2], "runtime" => 7}},
        {2, "run.heartbeat", %{"elapsed_seconds" => "soon", "interval_seconds" => 0}},
        {3, "run.egress", %{"host" => "api.example.com", "port" => "https"}},
        {4, "run.exited", %{"state" => 1, "exit_code" => "zero"}}
      ])

      assert {:ok, %Run{state: "failed", args: [], labels: %{}, projected_sequence: 4}} =
               Projector.project(run)
    end

    test "integers no column can hold are read as absent and block nothing", %{run: run} do
      huge = 99_999_999_999_999_999_999

      events_fixture(run, [
        {1, "ping", %{"runner_version" => "v0.4.0", "contract_version" => huge}},
        {2, "run.started", started_data()},
        {3, "run.heartbeat", %{"elapsed_seconds" => huge, "interval_seconds" => 2_000_000_000}},
        {4, "run.egress", egress_data(%{"port" => huge})},
        {5, "run.egress", egress_data(%{"port" => 70_000})},
        {6, "run.egress", egress_data(%{"path" => "/" <> String.duplicate("a", 100_000)})},
        {7, "run.exited", %{"state" => "failed", "exit_code" => huge, "duration_ms" => huge}}
      ])

      assert {:ok, %Run{} = projected} = Projector.project(run)

      assert projected.state == "failed"
      assert projected.projected_sequence == 7
      assert projected.contract_version == nil
      assert projected.elapsed_seconds == nil
      assert projected.heartbeat_interval_seconds == nil
      assert projected.exit_code == nil
      assert projected.duration_ms == nil
      assert %{unprojected: 0, connections: [%{port: 443, attempts: 1}]} = projection(run)

      before = projection(run)
      assert {:ok, _} = Projector.rebuild(run)
      assert projection(run) == before
    end

    test "projected_sequence advances over more than a page of events", %{run: run} do
      now = DateTime.utc_now()

      rows =
        for sequence <- 1..2500 do
          %{
            id: Ecto.UUID.generate(),
            organisation_id: run.organisation_id,
            hive_id: run.hive_id,
            run_id: run.id,
            sequence: sequence,
            event_id: Ecto.UUID.generate(),
            type: "ai.qory.session.started",
            time: now,
            data: %{},
            received_at: now
          }
        end

      Repo.insert_all(Event, rows)

      assert {:ok, %Run{projected_sequence: 2500}} = Projector.project(run)
    end

    test "a closed run stays closed whatever arrives", %{scope: scope, run: run} do
      {:ok, _} = Runs.close_run(scope, run)
      events_fixture(run, record())

      assert {:ok, %Run{state: "closed", exit_code: 0}} = Projector.project(run)
    end

    test "broadcasts on the hive's topic and the run's", %{scope: scope, run: run} do
      Runs.subscribe(scope)
      Runs.subscribe(scope, run)
      events_fixture(run, Enum.take(record(), 5))

      {:ok, _} = Projector.project(run)

      assert_receive {:run_changed, %Run{state: "running"}}
      assert_receive {:run_projected, %Run{state: "running"}, 1, 5}

      {:ok, _} = Projector.project(run)
      refute_receive {:run_changed, _}
      refute_receive {:run_projected, _, _, _}
    end

    test "a run that is gone is not found", %{run: run} do
      Repo.delete!(run)
      assert {:error, :not_found} = Projector.project(run)
    end
  end

  describe "project_async/1" do
    test "never raises into the caller, and logs no event data", %{run: run} do
      events_fixture(run, record())
      Repo.delete!(run)

      log = capture_log(fn -> assert :ok = Projector.project_async(run) end)

      assert log =~ "projection failed run=#{run.id}"
      refute log =~ "acme/shop"
      assert :ok = Projector.project_async(nil)
    end

    test "projects", %{run: run} do
      events_fixture(run, record())
      assert :ok = Projector.project_async(run)
      assert Repo.get!(Run, run.id).state == "exited"
    end
  end

  describe "rebuild/1" do
    test "equals the incremental result", %{scope: scope, run: run} do
      record()
      |> Enum.chunk_every(3)
      |> Enum.each(fn batch ->
        events_fixture(run, batch)
        {:ok, _} = Projector.project(run)
      end)

      incremental = projection(run)

      assert {:ok, %Run{state: "exited"}} = Projector.rebuild(run)
      assert projection(run) == incremental

      # And it is a rebuild: projections that no event accounts for are gone.
      Repo.update_all(from(c in Connection, where: c.run_id == ^run.id), set: [attempts: 99])
      Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [host: "elsewhere"])

      assert {:ok, _} = Projector.rebuild(run)
      assert projection(run) == incremental

      assert Runs.get_run!(scope, run.id).host == "dev-laptop"
    end

    test "keeps a close, which no event records", %{scope: scope, run: run} do
      events_fixture(run, record())
      {:ok, _} = Projector.project(run)
      {:ok, closed} = Runs.close_run(scope, run)

      assert {:ok, rebuilt} = Projector.rebuild(run)
      assert rebuilt.state == "closed"
      assert rebuilt.closed_at == closed.closed_at
      assert rebuilt.closed_by_id == scope.user.id
      assert rebuilt.exit_code == 0
    end
  end
end
