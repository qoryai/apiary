defmodule Apiary.Runs.TargetWritesTest do
  # What a run wrote to its targets (`Apiary.Runs.TargetWrite`): the projection of its
  # `dev.qory.run.target_write` events into `run_target_writes`, in every workspace, a
  # rebuild, and the read by place (`TargetWrite.writes/2`).
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.Runs.{Projector, Run, Target, TargetWrite}

  @app "0123456789abcdef0123456789abc0a1"
  @lib "0123456789abcdef0123456789abc0b2"

  setup do
    scope = scope_fixture()
    %{scope: scope, run: run_fixture(scope)}
  end

  defp write(sequence, path, state, request_id \\ nil) do
    data = %{"system" => "git.example", "path" => path, "state" => state}
    data = if request_id, do: Map.put(data, "request_id", request_id), else: data
    {sequence, "run.target_write", data}
  end

  defp project!(run, events) do
    events_fixture(run, events)
    {:ok, run} = Projector.project(run)
    run
  end

  defp rows(run) do
    for row <- TargetWrite.of_run(run),
        do: Map.take(row, [:sequence, :system, :path, :state, :request_id, :target_id])
  end

  # A row as the read takes it, without the database.
  defp row(sequence, path, state, request_id \\ nil),
    do: %{
      sequence: sequence,
      system: "git.example",
      path: path,
      state: state,
      request_id: request_id,
      target_id: nil
    }

  defp written(rows, ended?),
    do: for(w <- TargetWrite.writes(rows, ended?), do: {w.path, w.written})

  describe "the projection" do
    test "keeps one row per event, with the workspace's target of its place", %{
      scope: scope,
      run: run
    } do
      :ok =
        Target.insert_new(scope.organisation.id, scope.workspace.id, [
          Apiary.NodesFixtures.target_key(%{system: "git.example", path: "example-org/app"})
        ])

      %Target{id: app} = Repo.get_by!(Target, workspace_id: scope.workspace.id)

      project!(run, [
        write(1, "example-org/app", "started", @app),
        write(2, "example-org/app", "changed", @app),
        write(3, "example-org/lib", "started", @lib),
        write(4, "example-org/lib", "cut", @lib)
      ])

      assert rows(run) == [
               %{
                 sequence: 1,
                 system: "git.example",
                 path: "example-org/app",
                 state: "started",
                 request_id: @app,
                 target_id: app
               },
               %{
                 sequence: 2,
                 system: "git.example",
                 path: "example-org/app",
                 state: "changed",
                 request_id: @app,
                 target_id: app
               },
               %{
                 sequence: 3,
                 system: "git.example",
                 path: "example-org/lib",
                 state: "started",
                 request_id: @lib,
                 target_id: nil
               },
               %{
                 sequence: 4,
                 system: "git.example",
                 path: "example-org/lib",
                 state: "cut",
                 request_id: @lib,
                 target_id: nil
               }
             ]

      # A write creates no target.
      assert [_app] = Repo.all(from t in Target, where: t.workspace_id == ^scope.workspace.id)
    end

    test "keeps rows in a workspace of any domain", %{scope: scope} do
      scope = with_domain(scope, "example")
      run = run_fixture(scope)
      project!(run, [write(1, "queue/billing", "changed")])

      assert [%{path: "queue/billing", state: "changed"}] = rows(run)
    end

    test "folds an event it cannot read into nothing, and a request id it cannot into none", %{
      run: run
    } do
      project!(run, [
        {1, "run.target_write", %{"system" => "", "path" => "a/b", "state" => "started"}},
        {2, "run.target_write", %{"system" => "git.example", "state" => "started"}},
        {3, "run.target_write", %{"system" => "git.example", "path" => "a/b", "state" => "x"}},
        {4, "run.target_write",
         %{"system" => "git.example", "path" => "a\nb", "state" => "changed"}},
        {5, "run.target_write",
         %{
           "system" => "git.example",
           "path" => "a/b",
           "state" => "refused",
           "request_id" => String.upcase(@app)
         }}
      ])

      assert [%{sequence: 5, state: "refused", request_id: nil}] = rows(run)
    end

    test "a later pass adds its rows, and a rebuild folds the same rows again", %{run: run} do
      project!(run, [write(1, "example-org/app", "started", @app)])
      project!(run, [write(2, "example-org/app", "changed", @app)])
      expected = rows(run)
      assert length(expected) == 2

      Repo.update_all(from(w in TargetWrite, where: w.run_id == ^run.id), set: [path: "x/y"])

      assert {:ok, %Run{}} = Projector.rebuild(run)
      assert rows(run) == expected
    end

    test "the database accepts only the four states", %{run: run} do
      assert_raise Ecto.ConstraintError, ~r/run_target_writes_state_check/, fn ->
        Repo.insert!(%TargetWrite{
          organisation_id: run.organisation_id,
          workspace_id: run.workspace_id,
          run_id: run.id,
          sequence: 1,
          at: DateTime.utc_now(),
          system: "git.example",
          path: "a/b",
          state: "pushed"
        })
      end
    end

    test "the rows go with their run", %{run: run} do
      project!(run, [write(1, "example-org/app", "changed")])
      Repo.delete!(run)

      assert Repo.aggregate(from(w in TargetWrite, where: w.run_id == ^run.id), :count) == 0
    end
  end

  describe "writes/2" do
    test "a place with a changed write is changed, whatever else it has" do
      rows = [
        row(1, "a/app", "started", @app),
        row(2, "a/app", "changed", @app),
        row(3, "a/app", "started", @lib),
        row(4, "a/app", "refused", @lib)
      ]

      assert written(rows, true) == [{"a/app", :changed}]
    end

    test "a place whose every write was refused is refused" do
      rows = [row(1, "a/app", "started", @app), row(2, "a/app", "refused", @app)]
      assert written(rows, true) == [{"a/app", :refused}]
    end

    test "a cut write, or one still started once the run ended, may have changed it" do
      assert written([row(1, "a/app", "started", @app), row(2, "a/app", "cut", @app)], true) ==
               [{"a/app", :maybe}]

      assert written([row(1, "a/app", "started", @app)], true) == [{"a/app", :maybe}]
    end

    test "a started write of a run that has not ended is still started, and may change it" do
      [write] = TargetWrite.writes([row(1, "a/app", "started", @app)], false)
      assert write.written == :maybe
    end

    test "the state with the highest sequence decides a write, in any order of rows" do
      rows = [row(2, "a/app", "refused", @app), row(1, "a/app", "started", @app)]
      assert written(rows, true) == [{"a/app", :refused}]
    end

    test "a row without a request id is a write alone" do
      rows = [row(1, "a/app", "started"), row(2, "a/app", "refused")]
      assert written(rows, true) == [{"a/app", :maybe}]
    end

    test "of_run_targets/3 keeps the writes to the run's target and further paths alone" do
      run = %Run{
        target_system: "git.example",
        target_path: "a/app",
        labels: %{"repositories" => "a/app,a/lib"}
      }

      writes =
        TargetWrite.writes(
          [
            row(1, "a/app", "changed"),
            row(2, "a/lib", "cut"),
            row(3, "a/%2e%2e/app.git", "changed"),
            %{row(4, "a/app", "changed") | system: "other.example"}
          ],
          true
        )

      assert for(w <- TargetWrite.of_run_targets(writes, run, "repositories"), do: w.path) ==
               ["a/app", "a/lib"]

      assert for(w <- TargetWrite.of_run_targets(writes, run, nil), do: w.path) == ["a/app"]
      assert TargetWrite.of_run_targets(writes, %Run{}, "repositories") == []
    end

    test "places in the order of their first write; none for no rows" do
      rows = [
        row(1, "a/lib", "started", @lib),
        row(2, "a/app", "started", @app),
        row(3, "a/app", "changed", @app),
        row(4, "a/lib", "cut", @lib)
      ]

      assert written(rows, true) == [{"a/lib", :maybe}, {"a/app", :changed}]
      assert TargetWrite.writes([], true) == []
    end
  end
end
