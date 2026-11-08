defmodule Apiary.Runs.RunListTest do
  # The run list of the instance (`Apiary.Runs.RunList`, `Apiary.Runs.list_instance_runs/2`):
  # the contract's fixtures of the run list and its refusal first; then the query's rules,
  # each refusal with its parameter; the filters, done in the query; the order and the
  # pages across runs created at the same time; and each row's members. Every page is
  # valid under the vendored schema.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.DispatchedRunsFixtures, only: [handover_place_fixture: 1, handed_over_fixture: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.{DiagnosticsSchema, Repo, Runs}
  alias Apiary.Dispatches.Dispatch
  alias Apiary.Harnesses.RunHarness
  alias Apiary.Runs.{Run, RunList}
  alias Apiary.WorkItems.WorkItem

  @now ~U[2026-11-01 12:00:00.000000Z]

  setup_all do
    %{runs: DiagnosticsSchema.runs(), refusal: DiagnosticsSchema.runs_refusal()}
  end

  defp valid!(schema, document) do
    decoded = document |> Jason.encode!() |> Jason.decode!()
    assert DiagnosticsSchema.validate(schema, decoded) == :ok
    decoded
  end

  # The page `query` asks for, valid under the schema.
  defp page!(schema, query) do
    assert {:ok, document} = Runs.list_instance_runs(query, now: @now)
    valid!(schema, document)
  end

  defp ids(page), do: Enum.map(page["runs"], & &1["id"])

  # A run of the scope's workspace created at `at`, with `attrs`.
  defp run!(scope, at, attrs \\ %{}) do
    run_fixture(scope, Map.merge(%{public_id: Run.new_public_id(), inserted_at: at}, attrs))
  end

  defp decode(file), do: file |> File.read!() |> Jason.decode!()

  describe "the contract's fixtures" do
    test "each run list and refusal is valid, and each invalid one refused",
         %{runs: runs, refusal: refusal} do
      dir = DiagnosticsSchema.fixtures_dir()
      lists = Path.wildcard(Path.join(dir, "runs/*.json"))
      refusals = Path.wildcard(Path.join(dir, "runs-refusal/*.json"))
      invalid = Path.wildcard(Path.join(dir, "invalid/runs-*.json"))

      {invalid_refusals, invalid_lists} =
        Enum.split_with(invalid, &String.starts_with?(Path.basename(&1), "runs-refusal-"))

      assert length(lists) == 6 and length(refusals) == 2
      assert length(invalid_lists) == 15 and length(invalid_refusals) == 3

      for file <- lists, do: assert(DiagnosticsSchema.validate(runs, decode(file)) == :ok, file)

      for file <- refusals,
          do: assert(DiagnosticsSchema.validate(refusal, decode(file)) == :ok, file)

      for file <- invalid_lists,
          do: assert({:error, _} = DiagnosticsSchema.validate(runs, decode(file)), file)

      for file <- invalid_refusals,
          do: assert({:error, _} = DiagnosticsSchema.validate(refusal, decode(file)), file)
    end
  end

  describe "the query" do
    test "is empty: every parameter absent, 25 rows at most" do
      assert RunList.parse("") ==
               {:ok,
                %{
                  workspace: nil,
                  work_item: nil,
                  workflow: nil,
                  state: nil,
                  since: nil,
                  before: nil,
                  limit: 25
                }}
    end

    test "takes each parameter at its bounds" do
      before = Run.new_public_id()

      query =
        "workspace=example-org%2Fexample&work_item=9223372036854775807&workflow=a-1" <>
          "&state=lost&since=2026-11-01T23:59:59Z&before=#{before}&limit=100"

      assert {:ok, filters} = RunList.parse(query)

      assert filters == %{
               workspace: {"example-org", "example"},
               work_item: 9_223_372_036_854_775_807,
               workflow: "a-1",
               state: "lost",
               since: ~U[2026-11-01 23:59:59.000000Z],
               before: before,
               limit: 100
             }

      for state <- Run.states(),
          do: assert({:ok, %{state: ^state}} = RunList.parse("state=" <> state))

      assert {:ok, %{limit: 1}} = RunList.parse("limit=1")
      longest = "a" <> String.duplicate("b", 54)
      assert {:ok, %{workflow: ^longest}} = RunList.parse("workflow=" <> longest)
      slug = "a" <> String.duplicate("b", 38) <> "c"
      assert {:ok, %{workspace: {^slug, "x"}}} = RunList.parse("workspace=#{slug}/x")
    end

    test "since is the next whole microsecond at or after the time it names" do
      for {value, at} <- [
            {"2026-11-01T00:00:00Z", ~U[2026-11-01 00:00:00.000000Z]},
            {"2026-11-01T00:00:00.5Z", ~U[2026-11-01 00:00:00.500000Z]},
            {"2026-11-01T00:00:00.123456Z", ~U[2026-11-01 00:00:00.123456Z]},
            {"2026-11-01T00:00:00.000000001Z", ~U[2026-11-01 00:00:00.000001Z]},
            {"2026-11-01T00:00:00.123456000Z", ~U[2026-11-01 00:00:00.123456Z]},
            {"2026-12-31T23:59:59.999999999Z", ~U[2027-01-01 00:00:00.000000Z]},
            {"2024-02-29T00:00:00Z", ~U[2024-02-29 00:00:00.000000Z]}
          ] do
        assert {:ok, %{since: since}} = RunList.parse("since=" <> value), value
        assert DateTime.compare(since, at) == :eq, value
      end
    end

    test "refuses each rule broken, with the parameter's name" do
      for {query, parameter} <- [
            {"status=running", "status"},
            {"limit=5&limit=5", "limit"},
            {"state=running&limit=5&state=failed", "state"},
            {"limit=", "limit"},
            {"limit", "limit"},
            {"=5", ""},
            {"=", ""},
            {"limit=0", "limit"},
            {"limit=101", "limit"},
            {"limit=01", "limit"},
            {"limit=-1", "limit"},
            {"limit=1.0", "limit"},
            {"work_item=7", "work_item"},
            {"work_item=0&workspace=a/b", "work_item"},
            {"work_item=07&workspace=a/b", "work_item"},
            {"work_item=9223372036854775808&workspace=a/b", "work_item"},
            {"work_item=99999999999999999999&workspace=a/b", "work_item"},
            {"workspace=example", "workspace"},
            {"workspace=a/b/c", "workspace"},
            {"workspace=A/b", "workspace"},
            {"workspace=-a/b", "workspace"},
            {"workspace=a/b-", "workspace"},
            {"workspace=#{String.duplicate("a", 41)}/b", "workspace"},
            {"workflow=Hello", "workflow"},
            {"workflow=1hello", "workflow"},
            {"workflow=a" <> String.duplicate("b", 55), "workflow"},
            {"state=waiting", "state"},
            {"state=Running", "state"},
            {"since=2026-11-01", "since"},
            {"since=2026-11-01T00:00:60Z", "since"},
            {"since=2026-11-01T24:00:00Z", "since"},
            {"since=2026-11-01T00:60:00Z", "since"},
            {"since=2026-02-30T00:00:00Z", "since"},
            {"since=2026-11-01T00:00:00%2B01:00", "since"},
            {"since=2026-11-01T00:00:00z", "since"},
            {"since=2026-11-01T00:00:00.Z", "since"},
            {"since=2026-11-01T00:00:00.1234567890Z", "since"},
            {"before=rn_short", "before"},
            {"before=ws_0123456789abcdef", "before"},
            {"before=rn_0123456789ABCDEF", "before"}
          ] do
        assert RunList.parse(query) == {:error, parameter}, query
      end
    end

    test "skips an empty pair, as Plug does" do
      assert {:ok, %{limit: 5, state: "lost"}} = RunList.parse("limit=5&&state=lost&")
    end

    test "shows a name with each control character replaced, cut to 64 characters" do
      assert RunList.parse("a%01b%7Fc=1") == {:error, "a\u{FFFD}b\u{FFFD}c"}

      assert RunList.parse(String.duplicate("é", 70) <> "=1") ==
               {:error, String.duplicate("é", 64)}

      assert RunList.parse("a%FFb=1") == {:error, "a\u{FFFD}b"}
    end
  end

  describe "a page" do
    setup do
      %{scope: scope} = sign_up_fixture()
      %{scope: other} = sign_up_fixture()
      %{scope: scope, other: other}
    end

    test "lists the runs of every organisation, the last created first, each as stored",
         %{runs: schema, scope: scope, other: other} do
      first = run!(scope, ~U[2026-11-01 08:00:00.000000Z])

      second =
        run!(other, ~U[2026-11-01 09:00:00.250000Z], %{
          state: "completed",
          reason: "done",
          started_at: ~U[2026-11-01 09:01:00.000000Z],
          exited_at: ~U[2026-11-01 09:02:35.900000Z]
        })

      page = page!(schema, "")
      assert ids(page) == [second.public_id, first.public_id]
      assert page["next"] == nil

      assert [row, _first] = page["runs"]

      assert row == %{
               "id" => second.public_id,
               "number" => second.number,
               "organisation" => %{"slug" => other.organisation.slug},
               "workspace" => %{
                 "id" => other.workspace.public_id,
                 "slug" => other.workspace.slug
               },
               "state" => "completed",
               "reason" => "done",
               "created_at" => "2026-11-01T09:00:00Z",
               "started_at" => "2026-11-01T09:01:00Z",
               "duration_seconds" => 95
             }
    end

    test "counts a started run's seconds to now, and leaves them out without an exit",
         %{runs: schema, scope: scope} do
      started = ~U[2026-11-01 11:58:00.000000Z]

      running =
        run!(scope, ~U[2026-11-01 11:00:00.000000Z], %{state: "running", started_at: started})

      pending = run!(scope, ~U[2026-11-01 10:00:00.000000Z], %{state: "pending"})
      lost = run!(scope, ~U[2026-11-01 09:00:00.000000Z], %{state: "lost", started_at: started})

      failed =
        run!(scope, ~U[2026-11-01 08:00:00.000000Z], %{state: "failed", reason: "Not A Code"})

      rows = Map.new(page!(schema, "")["runs"], &{&1["id"], &1})

      assert rows[running.public_id]["duration_seconds"] == 120
      assert rows[running.public_id]["started_at"] == "2026-11-01T11:58:00Z"
      refute Map.has_key?(rows[pending.public_id], "duration_seconds")
      refute Map.has_key?(rows[pending.public_id], "started_at")
      assert rows[lost.public_id]["started_at"] == "2026-11-01T11:58:00Z"
      refute Map.has_key?(rows[lost.public_id], "duration_seconds")

      # A reason outside the contract's pattern is left out, never null.
      refute Map.has_key?(rows[failed.public_id], "reason")
      refute Map.has_key?(rows[failed.public_id], "workflow")
      refute Map.has_key?(rows[failed.public_id], "work_item_number")
    end

    test "filters by workspace, state and since",
         %{runs: schema, scope: scope, other: other} do
      a = run!(scope, ~U[2026-11-01 08:00:00.000000Z], %{state: "completed"})
      b = run!(scope, ~U[2026-11-01 09:00:00.000000Z], %{state: "failed"})
      c = run!(other, ~U[2026-11-01 10:00:00.000000Z], %{state: "failed"})

      workspace = "workspace=#{scope.organisation.slug}%2F#{scope.workspace.slug}"
      assert ids(page!(schema, workspace)) == [b.public_id, a.public_id]
      assert ids(page!(schema, "state=failed")) == [c.public_id, b.public_id]
      assert ids(page!(schema, workspace <> "&state=failed")) == [b.public_id]
      assert ids(page!(schema, "since=2026-11-01T09:00:00Z")) == [c.public_id, b.public_id]
      assert ids(page!(schema, "since=2026-11-01T09:00:00.000001Z")) == [c.public_id]
      assert ids(page!(schema, "state=cancelled")) == []
      assert page!(schema, "state=cancelled")["next"] == nil
    end

    test "pages across runs created at the same time by id, the greatest first",
         %{runs: schema, scope: scope, other: other} do
      at = ~U[2026-11-01 10:00:00.123456Z]

      same =
        for id <- ["rn_0000000000000003", "rn_000000000000000z", "rn_0000000000000001"] do
          run!(if(id == "rn_000000000000000z", do: other, else: scope), at, %{public_id: id})
        end

      later = run!(scope, DateTime.add(at, 1, :microsecond))
      earlier = run!(scope, DateTime.add(at, -1, :microsecond))

      order = [
        later.public_id,
        "rn_000000000000000z",
        "rn_0000000000000003",
        "rn_0000000000000001",
        earlier.public_id
      ]

      assert ids(page!(schema, "")) == order
      assert length(same) == 3

      first = page!(schema, "limit=2")
      assert ids(first) == Enum.take(order, 2)
      assert first["next"] == "rn_000000000000000z"

      second = page!(schema, "limit=2&before=rn_000000000000000z")
      assert ids(second) == ["rn_0000000000000003", "rn_0000000000000001"]
      assert second["next"] == "rn_0000000000000001"

      third = page!(schema, "limit=2&before=rn_0000000000000001")
      assert ids(third) == [earlier.public_id]
      assert third["next"] == nil

      assert page!(schema, "before=#{earlier.public_id}") == %{"runs" => [], "next" => nil}
    end

    test "has 25 rows by default and 100 at most, with next while more match",
         %{runs: schema, scope: scope} do
      for n <- 1..101, do: run!(scope, DateTime.add(@now, -n, :second))

      default = page!(schema, "")
      assert length(default["runs"]) == 25
      assert default["next"] == List.last(default["runs"])["id"]

      most = page!(schema, "limit=100")
      assert length(most["runs"]) == 100
      assert most["next"] == List.last(most["runs"])["id"]

      last = page!(schema, "limit=100&before=" <> most["next"])
      assert length(last["runs"]) == 1
      assert last["next"] == nil
    end

    test "refuses a workspace that does not exist and a before of no run",
         %{scope: scope} do
      run!(scope, @now)

      for query <- [
            "workspace=#{scope.organisation.slug}%2Fno-such-workspace",
            "workspace=no-such-org%2F#{scope.workspace.slug}&state=lost"
          ] do
        assert Runs.list_instance_runs(query) == {:error, "workspace"}, query
      end

      assert Runs.list_instance_runs("before=" <> Run.new_public_id()) == {:error, "before"}
    end
  end

  describe "a run of a workspace's queue" do
    @describetag needs: :factory

    setup do
      %{scope: scope} = sign_up_fixture()
      place = handover_place_fixture(scope)

      %{run: run, dispatch_run: queued, dispatch: dispatch} =
        handed_over_fixture(scope, place.key)

      {1, _} =
        Repo.update_all(from(h in RunHarness, where: h.dispatch_run_id == ^queued.id),
          set: [state: :resolved, workflow: "hello"]
        )

      work_item = Repo.get!(WorkItem, queued.work_item_id)
      %{scope: scope, run: run, dispatch: dispatch, work_item: work_item}
    end

    test "has its workflow and its work item, and is found by them",
         %{runs: schema, scope: scope, run: run, work_item: work_item} do
      other = run!(scope, DateTime.add(run.inserted_at, 1, :second))
      workspace = "workspace=#{scope.organisation.slug}%2F#{scope.workspace.slug}"

      assert [_other, row] = page!(schema, workspace)["runs"]
      assert row["id"] == run.public_id
      assert row["workflow"] == "hello"
      assert row["work_item_number"] == work_item.number
      assert row["work_item_title"] == work_item.title

      assert ids(page!(schema, "workflow=hello")) == [run.public_id]
      assert ids(page!(schema, "workflow=other")) == []

      assert ids(page!(schema, workspace <> "&work_item=#{work_item.number}")) ==
               [run.public_id]

      assert ids(page!(schema, workspace <> "&work_item=#{work_item.number + 1}")) == []
      assert other.public_id in ids(page!(schema, workspace))
    end

    test "leaves out a workflow longer than the contract's, and one not resolved",
         %{runs: schema, run: run} do
      for {changes, shown} <- [
            {[workflow: "a" <> String.duplicate("b", 55)], nil},
            {[state: :pending, origin: nil, workflow: "hello"], nil},
            {[state: :resolved, origin: :none, workflow: "a" <> String.duplicate("b", 54)],
             "a" <> String.duplicate("b", 54)}
          ] do
        {1, _} =
          Repo.update_all(from(h in RunHarness, where: h.dispatch_run_id == ^run.dispatch_run_id),
            set: changes
          )

        [row] = page!(schema, "")["runs"]
        assert row["workflow"] == shown
      end
    end

    test "a run whose start failed keeps the work item of its dispatch's row",
         %{runs: schema, run: run, dispatch: dispatch, work_item: work_item} do
      run
      |> Ecto.Changeset.change(
        dispatch_run_id: nil,
        dispatch_id: dispatch.id,
        state: "failed",
        reason: "machine_not_made",
        start_failure: "machine_not_made",
        start_failed_at: DateTime.utc_now()
      )
      |> Repo.update!()

      assert %Dispatch{dispatch_run_id: queued} = Repo.get!(Dispatch, dispatch.id)
      assert is_binary(queued)

      [row] = page!(schema, "state=failed")["runs"]
      assert row["work_item_number"] == work_item.number
      assert row["reason"] == "machine_not_made"
      assert row["workflow"] == "hello"
    end
  end
end
