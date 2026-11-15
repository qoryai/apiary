defmodule ApiaryPro.AuditChanges do
  @moduledoc """
  AuditChanges is the edition's module of changes of the audit test (`Apiary.AuditCase`): each of
  the edition's audited actions made the way the product makes it, what it needs first, then the
  trail as it is (`before`), then the change; and the same change refused, `{the trail
  before the attempt, the attempt's answer}`. A change that leaves an entry in two
  organisations is looked for in the organisation of the scope `make/2` returns.
  """

  import Apiary.AuditCase, only: [entries: 0, in_trail: 2, refuse_as_member: 4]
  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.Access
  alias Apiary.Accounts.Scope

  alias ApiaryPro.{
    Deletion,
    Grants,
    Operators,
    OrganisationPolicy,
    OrganisationVariables,
    Suspensions,
    Transfers
  }

  @doc "actions/0 is the edition's audited actions, each made and refused below."
  @spec actions() :: [Access.action()]
  def actions do
    [
      :"workspace_access.add",
      :"workspace_access.remove",
      :"organisation.withdraw_transfer",
      :"organisation.accept_transfer",
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

  # The arbiter's offer lapses when the owner's account is activated again: an entry in
  # the organisation, by the instance admin who activates it, beside the activation's
  # entry in the instance organisation.
  def make(:"organisation.withdraw_transfer", %{scope: scope}) do
    instance_admin = instance_admin_fixture()
    %{membership: membership} = member_fixture(scope, :admin)
    {:ok, _} = Suspensions.suspend_account(instance_admin.instance_scope, scope.user.id)

    {:ok, transfer} =
      Transfers.arbitrate(
        instance_admin.instance_scope,
        scope.organisation.id,
        membership.id,
        "The owner is away."
      )

    before = entries()
    {:ok, _} = Suspensions.activate_account(instance_admin.instance_scope, scope.user.id)
    activated = in_trail(entries() -- before, instance_admin.instance_scope.organisation)

    %{
      scope: %Scope{user: instance_admin.user, organisation: scope.organisation},
      subject: {"transfer", transfer.id},
      before: before ++ [activated]
    }
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
    %{operated: operated, admin: admin} = operated_with_admin()
    {:ok, _} = Suspensions.suspend_account(instance_admin.instance_scope, operated.owner.user.id)
    before = entries()

    {:ok, transfer} =
      Transfers.arbitrate(
        instance_admin.instance_scope,
        operated.organisation.id,
        admin.membership.id,
        "The owner is away."
      )

    scope = %Scope{user: instance_admin.user, organisation: operated.organisation}
    %{scope: scope, subject: {"transfer", transfer.id}, before: before}
  end

  # Features: an instance admin's grant is the organisation's entry.
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

  # The organisation's policy: an owner's change, one entry on the organisation; the
  # workspaces it renders again leave entries of `security_policy.edit` in the trail
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
  # Anywhere but in the instance organisation, the instance actions are not found.
  def refuse(action, %{scope: scope})
      when action in [:"instance.create_organisation", :"instance.create_operator"] do
    kind = if action == :"instance.create_operator", do: "operator", else: "organisation"
    before = entries()
    {before, Operators.create_organisation(scope, %{"name" => "Acme", "kind" => kind})}
  end

  # An operator that operates a workspace stays an operator.
  def refuse(:"instance.change_kind", _ctx) do
    admin = instance_admin_fixture()
    operator = operator_fixture()
    operated_fixture(operator.scope)
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

  # Only an instance admin's activation of the owner withdraws the arbiter's offer: an
  # admin of the organisation activates nobody, and the offer stays.
  def refuse(:"organisation.withdraw_transfer", %{scope: scope}) do
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
    {before, Suspensions.activate_account(admin, scope.user.id)}
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

  # A member where the change is an admin's: a workspace access.
  def refuse(action, ctx),
    do: refuse_as_member(action, ctx, &prepare(action, &1), &attempt(action, &1, &2))

  defp prepare(:"workspace_access.add", %{scope: scope}),
    do: {member_fixture(scope).membership, workspace_fixture(scope.organisation)}

  defp prepare(:"workspace_access.remove", %{scope: scope}),
    do: {member_fixture(scope).membership, scope.workspace}

  defp attempt(:"workspace_access.add", scope, {membership, workspace}),
    do: ApiaryPro.WorkspaceAccess.add(scope, membership.id, workspace.id)

  defp attempt(:"workspace_access.remove", scope, {membership, workspace}),
    do: ApiaryPro.WorkspaceAccess.remove(scope, membership.id, workspace.id)

  # An organisation whose workspace a fresh operator operates, with its owner and an admin:
  # the operator's fixture, the organisation's, with the operator's owner's scope in it,
  # and the admin's.
  defp operated_with_admin do
    operator = operator_fixture()
    operated = operated_fixture(operator.scope)
    %{operator: operator, operated: operated, admin: organisation_member_fixture(operated)}
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
