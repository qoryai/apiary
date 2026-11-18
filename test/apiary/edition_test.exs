defmodule Apiary.EditionTest do
  use ExUnit.Case, async: true

  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Organisations.{Organisation, Workspace}

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

  describe "schema_change_line/1" do
    # The configured edition's answer for an operated workspace:
    # test/apiary_pro/workspace_operators_test.exs.
    test "the core answers nil, so the page links to Harness settings", %{scope: scope} do
      assert Apiary.Edition.Core.schema_change_line(scope) == nil
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
end
