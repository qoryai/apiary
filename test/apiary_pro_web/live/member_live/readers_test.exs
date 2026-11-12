defmodule ApiaryProWeb.MemberLive.ReadersTest do
  # The People page lists the members for whoever reads the organisation without changing
  # it: `member.read` is among `ApiaryPro.Access.reads/0`. Not async: an operator and a
  # suspension are made by an instance admin, an owner of the suite's one instance
  # organisation, and operators need the node's features.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Features, Repo}
  alias Apiary.Organisations.Membership
  alias ApiaryPro.Suspensions

  @moduletag with_features: Features.all()

  defp people(user, organisation) do
    {:ok, lv, _html} =
      live(log_in_user(build_conn(), user), "/#{organisation.slug}/settings/people")

    lv
  end

  defp assert_members_listed(lv, memberships) do
    for %{id: id} <- memberships, do: assert(has_element?(lv, "#member-#{id}"))
    refute has_element?(lv, "#people-none")
  end

  defp membership(user, organisation),
    do: Repo.get_by!(Membership, user_id: user.id, organisation_id: organisation.id)

  describe "a client's People page" do
    setup do
      admin = instance_admin_fixture()
      operator = operator_fixture()
      client = client_fixture(operator.scope, "Acme")
      member = client_member_fixture(client, :member)

      %{
        instance_admin: admin.user,
        operator: operator,
        client: client,
        memberships: [member.membership, membership(client.owner.user, client.organisation)]
      }
    end

    test "lists the members for an instance admin, who reads it as a reader", ctx do
      scope = scope_in(ctx.instance_admin, ctx.client.organisation)
      assert Apiary.Access.reach(scope) == :instance
      assert Apiary.Access.level(scope) == nil

      ctx.instance_admin
      |> people(ctx.client.organisation)
      |> assert_members_listed(ctx.memberships)
    end

    test "lists the members for a member of the operator", ctx do
      operator_member = member_fixture(ctx.operator.scope, :member)

      operator_member.user
      |> people(ctx.client.organisation)
      |> assert_members_listed(ctx.memberships)
    end
  end

  describe "a suspended organisation's People page" do
    setup do
      home = sign_up_fixture()
      member = member_fixture(home.scope, :member)
      instance = instance_admin_fixture().instance_scope
      {:ok, _} = Suspensions.suspend_organisation(instance, home.organisation.id)

      %{
        home: home,
        member: member,
        memberships: [member.membership, membership(home.user, home.organisation)]
      }
    end

    test "lists the members for its owner", ctx do
      ctx.home.user
      |> people(ctx.home.organisation)
      |> assert_members_listed(ctx.memberships)
    end

    test "lists the members for its member", ctx do
      ctx.member.user
      |> people(ctx.home.organisation)
      |> assert_members_listed(ctx.memberships)
    end
  end
end
