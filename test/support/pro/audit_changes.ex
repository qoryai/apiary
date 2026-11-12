defmodule ApiaryPro.AuditChanges do
  @moduledoc """
  AuditChanges is the edition's module of changes of the audit test (`Apiary.AuditCase`): each of
  the edition's audited actions made the way the product makes it, what it needs first, then the
  trail as it is (`before`), then the change; and the same change refused, `{the trail
  before the attempt, the attempt's answer}`. A change that leaves an entry in two
  organisations, each naming the other, is looked for in its actor's own organisation.
  """

  import Apiary.AccountsFixtures, only: [unique_user_email: 0]
  import Apiary.AuditCase, only: [entries: 0, in_trail: 2, refuse_as_member: 4]
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures
  import ExUnit.Assertions

  alias Apiary.Access
  alias Apiary.Accounts.Scope
  alias Apiary.Audit.Entry

  alias ApiaryPro.{
    Deletion,
    Grants,
    Operators,
    OrganisationPolicy,
    OrganisationVariables,
    PolicyRequests,
    Suspensions,
    Transfers
  }

  @doc "actions/0 is the edition's audited actions, each made and refused below."
  @spec actions() :: [Access.action()]
  def actions do
    [
      :"workspace_access.add",
      :"workspace_access.remove",
      :"organisation.transfer",
      :"organisation.withdraw_transfer",
      :"organisation.accept_transfer",
      :"organisation.leave_operator",
      :"client.create",
      :"client.invite_owner",
      :"client.revoke_owner_invitation",
      :"client.renew_owner_invitation",
      :"client.invite_admin",
      :"client.revoke_admin_invitation",
      :"client.renew_admin_invitation",
      :"client.accept",
      :"client.grant_features",
      :"client.drop",
      :"client.set_model_chain",
      :"client.delete",
      :"instance.create_organisation",
      :"instance.create_operator",
      :"instance.change_kind",
      :"instance.purge_organisation",
      :"instance.suspend_account",
      :"instance.activate_account",
      :"instance.suspend_organisation",
      :"instance.activate_organisation",
      :"instance.transfer",
      :"instance.grant_features",
      :"instance.change_sign_up",
      :"instance.adopt",
      :"policy_request.send",
      :"policy_request.withdraw",
      :"policy_request.accept",
      :"policy_request.decline",
      :"organisation_policy.edit",
      :"organisation_policy.set_floor",
      :"organisation_policy.set_switch",
      :"organisation_variable.edit"
    ]
  end

  @doc """
  make/2 makes `action` the way the product makes it, in the context `Apiary.AuditCase`
  gives: what it needs first, then the trail as it is, then the change.
  """
  @spec make(Access.action(), map) :: map
  def make(:"workspace_access.add", %{scope: scope}) do
    %{membership: membership} = member_fixture(scope)
    second = workspace_fixture(scope.organisation)
    before = entries()
    {:ok, access} = ApiaryPro.WorkspaceAccess.add(scope, membership.id, second.id)
    %{scope: scope, subject: {"workspace_access", access.id}, before: before}
  end

  def make(:"workspace_access.remove", %{scope: scope}) do
    %{membership: membership} = member_fixture(scope)
    before = entries()

    {:ok, access} =
      ApiaryPro.WorkspaceAccess.remove(scope, membership.id, scope.workspace.id)

    %{scope: scope, subject: {"workspace_access", access.id}, before: before}
  end

  # An operator's new client begins its own trail, by the operator's person; the
  # invitation of its first owner follows, which is not the one looked for.
  def make(:"client.create", _ctx) do
    operator = operator_fixture()
    before = entries()

    {%{organisation: client}, _token} =
      create_client_fixture(operator.scope, %{"name" => "Acme", "email" => unique_user_email()})

    assert [%Entry{action: "client.invite_owner"} = invited] =
             Enum.filter(entries() -- before, &(&1.action == "client.invite_owner"))

    scope = %Scope{user: operator.user, organisation: client}
    %{scope: scope, subject: {"organisation", client.id}, before: before ++ [invited]}
  end

  # The operator's invitation of a client's first owner is the client's entry.
  def make(:"client.invite_owner", _ctx) do
    operator = operator_fixture()

    {%{organisation: client}, _token} =
      create_client_fixture(operator.scope, %{"name" => "Acme", "email" => unique_user_email()})

    before = entries()

    {:ok, invitation} =
      Operators.invite_owner(
        operator.scope,
        client.id,
        %{"email" => unique_user_email()},
        &"http://localhost/invitations/#{&1}"
      )

    scope = %Scope{user: operator.user, organisation: client}
    %{scope: scope, subject: {"invitation", invitation.id}, before: before}
  end

  # The operator's revocation of its client's first owner's invitation is the client's.
  def make(:"client.revoke_owner_invitation", _ctx) do
    operator = operator_fixture()

    {%{organisation: client}, _token} =
      create_client_fixture(operator.scope, %{"name" => "Acme", "email" => unique_user_email()})

    [invitation] =
      Operators.list_clients(operator.scope) |> elem(1) |> hd() |> Map.fetch!(:owner_invitations)

    before = entries()
    {:ok, _} = Operators.revoke_owner_invitation(operator.scope, client.id, invitation.id)
    scope = %Scope{user: operator.user, organisation: client}
    %{scope: scope, subject: {"invitation", invitation.id}, before: before}
  end

  # The operator's new link for its client's first owner's invitation is the client's,
  # without mail, whose link the page shows.
  def make(:"client.renew_owner_invitation", _ctx) do
    operator = operator_fixture()

    {%{organisation: client}, _token} =
      create_client_fixture(operator.scope, %{"name" => "Acme", "email" => unique_user_email()})

    [invitation] =
      Operators.list_clients(operator.scope) |> elem(1) |> hd() |> Map.fetch!(:owner_invitations)

    before = entries()
    Apiary.Mail.put_test_source(:none)

    {:ok, _, {:link, _url}} =
      Operators.renew_owner_invitation(
        operator.scope,
        client.id,
        invitation.id,
        &"http://localhost/invitations/#{&1}"
      )

    scope = %Scope{user: operator.user, organisation: client}
    %{scope: scope, subject: {"invitation", invitation.id}, before: before}
  end

  # While the operator owns its clients (`ApiaryPro.Flags.operator_infrastructure?/0`), the
  # invitation of a client's first admin, its revocation and its new link are the
  # client's, as the first owner's are.
  def make(:"client.invite_admin", _ctx) do
    ApiaryPro.Flags.put_operator_infrastructure(true)
    operator = operator_fixture()

    {%{organisation: client}, _token} =
      create_client_fixture(operator.scope, %{"name" => "Acme", "email" => unique_user_email()})

    before = entries()

    {:ok, invitation} =
      Operators.invite_admin(
        operator.scope,
        client.id,
        %{"email" => unique_user_email()},
        &"http://localhost/invitations/#{&1}"
      )

    scope = %Scope{user: operator.user, organisation: client}
    %{scope: scope, subject: {"invitation", invitation.id}, before: before}
  end

  def make(:"client.revoke_admin_invitation", _ctx) do
    ApiaryPro.Flags.put_operator_infrastructure(true)
    operator = operator_fixture()

    {%{organisation: client}, _token} =
      create_client_fixture(operator.scope, %{"name" => "Acme", "email" => unique_user_email()})

    [invitation] =
      Operators.list_clients(operator.scope) |> elem(1) |> hd() |> Map.fetch!(:owner_invitations)

    before = entries()
    {:ok, _} = Operators.revoke_admin_invitation(operator.scope, client.id, invitation.id)
    scope = %Scope{user: operator.user, organisation: client}
    %{scope: scope, subject: {"invitation", invitation.id}, before: before}
  end

  def make(:"client.renew_admin_invitation", _ctx) do
    ApiaryPro.Flags.put_operator_infrastructure(true)
    operator = operator_fixture()

    {%{organisation: client}, _token} =
      create_client_fixture(operator.scope, %{"name" => "Acme", "email" => unique_user_email()})

    [invitation] =
      Operators.list_clients(operator.scope) |> elem(1) |> hd() |> Map.fetch!(:owner_invitations)

    before = entries()
    Apiary.Mail.put_test_source(:none)

    {:ok, _, {:link, _url}} =
      Operators.renew_admin_invitation(
        operator.scope,
        client.id,
        invitation.id,
        &"http://localhost/invitations/#{&1}"
      )

    scope = %Scope{user: operator.user, organisation: client}
    %{scope: scope, subject: {"invitation", invitation.id}, before: before}
  end

  # A client with no owner yet deleted by its operator: the operator's entry, which
  # outlives the client's trail; its invitation's withdrawal is the client's.
  def make(:"client.delete", _ctx) do
    operator = operator_fixture()

    {%{organisation: client}, _token} =
      create_client_fixture(operator.scope, %{"name" => "Acme", "email" => unique_user_email()})

    before = entries()
    {:ok, _} = Deletion.delete_client(operator.scope, client.id, "Acme")
    withdrawn = in_trail(entries() -- before, client)

    %{
      scope: operator.scope,
      subject: {"organisation", operator.organisation.id},
      before: before ++ [withdrawn]
    }
  end

  # A client switched to its operator's model providers by the operator's owner: an entry
  # in the operator's trail. The client is made while the operator does not own its
  # clients' infrastructure, as a client is, then the flag is turned on.
  def make(:"client.set_model_chain", _ctx) do
    ApiaryPro.Flags.put_operator_infrastructure(false)
    %{operator: operator, client: client} = client_with_admin()
    ApiaryPro.Flags.put_operator_infrastructure(true)
    before = entries()
    {:ok, _} = Operators.set_model_chain(operator.scope, client.organisation.id, :operator)

    %{
      scope: operator.scope,
      subject: {"organisation", operator.organisation.id},
      before: before
    }
  end

  # A drop and a leaving: an entry in the client and one in the operator, each naming the
  # other; the one looked for is the actor's own organisation's.
  def make(:"client.drop", _ctx) do
    %{operator: operator, client: client} = client_with_admin()
    before = entries()
    {:ok, _} = Transfers.drop(operator.scope, client.organisation.id, client.organisation.name)
    parted = in_trail(entries() -- before, client.organisation)

    %{
      scope: operator.scope,
      subject: {"organisation", operator.organisation.id},
      before: before ++ [parted]
    }
  end

  def make(:"organisation.leave_operator", _ctx) do
    %{operator: operator, client: client} = client_with_admin()
    before = entries()
    {:ok, _} = Transfers.leave(client.owner.scope, operator.organisation.name)
    parted = in_trail(entries() -- before, operator.organisation)

    %{
      scope: client.owner.scope,
      subject: {"organisation", client.organisation.id},
      before: before ++ [parted]
    }
  end

  # A policy request: sent, an entry in the operator's trail and one in each client's;
  # answered or withdrawn, one in each trail; the one looked for is the actor's own
  # organisation's, and an acceptance's policy changes are the policy's own entries.
  def make(:"policy_request.send", _ctx) do
    %{operator: operator, client: client} = client_with_admin()
    before = entries()
    {:ok, request} = send_policy_request(operator.scope)
    received = in_trail(entries() -- before, client.organisation)

    %{
      scope: operator.scope,
      subject: {"policy_request", request.id},
      before: before ++ [received]
    }
  end

  def make(:"policy_request.withdraw", _ctx) do
    %{operator: operator, client: client} = client_with_admin()
    {:ok, request} = send_policy_request(operator.scope)
    before = entries()
    {:ok, _} = PolicyRequests.withdraw(operator.scope, request.id)
    withdrawn = in_trail(entries() -- before, client.organisation)

    %{
      scope: operator.scope,
      subject: {"policy_request", request.id},
      before: before ++ [withdrawn]
    }
  end

  def make(action, _ctx) when action in [:"policy_request.accept", :"policy_request.decline"] do
    %{operator: operator, client: client} = client_with_admin()
    {:ok, request} = send_policy_request(operator.scope)
    [answer] = request.answers
    before = entries()

    {:ok, _} =
      case action do
        :"policy_request.accept" ->
          PolicyRequests.accept(client.owner.scope, answer.id, [client.workspace.id])

        :"policy_request.decline" ->
          PolicyRequests.decline(client.owner.scope, answer.id, "Not now")
      end

    made = entries() -- before

    [answered] =
      Enum.filter(
        made,
        &(&1.action == Atom.to_string(action) and &1.organisation_id == client.organisation.id)
      )

    %{
      scope: client.owner.scope,
      subject: {"policy_request_answer", answer.id},
      before: before ++ (made -- [answered])
    }
  end

  # An organisation an instance admin creates begins its trail, by them.
  def make(action, _ctx)
      when action in [:"instance.create_organisation", :"instance.create_operator"] do
    admin = instance_admin_fixture()
    kind = if action == :"instance.create_operator", do: "operator", else: "organisation"
    before = entries()

    {:ok, %{organisation: organisation}} =
      Operators.create_organisation(admin.instance_scope, %{"name" => "Acme", "kind" => kind})

    scope = %Scope{user: admin.user, organisation: organisation}
    %{scope: scope, subject: {"organisation", organisation.id}, before: before}
  end

  def make(:"instance.change_kind", _ctx) do
    admin = instance_admin_fixture()
    %{organisation: organisation} = sign_up_fixture()
    before = entries()
    {:ok, _} = Operators.change_kind(admin.instance_scope, organisation.id, :operator)
    scope = %Scope{user: admin.user, organisation: organisation}
    %{scope: scope, subject: {"organisation", organisation.id}, before: before}
  end

  # The purged organisation's trail goes with it: the entry is the instance
  # organisation's.
  def make(:"instance.purge_organisation", _ctx) do
    admin = instance_admin_fixture()
    %{organisation: organisation} = sign_up_fixture()
    before = entries()

    {:ok, :purged} =
      Deletion.purge_on_request(admin.instance_scope, organisation.id, organisation.slug)

    operator = admin.instance_scope.organisation

    %{
      scope: admin.instance_scope,
      subject: {"organisation", operator.id},
      before: Enum.filter(before, &(&1 in entries()))
    }
  end

  # An organisation offered to an operator by its owner: the organisation's entry.
  def make(:"organisation.transfer", %{scope: scope}) do
    operator = operator_fixture()
    before = entries()
    {:ok, transfer} = Transfers.offer_to_operator(scope, operator.organisation.slug)
    %{scope: scope, subject: {"transfer", transfer.id}, before: before}
  end

  def make(:"organisation.withdraw_transfer", %{scope: scope}) do
    operator = operator_fixture()
    {:ok, transfer} = Transfers.offer_to_operator(scope, operator.organisation.slug)
    before = entries()
    {:ok, _} = Transfers.withdraw(scope)
    %{scope: scope, subject: {"transfer", transfer.id}, before: before}
  end

  # The admin accepts the arbiter's offer of an organisation whose owners are all
  # suspended: an entry in the organisation they now own.
  def make(:"organisation.accept_transfer", %{scope: scope}) do
    instance_admin = instance_admin_fixture()
    %{membership: membership, scope: admin} = member_fixture(scope, :admin)
    {:ok, _} = Suspensions.suspend_account(instance_admin.instance_scope, scope.user.id)

    {:ok, _} =
      Transfers.arbitrate(
        instance_admin.instance_scope,
        scope.organisation.id,
        membership.id,
        "The owner is away."
      )

    before = entries()
    {:ok, _} = Transfers.accept(admin)
    %{scope: admin, subject: {"organisation", scope.organisation.id}, before: before}
  end

  # An operator's owner accepts an organisation offered to it: an entry in the operator,
  # and one in the organisation it takes on, which is not the one looked for.
  def make(:"client.accept", _ctx) do
    operator = operator_fixture()
    offered = sign_up_fixture()
    {:ok, _} = Transfers.offer_to_operator(offered.scope, operator.organisation.slug)
    before = entries()
    {:ok, _} = Transfers.accept_client(operator.scope, offered.organisation.id)

    assert [%Entry{action: "client.accept", subject_kind: "organisation"} = joined] =
             Enum.filter(entries() -- before, &(&1.organisation_id == offered.organisation.id))

    assert joined.subject_id == offered.organisation.id
    assert joined.after == %{"operator_id" => operator.organisation.id}
    assert {joined.actor_kind, joined.actor_id} == {:person, operator.user.id}

    %{
      scope: operator.scope,
      subject: {"organisation", operator.organisation.id},
      before: before ++ [joined]
    }
  end

  # An account's suspension and activation are the instance organisation's entries.
  def make(:"instance.suspend_account", _ctx) do
    admin = instance_admin_fixture()
    %{user: user} = sign_up_fixture()
    before = entries()
    {:ok, _} = Suspensions.suspend_account(admin.instance_scope, user.id)
    operator = admin.instance_scope.organisation
    %{scope: admin.instance_scope, subject: {"organisation", operator.id}, before: before}
  end

  def make(:"instance.activate_account", _ctx) do
    admin = instance_admin_fixture()
    %{user: user} = sign_up_fixture()
    {:ok, _} = Suspensions.suspend_account(admin.instance_scope, user.id)
    before = entries()
    {:ok, _} = Suspensions.activate_account(admin.instance_scope, user.id)
    operator = admin.instance_scope.organisation
    %{scope: admin.instance_scope, subject: {"organisation", operator.id}, before: before}
  end

  # An organisation's suspension and activation are its own entries, by the instance admin.
  def make(:"instance.suspend_organisation", _ctx) do
    admin = instance_admin_fixture()
    %{organisation: organisation} = sign_up_fixture()
    before = entries()
    {:ok, _} = Suspensions.suspend_organisation(admin.instance_scope, organisation.id)
    scope = %Scope{user: admin.user, organisation: organisation}
    %{scope: scope, subject: {"organisation", organisation.id}, before: before}
  end

  def make(:"instance.activate_organisation", _ctx) do
    admin = instance_admin_fixture()
    %{organisation: organisation} = sign_up_fixture()
    {:ok, _} = Suspensions.suspend_organisation(admin.instance_scope, organisation.id)
    before = entries()
    {:ok, _} = Suspensions.activate_organisation(admin.instance_scope, organisation.id)
    scope = %Scope{user: admin.user, organisation: organisation}
    %{scope: scope, subject: {"organisation", organisation.id}, before: before}
  end

  # The arbiter's offer is the organisation's entry, by the instance admin.
  def make(:"instance.transfer", _ctx) do
    instance_admin = instance_admin_fixture()
    %{client: client, admin: admin} = client_with_admin()
    {:ok, _} = Suspensions.suspend_account(instance_admin.instance_scope, client.owner.user.id)
    before = entries()

    {:ok, transfer} =
      Transfers.arbitrate(
        instance_admin.instance_scope,
        client.organisation.id,
        admin.membership.id,
        "The owner is away."
      )

    scope = %Scope{user: instance_admin.user, organisation: client.organisation}
    %{scope: scope, subject: {"transfer", transfer.id}, before: before}
  end

  # Features: an instance admin's grant is the organisation's entry, an operator's the
  # client's.
  def make(:"instance.grant_features", %{scope: scope}) do
    admin = instance_admin_fixture()
    before = entries()

    {:ok, _} =
      Grants.set_organisation(admin.instance_scope, scope.organisation.id, ["observability"])

    %{
      scope: %Scope{user: admin.user, organisation: scope.organisation},
      subject: {"organisation", scope.organisation.id},
      before: before
    }
  end

  # Who may sign up: an instance admin's, after a recent sign-in, in the trail of the
  # instance's organisation, about the organisation.
  def make(:"instance.change_sign_up", _ctx) do
    admin = instance_admin_fixture()
    scope = admin.instance_scope
    scope = put_in(scope.user.authenticated_at, DateTime.utc_now())
    before = entries()
    {:ok, %{operator: :open}} = ApiaryPro.SignUp.save(scope, %{"operators" => "open"})
    instance = admin.instance_scope.organisation
    %{scope: admin.instance_scope, subject: {"organisation", instance.id}, before: before}
  end

  # An organisation the core created, adopted once the instance runs the edition: its
  # entry, by the instance, in its own trail.
  def make(:"instance.adopt", _ctx) do
    organisation = core_organisation!()
    before = entries()
    :ok = ApiaryPro.Adoption.run()

    %{
      scope: Scope.for_instance(organisation),
      actor: :instance,
      subject: {"organisation", organisation.id},
      before: before
    }
  end

  def make(:"client.grant_features", _ctx) do
    operator = operator_fixture()
    %{organisation: client} = client_fixture(operator.scope)
    before = entries()
    {:ok, _} = Grants.set_client(operator.scope, client.id, ["observability"])

    %{
      scope: %Scope{user: operator.user, organisation: client},
      subject: {"organisation", client.id},
      before: before
    }
  end

  # The organisation's policy: an owner's change, one entry on the organisation; the
  # workspaces it renders again leave their own entries, the policy's, in the trail
  # before it.
  def make(:"organisation_policy.edit", %{scope: scope}) do
    before = entries()
    {:ok, _rule} = OrganisationPolicy.deny(scope, %{host: "paste.example"})
    rendered = Enum.filter(entries() -- before, &(&1.action == "security_policy.edit"))
    %{scope: scope, subject: {"organisation", scope.organisation.id}, before: before ++ rendered}
  end

  def make(:"organisation_policy.set_floor", %{scope: scope}) do
    before = entries()
    {:ok, _policy} = OrganisationPolicy.set_floor(scope, true)
    rendered = Enum.filter(entries() -- before, &(&1.action == "security_policy.edit"))
    %{scope: scope, subject: {"organisation", scope.organisation.id}, before: before ++ rendered}
  end

  def make(:"organisation_policy.set_switch", %{scope: scope}) do
    before = entries()
    {:ok, _policy} = OrganisationPolicy.set_switch(scope, false)
    rendered = Enum.filter(entries() -- before, &(&1.action == "security_policy.edit"))
    %{scope: scope, subject: {"organisation", scope.organisation.id}, before: before ++ rendered}
  end

  # A variable of the organisation, by name, never by value.
  def make(:"organisation_variable.edit", %{scope: scope}) do
    before = entries()
    value = "plain-audit-value"

    {:ok, variable} = OrganisationVariables.create(scope, %{name: "LOG_LEVEL", value: value})

    %{
      scope: scope,
      subject: {"organisation_variable", variable.id},
      before: before,
      secret: value
    }
  end

  @doc """
  refuse/2 makes `action` refused or rolled back, in the context `Apiary.AuditCase` gives:
  `{the trail before the attempt, the attempt's answer}`.
  """
  @spec refuse(Access.action(), map) :: {list, term}
  # In an organisation that is no operator, clients are not found.
  def refuse(:"client.create", %{scope: scope}) do
    before = entries()
    attrs = %{"name" => "Acme", "email" => unique_user_email()}
    {before, Operators.create_client(scope, attrs, &"http://localhost/invitations/#{&1}")}
  end

  def refuse(:"client.invite_owner", %{scope: scope}) do
    before = entries()

    {before,
     Operators.invite_owner(
       scope,
       Ecto.UUID.generate(),
       %{"email" => unique_user_email()},
       &"http://localhost/invitations/#{&1}"
     )}
  end

  # A member of the operator: revoking an invitation of a client's owner is its owners'
  # and admins'.
  def refuse(:"client.revoke_owner_invitation", _ctx) do
    operator = operator_fixture()
    %{scope: member} = member_fixture(operator.scope, :member)

    {%{organisation: client}, _token} =
      create_client_fixture(operator.scope, %{"name" => "Acme", "email" => unique_user_email()})

    [invitation] =
      Operators.list_clients(operator.scope) |> elem(1) |> hd() |> Map.fetch!(:owner_invitations)

    before = entries()
    {before, Operators.revoke_owner_invitation(member, client.id, invitation.id)}
  end

  # A member of the operator: a new link for a client's owner's invitation is its owners'
  # and admins'.
  def refuse(:"client.renew_owner_invitation", _ctx) do
    operator = operator_fixture()
    %{scope: member} = member_fixture(operator.scope, :member)

    {%{organisation: client}, _token} =
      create_client_fixture(operator.scope, %{"name" => "Acme", "email" => unique_user_email()})

    [invitation] =
      Operators.list_clients(operator.scope) |> elem(1) |> hd() |> Map.fetch!(:owner_invitations)

    before = entries()

    {before,
     Operators.renew_owner_invitation(
       member,
       client.id,
       invitation.id,
       &"http://localhost/invitations/#{&1}"
     )}
  end

  # While the operator owns its clients: a client that is not there, and a member of the
  # operator, who neither revokes nor renews a first admin's invitation.
  def refuse(:"client.invite_admin", %{scope: scope}) do
    ApiaryPro.Flags.put_operator_infrastructure(true)
    before = entries()

    {before,
     Operators.invite_admin(
       scope,
       Ecto.UUID.generate(),
       %{"email" => unique_user_email()},
       &"http://localhost/invitations/#{&1}"
     )}
  end

  def refuse(:"client.revoke_admin_invitation", _ctx) do
    ApiaryPro.Flags.put_operator_infrastructure(true)
    operator = operator_fixture()
    %{scope: member} = member_fixture(operator.scope, :member)

    {%{organisation: client}, _token} =
      create_client_fixture(operator.scope, %{"name" => "Acme", "email" => unique_user_email()})

    [invitation] =
      Operators.list_clients(operator.scope) |> elem(1) |> hd() |> Map.fetch!(:owner_invitations)

    before = entries()
    {before, Operators.revoke_admin_invitation(member, client.id, invitation.id)}
  end

  def refuse(:"client.renew_admin_invitation", _ctx) do
    ApiaryPro.Flags.put_operator_infrastructure(true)
    operator = operator_fixture()
    %{scope: member} = member_fixture(operator.scope, :member)

    {%{organisation: client}, _token} =
      create_client_fixture(operator.scope, %{"name" => "Acme", "email" => unique_user_email()})

    [invitation] =
      Operators.list_clients(operator.scope) |> elem(1) |> hd() |> Map.fetch!(:owner_invitations)

    before = entries()

    {before,
     Operators.renew_admin_invitation(
       member,
       client.id,
       invitation.id,
       &"http://localhost/invitations/#{&1}"
     )}
  end

  # A client with an owner is dropped, not deleted.
  def refuse(:"client.delete", _ctx) do
    %{operator: operator, client: client} = client_with_admin()
    before = entries()

    {before,
     Deletion.delete_client(operator.scope, client.organisation.id, client.organisation.name)}
  end

  # An admin of the operator: dropping a client is its owners'.
  def refuse(:"client.drop", _ctx) do
    %{operator: operator, client: client} = client_with_admin()
    %{scope: operator_admin} = member_fixture(operator.scope, :admin)
    before = entries()
    {before, Transfers.drop(operator_admin, client.organisation.id, client.organisation.name)}
  end

  # A member of the operator: choosing a client's model providers is its owners' and admins'.
  def refuse(:"client.set_model_chain", _ctx) do
    ApiaryPro.Flags.put_operator_infrastructure(false)
    %{operator: operator, client: client} = client_with_admin()
    %{scope: operator_member} = member_fixture(operator.scope, :member)
    ApiaryPro.Flags.put_operator_infrastructure(true)
    before = entries()
    {before, Operators.set_model_chain(operator_member, client.organisation.id, :operator)}
  end

  # An admin of the client: leaving its operator is its owners'.
  def refuse(:"organisation.leave_operator", _ctx) do
    %{operator: operator, admin: admin} = client_with_admin()
    before = entries()
    {before, Transfers.leave(admin.scope, operator.organisation.name)}
  end

  # A member of the operator: sending and withdrawing are its owners' and admins'.
  def refuse(:"policy_request.send", _ctx) do
    %{operator: operator} = client_with_admin()
    %{scope: member} = member_fixture(operator.scope, :member)
    before = entries()
    {before, send_policy_request(member)}
  end

  def refuse(:"policy_request.withdraw", _ctx) do
    %{operator: operator} = client_with_admin()
    {:ok, request} = send_policy_request(operator.scope)
    %{scope: member} = member_fixture(operator.scope, :member)
    before = entries()
    {before, PolicyRequests.withdraw(member, request.id)}
  end

  # The operator's owner, who reads the client and answers nothing there.
  def refuse(action, _ctx)
      when action in [:"policy_request.accept", :"policy_request.decline"] do
    %{operator: operator, client: client} = client_with_admin()
    {:ok, request} = send_policy_request(operator.scope)
    [answer] = request.answers
    before = entries()

    {before,
     case action do
       :"policy_request.accept" ->
         PolicyRequests.accept(client.scope, answer.id, [client.workspace.id])

       :"policy_request.decline" ->
         PolicyRequests.decline(client.scope, answer.id, nil)
     end}
  end

  # Anywhere but in the instance organisation, the instance actions are not found.
  def refuse(action, %{scope: scope})
      when action in [:"instance.create_organisation", :"instance.create_operator"] do
    kind = if action == :"instance.create_operator", do: "operator", else: "organisation"
    before = entries()
    {before, Operators.create_organisation(scope, %{"name" => "Acme", "kind" => kind})}
  end

  # An operator with clients stays an operator.
  def refuse(:"instance.change_kind", _ctx) do
    admin = instance_admin_fixture()
    operator = operator_fixture()
    client_fixture(operator.scope)
    before = entries()

    {before, Operators.change_kind(admin.instance_scope, operator.organisation.id, :organisation)}
  end

  # A slug that is not the organisation's.
  def refuse(:"instance.purge_organisation", _ctx) do
    admin = instance_admin_fixture()
    %{organisation: organisation} = sign_up_fixture()
    before = entries()
    {before, Deletion.purge_on_request(admin.instance_scope, organisation.id, "not-the-slug")}
  end

  # An admin it was not offered to.
  def refuse(:"organisation.accept_transfer", %{scope: scope}) do
    instance_admin = instance_admin_fixture()
    %{membership: membership} = member_fixture(scope, :admin)
    %{scope: other} = member_fixture(scope, :admin)
    {:ok, _} = Suspensions.suspend_account(instance_admin.instance_scope, scope.user.id)

    {:ok, _} =
      Transfers.arbitrate(
        instance_admin.instance_scope,
        scope.organisation.id,
        membership.id,
        "The owner is away."
      )

    before = entries()
    {before, Transfers.accept(other)}
  end

  # An admin of the operator: accepting a client is its owners'.
  def refuse(:"client.accept", _ctx) do
    operator = operator_fixture()
    %{scope: operator_admin} = member_fixture(operator.scope, :admin)
    offered = sign_up_fixture()
    {:ok, _} = Transfers.offer_to_operator(offered.scope, operator.organisation.slug)
    before = entries()
    {before, Transfers.accept_client(operator_admin, offered.organisation.id)}
  end

  # An instance admin does not suspend their own account.
  def refuse(:"instance.suspend_account", _ctx) do
    admin = instance_admin_fixture()
    before = entries()
    {before, Suspensions.suspend_account(admin.instance_scope, admin.user.id)}
  end

  # Anywhere but in the instance organisation, an account is not activated.
  def refuse(:"instance.activate_account", %{scope: scope}) do
    admin = instance_admin_fixture()
    %{user: user} = sign_up_fixture()
    {:ok, _} = Suspensions.suspend_account(admin.instance_scope, user.id)
    before = entries()
    {before, Suspensions.activate_account(scope, user.id)}
  end

  # The instance organisation is never suspended.
  def refuse(:"instance.suspend_organisation", _ctx) do
    admin = instance_admin_fixture()
    before = entries()
    {before, Suspensions.suspend_organisation(admin.instance_scope, instance_organisation().id)}
  end

  # A suspended organisation's own owner does not activate it.
  def refuse(:"instance.activate_organisation", %{scope: scope}) do
    admin = instance_admin_fixture()
    {:ok, _} = Suspensions.suspend_organisation(admin.instance_scope, scope.organisation.id)
    before = entries()
    {before, Suspensions.activate_organisation(scope, scope.organisation.id)}
  end

  # An organisation with no operator and an owner who may act is not the arbiter's.
  def refuse(:"instance.transfer", %{scope: scope}) do
    admin = instance_admin_fixture()
    %{membership: membership} = member_fixture(scope, :admin)
    before = entries()

    {before,
     Transfers.arbitrate(admin.instance_scope, scope.organisation.id, membership.id, "Stuck.")}
  end

  # A grant the instance does not have to give; one above the operator's.
  def refuse(:"instance.grant_features", %{scope: scope}) do
    admin = instance_admin_fixture()
    before = entries()

    {before,
     Grants.set_organisation(admin.instance_scope, scope.organisation.id, ["no_such_feature"])}
  end

  # An instance admin whose sign-in is no longer recent signs in again first.
  def refuse(:"instance.change_sign_up", _ctx) do
    admin = instance_admin_fixture()
    old = DateTime.add(DateTime.utc_now(), -21, :minute)
    scope = admin.instance_scope
    scope = put_in(scope.user.authenticated_at, old)
    before = entries()
    {before, ApiaryPro.SignUp.save(scope, %{"operators" => "open"})}
  end

  # The adoption is the instance's, which nobody refuses: rolled back with the transaction
  # it runs in, it leaves no entry, since it writes its entries in it.
  def refuse(:"instance.adopt", _ctx) do
    core_organisation!()
    before = entries()

    {before,
     Apiary.Repo.transaction(fn ->
       :ok = ApiaryPro.Adoption.run()
       Apiary.Repo.rollback(:rolled_back)
     end)}
  end

  def refuse(:"client.grant_features", %{scope: scope}) do
    before = entries()
    {before, Grants.set_client(scope, Ecto.UUID.generate(), ["observability"])}
  end

  # The organisation's policy is an owner's: an admin reads it and is refused each change.
  def refuse(:"organisation_policy.edit", %{scope: scope}) do
    %{scope: admin} = member_fixture(scope, :admin)
    before = entries()
    {before, OrganisationPolicy.deny(admin, %{host: "paste.example"})}
  end

  def refuse(:"organisation_policy.set_floor", %{scope: scope}) do
    %{scope: admin} = member_fixture(scope, :admin)
    before = entries()
    {before, OrganisationPolicy.set_floor(admin, true)}
  end

  def refuse(:"organisation_policy.set_switch", %{scope: scope}) do
    %{scope: admin} = member_fixture(scope, :admin)
    before = entries()
    {before, OrganisationPolicy.set_switch(admin, false)}
  end

  # The organisation's variables are an owner's and an admin's: a member is refused.
  def refuse(:"organisation_variable.edit", %{scope: scope}) do
    %{scope: member} = member_fixture(scope, :member)
    before = entries()
    {before, OrganisationVariables.create(member, %{name: "LOG_LEVEL", value: "debug"})}
  end

  # A member where the change is an owner's or an admin's: a workspace access, an
  # organisation's transfer to an operator and its withdrawal.
  def refuse(action, ctx),
    do: refuse_as_member(action, ctx, &prepare(action, &1), &attempt(action, &1, &2))

  defp prepare(:"workspace_access.add", %{scope: scope}),
    do: {member_fixture(scope).membership, workspace_fixture(scope.organisation)}

  defp prepare(:"workspace_access.remove", %{scope: scope}),
    do: {member_fixture(scope).membership, scope.workspace}

  defp prepare(:"organisation.transfer", _ctx), do: operator_fixture().organisation

  # The owner's organisation offered to an operator, pending.
  defp prepare(:"organisation.withdraw_transfer", %{scope: scope}) do
    operator = operator_fixture()
    {:ok, _} = Transfers.offer_to_operator(scope, operator.organisation.slug)
    nil
  end

  defp attempt(:"workspace_access.add", scope, {membership, workspace}),
    do: ApiaryPro.WorkspaceAccess.add(scope, membership.id, workspace.id)

  defp attempt(:"workspace_access.remove", scope, {membership, workspace}),
    do: ApiaryPro.WorkspaceAccess.remove(scope, membership.id, workspace.id)

  defp attempt(:"organisation.transfer", scope, operator),
    do: Transfers.offer_to_operator(scope, operator.slug)

  defp attempt(:"organisation.withdraw_transfer", scope, _), do: Transfers.withdraw(scope)

  # A client of a fresh operator, with its owner and an admin of its own: the operator's
  # fixture, the client's, with the operator's owner's scope in it, and the admin's.
  defp client_with_admin do
    operator = operator_fixture()
    client = client_fixture(operator.scope)
    %{operator: operator, client: client, admin: client_member_fixture(client)}
  end

  # A policy request of the scope's operator to its clients, a host to allow.
  defp send_policy_request(scope) do
    PolicyRequests.send_request(scope, %{
      "changes" => %{
        "rules" => [%{"change" => "rule_added", "action" => "allow", "host" => "api.example"}]
      },
      "note" => "The harness calls it."
    })
  end

  # An organisation as the core's edition created it, with its workspace and its owner,
  # and no tenant: what `ApiaryPro.Adoption` adopts.
  defp core_organisation! do
    user = Apiary.AccountsFixtures.user_fixture()
    now = DateTime.utc_now()
    unique = System.unique_integer([:positive])

    organisation =
      Apiary.Repo.insert!(%Apiary.Organisations.Organisation{
        name: "Core #{unique}",
        slug: "core-#{unique}"
      })

    Apiary.Repo.insert!(%Apiary.Organisations.Workspace{
      organisation_id: organisation.id,
      name: "Main",
      slug: "main",
      type: "qory.software"
    })

    Apiary.Repo.insert!(%Apiary.Organisations.Membership{
      organisation_id: organisation.id,
      user_id: user.id,
      level: :owner,
      inserted_at: now,
      updated_at: now
    })

    organisation
  end
end
