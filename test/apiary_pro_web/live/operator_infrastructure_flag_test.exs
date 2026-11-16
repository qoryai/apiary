defmodule ApiaryProWeb.OperatorInfrastructureFlagTest do
  @moduledoc """
  An operator's people and the workspaces it operates while
  `ApiaryPro.Flags.operator_infrastructure?/0` is off: the operator's people read a
  workspace it operates and change nothing there.
  """
  # The flag is set for this process (`ApiaryPro.Flags.put_operator_infrastructure/1`).
  use ApiaryWeb.ConnCase, async: true

  # A workspace's set-up is finished, so a link to it leads to the Overview.
  setup do: Apiary.Edition.put_test_stub(Apiary.EditionStubs.SetUpFinished)

  import Phoenix.LiveViewTest
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Access, Features}
  alias ApiaryPro.Flags

  @moduletag with_features: Features.all()

  setup do: Flags.put_operator_infrastructure(false)

  describe "the flag" do
    test "is off by default, and a process's override reaches the processes it starts" do
      Process.delete({Flags, :operator_infrastructure})
      refute Flags.operator_infrastructure?()

      Flags.put_operator_infrastructure(true)
      assert Flags.operator_infrastructure?()
      assert Task.await(Task.async(&Flags.operator_infrastructure?/0))

      # Another process, started by no one who turned it on, keeps the default.
      parent = self()
      spawn(fn -> send(parent, {:flag, Flags.operator_infrastructure?()}) end)
      assert_receive {:flag, false}

      Flags.put_operator_infrastructure(false)
      refute Task.await(Task.async(&Flags.operator_infrastructure?/0))
    end

    test "is apart from the transfers' flag" do
      Flags.put_transfers(true)
      refute Flags.operator_infrastructure?()

      Flags.put_transfers(false)
      Flags.put_operator_infrastructure(true)
      refute Flags.transfers?()
    end
  end

  describe "while it is off" do
    test "the operator's owner reads a workspace it operates and changes nothing there",
         %{conn: conn} do
      operator = operator_fixture()
      operated = operated_fixture(operator.scope, "Acme")

      {:ok, _lv, _html} =
        live(
          log_in_user(conn, operator.user),
          ~p"/#{operated.organisation}/#{operated.workspace}"
        )

      refute Access.can?(operated.scope, :"node.create", operated.workspace)
    end
  end
end
