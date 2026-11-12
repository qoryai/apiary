defmodule ApiaryPro.TransfersTest do
  # Joining an operator takes both sides: an organisation's owner offers it, an owner of the
  # operator accepts, and its owners stay its owners. Parting takes one: a client's owner
  # leaves, an operator's owner drops it, at once. The arbiter offers the ownership of an
  # organisation whose owners are all suspended to one of its admins. The arbiter's tests,
  # and the instance organisation's, are in `ApiaryPro.TransfersInstanceOrganisationTest`.
  use Apiary.DataCase, async: true

  # Offers to an operator and leaving one are shown here, for this process and those it
  # starts (`ApiaryPro.Flags.put_transfers/1`).
  setup do: ApiaryPro.Flags.put_transfers(true)

  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Access, Features}
  alias Apiary.Audit.Entry
  alias Apiary.Organisations.{Membership, Organisation}
  alias ApiaryPro.{Operators, Suspensions, Tenants, Transfers}
  alias ApiaryPro.Grants.Grant
  alias ApiaryPro.Transfers.Transfer
  alias ApiaryPro.Tenants.Tenant

  describe "a client parting from its operator" do
    @describetag needs: :managed_organisations

    setup do
      operator = operator_fixture()
      client = client_fixture(operator.scope)

      %{
        operator: operator,
        client: client,
        admin: client_member_fixture(client, :admin),
        member: client_member_fixture(client, :member),
        operator_admin: member_fixture(operator.scope, :admin),
        instance_admin: suite_instance_admin().instance_scope
      }
    end

    @tag :feature_sets
    test "its owner leaves at once: no operator, the operator's grants gone, its people as they were",
         ctx do
      id = ctx.client.organisation.id
      name = ctx.operator.organisation.name

      # The operator's name, typed to confirm, is checked: anything else leaves nothing.
      assert {:error, :confirmation} = Transfers.leave(ctx.client.owner.scope, "Not it")
      assert {:error, :confirmation} = Transfers.leave(ctx.client.owner.scope, nil)
      assert Repo.get!(Tenant, id).operator_id == ctx.operator.organisation.id
      entries = entries()

      assert {:ok, %Organisation{edition: %{tenant: %Tenant{operator_id: nil}}}} =
               Transfers.leave(ctx.client.owner.scope, " #{name} ")

      assert %Tenant{operator_id: nil, operator_since: nil} = tenant_of(id)
      organisation = Repo.get!(Organisation, id)

      # It has what an organisation with no operator has: the instance's.
      assert Repo.all(from g in Grant, where: g.organisation_id == ^id) == []
      assert ApiaryPro.Features.of(organisation) == Features.enabled()

      for membership <- [ctx.client.owner.membership, ctx.admin.membership] do
        assert Repo.get!(Membership, membership.id).level == membership.level
      end

      assert_parted(entries, ctx, "organisation.leave_operator", ctx.client.owner.user.id)

      # The operator's people read it no more; its owner acts there as before.
      assert scope_in(ctx.operator.user, ctx.client.organisation) == nil

      assert Access.authorize(ctx.client.scope, :"run.read", ctx.client.workspace) ==
               {:error, :forbidden}

      owner = scope_in(ctx.client.owner.user, organisation, ctx.client.workspace)
      assert Access.authorize(owner, :"organisation.delete", owner.organisation) == :ok
      assert {:error, :not_found} = Transfers.leave(owner, name)
    end

    test "only its owners leave, whatever its operator is, and while it is not suspended", ctx do
      for scope <- [ctx.admin.scope, ctx.member.scope, ctx.client.scope] do
        assert {:error, :forbidden} = Transfers.leave(scope, ctx.operator.organisation.name)
      end

      %{scope: plain} = sign_up_fixture()
      assert {:error, :not_found} = Transfers.leave(plain, ctx.operator.organisation.name)

      id = ctx.client.organisation.id
      {:ok, _} = Suspensions.suspend_organisation(ctx.instance_admin, id)

      assert {:error, :forbidden} =
               Transfers.leave(ctx.client.owner.scope, ctx.operator.organisation.name)

      {:ok, _} = Suspensions.activate_organisation(ctx.instance_admin, id)

      # Its operator suspended, it leaves all the same.
      {:ok, _} =
        Suspensions.suspend_organisation(ctx.instance_admin, ctx.operator.organisation.id)

      assert {:ok, %Organisation{edition: %{tenant: %Tenant{operator_id: nil}}}} =
               Transfers.leave(ctx.client.owner.scope, ctx.operator.organisation.name)
    end

    test "the operator's owner drops it at once, as when it leaves", ctx do
      id = ctx.client.organisation.id
      name = ctx.client.organisation.name

      # The client's name, typed to confirm, is checked: anything else drops nothing.
      assert {:error, :confirmation} = Transfers.drop(ctx.operator.scope, id, "Not it")
      assert Repo.get!(Tenant, id).operator_id == ctx.operator.organisation.id
      entries = entries()

      assert {:ok, %Organisation{id: ^id, edition: %{tenant: %Tenant{operator_id: nil}}}} =
               Transfers.drop(ctx.operator.scope, id, name)

      assert Repo.all(from g in Grant, where: g.organisation_id == ^id) == []
      assert Repo.get!(Membership, ctx.client.owner.membership.id).level == :owner
      assert_parted(entries, ctx, "client.drop", ctx.operator.user.id)
      assert scope_in(ctx.operator.user, ctx.client.organisation) == nil
      assert {:error, :not_found} = Transfers.drop(ctx.operator.scope, id, name)
    end

    test "only an owner of its operator drops it, and only a client of the operator in use",
         ctx do
      id = ctx.client.organisation.id
      name = ctx.client.organisation.name

      for scope <- [ctx.operator_admin.scope, member_fixture(ctx.operator.scope, :member).scope] do
        assert {:error, :forbidden} = Transfers.drop(scope, id, name)
      end

      assert {:error, :not_found} = Transfers.drop(operator_fixture().scope, id, name)
      assert {:error, :not_found} = Transfers.drop(ctx.operator.scope, "not-an-id", name)
      assert {:error, :not_found} = Transfers.drop(ctx.client.owner.scope, id, name)

      {:ok, _} =
        Apiary.Deletion.delete_organisation(ctx.client.owner.scope, ctx.client.organisation.slug)

      assert {:error, :not_found} = Transfers.drop(ctx.operator.scope, id, name)

      assert %Tenant{operator_id: operator_id} = tenant_of(id)
      assert operator_id == ctx.operator.organisation.id
    end
  end

  describe "an organisation to an operator" do
    @describetag needs: :managed_organisations

    setup do
      operator = operator_fixture()
      offered = sign_up_fixture()
      second_owner = member_fixture(offered.scope, :owner)

      %{
        operator: operator,
        offered: offered,
        second_owner: second_owner,
        operator_admin: member_fixture(operator.scope, :admin),
        operator_member: member_fixture(operator.scope, :member),
        instance_admin: suite_instance_admin().instance_scope
      }
    end

    test "its owner offers it; the operator's Clients page lists it", ctx do
      assert {:ok, %Transfer{kind: :to_operator, recipient_id: nil} = transfer} =
               Transfers.offer_to_operator(
                 ctx.offered.scope,
                 " #{ctx.operator.organisation.slug} "
               )

      assert transfer.operator_id == ctx.operator.organisation.id

      assert %Entry{action: "organisation.transfer", details: details} = last()
      assert details == %{"kind" => "to_operator", "operator_id" => ctx.operator.organisation.id}

      assert {:ok, [%{transfer: %Transfer{id: id}, organisation: %Organisation{} = listed}]} =
               Transfers.list_offers(ctx.operator.scope)

      assert id == transfer.id
      assert listed.id == ctx.offered.organisation.id
      assert {:ok, [_]} = Transfers.list_offers(ctx.operator_member.scope)
      assert {:error, :not_found} = Transfers.list_offers(ctx.offered.scope)

      assert {:error, :pending} =
               Transfers.offer_to_operator(ctx.offered.scope, ctx.operator.organisation.slug)
    end

    test "it is offered to an operator in use, by an owner, and never an operator's or a client's",
         ctx do
      slug = ctx.operator.organisation.slug
      %{scope: admin} = member_fixture(ctx.offered.scope, :admin)
      assert {:error, :forbidden} = Transfers.offer_to_operator(admin, slug)

      assert {:error, :no_operator} =
               Transfers.offer_to_operator(ctx.offered.scope, "no-such-operator")

      assert {:error, :no_operator} =
               Transfers.offer_to_operator(ctx.offered.scope, sign_up_fixture().organisation.slug)

      assert {:error, :no_operator} = Transfers.offer_to_operator(ctx.offered.scope, nil)

      # An operator is no client of another. A client leaves its operator first: it never
      # has managed_organisations, so there is no offer to make from it.
      other = operator_fixture()
      assert {:error, :operator} = Transfers.offer_to_operator(other.scope, slug)
      client = client_fixture(other.scope)
      assert {:error, :not_found} = Transfers.offer_to_operator(client.owner.scope, slug)
      assert Transfers.pending(client.owner.scope) == nil

      {:ok, _} =
        Suspensions.suspend_organisation(ctx.instance_admin, ctx.operator.organisation.id)

      assert {:error, :no_operator} = Transfers.offer_to_operator(ctx.offered.scope, slug)

      {:ok, _} =
        Suspensions.activate_organisation(ctx.instance_admin, ctx.operator.organisation.id)

      assert {:ok, _} = Transfers.offer_to_operator(ctx.offered.scope, slug)
    end

    test "an owner of the operator accepts: it is a client, and its owners stay its owners",
         ctx do
      {:ok, _} = Transfers.offer_to_operator(ctx.offered.scope, ctx.operator.organisation.slug)
      entries = entries()

      assert {:ok, %Organisation{} = client} =
               Transfers.accept_client(ctx.operator.scope, ctx.offered.organisation.id)

      assert Tenants.operator_id(client) == ctx.operator.organisation.id

      assert %Tenant{operator_since: %DateTime{}} = tenant_of(client)
      joined = Repo.get!(Organisation, client.id)

      assert Tenants.client?(joined)
      assert Transfers.pending(ctx.offered.scope) == nil

      for membership <- [ctx.offered.membership, ctx.second_owner.membership] do
        assert %Membership{level: :owner} = Repo.get!(Membership, membership.id)
      end

      assert [here, there] =
               Enum.sort_by(
                 entries() -- entries,
                 &(&1.organisation_id != ctx.operator.organisation.id)
               )

      assert %Entry{action: "client.accept"} = here
      assert here.organisation_id == ctx.operator.organisation.id
      assert here.details == %{"organisation_id" => client.id}

      assert %Entry{action: "client.accept"} = there
      assert there.organisation_id == client.id
      assert there.after == %{"operator_id" => ctx.operator.organisation.id}

      # The operator's owner reads it and changes nothing; its owners act as before.
      reader = scope_in(ctx.operator.user, client, ctx.offered.workspace)
      assert Access.reader(reader) == :operator

      assert Access.authorize(reader, :"organisation.delete", reader.organisation) ==
               {:error, :forbidden}

      owner = scope_in(ctx.offered.user, client, ctx.offered.workspace)
      assert Access.level(owner) == :owner
      assert Access.authorize(owner, :"organisation.delete", owner.organisation) == :ok
    end

    test "the operator's admins and members do not accept, nor an operator suspended or made an organisation",
         ctx do
      id = ctx.offered.organisation.id
      {:ok, _} = Transfers.offer_to_operator(ctx.offered.scope, ctx.operator.organisation.slug)

      assert {:error, :forbidden} = Transfers.accept_client(ctx.operator_admin.scope, id)
      assert {:error, :forbidden} = Transfers.accept_client(ctx.operator_member.scope, id)

      # Another operator finds no offer to it.
      assert {:error, :not_found} = Transfers.accept_client(operator_fixture().scope, id)

      {:ok, _} =
        Suspensions.suspend_organisation(ctx.instance_admin, ctx.operator.organisation.id)

      assert {:error, :forbidden} = Transfers.accept_client(ctx.operator.scope, id)

      {:ok, _} =
        Suspensions.activate_organisation(ctx.instance_admin, ctx.operator.organisation.id)

      {:ok, _} =
        Operators.change_kind(ctx.instance_admin, ctx.operator.organisation.id, :organisation)

      assert {:error, :not_found} = Transfers.accept_client(ctx.operator.scope, id)
      assert %Tenant{operator_id: nil} = tenant_of(id)
    end

    test "an operator suspended, or made an organisation, has the offers to it withdrawn",
         ctx do
      id = ctx.offered.organisation.id
      operator_id = ctx.operator.organisation.id
      slug = ctx.operator.organisation.slug

      {:ok, _} = Transfers.offer_to_operator(ctx.offered.scope, slug)
      {:ok, _} = Suspensions.suspend_organisation(ctx.instance_admin, operator_id)
      assert_withdrawn(id, "operator_suspended")

      {:ok, _} = Suspensions.activate_organisation(ctx.instance_admin, operator_id)
      {:ok, _} = Transfers.offer_to_operator(ctx.offered.scope, slug)
      {:ok, _} = Operators.change_kind(ctx.instance_admin, operator_id, :organisation)
      assert_withdrawn(id, "operator_made_organisation")

      # It may offer itself elsewhere at once.
      assert {:ok, %Transfer{}} =
               Transfers.offer_to_operator(
                 ctx.offered.scope,
                 operator_fixture().organisation.slug
               )
    end

    test "an offer withdrawn, or an organisation changed or suspended since, is not accepted",
         ctx do
      id = ctx.offered.organisation.id
      slug = ctx.operator.organisation.slug

      {:ok, _} = Transfers.offer_to_operator(ctx.offered.scope, slug)
      {:ok, _} = Transfers.withdraw(ctx.offered.scope)
      assert {:error, :not_found} = Transfers.accept_client(ctx.operator.scope, id)

      {:ok, _} = Transfers.offer_to_operator(ctx.offered.scope, slug)
      {:ok, _} = Suspensions.suspend_organisation(ctx.instance_admin, id)
      assert {:error, :suspended} = Transfers.accept_client(ctx.operator.scope, id)
      {:ok, _} = Suspensions.activate_organisation(ctx.instance_admin, id)

      {:ok, _} = Operators.change_kind(ctx.instance_admin, id, :operator)
      assert {:error, :changed} = Transfers.accept_client(ctx.operator.scope, id)
      assert %Tenant{kind: :operator, operator_id: nil} = tenant_of(id)
    end
  end

  describe "a row of another organisation" do
    @describetag needs: :managed_organisations

    test "an offer is reached from its own organisation only" do
      operator = operator_fixture()
      %{scope: offered} = sign_up_fixture()
      {:ok, transfer} = Transfers.offer_to_operator(offered, operator.organisation.slug)
      %{scope: other} = sign_up_fixture()

      assert Transfers.pending(other) == nil
      assert {:error, :not_found} = Transfers.withdraw(other)
      assert {:error, :not_found} = Transfers.accept(other)

      assert {:error, :not_found} =
               Access.authorize(other, :"organisation.withdraw_transfer", transfer)

      assert Access.authorize(offered, :"organisation.withdraw_transfer", transfer) == :ok

      # Another operator lists none of the organisations offered to this one.
      assert {:ok, []} = Transfers.list_offers(operator_fixture().scope)
      assert {:ok, [_]} = Transfers.list_offers(operator.scope)
    end
  end

  # No offer of the organisation is pending, and its trail's last withdrawal is the
  # instance's, with `reason`.
  defp assert_withdrawn(organisation_id, reason) do
    assert Repo.get_by(Transfer, organisation_id: organisation_id) == nil

    assert %Entry{details: %{"reason" => ^reason}} =
             Repo.one(
               from e in Entry,
                 where: e.organisation_id == ^organisation_id,
                 where: e.action == "organisation.withdraw_transfer",
                 order_by: [desc: e.inserted_at, desc: e.id],
                 limit: 1
             )
  end

  # A leaving or a drop, `action`, by `actor_id`: an entry in the client's trail and one in
  # the operator's, each naming the other.
  defp assert_parted(before, ctx, action, actor_id) do
    assert [here, there] =
             Enum.sort_by(
               entries() -- before,
               &(&1.organisation_id != ctx.client.organisation.id)
             )

    assert %Entry{action: ^action, subject_kind: "organisation"} = here
    assert here.organisation_id == ctx.client.organisation.id
    assert here.before == %{"operator_id" => ctx.operator.organisation.id}
    assert here.after == %{"operator_id" => nil}
    assert {here.actor_kind, here.actor_id} == {:person, actor_id}

    assert %Entry{action: ^action} = there
    assert there.organisation_id == ctx.operator.organisation.id
    assert there.details == %{"organisation_id" => ctx.client.organisation.id}
  end

  defp entries, do: Repo.all(from e in Entry, order_by: [asc: e.inserted_at, asc: e.id])
  defp last, do: Repo.one(from e in Entry, order_by: [desc: e.inserted_at, desc: e.id], limit: 1)
end
