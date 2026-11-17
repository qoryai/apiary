defmodule ApiaryPro.WorkspaceOperatorsTest do
  # The link between a workspace and the operator that operates it
  # (`ApiaryPro.WorkspaceOperators`): what an operator's people reach through it, and what
  # it refuses. No code in the product starts a link, so the tests insert the row
  # (`ApiaryPro.OperatorsFixtures.operate_fixture/2`) and delete it.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Access, Deletion, Organisations}
  alias ApiaryPro.{Operators, Reach, Suspensions, WorkspaceOperators}
  alias ApiaryPro.Operators.WorkspaceOperator

  @moduletag with_features: Apiary.Features.all()

  setup do
    operator = operator_fixture()
    %{scope: owner, organisation: organisation} = sign_up_fixture()
    link = operate_fixture(owner.workspace, operator.organisation)

    %{operator: operator, owner: owner, organisation: organisation, link: link}
  end

  defp end_link!(workspace_id),
    do: Repo.delete_all(from l in WorkspaceOperator, where: l.workspace_id == ^workspace_id)

  describe "the links of an organisation" do
    test "are read with the organisation, and from the database", ctx do
      assert ctx.link.operator_id == ctx.operator.organisation.id
      assert ctx.link.organisation_id == ctx.organisation.id

      assert WorkspaceOperators.operator_ids_of(ctx.organisation.id) == [ctx.link.operator_id]
      assert WorkspaceOperators.operates_workspaces?(ctx.operator.organisation)
      assert WorkspaceOperators.has_operated_workspaces?(ctx.organisation)

      put = WorkspaceOperators.put(ctx.organisation)

      assert WorkspaceOperators.operated(put) == %{
               ctx.owner.workspace.id => ctx.operator.organisation.id
             }

      assert WorkspaceOperators.operator_ids(put) == [ctx.operator.organisation.id]
    end
  end

  describe "the reach through a link" do
    setup ctx do
      %{second: workspace_fixture(ctx.organisation, "Second")}
    end

    test "is the operated workspace alone", ctx do
      scope = scope_in(ctx.operator.user, ctx.organisation, ctx.owner.workspace)
      assert Access.reach(scope) == :operator
      assert Reach.operator_level(scope) == :owner
      assert Access.authorize(scope, :"run.read", ctx.owner.workspace) == :ok

      assert scope_in(ctx.operator.user, ctx.organisation, ctx.second) == nil

      assert Access.authorize(scope, :"audit.read", ctx.organisation) == {:error, :not_found}

      assert Access.authorize(scope, :"organisation_policy.read", ctx.organisation) ==
               {:error, :not_found}
    end

    test "ends with the link", ctx do
      end_link!(ctx.owner.workspace.id)
      assert scope_in(ctx.operator.user, ctx.organisation, ctx.owner.workspace) == nil
    end

    test "ends while the operator is suspended, and the link stays", ctx do
      admin = suite_instance_admin()
      scope = scope_in(ctx.operator.user, ctx.organisation, ctx.owner.workspace)

      {:ok, _} =
        Suspensions.suspend_organisation(admin.instance_scope, ctx.operator.organisation.id)

      assert {:error, _refused} = Access.authorize(scope, :"run.read", ctx.owner.workspace)
      assert scope_in(ctx.operator.user, ctx.organisation, ctx.owner.workspace) == nil

      assert WorkspaceOperators.operator_id(ctx.organisation, ctx.owner.workspace.id) ==
               ctx.operator.organisation.id
    end
  end

  describe "what a link refuses" do
    test "the operated workspace is not deleted until the link ends", ctx do
      _second = workspace_fixture(ctx.organisation, "Second")
      workspace = ctx.owner.workspace

      assert Deletion.delete_workspace(ctx.owner, workspace.id, workspace.slug) ==
               {:error, :operated}

      end_link!(workspace.id)
      assert {:ok, _} = Deletion.delete_workspace(ctx.owner, workspace.id, workspace.slug)
    end

    test "the operator is not deleted, nor made an organisation, until the link ends", ctx do
      admin = suite_instance_admin()
      operator = ctx.operator.organisation

      assert Deletion.delete_organisation(ctx.operator.scope, operator.slug) ==
               {:error, :has_operated_workspaces}

      assert Operators.change_kind(admin.instance_scope, operator.id, :organisation) ==
               {:error, :has_operated_workspaces}

      end_link!(ctx.owner.workspace.id)

      assert {:ok, _} = Operators.change_kind(admin.instance_scope, operator.id, :organisation)
    end

    test "an organisation with an operated workspace is not made an operator", ctx do
      admin = suite_instance_admin()

      assert Operators.change_kind(admin.instance_scope, ctx.organisation.id, :operator) ==
               {:error, :has_operated_workspaces}
    end

    test "the organisation's deletion is not refused", ctx do
      assert {:ok, _} = Deletion.delete_organisation(ctx.owner, ctx.organisation.slug)
    end
  end

  describe "schema_change_line/1" do
    @operator_step "To change the schema, ask the operator of this workspace."

    # A person of the operator, at `operator_level`, made an admin of the organisation.
    defp operator_person_who_is_org_admin(ctx, operator_level) do
      ApiaryPro.Flags.put_operator_infrastructure(false)
      %{user: user} = member_fixture(ctx.operator.scope, operator_level)
      %{membership: joined} = join_fixture(ctx.owner, user)
      {:ok, _} = Organisations.set_member_level(ctx.owner, joined.id, :admin)
      scope_in(user, ctx.organisation, ctx.owner.workspace)
    end

    test "is the step to ask the operator for the organisation's owner and admin", ctx do
      workspace = ctx.owner.workspace

      admin =
        organisation_member_fixture(
          %{organisation: ctx.organisation, workspace: workspace, owner: %{scope: ctx.owner}},
          :admin
        )

      ApiaryPro.Flags.put_operator_infrastructure(true)
      owner = scope_in(ctx.owner.user, ctx.organisation, workspace)

      assert WorkspaceOperators.schema_change_line(owner) == @operator_step
      assert WorkspaceOperators.schema_change_line(admin.scope) == @operator_step
      assert Apiary.Edition.schema_change_line(owner) == @operator_step
    end

    test "is nil with the flag off", ctx do
      ApiaryPro.Flags.put_operator_infrastructure(false)
      owner = scope_in(ctx.owner.user, ctx.organisation, ctx.owner.workspace)

      assert WorkspaceOperators.schema_change_line(owner) == nil
      assert Apiary.Edition.schema_change_line(owner) == nil
    end

    test "is nil for the operator's person", ctx do
      ApiaryPro.Flags.put_operator_infrastructure(true)
      scope = scope_in(ctx.operator.user, ctx.organisation, ctx.owner.workspace)

      assert WorkspaceOperators.schema_change_line(scope) == nil
      assert Apiary.Edition.schema_change_line(scope) == nil
    end

    test "follows through_operator?/1 for a person in both", ctx do
      tie = operator_person_who_is_org_admin(ctx, :admin)
      higher = operator_person_who_is_org_admin(ctx, :owner)
      ApiaryPro.Flags.put_operator_infrastructure(true)

      # An admin of both acts at their level in the organisation.
      refute ApiaryPro.Access.through_operator?(tie)
      assert WorkspaceOperators.schema_change_line(tie) == @operator_step

      # An owner of the operator who is an admin of the organisation acts through the operator.
      assert ApiaryPro.Access.through_operator?(higher)
      assert WorkspaceOperators.schema_change_line(higher) == nil
    end

    test "is nil in a workspace with no operator, and once the link ends", ctx do
      ApiaryPro.Flags.put_operator_infrastructure(true)
      %{scope: other} = sign_up_fixture()
      assert WorkspaceOperators.schema_change_line(other) == nil
      assert Apiary.Edition.schema_change_line(other) == nil

      end_link!(ctx.owner.workspace.id)
      scope = scope_in(ctx.owner.user, ctx.organisation, ctx.owner.workspace)
      assert WorkspaceOperators.schema_change_line(scope) == nil
    end
  end
end
