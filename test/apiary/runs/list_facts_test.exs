defmodule Apiary.Runs.ListFactsTest do
  # What the runs list shows of a run beside its row's fields (`Apiary.Runs.list_facts/2`):
  # the workflow its claim handed over, the stage that placed it, its work item and how it
  # started. Not async: a test runs with the workflow model off (`with_features:`).
  use Apiary.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.RunListFixtures

  alias Apiary.{Processes, Repo, Runs}
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: [:observability, :factory]

  setup do
    %{scope: scope, user: user} = sign_up_fixture()
    %{scope: scope, user: user}
  end

  defp facts(scope, run), do: Map.fetch!(Runs.list_facts(scope, [run]), run.id)

  defp walk(state, origin, workflow), do: %{state: state, origin: origin, workflow: workflow}

  describe "the workflow" do
    test "the walk's workflow, only while it is resolved from a file, a setting or the built-in",
         %{scope: scope} do
      for origin <- [:file, :setting, :builtin] do
        run = started_run(scope)
        queue_run!(scope, run, walk: walk(:resolved, origin, "explore-a-ticket"))
        assert facts(scope, run).workflow == "explore-a-ticket"
      end
    end

    test "a pending or failed walk, the origin none, and no walk at all are none", %{
      scope: scope
    } do
      pending = started_run(scope)
      queue_run!(scope, pending, walk: walk(:pending, nil, "explore-a-ticket"))

      none = started_run(scope)
      queue_run!(scope, none, walk: walk(:resolved, :none, nil))

      unwalked = started_run(scope)
      queue_run!(scope, unwalked)

      direct = started_run(scope)

      for run <- [pending, none, unwalked, direct], do: assert(facts(scope, run).workflow == nil)
    end

    test "a failed walk is none", %{scope: scope} do
      run = started_run(scope)
      queue_run!(scope, run, walk: %{state: :pending, origin: nil, workflow: nil})

      {1, _rows} =
        Repo.update_all(
          from(h in Apiary.Harnesses.RunHarness,
            where:
              h.dispatch_run_id in subquery(
                from r in Apiary.Runs.Run, where: r.id == ^run.id, select: r.dispatch_run_id
              )
          ),
          set: [state: :failed, failure: "source_unreachable", workflow: "explore-a-ticket"]
        )

      assert facts(scope, run).workflow == nil
    end

    test "a prebuild is :prebuild, with no work item and no start", %{scope: scope} do
      run = started_run(scope)
      queue_run!(scope, run, step: "prebuild")

      assert %{workflow: :prebuild, work_item: nil, started_by: nil, stage: nil} =
               facts(scope, run)
    end
  end

  describe "the stage" do
    setup %{scope: scope} do
      version = Processes.current(scope.workspace)
      stage = fn name -> Enum.find(version.document["stages"], &(&1["name"] == name))["id"] end
      %{version: version, stage: stage}
    end

    @tag needs: [:observability, :factory, :workflow_model]
    test "the stage runner's run: the stage, with its round inside a loop", %{
      scope: scope,
      version: version,
      stage: stage
    } do
      looped = started_run(scope)

      queue_run!(scope, looped,
        attempt: 4,
        of: 6,
        walk: walk(:resolved, :file, "implement"),
        queued: [
          process_version_id: version.id,
          stage_id: stage.("Build"),
          round: 2,
          loop_entry: 0
        ]
      )

      plain = started_run(scope)

      queue_run!(scope, plain,
        attempt: 5,
        of: 6,
        walk: walk(:resolved, :file, "run-checks"),
        queued: [process_version_id: version.id, stage_id: stage.("Verify"), round: 1]
      )

      assert facts(scope, looped).stage == %{name: "Build", round: 2}
      assert facts(scope, plain).stage == %{name: "Verify", round: nil}
      assert facts(scope, looped).started_by == :process
    end

    @tag needs: [:observability, :factory, :workflow_model]
    test "a stage named as the workflow, or as its first word, adds nothing", %{
      scope: scope,
      version: version,
      stage: stage
    } do
      explore = started_run(scope)

      queue_run!(scope, explore,
        walk: walk(:resolved, :setting, "explore-a-ticket"),
        queued: [
          process_version_id: version.id,
          stage_id: stage.("Explore"),
          round: 2,
          loop_entry: 0
        ]
      )

      shape = started_run(scope)

      queue_run!(scope, shape,
        walk: walk(:resolved, :file, "shape"),
        queued: [process_version_id: version.id, stage_id: stage.("Shape"), round: 1]
      )

      assert facts(scope, explore).stage == nil
      assert facts(scope, shape).stage == nil
    end

    @tag with_features: [:observability, :security, :factory]
    test "with the workflow model off, no stage", %{scope: scope, version: version, stage: stage} do
      run = started_run(scope)

      queue_run!(scope, run,
        walk: walk(:resolved, :file, "implement"),
        queued: [
          process_version_id: version.id,
          stage_id: stage.("Build"),
          round: 2,
          loop_entry: 0
        ]
      )

      assert facts(scope, run).stage == nil
    end
  end

  describe "how a run started" do
    test "a take in, a take in again, answers, Explore again and a missing image", %{
      scope: scope,
      user: user
    } do
      work_item = Apiary.WorkItemsFixtures.work_item_fixture(scope)

      first = started_run(scope)
      queue_run!(scope, first, work_item: work_item)

      work_item_event!(work_item, :answered, user, %{"take_in" => 1, "attempt" => 1})
      answered = started_run(scope)
      queue_run!(scope, answered, work_item: work_item, attempt: 2)

      work_item_event!(work_item, :explore_again, user, %{"take_in" => 1, "attempt" => 3})
      again = started_run(scope)
      queue_run!(scope, again, work_item: work_item, attempt: 3)

      requeued = started_run(scope)

      queue_run!(scope, requeued,
        work_item: work_item,
        attempt: 4,
        of: 4,
        queued: [image_requeue: true]
      )

      # A second take in, whose event names no take in: counted on from the first.
      work_item_event!(work_item, :taken_in, user, %{})
      second = started_run(scope)
      queue_run!(scope, second, work_item: work_item, take_in: 2)

      assert facts(scope, first).started_by == {:taken_in, user.id}
      assert facts(scope, answered).started_by == {:answers, 2, 3, user.id}
      assert facts(scope, again).started_by == {:explore_again, user.id}
      assert facts(scope, requeued).started_by == :image_requeue
      assert facts(scope, second).started_by == {:taken_in_again, user.id}

      assert %{number: number, title: "The checkout keeps the old price", here: true} =
               facts(scope, first).work_item

      assert number == work_item.number
    end

    test "a test work item's run, a direct run, and a later run no event explains", %{
      scope: scope,
      user: user
    } do
      test_item = Apiary.WorkItemsFixtures.work_item_fixture(scope, %{title: "Say hello"})

      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^test_item.id),
          set: [
            test: true,
            connection_id: nil,
            adapter_id: nil,
            item_id: nil,
            external_ref: nil,
            url: nil
          ]
        )

      tested = started_run(scope)
      queue_run!(scope, tested, work_item: test_item, walk: walk(:resolved, :builtin, "hello"))

      unexplained = started_run(scope)
      queue_run!(scope, unexplained, attempt: 2)

      direct = started_run(scope)

      assert %{workflow: "hello", started_by: {:test_run, id}} = facts(scope, tested)
      assert id == user.id
      assert facts(scope, unexplained).started_by == nil
      assert %{started_by: :direct, work_item: nil, workflow: nil} = facts(scope, direct)
    end

    test "another workspace's run has no facts", %{scope: scope} do
      other = sign_up_fixture().scope
      run = started_run(other)
      assert Runs.list_facts(scope, [run]) == %{}
    end
  end

  describe "the Machine or pool column" do
    test "names the instance's pool beside the workspace's nodes, never another workspace's",
         %{scope: scope} do
      pool = Apiary.NodesFixtures.instance_pool_fixture()
      mine = Apiary.NodesFixtures.node_fixture(scope)
      theirs = Apiary.NodesFixtures.node_fixture(sign_up_fixture().scope)

      names = Apiary.Nodes.names(scope, [pool.id, mine.id, theirs.id])

      assert names |> Map.keys() |> Enum.sort() == Enum.sort([pool.id, mine.id])
      assert ApiaryWeb.NodeComponents.shown_name(names[pool.id]) == "Qory Pool"
    end
  end
end
