defmodule ApiaryPro.OperatorAsOwnerAccessTest do
  # Who may take each action in a client while the operator owns its clients, per
  # `ApiaryPro.OperatorAsOwnerAccessRows`: one test per actor (`Apiary.AccessCase.assert_row/2`).
  use Apiary.DataCase, async: true

  alias ApiaryPro.OperatorAsOwnerAccessRows, as: Rows
  alias ApiaryPro.OperatorAsOwnerGatewayAccessRows, as: GatewayRows
  alias ApiaryPro.OperatorAsOwnerOperatorChainAccessRows, as: ChainRows

  @moduletag with_features: Apiary.Features.all()
  @modules [Rows]
  @gateway_modules [Rows, GatewayRows]
  @chain_modules [ChainRows]

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

  # What the client's switch decides, with the switch on the operator's providers, as
  # `ApiaryPro.OperatorAsOwnerOperatorChainAccessRows` says it. The default switch, the
  # client's, is asked in the table above.
  describe "who may, with the switch on the operator's providers" do
    setup do: Apiary.AccessCase.setup_actors(@chain_modules)

    for actor <- ChainRows.actors() do
      @actor actor
      test "as #{actor}", ctx do
        mismatches =
          for {action, row} <- ChainRows.rows(),
              message = mismatch(ctx, action, @actor, @actor in row[:yes], @chain_modules),
              do: "#{action}: #{message}"

        assert mismatches == [], Enum.join(mismatches, "\n")
      end
    end
  end

  # The organisation-level gateways, at the operator's place and at the client's, as
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
