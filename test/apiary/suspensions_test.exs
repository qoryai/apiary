defmodule Apiary.SuspensionsTest do
  # A membership's suspension pauses and removes nothing: suspended by its organisation's
  # owners and admins, its person acts there no more until it is activated.
  use Apiary.DataCase, async: true

  import Apiary.AccessKeysFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Access, AccessKeys, Accounts, Organisations}
  alias Apiary.Audit.Entry
  alias Apiary.Organisations.{Membership, Organisation}

  describe "a membership's suspension" do
    setup do
      %{scope: owner} = signed_up = sign_up_fixture()

      %{
        signed_up: signed_up,
        owner: owner,
        admin: member_fixture(owner, :admin),
        member: member_fixture(owner, :member),
        other_owner: member_fixture(owner, :owner)
      }
    end

    test "an owner suspends admins and members; an admin members only; nobody an owner or themselves",
         ctx do
      assert {:ok, %Membership{suspended_at: %DateTime{}} = suspended} =
               Organisations.suspend_member(ctx.admin.scope, ctx.member.membership.id)

      assert suspended.suspended_by_id == ctx.admin.user.id

      for membership <- [ctx.other_owner.membership, ctx.owner.membership] do
        assert {:error, :forbidden} = Organisations.suspend_member(ctx.admin.scope, membership.id)
      end

      assert {:error, :forbidden} =
               Organisations.suspend_member(ctx.admin.scope, ctx.admin.membership.id)

      assert {:error, :forbidden} =
               Organisations.suspend_member(ctx.owner, ctx.owner.membership.id)

      assert {:ok, %Membership{suspended_at: %DateTime{}}} =
               Organisations.suspend_member(ctx.owner, ctx.admin.membership.id)

      # An owner is not suspended by another.
      assert {:error, :forbidden} =
               Organisations.suspend_member(ctx.owner, ctx.other_owner.membership.id)

      # Activating: an owner admins and members, an admin members only, nobody their own.
      assert {:error, :forbidden} =
               Organisations.activate_member(ctx.member.scope, ctx.member.membership.id)

      assert {:ok, %Membership{suspended_at: nil, suspended_by_id: nil}} =
               Organisations.activate_member(ctx.owner, ctx.admin.membership.id)

      assert {:error, :forbidden} =
               Organisations.activate_member(ctx.admin.scope, ctx.other_owner.membership.id)

      assert {:ok, %Membership{suspended_at: nil}} =
               Organisations.activate_member(ctx.admin.scope, ctx.member.membership.id)
    end

    test "a membership of another organisation is not found", ctx do
      %{membership: elsewhere} = sign_up_fixture()
      assert {:error, :not_found} = Organisations.suspend_member(ctx.owner, elsewhere.id)
      assert {:error, :not_found} = Organisations.activate_member(ctx.owner, elsewhere.id)
      assert {:error, :not_found} = Organisations.suspend_member(ctx.owner, "not-an-id")
    end

    test "a suspended owner is not the owner who remains", ctx do
      # A membership suspended before it was made an owner's, as no page suspends one.
      Repo.update_all(from(m in Membership, where: m.id == ^ctx.other_owner.membership.id),
        set: [suspended_at: DateTime.utc_now()]
      )

      # The one owner who may act neither leaves nor steps down.
      assert {:error, :last_owner} =
               Organisations.remove_member(ctx.owner, ctx.owner.membership.id)

      assert {:error, :last_owner} =
               Organisations.set_member_level(ctx.owner, ctx.owner.membership.id, :admin)

      refute Organisations.other_active_owner?(ctx.owner.membership)
      assert Organisations.other_active_owner?(ctx.other_owner.membership)

      # Nor is their own account deleted, beside a co-owner who may not act.
      assert [%Organisation{}] = Organisations.sole_owned_organisations(ctx.owner.user)
      assert {:error, :last_owner} = Accounts.delete_user(ctx.owner)

      # The co-owner's membership in use again, they count.
      Repo.update_all(from(m in Membership, where: m.id == ^ctx.other_owner.membership.id),
        set: [suspended_at: nil]
      )

      assert Organisations.other_active_owner?(ctx.owner.membership)
    end

    test "nothing is removed: activated, they act again with the reach they had", ctx do
      in_main = workspace_scope(ctx.member.user, ctx.owner.workspace)
      %{access_key: key} = access_key_fixture(ctx.owner)

      {:ok, _} = Organisations.suspend_member(ctx.owner, ctx.member.membership.id)

      assert %Membership{level: :member, suspended_at: %DateTime{}} =
               Repo.get!(Membership, ctx.member.membership.id)

      # They reach it no more, and are told why rather than that it is not there.
      assert workspace_scope(ctx.member.user, ctx.owner.workspace) == nil
      assert Organisations.list_memberships(ctx.member.user) == []

      assert [%Membership{organisation: %Organisation{id: id}}] =
               Organisations.list_suspended_memberships(ctx.member.user)

      assert id == ctx.owner.organisation.id

      assert %Membership{} =
               Organisations.suspended_membership(ctx.member.user, ctx.owner.organisation.slug)

      assert Access.authorize(ctx.member.scope, :"node.read", ctx.owner.workspace) ==
               {:error, :forbidden}

      # The key is the workspace's, not theirs: it keeps working.
      assert {:ok, _} = AccessKeys.fetch_for_verification(key.key_id)

      {:ok, _} = Organisations.activate_member(ctx.owner, ctx.member.membership.id)

      assert Organisations.suspended_membership(ctx.member.user, ctx.owner.organisation.slug) ==
               nil

      assert Access.authorize(in_main, :"node.read", ctx.owner.workspace) == :ok
      assert workspace_scope(ctx.member.user, ctx.owner.workspace)
      assert Access.authorize(ctx.member.scope, :"node.read", ctx.owner.workspace) == :ok
    end

    test "each suspension and activation is an entry; one that changes nothing is none", ctx do
      id = ctx.member.membership.id
      {:ok, _} = Organisations.suspend_member(ctx.owner, id)

      assert %Entry{
               action: "member.suspend",
               subject_kind: "membership",
               before: %{"suspended_at" => nil},
               details: %{"level" => "member", "user_id" => user_id}
             } = last()

      assert user_id == ctx.member.user.id
      count = count()

      assert {:ok, %Membership{suspended_at: %DateTime{}}} =
               Organisations.suspend_member(ctx.owner, id)

      assert count() == count

      {:ok, _} = Organisations.activate_member(ctx.owner, id)

      assert %Entry{action: "member.activate", after: %{"suspended_at" => nil}} =
               last()

      assert {:ok, %Membership{suspended_at: nil}} = Organisations.activate_member(ctx.owner, id)
      assert count() == count + 1
    end
  end

  defp last, do: Repo.one(from e in Entry, order_by: [desc: e.inserted_at, desc: e.id], limit: 1)
  defp count, do: Repo.aggregate(Entry, :count)
end
