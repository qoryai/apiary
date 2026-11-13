defmodule ApiaryPro.TransfersInstanceOrganisationTest do
  # The tests of transfers that lock the suite's instance organisation, committed once
  # outside the sandbox: the arbiter's, whose account suspensions lock its owners, and the
  # refused withdrawal of its ownership, which locks its row. Not async
  # (docs/conventions.md, Tests); the other tests of transfers are in
  # `ApiaryPro.TransfersTest`.
  use Apiary.DataCase, async: false

  # The edition's switch `feature_visibility` is an opt-in feature, on with every feature:
  # these tests read it off, and a test that needs it turns it on (`ApiaryPro.Flags`).
  setup do
    ApiaryPro.Flags.put_feature_visibility(false)
  end

  # Offers to an operator and leaving one are shown here, for this process and those it
  # starts (`ApiaryPro.Flags.put_transfers/1`).
  setup do: ApiaryPro.Flags.put_transfers(true)

  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.Access
  alias Apiary.Audit.Entry
  alias Apiary.Organisations.{Membership, Organisation}
  alias ApiaryPro.{Suspensions, Transfers}
  alias ApiaryPro.Transfers.Transfer
  alias ApiaryPro.Tenants.Tenant

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
        instance_admin: instance_admin_fixture().instance_scope
      }
    end

    test "nobody offers or withdraws the instance organisation's ownership", ctx do
      io = ApiaryPro.Organisations.instance_organisation()
      assert Access.refused_on?(:"organisation.withdraw_transfer", io)
      assert Access.refused_on?(:"organisation.transfer", io)
      assert {:error, :forbidden} = Transfers.withdraw(%{ctx.instance_admin | organisation: io})
    end
  end

  describe "the arbiter" do
    setup do
      %{instance_admin: instance_admin_fixture().instance_scope}
    end

    @tag needs: :managed_organisations
    test "offers a client whose owners are all suspended to one of its admins; it stays its operator's",
         ctx do
      operator = operator_fixture()
      client = client_fixture(operator.scope)
      chosen = client_member_fixture(client, :admin)

      # Its owner may act: the instance does not overrule them.
      assert {:error, :has_owner} =
               Transfers.arbitrate(
                 ctx.instance_admin,
                 client.organisation.id,
                 chosen.membership.id,
                 "Stuck."
               )

      {:ok, _} = Suspensions.suspend_account(ctx.instance_admin, client.owner.user.id)
      assert ApiaryPro.Suspensions.owner_suspended?(client.organisation)

      assert {:ok, [_]} =
               Transfers.arbitration_candidates(ctx.instance_admin, client.organisation.id)

      assert {:ok, %Transfer{arbitrated: true, reason: "The owner is away."} = transfer} =
               Transfers.arbitrate(
                 ctx.instance_admin,
                 client.organisation.id,
                 chosen.membership.id,
                 "  The owner is away.  "
               )

      assert transfer.recipient_id == chosen.user.id
      # It names no operator but in its entry.
      assert transfer.operator_id == nil

      assert %Entry{action: "instance.transfer", subject_kind: "transfer"} = entry = last()
      assert entry.organisation_id == client.organisation.id
      assert entry.details["operator_id"] == operator.organisation.id
      assert {entry.actor_kind, entry.actor_id} == {:person, ctx.instance_admin.user.id}
      assert entry.details["reason"] == "The owner is away."

      # Nobody withdraws it here; accepted whatever its operator is.
      assert {:error, :forbidden} = Transfers.withdraw(chosen.scope)
      {:ok, _} = Suspensions.suspend_organisation(ctx.instance_admin, operator.organisation.id)

      assert {:ok, %Organisation{edition: %{tenant: %Tenant{operator_id: operator_id}}}} =
               Transfers.accept(chosen.scope)

      assert operator_id == operator.organisation.id
      assert %Membership{level: :owner} = Repo.get!(Membership, chosen.membership.id)

      assert %Entry{action: "organisation.accept_transfer", details: %{"arbitrated" => true}} =
               Repo.one!(
                 from e in Entry,
                   where:
                     e.organisation_id == ^client.organisation.id and
                       e.action == "organisation.accept_transfer"
               )
    end

    @tag needs: :managed_organisations
    test "offers a former client's ownership, and the offer outlives the purge of the operator it left",
         ctx do
      operator = operator_fixture()
      client = client_fixture(operator.scope)
      admin = client_member_fixture(client, :admin)
      name = client.organisation.name
      {:ok, _} = Transfers.drop(operator.scope, client.organisation.id, name)
      {:ok, _} = Suspensions.suspend_account(ctx.instance_admin, client.owner.user.id)

      {:ok, transfer} =
        Transfers.arbitrate(
          ctx.instance_admin,
          client.organisation.id,
          admin.membership.id,
          "The owner is away."
        )

      assert {:ok, :purged} =
               ApiaryPro.Deletion.purge_on_request(
                 ctx.instance_admin,
                 operator.organisation.id,
                 operator.organisation.slug
               )

      assert %Transfer{id: id} = Repo.get(Transfer, transfer.id)
      assert id == transfer.id
      assert {:ok, %Organisation{}} = Transfers.accept(admin.scope)
      assert Repo.get!(Membership, admin.membership.id).level == :owner
    end

    test "does not overrule an organisation with an owner who may act, and never the instance organisation",
         ctx do
      %{scope: owner, organisation: organisation} = sign_up_fixture()
      %{membership: admin, scope: admin_scope} = member_fixture(owner, :admin)

      assert {:error, :has_owner} =
               Transfers.arbitrate(ctx.instance_admin, organisation.id, admin.id, "Stuck.")

      %{membership: instance_member} = member_fixture(ctx.instance_admin, :admin)

      assert {:error, :forbidden} =
               Transfers.arbitrate(
                 ctx.instance_admin,
                 instance_organisation().id,
                 instance_member.id,
                 "No."
               )

      # Only an instance admin, on Instance settings › Organisations.
      assert {:error, :not_found} =
               Transfers.arbitrate(owner, organisation.id, admin.id, "Stuck.")

      # Its only owner's account suspended, it has none who may act: the arbiter's.
      {:ok, _} = Suspensions.suspend_account(ctx.instance_admin, owner.user.id)
      assert ApiaryPro.Suspensions.owner_suspended?(organisation)

      assert {:error, :reason} =
               Transfers.arbitrate(ctx.instance_admin, organisation.id, admin.id, "   ")

      assert {:error, :reason} =
               Transfers.arbitrate(
                 ctx.instance_admin,
                 organisation.id,
                 admin.id,
                 String.duplicate("a", 501)
               )

      assert {:error, :not_admin} =
               Transfers.arbitrate(
                 ctx.instance_admin,
                 organisation.id,
                 owner.membership.id,
                 "Stuck."
               )

      assert {:ok, %Transfer{arbitrated: true}} =
               Transfers.arbitrate(ctx.instance_admin, organisation.id, admin.id, "Stuck.")

      assert {:ok, %Organisation{}} = Transfers.accept(admin_scope)
      assert %Membership{level: :owner} = Repo.get!(Membership, admin.id)
      refute ApiaryPro.Suspensions.owner_suspended?(organisation)
    end

    test "accepting: not found for anyone else, forbidden for the recipient out of use", ctx do
      %{scope: owner, organisation: organisation} = sign_up_fixture()
      recipient = member_fixture(owner, :admin)
      other = member_fixture(owner, :admin)
      suspended = member_fixture(owner, :admin)
      member = member_fixture(owner, :member)
      {:ok, _} = Suspensions.suspend_account(ctx.instance_admin, owner.user.id)

      suspended.membership
      |> Ecto.Changeset.change(suspended_at: DateTime.utc_now())
      |> Repo.update!()

      {:ok, _} =
        Transfers.arbitrate(
          ctx.instance_admin,
          organisation.id,
          recipient.membership.id,
          "The owner is away."
        )

      for scope <- [other.scope, suspended.scope, member.scope] do
        assert Transfers.accept(scope) == {:error, :not_found}
      end

      # The scope keeps the old level: `accept/1` checks the membership it locked.
      made_member =
        recipient.membership |> Ecto.Changeset.change(level: :member) |> Repo.update!()

      assert Transfers.accept(recipient.scope) == {:error, :forbidden}

      made_member |> Ecto.Changeset.change(level: :admin) |> Repo.update!()
      {:ok, _} = Suspensions.suspend_account(ctx.instance_admin, recipient.user.id)

      assert Transfers.accept(recipient.scope) == {:error, :forbidden}
      assert %Transfer{} = Repo.get_by(Transfer, organisation_id: organisation.id)
    end

    test "accept/1 takes no row lock for a person it is not offered to, or with no offer",
         ctx do
      %{scope: owner, organisation: organisation, user: owner_user} = sign_up_fixture()
      recipient = member_fixture(owner, :admin)
      other = member_fixture(owner, :admin)
      {:ok, _} = Suspensions.suspend_account(ctx.instance_admin, owner_user.id)

      {:ok, _} =
        Transfers.arbitrate(
          ctx.instance_admin,
          organisation.id,
          recipient.membership.id,
          "The owner is away."
        )

      %{scope: with_no_offer} = sign_up_fixture()

      assert row_locks(fn -> Transfers.accept(other.scope) end) == {{:error, :not_found}, 0}
      assert row_locks(fn -> Transfers.accept(with_no_offer) end) == {{:error, :not_found}, 0}

      # The recipient's acceptance takes them, so the count does see a row lock.
      assert {{:ok, %Organisation{}}, locks} =
               row_locks(fn -> Transfers.accept(recipient.scope) end)

      assert locks > 0
    end

    test "does not offer a suspended organisation", ctx do
      %{scope: owner, organisation: organisation} = sign_up_fixture()
      %{membership: admin} = member_fixture(owner, :admin)
      {:ok, _} = Suspensions.suspend_account(ctx.instance_admin, owner.user.id)
      {:ok, _} = Suspensions.suspend_organisation(ctx.instance_admin, organisation.id)

      assert {:error, :suspended} =
               Transfers.arbitrate(ctx.instance_admin, organisation.id, admin.id, "Stuck.")
    end
  end

  # What `fun` returns, and how many statements with a row lock it ran, counted through the
  # repo's query telemetry. A handler runs in the process that runs the query.
  defp row_locks(fun) do
    handler = "row-locks-#{System.unique_integer()}"
    Process.put(:row_locks, 0)
    :telemetry.attach(handler, [:apiary, :repo, :query], &__MODULE__.count_row_lock/4, nil)

    try do
      {fun.(), Process.get(:row_locks)}
    after
      :telemetry.detach(handler)
    end
  end

  @doc false
  def count_row_lock(_event, _measurements, %{query: query}, _config) do
    if query =~ ~r/\bFOR (UPDATE|NO KEY UPDATE|SHARE|KEY SHARE)\b/,
      do: Process.put(:row_locks, Process.get(:row_locks, 0) + 1)
  end

  defp last, do: Repo.one(from e in Entry, order_by: [desc: e.inserted_at, desc: e.id], limit: 1)
end
