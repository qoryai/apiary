defmodule Apiary.EditionTest do
  use ExUnit.Case, async: true

  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Organisations.{Membership, Organisation, Workspace}

  setup do
    organisation = %Organisation{id: Ecto.UUID.generate()}
    workspace = %Workspace{id: Ecto.UUID.generate(), organisation_id: organisation.id}

    %{
      scope: %Scope{
        user: %User{id: Ecto.UUID.generate()},
        organisation: organisation,
        workspace: workspace
      }
    }
  end

  describe "put_organisation/1" do
    # The configured edition's answer puts the tenant on the organisation:
    # test/apiary_pro/list_checks_test.exs.
    test "the core puts nothing on the organisation", %{scope: scope} do
      assert Apiary.Edition.Core.put_organisation(scope.organisation) == scope.organisation
    end
  end

  describe "hidden/1" do
    # The configured edition's answer reads the organisation's grants:
    # test/apiary_pro/feature_visibility_test.exs.
    test "the core hides nothing from a person", %{scope: scope} do
      assert Apiary.Edition.Core.hidden(scope) == []
    end

    test "a test's stub answers it, in the test's process and those it starts", %{scope: scope} do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.WithoutSecrets)

      assert Apiary.Edition.hidden(scope) == [:secrets]
      assert Task.await(Task.async(fn -> Apiary.Edition.hidden(scope) end)) == [:secrets]
    end
  end

  describe "scope_setting?/1" do
    test "the core shows no setting of where a connection applies, the edition shows it",
         %{scope: scope} do
      refute Apiary.Edition.Core.scope_setting?(scope)
      assert Apiary.Edition.scope_setting?(scope)
    end

    test "a test's stub shows it", %{scope: scope} do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ScopeSetting)
      assert Apiary.Edition.scope_setting?(scope)
    end
  end

  describe "machines_who_may/2" do
    test "the core answers who acts on a pool of the workspace", %{scope: scope} do
      for edition <- [Apiary.Edition.Core, Apiary.Edition] do
        assert edition.machines_who_may(scope, scope.workspace) ==
                 "Only owners and admins add a pool and join a machine to it."
      end
    end
  end

  describe "model_choice_chain/1" do
    test "the core answers the organisation's chain", %{scope: scope} do
      assert Apiary.Edition.Core.model_choice_chain(scope.organisation.id) == "organisation"
      assert Apiary.Edition.model_choice_chain(scope.organisation.id) == "organisation"
    end

    test "a test's stub answers the operator's chain", %{scope: scope} do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.OperatorChain)
      assert Apiary.Edition.model_choice_chain(scope.organisation.id) == "operator"
    end
  end

  describe "operated?/1" do
    # The configured edition's answer reads the organisation's tenant:
    # test/apiary_pro/operated_test.exs.
    test "the core answers false", %{scope: scope} do
      refute Apiary.Edition.Core.operated?(scope.organisation)
    end

    test "a test's stub answers true", %{scope: scope} do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.Operated)
      assert Apiary.Edition.operated?(scope.organisation)
    end
  end

  # The core's answers for an instance admin and for a scope with no owner read the
  # database: `test/apiary/stacks_test.exs`.
  describe "harness_owner/1" do
    test "the core answers a member's organisation", %{scope: scope} do
      member = %{scope | membership: %Membership{organisation_id: scope.organisation.id}}

      assert Apiary.Edition.Core.harness_owner(member) == scope.organisation.id
      assert Apiary.Edition.harness_owner(member) == scope.organisation.id
    end

    test "a test's stub answers nil", %{scope: scope} do
      member = %{scope | membership: %Membership{organisation_id: scope.organisation.id}}
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.NoHarnessOwner)
      assert Apiary.Edition.harness_owner(member) == nil
    end
  end

  describe "harness_source_allowed?/3" do
    @source %{"git" => "https://code.example.com/team/stacks", "ref" => "v1"}

    test "the core answers false", %{scope: scope} do
      owner = Ecto.UUID.generate()
      refute Apiary.Edition.Core.harness_source_allowed?(scope.organisation.id, owner, @source)
      refute Apiary.Edition.harness_source_allowed?(scope.organisation.id, owner, @source)
    end

    test "a test's stub answers true", %{scope: scope} do
      owner = Ecto.UUID.generate()
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.HarnessSourceAllowed)
      assert Apiary.Edition.harness_source_allowed?(scope.organisation.id, owner, @source)
    end
  end
end
