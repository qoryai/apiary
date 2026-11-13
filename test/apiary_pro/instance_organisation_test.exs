defmodule ApiaryPro.InstanceOrganisationTest do
  @moduledoc """
  The instance organisation on an instance without `managed_organisations`: the instance's
  first sign-up makes it an organisation like any other
  (`ApiaryPro.Tenants.first_sign_up_kind/0`), whose owners are the instance admins, who
  read every other organisation and take every instance action the instance has from it,
  and in which no operator's action is found; once the instance has the feature, an
  instance admin makes it an operator, and an organisation again while it has no clients.
  """
  # Not async: the features are the node's, and each test takes the flag off the suite's
  # instance organisation inside its sandbox, for a first sign-up of its own.
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
  import ApiaryPro.OperatorsFixtures, only: [client_fixture: 1, scope_in: 2, tenant_of: 1]

  alias Apiary.{Access, Features}
  alias Apiary.Organisations.Organisation
  alias ApiaryPro.{Deletion, Grants, Operators, Suspensions, Tenants, Transfers}
  alias ApiaryPro.Tenants.Tenant
  alias ApiaryPro.Transfers.Transfer

  @moduletag with_features: Features.all() -- [:managed_organisations]

  # What an operator does, found in an operator alone.
  @operator_actions [
    :"client.read",
    :"client.create",
    :"client.invite_owner",
    :"client.accept",
    :"client.grant_features",
    :"client.drop",
    :"client.delete"
  ]

  setup do
    Apiary.EditionKit.hide_instance_organisation()
    first = sign_up_fixture()
    %{first: first, scope: scope_in(first.user, first.organisation)}
  end

  # The instance's features switched for the rest of the test, and back after.
  defp features_on!(features) do
    previous = Application.get_env(:apiary, :features)
    Application.put_env(:apiary, :features, features)
    on_exit(fn -> Application.put_env(:apiary, :features, previous) end)
  end

  test "the first sign-up makes it an organisation, and its owner an instance admin",
       %{first: first, scope: scope} do
    assert Tenants.first_sign_up_kind() == :organisation

    assert %Tenant{kind: :organisation, instance_organisation: true, operator_id: nil} =
             tenant_of(first.organisation)

    assert Tenants.instance_organisation_id() == first.organisation.id
    assert Apiary.Edition.instance_organisation_id() == first.organisation.id
    assert Access.instance_admin?(scope)
    assert scope.reach == nil

    # No organisation is shown the switch of the whole instance.
    assert ApiaryPro.Features.of(scope.organisation) ==
             Features.enabled() -- [:feature_visibility]
  end

  test "no operator's action is found in it, whatever the instance has", %{
    first: first,
    scope: scope
  } do
    for action <- @operator_actions do
      assert Access.check(scope, action, scope.organisation) == {:error, :not_found}
    end

    assert {:error, :not_found} = Operators.list_clients(scope)
    assert Operators.count_clients(scope) == 0

    # The feature on, the kind still answers: an organisation has no clients.
    features_on!(Features.all())
    scope = scope_in(first.user, first.organisation)

    for action <- @operator_actions do
      assert Access.check(scope, action, scope.organisation) == {:error, :not_found}
    end

    assert Access.can?(scope, :"instance.change_kind", scope.organisation)
  end

  test "its owners read every other organisation as the instance admins", %{first: first} do
    home = sign_up_fixture()
    reader = scope_in(first.user, home.organisation)

    assert reader.reach == :instance
    assert Access.reader(reader) == :instance
    assert Access.can?(reader, :"audit.read", home.organisation)
    refute Access.can?(reader, :"organisation.rename", home.organisation)

    assert Access.authorize(reader, :"organisation.rename", home.organisation) ==
             {:error, :forbidden}

    # Its admins and members reach it alone.
    %{user: admin} = member_fixture(scope_in(first.user, first.organisation), :admin)
    refute Access.instance_admin?(Apiary.Accounts.Scope.for_user(admin))
    assert scope_in(admin, home.organisation) == nil
  end

  test "its owners take every instance action the instance has, and none on it", %{
    first: first,
    scope: scope
  } do
    home = sign_up_fixture()
    %{membership: home_admin} = member_fixture(home.scope, :admin)
    other = sign_up_fixture()

    # instance.read: every organisation, the instance's own first.
    assert {:ok, [own | rows]} = Operators.list_organisations(scope)
    assert own.organisation.id == first.organisation.id
    assert Tenants.kind(own.organisation) == :organisation
    assert Enum.any?(rows, &(&1.organisation.id == home.organisation.id))
    assert {:ok, [_ | _]} = Suspensions.list_accounts(scope)

    # instance.create_organisation, and no operator without the feature.
    assert {:ok, %{organisation: created}} =
             Operators.create_organisation(scope, %{"name" => "Newco", "kind" => "organisation"})

    assert tenant_of(created).kind == :organisation

    assert {:error, :not_found} =
             Operators.create_organisation(scope, %{"name" => "Opco", "kind" => "operator"})

    assert {:error, :not_found} = Operators.change_kind(scope, home.organisation.id, :operator)

    # instance.grant_features: what an organisation with no operator keeps.
    assert {:ok, kept} = Grants.set_organisation(scope, home.organisation.id, [:observability])
    assert :observability in kept
    refute :security in kept

    # instance.suspend_organisation and instance.activate_organisation.
    assert {:ok, suspended} = Suspensions.suspend_organisation(scope, home.organisation.id)
    assert Tenants.suspended?(suspended)
    assert {:ok, activated} = Suspensions.activate_organisation(scope, home.organisation.id)
    refute Tenants.suspended?(activated)

    # instance.suspend_account, then the arbiter's instance.transfer to an admin of the
    # organisation whose owner it was, then instance.activate_account.
    assert {:ok, %{user: _owner}} = Suspensions.suspend_account(scope, home.user.id)

    assert {:ok, %Transfer{arbitrated: true}} =
             Transfers.arbitrate(scope, home.organisation.id, home_admin.id, "The owner is away.")

    assert {:ok, _user} = Suspensions.activate_account(scope, home.user.id)

    # instance.purge_organisation.
    assert {:ok, :purged} =
             Deletion.purge_on_request(scope, other.organisation.id, other.organisation.slug)

    refute Repo.get(Organisation, other.organisation.id)

    # None of them on the instance organisation itself.
    here = first.organisation.id
    assert {:error, :forbidden} = Suspensions.suspend_organisation(scope, here)
    assert {:error, :forbidden} = Grants.set_organisation(scope, here, [:observability])
    assert {:error, :forbidden} = Transfers.arbitrate(scope, here, home_admin.id, "No.")

    assert {:error, :forbidden} =
             Deletion.purge_on_request(scope, here, first.organisation.slug)

    assert Repo.get(Organisation, here)
  end

  test "once the instance has managed_organisations, an instance admin makes it an operator, and back",
       %{first: first} do
    features_on!(Features.all())
    here = first.organisation.id
    scope = scope_in(first.user, first.organisation)

    # An organisation of no operator, which is never offered to one: it stays the
    # instance's.
    assert {:ok, %{organisation: opco}} =
             Operators.create_organisation(scope, %{"name" => "Opco", "kind" => "operator"})

    assert {:error, :forbidden} = Transfers.offer_to_operator(scope, opco.slug)

    assert {:ok, operator} = Operators.change_kind(scope, here, :operator)
    assert %Tenant{kind: :operator, instance_organisation: true} = tenant_of(operator)

    # Its Clients page and its clients, as any operator's.
    scope = scope_in(first.user, operator)
    assert Access.can?(scope, :"client.read", scope.organisation)
    assert Access.can?(scope, :"instance.read", scope.organisation)
    client = client_fixture(scope)
    assert {:ok, [_row]} = Operators.list_clients(scope)
    assert client.scope.reach |> elem(0) == :operator

    # An organisation again once it has no clients, the rule of every operator.
    assert {:error, :has_clients} = Operators.change_kind(scope, here, :organisation)
    {:ok, _} = Transfers.drop(scope, client.organisation.id, client.organisation.name)
    assert {:ok, organisation} = Operators.change_kind(scope, here, :organisation)
    assert %Tenant{kind: :organisation, instance_organisation: true} = tenant_of(organisation)
  end
end
