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
      number: 12,
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
             "The run did not start, because its variable QORY_RUN_SYSTEM, the system Not_A_Host of target acme/web-shop, is not a host name: a-z, 0-9, dots and dashes, with no dot at either end and no two dots in a row.\n" <>
               "Owners and admins of #{org} check the integration that brings in target acme/web-shop in Organisation settings › Integrations."

    work_item = %{work_item | target_system: "git.example.com", target_path: "-acme/web-shop"}

    assert text(:variables_invalid, work_item) =~
             "its variable QORY_RUN_REPOSITORIES breaks its rule"

    # No variable breaks its rule when the text is written: no variable is named.
    work_item = %{work_item | target_path: "acme/web-shop"}

    assert text(:variables_invalid, work_item) ==
             "The run did not start, because one of its variables breaks its rule.\n" <>
               "Contact support with work item #12."
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

    # The instance's gateway is not named: the person sees neither it nor its keys.
    for keys <- [keys, [%{allow_secrets: true}]] do
      assert text(:secrets_not_allowed, work_item, [], %{gateway: instance, keys: keys}) ==
               "The run did not start, because its gateway is not allowed to receive the run's secrets.\n" <>
                 "Contact support with work item #12."
    end

    organisation = %{instance | organisation_id: work_item.organisation_id}

    assert text(:secrets_not_allowed, work_item, [], %{gateway: organisation, keys: keys}) =~
             "\nOwners and admins of #{org} add an access key for edge-1 with stored secrets allowed, on Gateways › edge-1 › Access key."

    workspace = %{organisation | workspace_id: work_item.workspace_id}

    assert text(:secrets_not_allowed, work_item, [], %{gateway: workspace, keys: keys}) =~
             "\nOwners and admins of #{ws} add an access key for edge-1 with stored secrets allowed, on Machines › edge-1 › Access key."

    assert text(:secrets_not_allowed, work_item, [], %{
             gateway: organisation,
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
             ~r/\AQory Apiary could not read the harness of .+ \(a failure Qory Apiary has no description for\)\.\nContact support with work item #12\.\z/

    assert text(:collection_ended, work_item) ==
             "The run ended before it started. Qory Apiary has no description for its end cause (collection_ended).\n" <>
               "Contact support with work item #12."

    assert text(:run_refused, work_item, end_detail: "machine_busy") ==
             "The gateway did not start the run. Qory Apiary has no description for its refusal (machine_busy).\n" <>
               "Contact support with work item #12."
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
      assert StopCause.set_up_step(%DispatchRun{end_cause: :provider_gone}) == nil
    end

    test "a built-in harness at a branch its repository does not have: contact support, and no set-up step" do
      %{scope: scope} = sign_up_fixture()
      url = Apiary.Harnesses.Builtin.git()
      {run, work_item} = walk_failed(scope, "ref_missing", url)

      {1, _rows} =
        Repo.update_all(
          from(h in Apiary.Harnesses.RunHarness, where: h.dispatch_run_id == ^run.id),
          set: [
            failure_rule: %{
              "rule" => "claim",
              "values" => %{"url" => url, "ref" => "gone", "builtin" => true}
            }
          ]
        )

      assert StopCause.text(run, work_item) ==
               "Reading the harness from #{url} failed: the repository has no branch gone.\n" <>
                 "Contact support."

      assert StopCause.set_up_step(run) == nil
    end

    test "with no source shown, the line starts with a capital and the fix does not" do
      %{scope: scope} = sign_up_fixture()
      org = scope.organisation.name
      ws = scope.workspace.name
      {run, work_item} = walk_failed(scope, "not_covered", nil)

      assert StopCause.text(run, work_item) ==
               "The harness of #{ws} is not public, or does not exist, and no connection of #{org} reaches it.\n" <>
                 "Owners and admins of #{org} connect an integration that covers the harness of #{ws} in Organisation settings › Integrations."
    end

    test "with a source that is not public and no connection that reaches it" do
      %{scope: scope} = sign_up_fixture()
      org = scope.organisation.name
      source = "https://code.example.com/team/stacks"
      {run, work_item} = walk_failed(scope, "not_covered", source)

      assert StopCause.text(run, work_item) ==
               "#{source} is not public, or does not exist, and no connection of #{org} reaches it.\n" <>
                 "Owners and admins of #{org} connect an integration that covers #{source} in Organisation settings › Integrations."
    end
  end

  describe "a read-only run qory closed" do
    @describetag needs: :factory

    @wall "A read-only run needs a wall, and this machine has none."
    @inside "A read-only run cannot run its setup inside the agent's container."

    # The run of a work item queued, whose registered run failed with `reason` on `node`.
    defp read_run(scope, reason, node) do
      work_item = Apiary.WorkItemsFixtures.work_item_fixture(scope)
      {:ok, run} = Repo.transact(fn -> Apiary.Dispatches.queue(work_item, 1) end)

      %Apiary.Runs.Run{
        number: Apiary.RunEventsFixtures.next_run_number(run.organisation_id, run.workspace_id),
        organisation_id: run.organisation_id,
        workspace_id: run.workspace_id,
        node_run_id: run.run_id,
        dispatch_run_id: run.id,
        node_id: node && node.id,
        state: "failed",
        exit_state: "failed",
        reason: reason
      }
      |> Ecto.Changeset.change()
      |> Apiary.RunEventsFixtures.insert_run!()

      {%{run | state: :ended, end_cause: :run_ended, result_outcome: :none}, work_item}
    end

    defp words(scope, reason, node) do
      {run, work_item} = read_run(scope, reason, node)
      StopCause.text(run, work_item)
    end

    test "each reason has its fix, then its cause, on a pool of the workspace" do
      %{scope: scope} = sign_up_fixture()
      pool = Apiary.NodesFixtures.pool_fixture(scope)

      for {reason, text} <- [
            {"read_needs_wall",
             "Set a wall in the machine's forager.yaml, then start the run again. " <> @wall},
            {"read_needs_setup_outside",
             "Set wall.setup to outside in the machine's forager.yaml, or remove it, then start the run again. " <>
               @inside},
            {"read_needs_setup_removed",
             "Start the run again. The setup container was not removed, so a process in it could still write the files."}
          ] do
        assert words(scope, reason, pool) == text
      end
    end

    test "a target is a repository only in a software workspace" do
      %{scope: scope} = sign_up_fixture()
      docker = "read_needs_no_nested_docker"

      assert words(scope, docker, nil) ==
               "Choose an image without nested Docker in the repository's environment, then start the run again. A read-only run cannot use an image with nested Docker."

      {1, _rows} =
        Repo.update_all(
          from(w in Apiary.Organisations.Workspace, where: w.id == ^scope.workspace.id),
          set: [domain: "example"]
        )

      assert words(scope, docker, nil) ==
               "Choose an image without nested Docker in the target's environment, then start the run again. A read-only run cannot use an image with nested Docker."
    end
  end

  describe "a run whose harness has no skill for its workflow" do
    @describetag needs: :factory

    # The run of a work item queued, its walk resolved with `walk`, and its registered run
    # failed with `reason`.
    defp gap(scope, walk, reason \\ "workflow_not_in_harness") do
      work_item = Apiary.WorkItemsFixtures.work_item_fixture(scope)
      {:ok, run} = Repo.transact(fn -> Apiary.Dispatches.queue(work_item, 1) end)

      {1, _rows} =
        Repo.update_all(
          from(h in Apiary.Harnesses.RunHarness, where: h.dispatch_run_id == ^run.id),
          set: Keyword.merge([state: :resolved, workflow: "explore-a-ticket"], walk)
        )

      %Apiary.Runs.Run{
        number: Apiary.RunEventsFixtures.next_run_number(run.organisation_id, run.workspace_id),
        organisation_id: run.organisation_id,
        workspace_id: run.workspace_id,
        node_run_id: run.run_id,
        dispatch_run_id: run.id,
        state: "failed",
        exit_state: "failed",
        reason: reason
      }
      |> Ecto.Changeset.change()
      |> Apiary.RunEventsFixtures.insert_run!()

      run = %{run | state: :ended, end_cause: :run_ended, result_outcome: :none}
      {run, %{work_item | target_path: "acme/web-shop"}}
    end

    test "names the workflow and where the harness comes from, by the walk's origin" do
      %{scope: scope} = sign_up_fixture()
      {:ok, choice} = Apiary.Stacks.Sources.choose(scope, :qory)
      missing = "The run's harness has no skill for the workflow explore-a-ticket."

      {run, work_item} = gap(scope, origin: :file)

      assert StopCause.text(run, work_item) ==
               missing <>
                 " The harness comes from the harness file at the root of repository acme/web-shop."

      base = %{"git" => "https://code.example.com/acme/harness", "ref" => "main"}

      for {extends, from} <- [
            {Map.put(base, "stack", "triage"), " stack triage."},
            {Map.put(base, "path", "stacks/web"), " folder stacks/web."}
          ] do
        {run, work_item} =
          gap(scope, origin: :setting, stack_id: choice.id, document: %{"extends" => extends})

        assert StopCause.text(run, work_item) ==
                 missing <>
                   " The harness comes from https://code.example.com/acme/harness," <> from
      end

      {run, work_item} =
        gap(scope, origin: :setting, stack_id: choice.id, document: %{"extends" => base})

      assert StopCause.text(run, work_item) ==
               missing <> " The harness comes from https://code.example.com/acme/harness."

      {run, work_item} =
        gap(scope,
          origin: :setting,
          stack_id: choice.id,
          document: %{"modules" => [%{"name" => "core"}]}
        )

      assert StopCause.text(run, work_item) ==
               missing <> " The harness is the workspace's harness."

      {run, work_item} = gap(scope, origin: :setting, document: %{"extends" => base})
      assert StopCause.text(run, work_item) == missing <> " The harness is the Qory harness."

      # A hidden harness shows no source.
      {run, work_item} = gap(scope, origin: :file, harness_hidden: true)
      assert StopCause.text(run, work_item) == missing
    end

    test "a target is a repository only in a software workspace" do
      %{scope: scope} = sign_up_fixture()

      {1, _rows} =
        Repo.update_all(
          from(w in Apiary.Organisations.Workspace, where: w.id == ^scope.workspace.id),
          set: [domain: "example"]
        )

      {run, work_item} = gap(scope, origin: :file)

      assert StopCause.text(run, work_item) ==
               "The run's harness has no skill for the workflow explore-a-ticket. The harness comes from the harness file at the root of target acme/web-shop."
    end

    test "any other reason is a run that ended without a result" do
      %{scope: scope} = sign_up_fixture()
      {run, work_item} = gap(scope, [origin: :file], "no_session")
      assert StopCause.text(run, work_item) == "The run ended without a result."
    end
  end
end
