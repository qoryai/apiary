defmodule ApiaryPro.OperatorsFixtures do
  @moduledoc """
  Test helpers for operators and the instance admins, created the way the product creates
  them: an instance admin by the release command's function, an operator by an instance
  admin's change of kind (`ApiaryPro.Operators`). No code in the product makes an
  organisation an operator's client any more: `client_fixture/2` writes the tenant row
  directly. An operator needs `managed_organisations`: a test that makes one runs where the
  instance has it (`@tag needs: :managed_organisations`, or `with_features:`).
  """

  import Apiary.OrganisationsFixtures
  import Ecto.Query, only: [from: 2]

  alias Apiary.{Organisations, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.Organisation
  alias ApiaryPro.Operators

  @doc """
  A fresh person made an instance admin, an owner of the instance organisation: what
  `sign_up_fixture/1` returns for their own organisation, and `instance_scope`, their scope
  in the instance organisation, as its page's path loads it.
  """
  def instance_admin_fixture do
    signed_up = sign_up_fixture()
    {:ok, _} = Organisations.grant_instance_admin(signed_up.user)
    Map.put(signed_up, :instance_scope, scope_in(signed_up.user, instance_organisation()))
  end

  @doc """
  The suite's instance admin (`Apiary.OrganisationsFixtures.instance_admin_scope/0`): `user`,
  their account, and `instance_scope`, their scope in the instance organisation, as
  `instance_admin_fixture/0` returns them. Nothing is written, so an async test acts with it.
  """
  def suite_instance_admin do
    user = instance_admin_scope().user
    %{user: user, instance_scope: scope_in(user, instance_organisation())}
  end

  @doc """
  The suite's instance organisation made an operator by the instance admin `admin`
  (`instance_admin_fixture/0`), inside the test's sandbox, where the suite's first sign-up
  made it an organisation, as on an instance without `managed_organisations`; left as it
  is where it is one already. The admin's scope in it after, as its page's path loads it.
  The test runs where the instance has the feature.
  """
  def make_instance_organisation_an_operator(%{user: user, instance_scope: scope}) do
    here = scope.organisation

    unless ApiaryPro.Tenants.operator?(here),
      do: {:ok, _} = Operators.change_kind(scope, here.id, :operator)

    scope_in(user, instance_organisation())
  end

  @doc """
  A fresh organisation made an operator by the suite's instance admin
  (`Apiary.OrganisationsFixtures.instance_admin_scope/0`), with its owner: what
  `sign_up_fixture/1` returns, the organisation and the scope as they are after.
  """
  def operator_fixture(attrs \\ %{}) do
    signed_up = sign_up_fixture(attrs)
    # The suite's committed admin: `instance_admin_fixture/0` locks the instance
    # organisation's owner memberships until the test ends.
    admin = suite_instance_admin().instance_scope
    {:ok, operator} = Operators.change_kind(admin, signed_up.organisation.id, :operator)

    %{signed_up | organisation: operator, scope: scope_in(signed_up.user, operator)}
  end

  @doc """
  An organisation made a client of the scope's operator, an organisation of the kind
  `organisation` whose tenant's `operator_id` is the operator, written directly to its
  tenant row, since no code in the product makes a client any more. Its first person signs
  up and creates it with its first workspace, Main, which the operator operates
  (`operate_fixture/2`); while `ApiaryPro.Flags.operator_infrastructure?/0` is on, that
  person is its admin, as the operator's invitation made them. The client is granted what
  its operator has (`ApiaryPro.Grants.written_out/3`). The client, its workspace, `scope`,
  the operator's person's scope in it, reached through the operator, and `owner`, what
  `sign_up_fixture/1` returns for the first person, `scope` theirs in Main.
  """
  def client_fixture(%Scope{} = operator_scope, name \\ nil) do
    name = name || "Client #{System.unique_integer([:positive])}"
    owner = sign_up_fixture(%{organisation_name: name})
    %{organisation: organisation, workspace: workspace} = owner
    operator = operator_scope.organisation

    {1, _} =
      Repo.update_all(
        from(t in ApiaryPro.Tenants.Tenant, where: t.organisation_id == ^organisation.id),
        set: [kind: :organisation, operator_id: operator.id, operator_since: DateTime.utc_now()]
      )

    client = ApiaryPro.Tenants.put(Repo.get!(Organisation, organisation.id))
    {:ok, _features} = ApiaryPro.Grants.written_out(client, {:client, operator})

    if ApiaryPro.Flags.operator_infrastructure?() do
      {1, _} =
        Repo.update_all(
          from(m in Apiary.Organisations.Membership, where: m.id == ^owner.membership.id),
          set: [level: :admin]
        )
    end

    operate_fixture(workspace, operator)

    %{
      organisation: client,
      workspace: workspace,
      scope: scope_in(operator_scope.user, client, workspace),
      owner: %{owner | scope: scope_in(owner.user, client, workspace)}
    }
  end

  @doc """
  The operator `operator` made the operator of `workspace`: a row of `workspace_operators`
  inserted (`ApiaryPro.Operators.WorkspaceOperator`), since no code in the product starts
  a link. The link.
  """
  def operate_fixture(%Apiary.Organisations.Workspace{} = workspace, %Organisation{} = operator) do
    workspace
    |> ApiaryPro.Operators.WorkspaceOperator.create_changeset(operator.id, DateTime.utc_now())
    |> Repo.insert!()
  end

  @doc """
  The client with its model chain set to `chain`, `:organisation` or `:operator`, written
  directly to its tenant row, and the scopes of the client's owner and the operator's
  person in it made again, since a scope carries the switch as it was when it was made.
  """
  def model_chain_fixture(%Scope{} = _operator_scope, client, chain)
      when chain in [:organisation, :operator] do
    {1, _} =
      Repo.update_all(
        from(t in ApiaryPro.Tenants.Tenant, where: t.organisation_id == ^client.organisation.id),
        set: [model_chain: chain]
      )

    organisation = ApiaryPro.Tenants.put(Repo.get!(Organisation, client.organisation.id))

    %{
      client
      | organisation: organisation,
        scope: scope_in(client.scope.user, organisation, client.workspace),
        owner: %{
          client.owner
          | scope: scope_in(client.owner.user, organisation, client.workspace)
        }
    }
  end

  @doc """
  A person of the client's own, at `level`, admin by default: invited by the client's
  owner, whose scope `client_fixture/2` returned, and made `level` by them. What
  `member_fixture/2` returns, `scope` theirs in the client's workspace.
  """
  def client_member_fixture(
        %{organisation: client, workspace: workspace, owner: %{scope: scope}},
        level \\ :admin
      ) do
    person = member_fixture(scope, level)
    %{person | scope: scope_in(person.user, client, workspace)}
  end

  @doc """
  The scope of `user` in `organisation`, and `workspace` of it when given, as a page of
  its path loads it; nil where they do not reach it.
  """
  def scope_in(user, %Organisation{} = organisation, workspace \\ nil) do
    case Organisations.resolve_scope(
           Scope.for_user(user),
           organisation.slug,
           workspace && workspace.slug
         ) do
      {:ok, scope} -> scope
      :error -> nil
    end
  end

  @doc "The suite's instance organisation, as it is now."
  def instance_organisation, do: ApiaryPro.Organisations.instance_organisation()

  @doc """
  The tenant of `organisation`, or of the organisation of that id, as the database has it
  now (`ApiaryPro.Tenants.Tenant`).
  """
  def tenant_of(%Organisation{id: id}), do: tenant_of(id)
  def tenant_of(id) when is_binary(id), do: Apiary.Repo.get!(ApiaryPro.Tenants.Tenant, id)
end
