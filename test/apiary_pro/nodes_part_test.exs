defmodule ApiaryPro.NodesPartTest do
  # The nodes, a part of no feature (`Apiary.Features.parts/0`, `:nodes`), which an
  # operator hides from a client's people (`ApiaryPro.Features.hidden/1`) through the
  # client's grant (`ApiaryPro.Grants`): only while the operator owns its clients
  # (`ApiaryPro.Flags.operator_infrastructure?/0`) and features are shown by who asks
  # (`ApiaryPro.Flags.feature_visibility?/0`), and never from the operator's people, an
  # operator's, an organisation's with no operator, the instance organisation's, or an
  # instance admin who reaches a client through the instance. With either switch off no
  # row hides them and no grant names them.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures
  import Ecto.Query

  alias Apiary.{Access, Features, Organisations, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Audit.Entry
  alias ApiaryPro.{Flags, Grants}
  alias ApiaryPro.Grants.Grant
  alias ApiaryProWeb.ActivityDescriber

  @moduletag with_features: Features.all()

  # An operator and its client, whose owner, admin and member are the client's people, all
  # made while the operator did not own its clients; an admin of the operator; then both
  # switches on.
  setup do
    Flags.put_operator_infrastructure(false)
    Flags.put_feature_visibility(true)
    %{instance_scope: admin, user: admin_user} = suite_instance_admin()
    operator = operator_fixture()
    client = client_fixture(operator.scope, "Acme")

    ctx = %{
      admin: admin,
      admin_user: admin_user,
      operator: operator,
      operator_admin: member_fixture(operator.scope, :admin),
      client: client,
      client_admin: client_member_fixture(client, :admin),
      client_member: client_member_fixture(client, :member)
    }

    Flags.put_operator_infrastructure(true)
    ctx
  end

  defp fresh(user, organisation, workspace \\ nil), do: scope_in(user, organisation, workspace)

  # The client's people, each scope as their page's path loads it.
  defp client_people(ctx) do
    for person <- [ctx.client.owner, ctx.client_admin, ctx.client_member],
        do: fresh(person.user, ctx.client.organisation, ctx.client.workspace)
  end

  defp nodes?(scope), do: Access.authorize(scope, :"node.read", scope.workspace)

  # What the client's Features page sends: what it has checked now, but the nodes where
  # `shown?` is false, and with them where it is true.
  defp set_nodes(ctx, shown?) do
    client = Repo.reload!(ctx.client.organisation)
    shown = Grants.shown(client)
    has = Enum.filter(ApiaryPro.Features.of(client) ++ Grants.parts_kept(client), &(&1 in shown))
    names = if shown?, do: Enum.uniq(has ++ [:nodes]), else: has -- [:nodes]
    Grants.set_client(ctx.operator.scope, client.id, Enum.map(names, &Atom.to_string/1))
  end

  defp rows(organisation_id) do
    Repo.all(
      from g in Grant,
        where: g.organisation_id == ^organisation_id,
        order_by: g.feature,
        select: {g.feature, g.granted}
    )
  end

  describe "with both switches on" do
    test "a client's page offers the nodes, checked, and no other page does", ctx do
      client = ctx.client.organisation
      assert :nodes in Grants.shown(client)
      assert :nodes in Grants.parts_kept(client)
      assert List.last(Grants.shown(client)) == :nodes

      for organisation <- [ctx.operator.organisation, sign_up_fixture().organisation] do
        refute :nodes in Grants.shown(organisation)
        refute :nodes in Grants.parts_kept(organisation)
      end
    end

    test "the client's grant hides them from its owner, admin and member", ctx do
      for scope <- client_people(ctx) do
        refute :nodes in scope.hidden
        assert :ok = nodes?(scope)
      end

      assert {:ok, _} = set_nodes(ctx, false)
      assert {:nodes, false} in rows(ctx.client.organisation.id)
      refute :nodes in Grants.parts_kept(ctx.client.organisation)

      for scope <- client_people(ctx) do
        assert :nodes in scope.hidden
        refute Features.visible?(scope, :nodes)
        assert {:error, :not_found} = nodes?(scope)
        assert :ok = Access.authorize(scope, :"run.read", scope.workspace)
      end
    end

    test "the operator's people see them in the client, through the operator and from a lower membership there",
         ctx do
      assert {:ok, _} = set_nodes(ctx, false)

      for person <- [ctx.operator, ctx.operator_admin] do
        scope = fresh(person.user, ctx.client.organisation, ctx.client.workspace)
        assert {:operator, _via} = scope.reach
        refute :nodes in scope.hidden
        assert :ok = nodes?(scope)
      end

      # An admin of the operator who is a member of the client too.
      _joined = join_fixture(ctx.client.owner.scope, ctx.operator_admin.user)
      scope = fresh(ctx.operator_admin.user, ctx.client.organisation, ctx.client.workspace)
      assert %{level: :member} = scope.membership
      assert {:operator, %{level: :admin}} = scope.reach
      refute :nodes in scope.hidden
      assert :ok = nodes?(scope)

      # In the operator itself nothing hides them.
      refute :nodes in fresh(ctx.operator.user, ctx.operator.organisation).hidden
    end

    test "an instance admin who reaches the client through the instance is hidden nothing",
         ctx do
      assert {:ok, _} = set_nodes(ctx, false)
      scope = fresh(ctx.admin_user, ctx.client.organisation, ctx.client.workspace)
      assert scope.reach == :instance
      assert scope.hidden == []
    end

    test "the instance's form never names them, for an operator or an organisation with no operator",
         ctx do
      %{organisation: lone} = sign_up_fixture()

      for organisation <- [ctx.operator.organisation, lone] do
        names = Enum.map(Grants.shown(organisation), &Atom.to_string/1)

        assert {:error, :above} =
                 Grants.set_organisation(ctx.admin, organisation.id, names ++ ["nodes"])

        refute {:nodes, false} in rows(organisation.id)
      end
    end

    test "an operator's row, or one of an organisation with no operator, hides nothing", ctx do
      %{user: lone_user, organisation: lone, workspace: lone_workspace} = sign_up_fixture()

      for organisation <- [ctx.operator.organisation, lone, instance_organisation()] do
        Repo.insert!(%Grant{organisation_id: organisation.id, feature: :nodes, granted: false})
      end

      for scope <- [
            fresh(ctx.operator.user, ctx.operator.organisation),
            fresh(lone_user, lone, lone_workspace),
            fresh(ctx.admin_user, instance_organisation()),
            fresh(ctx.operator.user, ctx.client.organisation, ctx.client.workspace)
            | client_people(ctx)
          ] do
        refute :nodes in scope.hidden
      end

      # Still offered for the client: an operator is never hidden them.
      assert :nodes in Grants.shown(ctx.client.organisation)
    end

    test "a change of the nodes alone is recorded, marked shown, and tells both sides", ctx do
      for user <- [ctx.operator.user, ctx.client.owner.user, ctx.client_member.user],
          do: Phoenix.PubSub.subscribe(Apiary.PubSub, Organisations.membership_topic(user.id))

      # The same set again changes nothing and tells no one.
      assert {:ok, _} = set_nodes(ctx, true)
      refute_received {:membership_changed, _}

      assert {:ok, _} = set_nodes(ctx, false)

      client_id = ctx.client.organisation.id
      operator_id = ctx.operator.organisation.id
      assert_received {:membership_changed, %{organisation_id: ^client_id}}
      assert_received {:membership_changed, %{organisation_id: ^client_id}}
      assert_received {:membership_changed, %{organisation_id: ^operator_id}}

      assert [entry] = entries(client_id)
      assert List.last(entry.before["features"]) == "nodes"
      assert entry.after["features"] == entry.before["features"] -- ["nodes"]
      assert entry.details["shown"] == true

      # The Activity page names the nodes by the name their box has, after the features.
      said =
        :"client.grant_features"
        |> ActivityDescriber.change(entry.before, entry.after, %{})
        |> ApiaryWeb.RichText.plain_text(%{})

      assert said =~ ~r/^Runs, Terminal tab, .*, Machines and access keys → Runs, Terminal tab, /
      refute said =~ ~r/→ .*Machines and access keys/
    end

    test "ticked again, they are shown again and both sides are told", ctx do
      assert {:ok, _} = set_nodes(ctx, false)
      assert {:error, :not_found} = nodes?(hd(client_people(ctx)))

      for user <- [ctx.operator.user, ctx.client.owner.user],
          do: Phoenix.PubSub.subscribe(Apiary.PubSub, Organisations.membership_topic(user.id))

      assert {:ok, _} = set_nodes(ctx, true)

      client_id = ctx.client.organisation.id
      operator_id = ctx.operator.organisation.id
      assert_received {:membership_changed, %{organisation_id: ^client_id}}
      assert_received {:membership_changed, %{organisation_id: ^operator_id}}

      refute {:nodes, false} in rows(client_id)
      assert :nodes in Grants.parts_kept(ctx.client.organisation)

      for scope <- client_people(ctx) do
        refute :nodes in scope.hidden
        assert :ok = nodes?(scope)
      end

      # The test's transaction gives its entries one time: the one that shows them again.
      assert Enum.any?(
               entries(client_id),
               &("nodes" not in &1.before["features"] and "nodes" in &1.after["features"])
             )
    end

    test "the nodes are shown whatever features the client is shown", ctx do
      assert {:ok, _} =
               Grants.set_client(ctx.operator.scope, ctx.client.organisation.id, ["nodes"])

      scope = fresh(ctx.client.owner.user, ctx.client.organisation, ctx.client.workspace)
      assert :observability in scope.hidden
      refute :nodes in scope.hidden
      assert :ok = nodes?(scope)

      assert {:ok, _} = Grants.set_client(ctx.operator.scope, ctx.client.organisation.id, [])
      assert :nodes in fresh(ctx.client.owner.user, ctx.client.organisation).hidden
    end
  end

  describe "by place, where the scope carries no reach" do
    setup ctx do
      _joined = join_fixture(ctx.client.owner.scope, ctx.operator_admin.user)
      assert {:ok, _} = set_nodes(ctx, false)
      :ok
    end

    # The person's scope in the client as the core's `load_scope/2` and
    # `load_home_scope/2` put it, with their membership there and no reach.
    defp by_place(user, ctx) do
      for scope <- [
            Organisations.load_scope(Scope.for_user(user), ctx.client.organisation.id),
            Organisations.load_home_scope(Scope.for_user(user), ctx.client.workspace.id)
          ] do
        assert scope.organisation.id == ctx.client.organisation.id
        assert scope.reach == nil
        scope
      end
    end

    test "an admin of the operator who is a member of the client is not hidden the nodes",
         ctx do
      for scope <- by_place(ctx.operator_admin.user, ctx),
          do: refute(:nodes in scope.hidden)

      # The run's Terminal and the features stay hidden there by place, more and never
      # less.
      assert {:ok, _} =
               Grants.set_client(ctx.operator.scope, ctx.client.organisation.id, [
                 "observability"
               ])

      for scope <- by_place(ctx.operator_admin.user, ctx) do
        refute :nodes in scope.hidden
        assert :"observability.terminal" in scope.hidden
        assert :security in scope.hidden
      end
    end

    test "the client's admin and member, with no membership in the operator, are", ctx do
      for person <- [ctx.client_admin, ctx.client_member],
          scope <- by_place(person.user, ctx),
          do: assert(:nodes in scope.hidden)
    end

    test "a suspended membership in the operator does not count", ctx do
      assert {:ok, _} =
               Organisations.suspend_member(
                 ctx.operator.scope,
                 ctx.operator_admin.membership.id
               )

      for scope <- by_place(ctx.operator_admin.user, ctx),
          do: assert(:nodes in scope.hidden)
    end
  end

  describe "a client's rows of the nodes" do
    setup ctx do
      assert {:ok, _} = set_nodes(ctx, false)
      assert {:nodes, false} in rows(ctx.client.organisation.id)
      :ok
    end

    test "are deleted when its operator drops it", ctx do
      # A drop is not found while the operator owns its clients.
      Flags.put_operator_infrastructure(false)

      assert {:ok, _} =
               ApiaryPro.Transfers.drop(ctx.operator.scope, ctx.client.organisation.id, "Acme")

      assert rows(ctx.client.organisation.id) == []
    end

    test "are deleted when it leaves its operator", ctx do
      Flags.put_transfers(true)
      owner = fresh(ctx.client.owner.user, ctx.client.organisation)

      assert {:ok, _} = ApiaryPro.Transfers.leave(owner, ctx.operator.organisation.name)
      assert rows(ctx.client.organisation.id) == []
    end

    test "are deleted when it becomes a new client", ctx do
      client = Repo.reload!(ctx.client.organisation)
      assert {:ok, _} = Grants.written_out(client, {:client, ctx.operator.organisation})
      refute {:nodes, false} in rows(client.id)
    end

    test "are kept on a change of kind, as the parts of a feature are", ctx do
      client = Repo.reload!(ctx.client.organisation)
      assert {:ok, _} = Grants.written_out(client, :operator, features: [:observability])
      assert {:nodes, false} in rows(client.id)
    end
  end

  describe "with a switch off" do
    for {flag, put} <- [
          operator_infrastructure: :put_operator_infrastructure,
          feature_visibility: :put_feature_visibility
        ] do
      @put put

      test "#{flag} off: nothing hides them, no page offers them and a save keeps the row",
           ctx do
        assert {:ok, _} = set_nodes(ctx, false)
        apply(Flags, @put, [false])

        for scope <- client_people(ctx) do
          refute :nodes in scope.hidden
          assert :ok = nodes?(scope)
        end

        refute :nodes in Grants.shown(ctx.client.organisation)
        refute :nodes in Grants.parts_kept(ctx.client.organisation)

        assert {:error, :above} =
                 Grants.set_client(ctx.operator.scope, ctx.client.organisation.id, [
                   "observability",
                   "nodes"
                 ])

        client = Repo.reload!(ctx.client.organisation)
        has = Enum.filter(ApiaryPro.Features.of(client), &(&1 in Grants.shown(client)))

        assert {:ok, _} =
                 Grants.set_client(
                   ctx.operator.scope,
                   client.id,
                   Enum.map(has, &Atom.to_string/1)
                 )

        assert {:nodes, false} in rows(client.id)
      end
    end
  end

  # The client's entries of its grants, in the order they were written.
  defp entries(client_id) do
    Repo.all(
      from e in Entry,
        where: e.organisation_id == ^client_id and e.action == "client.grant_features",
        order_by: [e.inserted_at, e.id]
    )
  end
end
