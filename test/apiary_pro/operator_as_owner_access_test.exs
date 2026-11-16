defmodule ApiaryPro.OperatorAsOwnerAccessTest do
  # Who may take each action in an organisation whose workspace Main an operator operates,
  # while `ApiaryPro.Flags.operator_infrastructure?/0` is on, per
  # `ApiaryPro.OperatorAsOwnerAccessRows`: one test per actor (`Apiary.AccessCase.assert_row/2`).
  use Apiary.DataCase, async: true

  alias ApiaryPro.OperatorAsOwnerAccessRows, as: Rows
  alias ApiaryPro.OperatorAsOwnerGatewayAccessRows, as: GatewayRows

  @moduletag with_features: Apiary.Features.all()
  @modules [Rows]
  @gateway_modules [Rows, GatewayRows]

  test "every action has a row, and every row an action" do
    assert Enum.sort(Enum.map(Rows.rows(), &elem(&1, 0))) == Enum.sort(Apiary.Access.actions())
  end

  test "the gateways' rows are the nodes' and access keys' actions, each once" do
    assert Enum.sort(Enum.map(GatewayRows.rows(), &elem(&1, 0))) ==
             Enum.sort(GatewayRows.actions())

    for {_action, row} <- GatewayRows.rows(), actor <- row[:yes] do
      assert actor in GatewayRows.actors()
    end
  end

  test "every row names only the actors of the table" do
    for {action, row} <- Rows.rows(), actor <- row[:yes] do
      assert actor in Rows.actors(), "#{action} names #{inspect(actor)}, which is no actor"
    end
  end

  describe "who may" do
    setup do: Apiary.AccessCase.setup_actors(@modules)

    for actor <- Rows.actors() do
      @actor actor
      test "as #{actor}", ctx do
        mismatches =
          for {action, row} <- Rows.rows(),
              message = mismatch(ctx, action, @actor, @actor in row[:yes]),
              do: "#{action}: #{message}"

        assert mismatches == [], Enum.join(mismatches, "\n")
      end
    end
  end

  # The organisation-level gateways, at the operator's place and at the organisation's, as
  # `ApiaryPro.OperatorAsOwnerGatewayAccessRows` says it: the nodes' and access keys'
  # actions alone, asked of the organisation.
  describe "who may, of the organisation-level gateways" do
    setup do: Apiary.AccessCase.setup_actors(@gateway_modules)

    for actor <- GatewayRows.actors() do
      @actor actor
      test "as #{actor}", ctx do
        mismatches =
          for {action, row} <- GatewayRows.rows(),
              message = mismatch(ctx, action, @actor, @actor in row[:yes], @gateway_modules),
              do: "#{action}: #{message}"

        assert mismatches == [], Enum.join(mismatches, "\n")
      end
    end
  end

  defp mismatch(ctx, action, actor, answer, modules \\ @modules) do
    Apiary.AccessCase.assert_row(
      Map.merge(ctx, %{action: action, actor: actor, answer: answer}),
      modules
    )

    nil
  rescue
    error in ExUnit.AssertionError ->
      "#{if answer, do: "may", else: "may not"}, but #{error.message}"
  end
end
