defmodule Apiary.Stages.StopCauseTest do
  # Why a run of a stage stopped, as an escalation shows it (`Apiary.Stages.StopCause`):
  # for a run that ended before it started, the cause, then who fixes it and where.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  import Apiary.OrganisationsFixtures

  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Nodes.Node
  alias Apiary.Stages.StopCause
  alias Apiary.WorkItems.WorkItem

  setup do
    %{scope: scope} = sign_up_fixture()
    workspace = scope.workspace
    organisation = scope.organisation

    work_item = %WorkItem{
      id: Ecto.UUID.generate(),
      workspace_id: workspace.id,
      organisation_id: organisation.id,
      target_system: "git.example.com",
      target_path: "acme/web-shop"
    }

    %{work_item: work_item, ws: workspace.name, org: organisation.name}
  end

  defp text(cause, work_item, fields \\ [], context \\ %{}) do
    run =
      struct(
        %DispatchRun{
          id: Ecto.UUID.generate(),
          workspace_id: work_item.workspace_id,
          organisation_id: work_item.organisation_id,
          state: :ended,
          end_cause: cause
        },
        fields
      )

    StopCause.text(run, work_item, context)
  end

  test "a cause of the model choice names the owners and admins and Workspace settings › Model",
       %{work_item: work_item, ws: ws} do
    assert text(:key_gone, work_item) ==
             "The run did not start, because the chosen model provider no longer has the chosen key.\n" <>
               "Owners and admins of #{ws} choose another key on the set-up step Model."

    assert text(:provider_gone, work_item) ==
             "The run did not start, because the model provider of its model choice was removed, or no longer applies to #{ws}.\n" <>
               "Owners and admins of #{ws} choose another model provider in Workspace settings › Model."

    assert text(:runtime_unserved, work_item) =~
             "\nOwners and admins of #{ws} choose another runtime or model provider in Workspace settings › Model."

    assert text(:model_gone, work_item) =~
             "\nOwners and admins of #{ws} choose another model or effort in Workspace settings › Model."
  end

  test "a missing model key", %{work_item: work_item, ws: ws} do
    assert text(:run_refused, work_item, end_detail: "model_key_missing") ==
             "The gateway did not start the run, because it had no model key for the run.\n" <>
               "Owners and admins of #{ws} add a model key on the set-up step Model."
  end

  test "a ticket that is gone, and an input that breaks its rule", %{work_item: work_item} do
    assert text(:ticket_gone, work_item) ==
             "The run did not start, because the work item's ticket is no longer in Qory Apiary.\n" <>
               "Close the work item, or take the ticket in again."

    assert text(:inputs_invalid, work_item) =~
             "\nWhoever can edit the ticket where it comes from shortens or corrects it, then takes it in again."
  end

  test "a failed build with no build run names the target's page", %{work_item: work_item} do
    assert text(:build_failed, work_item) ==
             "The run did not start, because the build of the environment for target acme/web-shop failed.\n" <>
               "Read why on the page of target acme/web-shop, under Targets, then choose Rebuild there."

    assert StopCause.build_run(work_item) == nil
  end

  test "a run variable names the variable and its rule", %{work_item: work_item, org: org} do
    work_item = %{work_item | target_system: "Not_A_Host"}

    assert text(:variables_invalid, work_item) ==
             "The run did not start, because its variable QORY_RUN_SYSTEM, the system of target acme/web-shop, is not a host name of a-z, 0-9, dots and dashes.\n" <>
               "Owners and admins of #{org} check the integration that brings in target acme/web-shop in Organisation settings › Integrations."

    work_item = %{work_item | target_system: "git.example.com", target_path: "-acme/web-shop"}

    assert text(:variables_invalid, work_item) =~
             "its variable QORY_RUN_REPOSITORIES breaks its rule"

    # No variable breaks its rule when the text is written: no variable is named.
    work_item = %{work_item | target_path: "acme/web-shop"}

    assert text(:variables_invalid, work_item) ==
             "The run did not start, because one of its variables breaks its rule.\n" <>
               "The instance admin finds the details in the instance's log."
  end

  test "a missing or removed model key links the set-up step Model", %{work_item: work_item} do
    run = %DispatchRun{state: :ended, end_cause: :run_refused, end_detail: "model_key_missing"}
    assert StopCause.set_up_step(run) == :model
    assert StopCause.set_up_step(%DispatchRun{end_cause: :key_gone}) == :model
    assert StopCause.set_up_step(%DispatchRun{end_cause: :provider_gone}) == nil
    assert text(:key_gone, work_item) =~ "on the set-up step Model."
  end

  test "a gateway without stored secrets names the gateway and who adds a key, by its level",
       %{work_item: work_item, org: org, ws: ws} do
    keys = [%{allow_secrets: false}]
    instance = %Node{kind: :gateway, name: "edge-1"}

    assert text(:secrets_not_allowed, work_item, [], %{gateway: instance, keys: keys}) ==
             "The run did not start, because gateway edge-1 is not allowed to receive the run's secrets.\n" <>
               "The instance admin adds an access key for edge-1 with stored secrets allowed, on Instance settings › Nodes › edge-1 › Access key."

    organisation = %{instance | organisation_id: work_item.organisation_id}

    assert text(:secrets_not_allowed, work_item, [], %{gateway: organisation, keys: keys}) =~
             "\nOwners and admins of #{org} add an access key for edge-1 with stored secrets allowed, on Gateways › edge-1 › Access key."

    workspace = %{organisation | workspace_id: work_item.workspace_id}

    assert text(:secrets_not_allowed, work_item, [], %{gateway: workspace, keys: keys}) =~
             "\nOwners and admins of #{ws} add an access key for edge-1 with stored secrets allowed, on Nodes › edge-1 › Access key."

    assert text(:secrets_not_allowed, work_item, [], %{
             gateway: instance,
             keys: [%{allow_secrets: true}]
           }) =~ "may not be sent to gateway edge-1"
  end

  test "a target no collection of the workspace reaches any more", %{
    work_item: work_item,
    org: org
  } do
    assert text(:target_access_gone, work_item) ==
             "The run did not start, because no integration of #{org} reaches target acme/web-shop.\n" <>
               "Owners and admins of #{org} connect one in Organisation settings › Integrations."
  end

  test "a harness with no walk row, and an unknown cause, show the code with a description",
       %{work_item: work_item} do
    assert text(:harness_unresolved, work_item) =~
             ~r/\AQory Apiary could not read the harness of .+ \(a failure Qory Apiary has no description for\)\.\nThe instance admin finds the details in the instance's log\.\z/

    assert text(:collection_ended, work_item) ==
             "The run ended before it started. Qory Apiary has no description for its end cause (collection_ended).\n" <>
               "The instance admin finds the details in the instance's log."
  end

  describe "a harness walk that failed" do
    @describetag needs: :factory

    # The run of a work item queued, its walk failed with `failure` at `source`.
    defp walk_failed(scope, failure, source) do
      work_item = Apiary.WorkItemsFixtures.work_item_fixture(scope)
      {:ok, run} = Repo.transact(fn -> Apiary.Dispatches.queue(work_item, 1) end)

      {1, _rows} =
        Repo.update_all(
          from(h in Apiary.Harnesses.RunHarness, where: h.dispatch_run_id == ^run.id),
          set: [state: :failed, origin: nil, failure: failure, failed_source: source]
        )

      {%{run | state: :ended, end_cause: :harness_unresolved}, work_item}
    end

    test "on the workspace's choice, the fix is on the set-up step Harness" do
      %{scope: scope} = sign_up_fixture()
      ws = scope.workspace.name
      {run, work_item} = walk_failed(scope, "no_harness", nil)

      assert StopCause.text(run, work_item) ==
               "Qory Apiary could not read the harness of #{ws} (the target has no harness file, and the workspace sets no harness).\n" <>
                 "Owners and admins of #{ws} choose a harness on the set-up step Harness."

      assert StopCause.set_up_step(run) == :harness

      {run, _work_item} = walk_failed(scope, "invalid", "https://code.example.com/team/stacks")
      assert StopCause.set_up_step(run) == nil
      assert StopCause.set_up_step(%DispatchRun{end_cause: :key_gone}) == nil
    end

    test "with no integration that reaches it, in the Workflow page's words" do
      %{scope: scope} = sign_up_fixture()
      org = scope.organisation.name
      {run, work_item} = walk_failed(scope, "not_covered", "https://code.example.com/team/stacks")

      assert StopCause.text(run, work_item) ==
               "No integration of #{org} reaches https://code.example.com/team/stacks. Qory Apiary reads a harness only through an integration.\n" <>
                 "Owners and admins of #{org} connect one in Organisation settings › Integrations."
    end
  end
end
