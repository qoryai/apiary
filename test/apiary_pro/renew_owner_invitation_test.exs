defmodule ApiaryPro.RenewOwnerInvitationTest do
  @moduledoc """
  A new link for a pending invitation of a client's first owner
  (`ApiaryPro.Operators.renew_owner_invitation/4`, `client.renew_owner_invitation`): the
  same invitation and its operator's row, a new token, the old link dead at once, counted
  against the operator's allowance; the operator's owners and admins only, while the
  client has no owner and is not suspended. Without mail the link is handed back; with
  mail it is emailed.
  """
  # Not async: the features and the day's limit are the node's, and an operator is made by
  # an instance admin, an owner of the suite's one instance organisation.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Features, Mail, Organisations}
  alias Apiary.Audit.Entry
  alias Apiary.Organisations.Invitation
  alias ApiaryPro.Operators
  alias ApiaryPro.Operators.OperatorInvitation

  @moduletag with_features: Features.all()

  defp email, do: Apiary.AccountsFixtures.unique_user_email()

  # The invitation's URL, its token sent to the test's process.
  defp url(token) do
    send(self(), {:renewed_token, token})
    "http://localhost/invitations/#{token}"
  end

  defp renewed_token do
    receive do
      {:renewed_token, token} -> token
    after
      0 -> flunk("no link was made")
    end
  end

  # An operator, and a client of it with no owner yet, whose first owner's invitation was
  # emailed: the invitation and its token.
  defp pending(_ctx) do
    operator = operator_fixture()

    {%{organisation: client}, token} =
      create_client_fixture(operator.scope, %{"name" => "Example Co", "email" => email()})

    [invitation] = Repo.all(from i in Invitation, where: i.organisation_id == ^client.id)
    %{operator: operator, client: client, invitation: invitation, token: token}
  end

  defp entries(client, action) do
    Repo.all(
      from e in Entry,
        where: e.organisation_id == ^client.id and e.action == ^action,
        order_by: [asc: e.inserted_at, asc: e.id]
    )
  end

  describe "without mail" do
    # The fixtures sign their people up and confirm them by email: mail goes after them.
    setup :pending

    test "the same invitation gets a new link, and the old one stops at once", ctx do
      Mail.put_test_source(:none)

      assert {:ok, %Invitation{id: id} = renewed, {:link, link}} =
               Operators.renew_owner_invitation(
                 ctx.operator.scope,
                 ctx.client.id,
                 ctx.invitation.id,
                 &url/1
               )

      token = renewed_token()
      assert link == "http://localhost/invitations/#{token}"
      assert id == ctx.invitation.id
      assert DateTime.compare(renewed.expires_at, ctx.invitation.expires_at) != :lt

      # The old link opens nothing; the new one opens the same invitation.
      assert Organisations.get_invitation_by_token(ctx.token) == nil
      assert Organisations.get_invitation_by_token(token).id == id

      # The operator's row stands, so its person still joins as the owner.
      assert %OperatorInvitation{organisation_id: client_id, operator_id: operator_id} =
               Repo.get!(OperatorInvitation, id)

      assert {client_id, operator_id} == {ctx.client.id, ctx.operator.organisation.id}

      # The client's entry, by the operator's person, counted against the operator.
      assert [entry] = entries(ctx.client, "client.renew_owner_invitation")
      assert {entry.subject_kind, entry.subject_id} == {"invitation", id}
      assert {entry.actor_kind, entry.actor_id} == {:person, ctx.operator.user.id}
      assert entry.details["allowance_id"] == ctx.operator.organisation.id
      assert entries(ctx.client, "invitation.renew") == []
    end

    test "an invitation sent from a workspace gets a new link too, one sent without gets one as well",
         ctx do
      # The client starts with no workspace, so its first invitation has none.
      assert is_nil(ctx.invitation.workspace_id)

      ApiaryPro.Flags.put_operator_infrastructure(true)

      assert {:ok, workspace} =
               Organisations.create_first_workspace(scope_in(ctx.operator.user, ctx.client), %{
                 "domain" => Apiary.Lingo.Domain.default().name()
               })

      ApiaryPro.Flags.put_operator_infrastructure(false)
      Mail.put_test_source(:none)

      assert {:ok, %Invitation{workspace_id: workspace_id} = sent, {:link, _link}} =
               Operators.invite_owner(
                 ctx.operator.scope,
                 ctx.client.id,
                 %{"email" => email()},
                 &url/1
               )

      assert workspace_id == workspace.id
      _sent_token = renewed_token()

      for invitation <- [sent, ctx.invitation] do
        assert {:ok, %Invitation{id: id}, {:link, _link}} =
                 Operators.renew_owner_invitation(
                   ctx.operator.scope,
                   ctx.client.id,
                   invitation.id,
                   &url/1
                 )

        assert id == invitation.id
        _renewed_token = renewed_token()
      end
    end

    test "only the operator's owners and admins make one", ctx do
      %{scope: admin} = member_fixture(ctx.operator.scope, :admin)
      %{scope: member} = member_fixture(ctx.operator.scope, :member)
      Mail.put_test_source(:none)

      assert {:error, :forbidden} =
               Operators.renew_owner_invitation(member, ctx.client.id, ctx.invitation.id, &url/1)

      assert Organisations.get_invitation_by_token(ctx.token)
      assert entries(ctx.client, "client.renew_owner_invitation") == []

      assert {:ok, _renewed, {:link, _link}} =
               Operators.renew_owner_invitation(admin, ctx.client.id, ctx.invitation.id, &url/1)
    end

    test "none once the client has an owner, who invites its people", ctx do
      owned = client_fixture(ctx.operator.scope)
      Mail.put_test_source(:none)

      assert {:error, :has_owner} =
               Operators.renew_owner_invitation(
                 ctx.operator.scope,
                 owned.organisation.id,
                 Ecto.UUID.generate(),
                 &url/1
               )
    end

    test "none for an invitation that is not the pending one of the client's first owner",
         ctx do
      scope = ctx.operator.scope
      Mail.put_test_source(:none)

      assert {:ok, _revoked} =
               Operators.revoke_owner_invitation(scope, ctx.client.id, ctx.invitation.id)

      assert {:error, :not_found} =
               Operators.renew_owner_invitation(scope, ctx.client.id, ctx.invitation.id, &url/1)

      assert {:error, :not_found} =
               Operators.renew_owner_invitation(scope, ctx.client.id, "not an id", &url/1)
    end

    test "none for a suspended client", ctx do
      %{instance_scope: instance} = instance_admin_fixture()
      {:ok, _suspended} = ApiaryPro.Suspensions.suspend_organisation(instance, ctx.client.id)
      Mail.put_test_source(:none)

      assert {:error, :suspended} =
               Operators.renew_owner_invitation(
                 ctx.operator.scope,
                 ctx.client.id,
                 ctx.invitation.id,
                 &url/1
               )

      # A suspended client's invitation opens nothing meanwhile; its link is the same.
      assert Repo.get!(Invitation, ctx.invitation.id).token_hash == ctx.invitation.token_hash
    end

    test "none once the operator's invitations of the day are spent", ctx do
      previous = Application.fetch_env!(:apiary, :invitations_per_day)
      on_exit(fn -> Application.put_env(:apiary, :invitations_per_day, previous) end)
      # The client's creation invited one, against the operator's allowance.
      Application.put_env(:apiary, :invitations_per_day, 1)
      Mail.put_test_source(:none)

      assert {:error, %Ecto.Changeset{errors: errors}} =
               Operators.renew_owner_invitation(
                 ctx.operator.scope,
                 ctx.client.id,
                 ctx.invitation.id,
                 &url/1
               )

      assert {_message, opts} = Keyword.fetch!(errors, :email)
      assert opts[:validation] == :invitations_per_day
      assert opts[:limit] == 1

      # Nothing changed: the old link still works.
      assert Organisations.get_invitation_by_token(ctx.token).id == ctx.invitation.id
      assert entries(ctx.client, "client.renew_owner_invitation") == []
    end
  end

  describe "with mail" do
    setup :pending

    test "the new link is emailed, and the old one stops at once", ctx do
      address = ctx.invitation.email

      # The creation's email, already sent.
      assert_received {:email, %Swoosh.Email{to: [{_, ^address}]}}

      assert {:ok, %Invitation{id: id}} =
               Operators.renew_owner_invitation(
                 ctx.operator.scope,
                 ctx.client.id,
                 ctx.invitation.id,
                 &url/1
               )

      token = renewed_token()
      assert id == ctx.invitation.id

      assert_received {:email, %Swoosh.Email{to: [{_, ^address}], text_body: body}}
      assert body =~ "/invitations/#{token}"

      assert Organisations.get_invitation_by_token(ctx.token) == nil
      assert Organisations.get_invitation_by_token(token).id == id
      assert [_entry] = entries(ctx.client, "client.renew_owner_invitation")
    end
  end
end
