defmodule ApiaryPro.OperatedTest do
  # What the edition answers to `c:Apiary.Edition.operated?/1`: true for a client of
  # an operator, and what that does to the run input of the core's stacks.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import ApiaryPro.OperatorsFixtures

  alias Apiary.Edition
  alias Apiary.Runs.Target
  alias Apiary.Stacks
  alias ApiaryPro.Flags

  @moduletag with_features: Apiary.Features.all()

  @stacks "https://code.example.com/team/stacks"
  # A harness document that extends the stack `core` of the stacks source at main.
  @document "extends: {git: #{@stacks}, ref: main, path: core}\n"

  setup do
    operator = operator_fixture()
    client = client_fixture(operator.scope)

    %{operator: operator, client: client}
  end

  describe "operated?/1" do
    test "is true for a client of an operator", ctx do
      assert Edition.operated?(ctx.client.organisation)
    end

    test "is false for an organisation without an operator and for an operator" do
      %{organisation: organisation} = sign_up_fixture()
      operator = operator_fixture()

      refute Edition.operated?(organisation)
      refute Edition.operated?(operator.organisation)
    end

    test "is false for the instance organisation" do
      refute Edition.operated?(instance_organisation())
    end

    test "is true for a client with operator_infrastructure off and on", ctx do
      for on? <- [false, true] do
        Flags.put_operator_infrastructure(on?)
        assert Edition.operated?(ctx.client.organisation)
      end
    end
  end

  describe "the run's harness_hidden" do
    defp target!(scope) do
      Repo.insert!(%Target{
        organisation_id: scope.organisation.id,
        workspace_id: scope.workspace.id,
        system: "system.example",
        path: "acme/main",
        first_seen_at: DateTime.utc_now()
      })
    end

    # The resolution of the workflow `explore` for a harness document that an owner of the
    # organisation saved as the workspace's harness choice.
    defp resolution(%{organisation: organisation, workspace: workspace, owner: %{scope: scope}}) do
      target = target!(scope)

      {:ok, _row} =
        Stacks.put_stack(scope, {:workspace, workspace}, @document, choice: :repository)

      {:chosen, resolution} =
        Stacks.chosen_for(
          organisation,
          workspace,
          %{system: target.system, path: target.path},
          "explore"
        )

      resolution
    end

    test "is true for a client, whose stack the client's owner saved", ctx do
      Flags.put_operator_infrastructure(false)
      assert %{harness_hidden: true} = resolution(ctx.client)
    end

    test "is true for a client while operator_infrastructure is on", ctx do
      Flags.put_operator_infrastructure(true)
      assert %{harness_hidden: true} = resolution(ctx.client)
    end

    test "is false for an organisation without an operator, whose stack its owner saved" do
      signed_up = sign_up_fixture()

      assert %{harness_hidden: false} =
               resolution(%{
                 organisation: signed_up.organisation,
                 workspace: signed_up.workspace,
                 owner: signed_up
               })
    end
  end
end
