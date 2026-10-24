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

  describe "hidden/1" do
    test "the core hides nothing from a person", %{scope: scope} do
      assert Apiary.Edition.Core.hidden(scope) == []
      assert Apiary.Edition.hidden(scope) == []
    end

    test "a test's stub answers it, in the test's process and those it starts", %{scope: scope} do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.WithoutSecrets)

      assert Apiary.Edition.hidden(scope) == [:secrets]
      assert Task.await(Task.async(fn -> Apiary.Edition.hidden(scope) end)) == [:secrets]
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
    test "the core answers false", %{scope: scope} do
      refute Apiary.Edition.Core.operated?(scope.organisation)
      refute Apiary.Edition.operated?(scope.organisation)
    end

    test "a test's stub answers true", %{scope: scope} do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.Operated)
      assert Apiary.Edition.operated?(scope.organisation)
    end
  end
end
