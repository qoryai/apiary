defmodule Apiary.Dispatches.InputsTrackTest do
  # The work item's track in a run's inputs (`Apiary.Stages.input_track/2`): a run of any
  # stage but Explore's has it, at the claim (`Apiary.Dispatches.Handover`) and in each
  # later session of a shared run (`Apiary.Stages.next_session/2`); a run of Explore's
  # stage, and a work item with no track, have no `track` member.
  # Not async: the artifact store is the application's setting.
  use Apiary.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures
  import Apiary.StagesFixtures

  alias Apiary.{Dispatches, ExploreInputsSchema, Processes, Repo, Stages, WorkItems}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: [:factory, :workflow_model]

  @explore "st_r79kph11eg"
  @build "st_6ns22c4pav"
  @tracks [
    %{"id" => "standard", "name" => "Standard"},
    %{"id" => "fast-track", "name" => "Fast track"}
  ]

  setup do
    %{scope: scope} = sign_up_fixture()
    Map.put(Apiary.DispatchedRunsFixtures.handover_place_fixture(scope), :scope, scope)
  end

  # Explore, then Build, whose two workflows share one run. With `tracked`, the process
  # declares Standard and Fast track, and both gates offer them; without, it has no tracks.
  defp process!(scope, tracked) do
    gate = fn ->
      Map.merge(
        %{"kind" => "person", "approvers" => "members"},
        if(tracked, do: %{"tracks" => ["standard", "fast-track"]}, else: %{})
      )
    end

    stage = fn id, name, sequence, extra ->
      Map.merge(
        %{
          "id" => id,
          "name" => name,
          "inputs" => [],
          "sequence" => Enum.map(sequence, &%{"workflow" => &1}),
          "outputs" => [],
          "gate" => gate.()
        },
        extra
      )
    end

    document =
      %{
        "schema" => "qory.process/v1",
        "machine" => "default",
        "stages" => [
          stage.(@explore, "Explore", ["explore-a-ticket"], %{
            "outputs" => [%{"type" => "proposal", "required" => true}]
          }),
          stage.(@build, "Build", ["plan-the-build", "implement-changes"], %{
            "shared_run" => true
          })
        ]
      }
      |> Map.merge(if(tracked, do: %{"tracks" => @tracks}, else: %{}))

    {:ok, _version} = Processes.save(scope, scope.workspace, document)
  end

  # The work item in Build, its proposal confirmed with `track` (none for nil), and its
  # Build run queued.
  defp in_build!(scope, track) do
    work_item = taken_in_fixture(scope) |> end_run!(understood_result())
    opts = if track, do: [track: track], else: []
    {:ok, _moved} = WorkItems.confirm(scope, work_item, 1, opts)
    Repo.get!(WorkItem, work_item.id)
  end

  # The claim of the oldest waiting run, with its inputs decoded.
  defp claimed!(ctx) do
    {:ok, claimed} = Apiary.DispatchedRunsFixtures.walked_claim(ctx.key, Dispatches.now())
    {claimed.run, claimed.documents.inputs |> Jason.encode!() |> Jason.decode!()}
  end

  # The run stores `verdict` during its session, as a run does through the run API.
  defp verdict!(run, verdict) do
    {:ok, _version} =
      Stages.Artifacts.push_json(
        {:run, run},
        Repo.get!(WorkItem, run.work_item_id),
        "verdict",
        verdict,
        stage_id: run.stage_id
      )

    :ok
  end

  defp next_inputs!(run, verdict) do
    :ok = verdict!(run, verdict)

    assert {:session, %{session: 2, workflow: "implement-changes", inputs: inputs}} =
             Stages.next_session(run, %{session: 1, state: "succeeded", reason: nil})

    inputs
  end

  test "a Build run's inputs have the work item's track, and so does its later session", ctx do
    process!(ctx.scope, true)
    work_item = in_build!(ctx.scope, "fast-track")

    {run, inputs} = claimed!(ctx)
    assert %DispatchRun{stage_id: @build, workflow: "plan-the-build"} = run
    assert inputs["track"] == "fast-track"

    assert next_inputs!(run, %{"verdict" => "passed"})["track"] == "fast-track"
    assert Stages.track(Repo.get!(WorkItem, work_item.id)) == "fast-track"
  end

  test "a Build run of a work item with no track has no track member", ctx do
    process!(ctx.scope, false)
    in_build!(ctx.scope, nil)

    {run, inputs} = claimed!(ctx)
    assert %DispatchRun{stage_id: @build} = run
    refute Map.has_key?(inputs, "track")

    refute Map.has_key?(next_inputs!(run, %{"verdict" => "passed"}), "track")
  end

  test "a run's verdict proposes a track; the next session's input keeps the approved one",
       ctx do
    process!(ctx.scope, true)
    in_build!(ctx.scope, "standard")

    {run, inputs} = claimed!(ctx)
    assert inputs["track"] == "standard"

    proposal = %{
      "verdict" => "passed",
      "track" => %{"id" => "fast-track", "reason" => "A small change."}
    }

    assert next_inputs!(run, proposal)["track"] == "standard"
  end

  test "an Explore run's inputs have no track and fit Explore's input schema", ctx do
    process!(ctx.scope, true)
    work_item = taken_in_fixture(ctx.scope)

    {run, inputs} = claimed!(ctx)
    assert %DispatchRun{stage_id: @explore} = run
    refute Map.has_key?(inputs, "track")
    assert ExploreInputsSchema.validate(inputs) == :ok

    # Once the work item is on a track, a run of Explore's stage still has none: the run of
    # Explore, and a run of Explore's stage that is not the take in's, as after a move back.
    work_item = work_item |> end_run!(understood_result())
    {:ok, _moved} = WorkItems.confirm(ctx.scope, work_item, 1, track: "fast-track")
    work_item = Repo.get!(WorkItem, work_item.id)
    assert Stages.track(work_item) == "fast-track"

    explore_run = Repo.get!(DispatchRun, run.id)
    assert Stages.input_track(explore_run, work_item) == nil

    {1, _rows} =
      Repo.update_all(from(r in DispatchRun, where: r.id == ^run.id),
        set: [explore: false, workflow: "triage-review"]
      )

    assert Stages.input_track(Repo.get!(DispatchRun, run.id), work_item) == nil

    build_run = newest_run(work_item)
    assert %DispatchRun{stage_id: @build} = build_run
    assert Stages.input_track(build_run, work_item) == "fast-track"
  end
end
