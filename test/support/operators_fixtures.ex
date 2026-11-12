defmodule ApiaryPro.OperatorsFixtures do
  @moduledoc """
  Test helpers for operators, their clients and the instance admins, created the way the
  product creates them: an instance admin by the release command's function, an operator
  by an instance admin's change of kind, a client by its operator's owner
  (`ApiaryPro.Operators`). An operator needs `managed_organisations`: a test that makes one
  runs where the instance has it (`@tag needs: :managed_organisations`, or
  `with_features:`).
  """

  import Apiary.OrganisationsFixtures
  import Ecto.Query, only: [from: 2]

  alias Apiary.{AccountsFixtures, Organisations, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Membership, Organisation}
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
  A client of the scope's operator, created by the scope's person, an owner or an admin
  of it, with its first owner, whom the operator invited and who signed up with the
  invitation, and its first workspace, Main, which the client starts without
  (`first_workspace_fixture/3`): the client, its workspace, `scope`, the operator's
  person's scope in it, reached through the operator, which reads and changes nothing,
  and `owner`, what `sign_up_fixture/1` returns for the owner, `scope` theirs in Main.
  """
  def client_fixture(%Scope{} = operator_scope, name \\ nil) do
    name = name || "Client #{System.unique_integer([:positive])}"
    email = AccountsFixtures.unique_user_email()
    {created, token} = create_client_fixture(operator_scope, %{"name" => name, "email" => email})
    %{organisation: client} = created

    owner = sign_up_fixture(%{email: email, invitation_token: token})
    workspace = first_workspace_fixture(operator_scope, client, owner)

    %{
      organisation: client,
      workspace: workspace,
      scope: scope_in(operator_scope.user, client, workspace),
      owner: %{owner | scope: scope_in(owner.user, client, workspace)}
    }
  end

  @doc """
  The first workspace, Main, of the client `client`, which has none after
  `ApiaryPro.Operators.create_client/3`, made as the overview's kind cards make it
  (`Apiary.Organisations.create_first_workspace/2`) by whom `workspace.create` allows: the
  client's first person, `first` (what `sign_up_fixture/1` returns), or, while
  `ApiaryPro.Flags.operator_infrastructure?/0` is on, an owner of the operator, as the
  scope `operator_scope` is in the operator. The workspace.
  """
  def first_workspace_fixture(%Scope{organisation: operator} = _operator_scope, client, first) do
    maker =
      if ApiaryPro.Flags.operator_infrastructure?() do
        owner =
          Repo.one!(
            from m in Membership,
              where: m.organisation_id == ^operator.id and m.level == :owner,
              order_by: [asc: m.inserted_at, asc: m.id],
              limit: 1,
              preload: [:user]
          )

        scope_in(owner.user, client)
      else
        scope_in(first.user, client)
      end

    {:ok, workspace} =
      Organisations.create_first_workspace(maker, %{
        "domain" => Apiary.Lingo.Domain.default().name()
      })

    workspace
  end

  @doc """
  `ApiaryPro.Operators.create_client/3` by the scope's person, with `attrs`, and the URL
  token of the invitation of the client's first owner: `{created, token}`. The client has
  no workspace, and the invitation is to the organisation alone.
  """
  def create_client_fixture(%Scope{} = operator_scope, attrs) do
    parent = self()
    ref = make_ref()

    {:ok, %{sent: {:ok, _invitation}} = created} =
      Operators.create_client(operator_scope, attrs, fn token ->
        send(parent, {ref, token})
        "http://localhost/invitations/#{token}"
      end)

    receive do
      {^ref, token} -> {created, token}
    after
      0 -> raise "create_client did not call the URL function"
    end
  end

  @doc """
  The client with its model chain set to `chain`, `:organisation` or `:operator`, by the
  person of `operator_scope` (`ApiaryPro.Operators.set_model_chain/3`, with the operator
  owning its clients), and the scopes of the client's owner and the operator's person in it
  made again, since a scope carries the switch as it was when it was made.
  """
  def model_chain_fixture(%Scope{} = operator_scope, client, chain) do
    {:ok, organisation} =
      Operators.set_model_chain(operator_scope, client.organisation.id, chain)

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
