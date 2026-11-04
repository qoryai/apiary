defmodule Apiary.Processes.MigrationTest do
  # The backfill of the migration that keeps each workspace's process, run inside the
  # test's transaction, which rolls it all back: a workspace with no version gets version 1,
  # the software type's default, and each open work item with no version gets it and the
  # stage that matches where it is. It writes to every workspace without a version, so it
  # is not async.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures, only: [work_item_fixture: 1, explore_run_fixture: 2]

  alias Apiary.Processes
  alias Apiary.Processes.Version
  alias Apiary.WorkItems.{Confirmation, WorkItem}

  @migration {20_261_031_090_500, Apiary.Repo.Migrations.KeepEachWorkspaceSProcess,
              "keep_each_workspace_s_process"}

  @explore "st_r79kph11eg"
  @shape "st_p9w5cvh311"

  setup_all do
    {version, migration, name} = @migration

    if not Code.ensure_loaded?(migration) do
      Application.app_dir(:apiary, "priv/repo/migrations")
      |> Path.join("#{version}_#{name}.exs")
      |> Code.require_file()
    end

    :ok
  end

  defp backfill!, do: elem(@migration, 1).backfill(Repo)

  # A work item of the scope's workspace, its newest explore run ended with `outcome`.
  defp explored!(scope, outcome) do
    work_item = work_item_fixture(scope)
    %{dispatch_run: run} = explore_run_fixture(work_item, registered: false)
    Repo.update!(Ecto.Changeset.change(run, result_outcome: outcome))
    work_item
  end

  defp confirm!(work_item, user) do
    Repo.insert!(%Confirmation{
      organisation_id: work_item.organisation_id,
      workspace_id: work_item.workspace_id,
      work_item_id: work_item.id,
      take_in: work_item.take_in,
      attempt: 1,
      result: %{},
      confirmed_by_id: user.id,
      confirmed_at: DateTime.utc_now()
    })
  end

  # A row of the table the migration read answers from, which no code writes since
  # answers are kept in the questions artifact.
  defp answer!(work_item, user) do
    {:ok, work_item_id} = Ecto.UUID.dump(work_item.id)
    {:ok, organisation_id} = Ecto.UUID.dump(work_item.organisation_id)
    {:ok, workspace_id} = Ecto.UUID.dump(work_item.workspace_id)
    {:ok, user_id} = Ecto.UUID.dump(user.id)

    Repo.insert_all("work_item_answers", [
      %{
        id: Ecto.UUID.bingenerate(),
        organisation_id: organisation_id,
        workspace_id: workspace_id,
        work_item_id: work_item_id,
        take_in: work_item.take_in,
        attempt: 1,
        position: 1,
        question: "Which checkout?",
        answer: "The one at the shop.",
        custom: true,
        answered_by_id: user_id,
        answered_at: DateTime.utc_now()
      }
    ])
  end

  defp placed(work_item) do
    work_item = Repo.reload!(work_item)

    {work_item.stage_id, work_item.stage_state, work_item.stage_round, work_item.stage_entry,
     work_item.loop_entry}
  end

  test "gives a workspace with no version version 1, and each open work item its stage" do
    %{scope: scope, user: user} = sign_up_fixture()

    fresh = work_item_fixture(scope)
    running = work_item_fixture(scope)
    explore_run_fixture(running, state: :claimed, registered: false)
    proposed = explored!(scope, :proposal)
    asked = explored!(scope, :questions)
    answered = explored!(scope, :questions)
    answer!(answered, user)
    failed = explored!(scope, :error)
    confirmed = explored!(scope, :proposal)
    confirm!(confirmed, user)

    closed =
      Repo.update!(
        Ecto.Changeset.change(work_item_fixture(scope),
          state: :closed,
          closed_at: DateTime.utc_now(),
          closed_by_id: user.id
        )
      )

    # As before the migration: no version, and no place in one.
    Repo.delete_all(from v in Version, where: v.workspace_id == ^scope.workspace.id)

    assert Repo.aggregate(from(w in WorkItem, where: not is_nil(w.process_version_id)), :count) ==
             0

    backfill!()

    assert [version] = Processes.list_versions(scope.workspace)

    assert %Version{number: 1, status: :current, author_id: nil, based_on_id: nil} = version
    # The software type's default as the migration copied it: Explore then had a loop of
    # 3 rounds, which today's default has no more.
    loop = [%{"loop" => %{"rounds" => 3, "body" => [%{"workflow" => "explore-a-ticket"}]}}]

    assert version.document ==
             update_in(
               Processes.default_document("software"),
               ["stages", Access.at(0), "sequence"],
               fn _today -> loop end
             )

    assert version.template == %{"type" => "qory.software", "version" => 1}
    assert version.public_id =~ ~r/\Apv_[0-9a-hjkmnp-tv-z]{16}\z/

    assert placed(fresh) == {@explore, :running, 0, 0, 0}
    assert placed(running) == {@explore, :running, 1, 0, 0}
    assert placed(proposed) == {@explore, :at_gate, 1, 0, 0}
    assert placed(asked) == {@explore, :waiting_answers, 1, 0, 0}
    assert placed(answered) == {@explore, :running, 1, 0, 0}
    assert placed(failed) == {@explore, :escalated, 1, 0, 0}
    assert placed(confirmed) == {@shape, :at_gate, 0, 0, nil}
    assert placed(closed) == {nil, nil, nil, nil, nil}

    for work_item <- [fresh, running, proposed, asked, answered, failed, confirmed] do
      assert Repo.reload!(work_item).process_version_id == version.id
    end

    assert Repo.reload!(closed).process_version_id == nil
  end

  test "leaves a workspace that has a version, and a work item placed in one, as they are" do
    %{scope: scope} = sign_up_fixture()
    [before] = Processes.list_versions(scope.workspace)
    work_item = work_item_fixture(scope)

    Repo.update!(
      Ecto.Changeset.change(work_item,
        process_version_id: before.id,
        stage_id: @shape,
        stage_state: :done
      )
    )

    backfill!()

    assert Processes.list_versions(scope.workspace) == [before]
    assert {@shape, :done, nil, nil, nil} = placed(work_item)
  end
end
