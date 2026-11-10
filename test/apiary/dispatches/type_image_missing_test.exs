defmodule Apiary.Dispatches.TypeImageMissingTest do
  # A run given its machine type's image (`runs.configured_image_from_type`) whose exit
  # reason is `image_missing`: the registry has no copy of it. It ends as any failed run
  # does: no record of its pool is cleared, no build is queued, and nothing is queued
  # again (`Apiary.Dispatches.RunEnd`), whatever the type's image is by then, and after
  # the type is deleted, which sets `configured_image_machine_type_id` to null. Not
  # async: the test sets a type's image, and a save of a process document locks the
  # table of types.
  use Apiary.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.AccessKeysFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Environments.Record
  alias Apiary.MachineTypes.MachineType
  alias Apiary.Runs.{Projector, Run}

  @moduletag needs: [:factory, :registry]

  @image "ghcr.io/qoryai/qory-agent-browser@sha256:" <> String.duplicate("7d2c", 16)
  @target %{system: "forge.example.com", path: "acme/shop"}
  @labels %{"forge" => "forge.example.com", "repository" => "acme/shop"}

  # A run started in the image that browser had then, which is also the image of the
  # pool's record, then `change` runs on the type browser, then the run exits with the
  # reason `image_missing`: no record is cleared, no build is queued, and nothing is
  # queued again.
  defp assert_nothing_queued(change) do
    %{scope: scope} = sign_up_fixture()
    pool = pool_fixture(scope)
    %{access_key: key} = enrolled_key_fixture(scope, pool)

    collection =
      collection_fixture(scope, target_system: @target.system, target_path: @target.path)

    now = DateTime.utc_now()

    record =
      Repo.insert!(%Record{
        organisation_id: scope.organisation.id,
        workspace_id: scope.workspace.id,
        pool_id: pool.id,
        source_collection_id: collection.id,
        image: registry_image(scope.organisation.id, String.duplicate("3b9d", 16)),
        size: 734_003_200,
        commit: "9c1e4a7b",
        built_at: now,
        reported_ref: "env-1",
        built_ref: "env-1",
        built_target_system: @target.system,
        built_target_path: @target.path,
        built_queued_at: now
      })

    browser = Repo.get_by!(MachineType, key: "browser")

    # The two images are the same: they differ only in the machine type kept on the run.
    %{dispatch_run: dispatch_run, run: run} =
      handed_over_fixture(scope, key, %{
        configured_image: record.image,
        configured_image_from_type: true,
        configured_image_machine_type_id: browser.id,
        registration_labels: @labels
      })

    change.(browser)

    event_fixture(run, 9, "run.exited", %{
      "state" => "failed",
      "reason" => "image_missing",
      "exit_code" => -1
    })

    assert {:ok, %Run{exited_at: %DateTime{}}} = Projector.project(run)

    assert Repo.get!(Record, record.id) == record

    assert Repo.all(
             from d in DispatchRun,
               where: d.source_collection_id == ^collection.id,
               select: d.id
           ) == []

    assert Repo.all(
             from d in DispatchRun,
               where: d.work_item_id == ^dispatch_run.work_item_id,
               select: {d.attempt, d.state, d.end_cause}
           ) == [{1, :ended, :run_ended}]

    Repo.get!(Run, run.id)
  end

  test "a run that started in its machine type's image clears nothing and queues nothing, after the type's image changed" do
    run =
      assert_nothing_queued(fn browser ->
        {1, _rows} =
          Repo.update_all(from(t in MachineType, where: t.id == ^browser.id),
            set: [image: @image]
          )
      end)

    assert run.configured_image_machine_type_id
  end

  test "a run that started in its machine type's image clears nothing and queues nothing, after the type was deleted" do
    run =
      assert_nothing_queued(fn browser ->
        {1, _rows} = Repo.delete_all(from(t in MachineType, where: t.id == ^browser.id))
      end)

    assert {run.configured_image_from_type, run.configured_image_machine_type_id} == {true, nil}
  end
end
