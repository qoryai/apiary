defmodule ApiaryWeb.ActivityStagesTest do
  # The Activity lines of the workflow model: a decision at a stage of a work item
  # (`gate.approve`), a change to the workspace's process (`process.edit`), a person's
  # artifact version (`artifact.write`) and a change to the artifact types
  # (`artifact_type.edit`), by their labels in the filter and their sentences.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.Audit.Entry
  alias ApiaryWeb.Activity.Describer.Core

  @moduletag needs: [:factory, :workflow_model]

  defp entry(action, details),
    do: %Entry{
      action: Atom.to_string(action),
      actor_kind: :person,
      details: details,
      subject_kind: "work_item",
      subject_id: Ecto.UUID.generate()
    }

  test "the labels, offered in the filter" do
    %{scope: scope} = sign_up_fixture()

    assert Core.label(:"gate.approve") == "Work item stage decided"
    assert Core.label(:"process.edit") == "Process changed"
    assert Core.offered?(scope, :"gate.approve")
    assert Core.label(:"workspace_type.edit") == "Workspace type changed"
    assert Core.offered?(scope, :"process.edit")
    assert Core.offered?(scope, :"workspace_type.edit")
    assert Core.label(:"artifact.write") == "Artifact version added"
    assert Core.label(:"artifact_type.edit") == "Artifact type changed"
    assert Core.offered?(scope, :"artifact.write")
    assert Core.offered?(scope, :"artifact_type.edit")
  end

  test "the sentences of a stage's decisions" do
    said = fn change ->
      Core.sentence(:"gate.approve", entry(:"gate.approve", %{"change" => change}), %{})
    end

    assert said.("approve") == "Approved a stage of a work item"
    assert said.("request_changes") == "Asked for changes in a stage of a work item"
    assert said.("move") == "Moved a work item to another stage"
    assert said.("escalation_accept") == "Accepted an escalated stage of a work item as it is"

    assert said.("escalation_another_round") ==
             "Started another round of an escalated stage of a work item"

    assert said.("escalation_move_back") ==
             "Moved a work item back to an earlier stage to resolve an escalation"

    assert said.("escalation_close") == "Closed a work item to resolve an escalation"
    assert said.("escalation_decline") == "Declined a work item to resolve an escalation"
  end

  test "the sentences of the process's changes" do
    said = fn change ->
      Core.sentence(
        :"process.edit",
        entry(:"process.edit", %{"change" => change, "number" => 3}),
        %{}
      )
    end

    assert said.("save") == "Saved version 3 of the process"
    assert said.("save_trial") == "Saved version 3 of the process as a trial"
    assert said.("make_current") == "Made version 3 the current process"
    assert said.("drop_trial") == "Dropped the trial version 3 of the process"
    assert said.("assign") == "Assigned a work item to version 3 of the process"
  end

  test "the sentences of an artifact's version, with its name where it is not main" do
    said = fn name ->
      details = %{"type" => "mockup", "name" => name, "number" => 3}
      Core.sentence(:"artifact.write", entry(:"artifact.write", details), %{})
    end

    assert said.("main") == "Added version 3 of mockup"
    assert said.("payment") == "Added version 3 of mockup payment"
  end

  test "the sentences of a change to the artifact types" do
    said = fn change ->
      details = %{"change" => change, "type" => "brief"}
      Core.sentence(:"artifact_type.edit", entry(:"artifact_type.edit", details), %{})
    end

    assert said.("create") == "Added artifact type brief"
    assert said.("update") == "Saved artifact type brief"
    assert said.("delete") == "Deleted artifact type brief"
  end

  test "the sentence of a change to a workspace type's default" do
    details = %{"change" => "save", "type" => "qory.software", "number" => 2}

    assert Core.sentence(:"workspace_type.edit", entry(:"workspace_type.edit", details), %{}) ==
             "Workspace type changed"
  end
end
