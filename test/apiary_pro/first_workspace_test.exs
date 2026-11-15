defmodule ApiaryPro.FirstWorkspaceTest do
  @moduledoc """
  The first workspace of an organisation the edition creates. A person's New organisation and
  an instance admin's New organisation create it with no workspace, for the kind cards of its
  overview to make. The line about who waits for the first workspace
  (`c:Apiary.Edition.first_workspace_waiting_line/1`) is the core's.
  """
  # Not async: the sign-up settings and the features are the node's.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures
  import ApiaryPro.SignUpFixtures, only: [open!: 1]

  alias Apiary.Organisations
  alias ApiaryPro.{Flags, Operators}

  @moduletag with_features: Apiary.Features.all()

  setup do: Flags.put_operator_infrastructure(false)

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
  end

  describe "the lines about the first workspace" do
    test "are the core's, with the flag on" do
      %{organisation: organisation} = sign_up_fixture()
      Flags.put_operator_infrastructure(true)

      assert Apiary.Edition.first_workspace_waiting_line(organisation) ==
               "An owner of #{organisation.name} creates the first workspace."
    end
  end
end
