defmodule ApiaryPro.ReachTest do
  # The scopes the edition builds for a person beside the core's resolution: none that carries a
  # role goes out without `hidden`, which the core reads as nothing hidden where it is nil
  # (`Apiary.Features.visible?/2`).
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Access, Features, Organisations, Repo}
  alias Apiary.Organisations.Membership
  alias ApiaryPro.{ClientReach, Flags, Reach}

  @moduletag with_features: Features.all()

  setup do
    operator = operator_fixture()
    client = client_fixture(operator.scope, "Acme")
    %{operator: operator, client: client}
  end

  test "a scope moved into a client from its operator's pages carries no role", ctx do
    moved = Reach.in_client(ctx.operator.scope, ctx.client.organisation)
    assert moved.hidden == nil
    assert Access.role(moved) == nil

    in_workspace = %{moved | workspace: ctx.client.workspace}

    for {action, on} <- [
          {:"secret.read", ctx.client.workspace},
          {:"variable.read", ctx.client.workspace},
          {:"connection.read", ctx.client.organisation},
          {:"run.read", ctx.client.workspace}
        ] do
      assert Access.check(in_workspace, action, on) == {:error, :forbidden}, "#{action}"
    end
  end

  describe "whether an entry's person acted through the operator" do
    test "is a yes or no from the levels, never a scope with the operator's reach", ctx do
      client = ctx.client.organisation
      Flags.put_operator_infrastructure(true)

      assert Reach.acted_through_operator?(Reach.in_client(ctx.operator.scope, client))
      refute Reach.acted_through_operator?(Reach.in_client(ctx.client.owner.scope, client))
      refute Reach.acted_through_operator?(ctx.client.scope)
      refute Reach.acted_through_operator?(ctx.operator.scope)
    end

    test "answers as the scope of the same person in the client does", ctx do
      client = ctx.client.organisation

      for {in_operator, in_client, through?} <- [
            {:admin, :member, true},
            {:admin, :admin, false},
            {:member, :admin, false},
            {:owner, :admin, true},
            {:owner, :owner, false}
          ] do
        user = in_both(ctx, in_operator, in_client)
        from_operator = Reach.in_client(scope_in(user, ctx.operator.organisation), client)
        said = "#{in_operator} in the operator, #{in_client} in the client"

        assert Reach.acted_through_operator?(from_operator) == through?, said

        assert ApiaryPro.Access.through_operator?(scope_in(user, client)) == through?, said
      end
    end

    test "a suspended membership in the client counts as none", ctx do
      client = ctx.client.organisation
      user = in_both(ctx, :admin, :admin)
      joined = Repo.get_by!(Membership, organisation_id: client.id, user_id: user.id)
      {:ok, _} = Organisations.suspend_member(ctx.client.owner.scope, joined.id)

      assert Reach.acted_through_operator?(
               Reach.in_client(scope_in(user, ctx.operator.organisation), client)
             )
    end
  end

  # A person at `in_operator` in the operator and at `in_client` in its client.
  defp in_both(ctx, in_operator, in_client) do
    %{user: user} = member_fixture(ctx.operator.scope, in_operator)
    %{membership: joined} = join_fixture(ctx.client.owner.scope, user)

    if in_client != :member,
      do: {:ok, _} = Organisations.set_member_level(ctx.client.owner.scope, joined.id, in_client)

    user
  end

  test "the switcher's places give no scope", ctx do
    place = %ClientReach{
      organisation: ctx.client.organisation,
      organisation_id: ctx.client.organisation.id,
      operator_membership: %{ctx.operator.scope.membership | user_id: ctx.operator.user.id}
    }

    assert ApiaryProWeb.Edition.place_scope(place, ctx.client.workspace) == nil

    %Membership{} = membership = ctx.client.owner.scope.membership
    assert ApiaryProWeb.Edition.place_scope(membership, ctx.client.workspace) == nil
  end
end
