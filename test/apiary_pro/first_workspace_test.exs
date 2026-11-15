defmodule ApiaryPro.FirstWorkspaceTest do
  @moduledoc """
  The first workspace of an organisation the edition creates. A person's New organisation and
  an instance admin's New organisation create it with no workspace, for the kind cards of its
  overview to make. The line about who waits for the first workspace
  (`c:Apiary.Edition.first_workspace_waiting_line/1`) names a client's owners and admins.
  """
  # Not async: the sign-up settings and the features are the node's.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures
  import ApiaryPro.SignUpFixtures, only: [open!: 1]

  alias Apiary.Organisations
  alias Apiary.Organisations.Membership
  alias ApiaryPro.{Flags, Operators, WorkspaceAccess}

  @moduletag with_features: Apiary.Features.all()

  setup do: Flags.put_operator_infrastructure(false)

  # An organisation with no workspace, created by a person's New organisation, made a client
  # of `operator` by writing its tenant row, and its first person at `level`: the client, as
  # the tenant has it, and that person's account.
  defp client_without_workspace(operator, level) do
    open!([:organisation])
    %{scope: scope} = sign_up_fixture()

    {:ok, %{organisation: organisation, membership: membership}} =
      ApiaryPro.Organisations.create_organisation(scope, %{"name" => "Acme"})

    {1, _} =
      Repo.update_all(
        from(t in ApiaryPro.Tenants.Tenant, where: t.organisation_id == ^organisation.id),
        set: [operator_id: operator.organisation.id, operator_since: DateTime.utc_now()]
      )

    {1, _} =
      Repo.update_all(from(m in Membership, where: m.id == ^membership.id), set: [level: level])

    client = ApiaryPro.Tenants.put(Repo.get!(Apiary.Organisations.Organisation, organisation.id))
    %{organisation: client, user: scope.user}
  end

  describe "the organisations the edition creates" do
    test "a person's New organisation has no workspace, and an owner" do
      open!([:organisation])
      %{scope: scope} = sign_up_fixture()

      assert {:ok, %{organisation: organisation, workspace: nil, membership: membership}} =
               ApiaryPro.Organisations.create_organisation(scope, %{"name" => "Kestrel Works"})

      assert membership.level == :owner
      refute Organisations.has_workspace?(organisation)
    end

    test "an instance admin's New organisation has no workspace, and the admin as owner" do
      %{instance_scope: scope} = instance_admin_fixture()

      assert {:ok, %{organisation: organisation, workspace: nil, membership: membership}} =
               Operators.create_organisation(scope, %{
                 "name" => "Tern Ops",
                 "kind" => "organisation"
               })

      assert membership.level == :owner
      assert membership.user_id == scope.user.id
      refute Organisations.has_workspace?(organisation)
    end

    test "with the flag on, a client's admin makes the first workspace as an owner does" do
      Flags.put_operator_infrastructure(true)
      operator = operator_fixture()
      %{organisation: client, user: first} = client_without_workspace(operator, :admin)
      refute Repo.exists?(from a in WorkspaceAccess.Row, where: a.user_id == ^first.id)

      # The client's admin makes it from the kind card, named after the kind.
      assert {:ok, workspace} =
               Organisations.create_workspace_of_kind(
                 scope_in(first, client),
                 Apiary.Lingo.Domain.default(),
                 :first
               )

      assert workspace.name == Apiary.Lingo.Domain.default().type_name()
      assert Organisations.has_workspace?(client)

      # The operator operates none of its workspaces: its owner does not reach the client.
      assert scope_in(operator.user, client) == nil
    end

    test "with the flag on, the operator's people do not reach a client with no workspace they operate" do
      Flags.put_operator_infrastructure(true)
      operator = operator_fixture()
      admin = member_fixture(operator.scope, :admin)
      %{organisation: client} = client_without_workspace(operator, :owner)

      for user <- [operator.user, admin.user], do: assert(scope_in(user, client) == nil)

      refute Organisations.has_workspace?(client)
    end
  end

  describe "the lines about the first workspace" do
    test "are the core's in an organisation that is no client" do
      %{organisation: organisation} = sign_up_fixture()
      Flags.put_operator_infrastructure(true)

      assert Apiary.Edition.first_workspace_waiting_line(organisation) ==
               "An owner of #{organisation.name} creates the first workspace."
    end

    test "name a client's owners and admins, with the flag on or off" do
      operator = operator_fixture()
      %{organisation: client} = client_fixture(operator.scope)

      for flag <- [false, true] do
        Flags.put_operator_infrastructure(flag)

        assert Apiary.Edition.first_workspace_waiting_line(client) ==
                 "An owner or an admin of #{client.name} creates the first workspace."
      end
    end
  end
end
