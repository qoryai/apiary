defmodule ApiaryPro.HarnessAssignmentsDropTest do
  # What a drop of a client removes of its operator's harness: the harness documents the
  # operator owns in the client, and its assignments of harness sources to it
  # (`ApiaryPro.Transfers.drop/3`).
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import ApiaryPro.OperatorsFixtures

  alias Apiary.Harnesses
  alias Apiary.Stacks
  alias Apiary.Stacks.Stack
  alias ApiaryPro.{Flags, HarnessAssignments, Transfers}
  alias ApiaryPro.HarnessAssignments.Assignment

  @moduletag with_features: Apiary.Features.all()

  @git "https://code.example.com/team/stacks"
  @base %{"git" => @git, "ref" => "main", "path" => "core"}
  @export %{"git" => @git, "ref" => "main", "stack" => "web"}
  @module %{"git" => @git, "ref" => "main", "module" => "lint"}
  @document """
  extends: {git: #{@git}, ref: main, path: core}
  modules:
    - source: {git: #{@git}, ref: main, module: lint}
  """
  @clients_document "extends: {git: https://code.example.com/client/stacks, ref: main}\n"

  # An operator with two clients, the first with an operator's document, an operator's
  # document that sets a workflow too, and a document its people saved; the second with a
  # document of the operator. Assignments for both. The flag is off while they are made,
  # then on while the documents are saved, and off for the drop, which the flag hides.
  setup do
    Flags.put_transfers(true)
    Flags.put_operator_infrastructure(false)

    operator = operator_fixture()
    client = client_fixture(operator.scope)
    second = client_fixture(operator.scope)
    client_owner = client.owner

    for target <- [client, second], source <- [@base, @export] do
      {:ok, _} =
        HarnessAssignments.assign(operator.organisation.id, target.organisation.id, source)
    end

    # A client's people save at the organisation level, the operator at the workspace.
    {:ok, theirs} =
      Stacks.put_stack(
        client_owner.scope,
        {:organisation, client.organisation},
        @clients_document
      )

    Flags.put_operator_infrastructure(true)

    {:ok, document} = Stacks.put_stack(client.scope, {:workspace, client.workspace}, @document)

    {:ok, with_workflow} =
      Stacks.put_stack(client.scope, {:workspace, client.workspace, "explore"}, @document)

    {:ok, other} = Stacks.put_stack(second.scope, {:workspace, second.workspace}, @document)

    Flags.put_operator_infrastructure(false)

    %{
      operator: operator,
      client: client,
      second: second,
      theirs: theirs,
      document: document,
      with_workflow: with_workflow,
      other: other
    }
  end

  defp drop(ctx) do
    assert {:ok, dropped} =
             Transfers.drop(
               ctx.operator.scope,
               ctx.client.organisation.id,
               ctx.client.organisation.name
             )

    Flags.put_operator_infrastructure(true)
    dropped
  end

  test "setup: the documents belong to whom saved them", ctx do
    operator_id = ctx.operator.organisation.id

    assert ctx.document.owner_organisation_id == operator_id
    assert ctx.with_workflow.owner_organisation_id == operator_id
    assert ctx.other.owner_organisation_id == operator_id
    assert ctx.theirs.owner_organisation_id == ctx.client.organisation.id
  end

  test "a drop deletes the operator's documents in the client, and keeps the people's", ctx do
    drop(ctx)

    refute Repo.get(Stack, ctx.document.id)
    assert Repo.get(Stack, ctx.theirs.id).harness == @clients_document

    # A row that sets a workflow keeps the workflow, without the operator's document.
    kept = Repo.get(Stack, ctx.with_workflow.id)
    assert kept.workflow == "explore"
    assert kept.harness == nil
  end

  test "a drop deletes the operator's assignments to the client, and no other", ctx do
    operator_id = ctx.operator.organisation.id
    client_id = ctx.client.organisation.id

    assert length(HarnessAssignments.list(operator_id, client_id)) == 2
    drop(ctx)

    assert HarnessAssignments.list(operator_id, client_id) == []
    refute Repo.exists?(from a in Assignment, where: a.organisation_id == ^client_id)

    # The operator's other client keeps its assignments and its document.
    assert length(HarnessAssignments.list(operator_id, ctx.second.organisation.id)) == 2
    assert Repo.get(Stack, ctx.other.id).harness == @document
  end

  test "after a drop the operator's sources are refused for the client", ctx do
    operator_id = ctx.operator.organisation.id
    client_id = ctx.client.organisation.id

    Flags.put_operator_infrastructure(true)
    assert Harnesses.allowed?(client_id, operator_id, @base)
    assert Harnesses.allowed?(ctx.second.organisation.id, operator_id, @base)
    Flags.put_operator_infrastructure(false)

    drop(ctx)

    refute Harnesses.allowed?(client_id, operator_id, @base)
    refute Harnesses.allowed?(client_id, operator_id, @export)
    assert Harnesses.allowed?(ctx.second.organisation.id, operator_id, @base)

    # Even a row that survived, or is written later, is no answer: the client's tenant
    # names no operator.
    Repo.insert!(%Assignment{
      operator_id: operator_id,
      organisation_id: client_id,
      git: @git,
      ref: "main",
      path: "core"
    })

    refute Harnesses.allowed?(client_id, operator_id, @base)
    assert HarnessAssignments.assign(operator_id, client_id, @export) == {:error, :not_found}
  end

  test "after a drop the client's people save a harness document", ctx do
    dropped = drop(ctx)

    scope = scope_in(ctx.client.owner.user, dropped, ctx.client.workspace)

    assert {:ok, %Stack{} = stack} =
             Stacks.put_stack(scope, {:workspace, ctx.client.workspace}, @clients_document)

    assert stack.owner_organisation_id == ctx.client.organisation.id
    assert stack.harness == @clients_document
  end

  test "after a drop a source only the operator's document lists is refused", ctx do
    operator_id = ctx.operator.organisation.id
    client_id = ctx.client.organisation.id

    Flags.put_operator_infrastructure(true)
    assert Harnesses.allowed?(client_id, operator_id, @module)
    assert Harnesses.allowed?(ctx.second.organisation.id, operator_id, @module)
    Flags.put_operator_infrastructure(false)

    drop(ctx)

    refute Harnesses.allowed?(client_id, operator_id, @module)
    assert Harnesses.allowed?(ctx.second.organisation.id, operator_id, @module)

    # Even a document of the operator that is stored again is no answer: the client's
    # tenant names no operator.
    Repo.insert!(%Stack{
      organisation_id: client_id,
      workspace_id: ctx.client.workspace.id,
      owner_organisation_id: operator_id,
      harness: @document
    })

    refute Harnesses.allowed?(client_id, operator_id, @module)
    refute Harnesses.allowed?(client_id, operator_id, @base)
  end
end
