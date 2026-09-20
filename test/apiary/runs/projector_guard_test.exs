defmodule Apiary.Runs.ProjectorGuardTest do
  # Not async: both tests change something global, the projector's fold and the logger's
  # level, for their duration.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures
  import ExUnit.CaptureLog

  alias Apiary.Runs.{Event, Fold, LogChunk, Projector, Run}

  defmodule RaisingFold do
    @moduledoc "The fold, except that an event carrying the poison raises, as a bug would."
    def fold(run, events, latest) do
      if Enum.any?(events, &match?(%{data: %{"poison" => true}}, &1)) do
        raise ArgumentError, "a message that quotes poison-marker data"
      end

      Fold.fold(run, events, latest)
    end
  end

  defp with_fold(module) do
    config = Application.get_env(:apiary, Projector, [])
    Application.put_env(:apiary, Projector, Keyword.put(config, :fold, module))
    on_exit(fn -> Application.put_env(:apiary, Projector, config) end)
  end

  setup do
    %{run: run_fixture(scope_fixture())}
  end

  describe "an event that makes the pass raise" do
    setup do
      with_fold(RaisingFold)
    end

    test "is skipped and named, and the events around it are projected", %{run: run} do
      events_fixture(run, [
        {1, "run.started", started_data()},
        {2, "run.log", %{"stream" => "stdout", "bytes" => Base.encode64("before\n")}},
        {3, "run.egress", %{"poison" => true, "host" => "poison-marker.example.com"}},
        {4, "run.log", %{"stream" => "stdout", "bytes" => Base.encode64("after\n")}},
        {5, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 9}}
      ])

      log =
        capture_log(fn ->
          assert {:ok, %Run{state: "succeeded", projected_sequence: 5}} = Projector.project(run)
        end)

      assert log =~ "event skipped run=#{run.id} sequence=3 error=ArgumentError"
      refute log =~ "poison-marker"
      refute log =~ "sequence=2"

      assert Repo.aggregate(from(l in LogChunk, where: l.run_id == ^run.id), :count) == 2
      refute Repo.exists?(from e in Event, where: e.run_id == ^run.id and is_nil(e.projected_at))

      # Nothing is left to raise again.
      assert capture_log(fn -> assert {:ok, _} = Projector.project(run) end) == ""
    end

    test "later batches of the run are projected as ever", %{run: run} do
      events_fixture(run, [{1, "run.egress", %{"poison" => true}}])
      capture_log(fn -> assert {:ok, %Run{state: "pending"}} = Projector.project(run) end)

      events_fixture(run, [{2, "run.started", started_data()}])
      assert {:ok, %Run{state: "running", projected_sequence: 2}} = Projector.project(run)
    end

    test "rebuild survives it too", %{run: run} do
      events_fixture(run, [
        {1, "run.started", started_data()},
        {2, "run.egress", %{"poison" => true}},
        {3, "run.exited", %{"state" => "failed", "exit_code" => 1, "duration_ms" => 9}}
      ])

      capture_log(fn ->
        assert {:ok, %Run{state: "failed"} = first} = Projector.project(run)
        assert {:ok, %Run{state: "failed"} = rebuilt} = Projector.rebuild(run)
        assert rebuilt.projected_sequence == 3
        assert Map.drop(rebuilt, [:updated_at]) == Map.drop(first, [:updated_at])
      end)
    end
  end

  describe "the query log at debug level" do
    # Raised after the events are stored: the fixture's own inserts are not the subject.
    defp debug_level do
      level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: level) end)
    end

    test "carries no event data from a projection or a rebuild", %{run: run} do
      events_fixture(run, [
        {1, "run.started",
         started_data(%{
           "args" => ["--prompt", "marker-in-an-arg"],
           "labels" => %{
             "forge" => "git.example.com",
             "repository" => "acme/shop",
             "task" => "marker-in-a-label"
           }
         })},
        {2, "run.log", %{"stream" => "stdout", "bytes" => Base.encode64("marker-in-the-log")}},
        {3, "run.egress", egress_data(%{"host" => "marker-in-a-host.example.com"})}
      ])

      debug_level()

      log =
        capture_log([level: :debug], fn ->
          assert {:ok, %Run{task: "marker-in-a-label"}} = Projector.project(run)
          assert {:ok, %Run{}} = Projector.rebuild(run)
        end)

      # The log is on, and says what ran without the values.
      assert log =~ "QUERY OK"
      refute log =~ "marker-in"
      refute log =~ Base.encode64("marker-in-the-log")
      refute log =~ "acme/shop"
    end
  end
end
