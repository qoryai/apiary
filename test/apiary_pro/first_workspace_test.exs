defmodule ApiaryPro.FirstWorkspaceTest do
  @moduledoc """
  The first workspace of an organisation the edition creates. A person's New organisation, an
  instance admin's New organisation and an operator's New client create it with no
  workspace, for the kind cards of its overview to make; a client's first invitation is to
  the organisation alone. The line about who waits for the first workspace
  (`c:Apiary.Edition.first_workspace_waiting_line/1`) names a client's owners and admins,
  and the operator's owners while the operator owns its clients.
  """
  # Not async: the sign-up settings and the features are the node's.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures
  import ApiaryPro.SignUpFixtures, only: [open!: 1]

  alias Apiary.Audit.Entry
  alias Apiary.Organisations
  alias Apiary.Organisations.{Invitation, Membership}
  alias ApiaryPro.{Flags, Operators, WorkspaceAccess}

  @moduletag with_features: Apiary.Features.all()

  setup do: Flags.put_operator_infrastructure(false)

  defp entries(client, action),
    do: Repo.all(from e in Entry, where: e.organisation_id == ^client.id and e.action == ^action)

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

    test "an operator's New client has no workspace, and its first owner's invitation is to the organisation alone" do
      operator = operator_fixture()
      address = Apiary.AccountsFixtures.unique_user_email()

      {created, token} =
        create_client_fixture(operator.scope, %{"name" => "Acme", "email" => address})

      assert %{organisation: client, sent: {:ok, %Invitation{}}} = created
      refute Map.has_key?(created, :workspace)
      refute Organisations.has_workspace?(client)

      assert [%Invitation{email: ^address, workspace_id: nil}] =
               Repo.all(from i in Invitation, where: i.organisation_id == ^client.id)

      assert [%Entry{workspace_id: nil}] = entries(client, "client.invite_owner")

      # With the flag off, the person who accepts is the owner, and no workspace is theirs.
      first = sign_up_fixture(%{email: address, invitation_token: token})
      assert first.membership.level == :owner
      assert is_nil(first.workspace)
      refute Repo.exists?(from a in WorkspaceAccess.Row, where: a.user_id == ^first.user.id)
      refute Organisations.has_workspace?(client)

      # They make the first workspace, as the set-up page does.
      assert {:ok, workspace} =
               Organisations.create_first_workspace(scope_in(first.user, client), %{
                 "domain" => "software"
               })

      assert workspace.name == "Main"
    end

    test "with the flag on, the first person is the client's admin, who makes the first workspace as an owner does" do
      Flags.put_operator_infrastructure(true)
      operator = operator_fixture()
      address = Apiary.AccountsFixtures.unique_user_email()

      {created, token} =
        create_client_fixture(operator.scope, %{"name" => "Acme", "email" => address})

      assert %{organisation: client, sent: {:ok, %Invitation{workspace_id: nil}}} = created
      refute Organisations.has_workspace?(client)

      first = sign_up_fixture(%{email: address, invitation_token: token})
      assert first.membership.level == :admin
      refute Repo.exists?(from a in WorkspaceAccess.Row, where: a.user_id == ^first.user.id)

      # The client's admin makes it from the kind card, named after the kind.
      assert {:ok, workspace} =
               Organisations.create_workspace_of_kind(
                 scope_in(first.user, client),
                 Apiary.Lingo.Domain.default(),
                 :first
               )

      assert workspace.name == Apiary.Lingo.Domain.default().type_name()
      assert Organisations.has_workspace?(client)

      # An owner of the operator makes another, through the operator.
      assert {:ok, _other} =
               Organisations.create_workspace_of_kind(
                 scope_in(operator.user, client),
                 Apiary.Lingo.Domain.default(),
                 :any
               )
    end

    test "with the flag on, an admin of the operator may not make a client's first workspace" do
      Flags.put_operator_infrastructure(true)
      operator = operator_fixture()
      admin = member_fixture(operator.scope, :admin)

      {%{organisation: client}, _token} =
        create_client_fixture(operator.scope, %{
          "name" => "Acme",
          "email" => Apiary.AccountsFixtures.unique_user_email()
        })

      assert {:error, :forbidden} =
               Organisations.create_workspace_of_kind(
                 scope_in(admin.user, client),
                 Apiary.Lingo.Domain.default(),
                 :first
               )

      refute Organisations.has_workspace?(client)
    end
  end

  describe "accepting an invitation sent without a workspace" do
    test "grants no workspace access, does not raise, and the entry has no workspace" do
      operator = operator_fixture()

      {%{organisation: client}, token} =
        create_client_fixture(operator.scope, %{
          "name" => "Acme",
          "email" => Apiary.AccountsFixtures.unique_user_email()
        })

      user = Apiary.AccountsFixtures.user_fixture()

      assert {:ok, %Membership{level: :owner, organisation_id: organisation_id}} =
               Organisations.accept_invitation(user, token)

      assert organisation_id == client.id
      refute Repo.exists?(from a in WorkspaceAccess.Row, where: a.user_id == ^user.id)

      assert [%Entry{workspace_id: nil}] = entries(client, "invitation.accept")
    end
  end

  describe "the lines about the first workspace" do
    test "are the core's in an organisation that is no client" do
      %{organisation: organisation} = sign_up_fixture()
      Flags.put_operator_infrastructure(true)

      assert Apiary.Edition.first_workspace_waiting_line(organisation) ==
               "An owner of #{organisation.name} creates the first workspace."
    end

    test "name a client's owners and admins while the operator does not own its clients" do
      operator = operator_fixture()
      %{organisation: client} = client_fixture(operator.scope)

      assert Apiary.Edition.first_workspace_waiting_line(client) ==
               "An owner or an admin of #{client.name} creates the first workspace."
    end

    test "name the operator's owners too while the operator owns its clients" do
      operator = operator_fixture()
      %{organisation: client} = client_fixture(operator.scope)
      Flags.put_operator_infrastructure(true)

      assert Apiary.Edition.first_workspace_waiting_line(client) ==
               "An owner or an admin of #{client.name}, or an owner of #{operator.organisation.name}, creates the first workspace."
    end
  end
end
