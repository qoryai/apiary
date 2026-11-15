defmodule ApiaryPro.NodesPartTest do
  # The nodes, a part of no feature (`Apiary.Features.parts/0`, `:nodes`): the edition
  # offers them on no Features page, no grant names them, and no row hides them
  # (`ApiaryPro.Features.hidden/1`), for an operator, an organisation whose workspace an
  # operator operates, any other organisation or the instance organisation, whatever the
  # switches (`ApiaryPro.Flags`).
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures
  import Ecto.Query

  alias Apiary.{Access, Features, Repo}
  alias ApiaryPro.{Flags, Grants}
  alias ApiaryPro.Grants.Grant

  @moduletag with_features: Features.all()

  # An operator, an organisation whose workspace Main it operates, with an admin and a
  # member, and an organisation with no operator, all made with the operator's flag off;
  # then both switches on.
  setup do
    Flags.put_operator_infrastructure(false)
    Flags.put_feature_visibility(true)
    %{instance_scope: admin, user: admin_user} = suite_instance_admin()
    operator = operator_fixture()
    operated = client_fixture(operator.scope, "Acme")

    ctx = %{
      admin: admin,
      admin_user: admin_user,
      operator: operator,
      operated: operated,
      operated_admin: client_member_fixture(operated, :admin),
      operated_member: client_member_fixture(operated, :member),
      lone: sign_up_fixture()
    }

    Flags.put_operator_infrastructure(true)
    ctx
  end

  defp fresh(user, organisation, workspace \\ nil), do: scope_in(user, organisation, workspace)

  # The people of the operated organisation, each scope as their page's path loads it.
  defp operated_people(ctx) do
    for person <- [ctx.operated.owner, ctx.operated_admin, ctx.operated_member],
        do: fresh(person.user, ctx.operated.organisation, ctx.operated.workspace)
  end

  defp rows(organisation_id) do
    Repo.all(
      from g in Grant,
        where: g.organisation_id == ^organisation_id,
        order_by: g.feature,
        select: {g.feature, g.granted}
    )
  end

  test "no Features page offers them", ctx do
    for organisation <- [
          ctx.operator.organisation,
          ctx.operated.organisation,
          ctx.lone.organisation
        ] do
      refute :nodes in Grants.shown(organisation)
      refute :nodes in Grants.parts_kept(organisation)
    end
  end

  test "the instance's form never names them", ctx do
    for organisation <- [
          ctx.operator.organisation,
          ctx.operated.organisation,
          ctx.lone.organisation
        ] do
      names = Enum.map(Grants.shown(organisation), &Atom.to_string/1)

      assert {:error, :above} =
               Grants.set_organisation(ctx.admin, organisation.id, names ++ ["nodes"])

      refute {:nodes, false} in rows(organisation.id)
    end
  end

  test "a row of the nodes hides nothing, from anyone", ctx do
    for organisation <- [
          ctx.operator.organisation,
          ctx.operated.organisation,
          ctx.lone.organisation,
          instance_organisation()
        ] do
      Repo.insert!(%Grant{organisation_id: organisation.id, feature: :nodes, granted: false})
    end

    for scope <- [
          fresh(ctx.operator.user, ctx.operator.organisation),
          fresh(ctx.lone.user, ctx.lone.organisation, ctx.lone.workspace),
          fresh(ctx.admin_user, instance_organisation()),
          fresh(ctx.operator.user, ctx.operated.organisation, ctx.operated.workspace)
          | operated_people(ctx)
        ] do
      refute :nodes in scope.hidden
      refute :nodes in ApiaryPro.Features.hidden(scope)
    end

    for scope <- operated_people(ctx),
        do: assert(:ok = Access.authorize(scope, :"node.read", scope.workspace))
  end
end
