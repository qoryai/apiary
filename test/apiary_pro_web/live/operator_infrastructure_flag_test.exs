defmodule ApiaryProWeb.OperatorInfrastructureFlagTest do
  @moduledoc """
  An operator's people and its clients while `ApiaryPro.Flags.operator_infrastructure?/0`
  is off: everything as it was. The operator's people read its clients and change nothing
  there, a client's first person is its owner, the actions of the first admin's invitation
  are not found, and Drop is offered.
  """
  # The flag is set for this process (`ApiaryPro.Flags.put_operator_infrastructure/1`).
  use ApiaryWeb.ConnCase, async: true

  # A workspace's set-up is finished, so a link to it leads to the Overview.
  setup do: Apiary.Edition.put_test_stub(Apiary.EditionStubs.SetUpFinished)

  import Phoenix.LiveViewTest
  import ApiaryPro.OperatorsFixtures

  alias Apiary.{Access, Features}
  alias ApiaryPro.{Flags, Operators}

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
    test "the first admin's invitation is not found, and the first owner's is offered",
         %{conn: conn} do
      operator = operator_fixture()

      {%{organisation: client}, _token} =
        create_client_fixture(operator.scope, %{
          "name" => "Acme",
          "email" => Apiary.AccountsFixtures.unique_user_email()
        })

      for action <- [
            :"client.invite_admin",
            :"client.revoke_admin_invitation",
            :"client.renew_admin_invitation"
          ] do
        assert Access.authorize(operator.scope, action, operator.organisation) ==
                 {:error, :not_found}
      end

      assert Access.authorize(operator.scope, :"client.invite_owner", operator.organisation) ==
               :ok

      assert Operators.invite_admin(
               operator.scope,
               client.id,
               %{"email" => Apiary.AccountsFixtures.unique_user_email()},
               &"http://localhost/invitations/#{&1}"
             ) == {:error, :not_found}

      conn = log_in_user(conn, operator.user)

      assert_raise ApiaryWeb.NotFound, fn ->
        live(conn, ~p"/#{operator.organisation}/clients/#{client.id}/admin")
      end

      {:ok, lv, _html} = live(conn, ~p"/#{operator.organisation}/clients")
      render_async(lv)
      assert has_element?(lv, "#client-#{client.id}-invite-owner")
      refute has_element?(lv, "#client-#{client.id}-invite-admin")
      assert has_element?(lv, "#client-#{client.id}-owners", "No owner yet")
    end

    test "a client's first person is its owner, and Drop is offered once it has one",
         %{conn: conn} do
      operator = operator_fixture()
      client = client_fixture(operator.scope, "Acme")
      assert client.owner.membership.level == :owner

      {:ok, lv, _html} =
        live(log_in_user(conn, operator.user), ~p"/#{operator.organisation}/clients")

      render_async(lv)
      assert has_element?(lv, "#client-#{client.organisation.id}-drop")
      assert has_element?(lv, "th", "Owner")
    end

    test "the Action filter leaves out the first admin's invitation" do
      operator = operator_fixture()

      for action <- [
            :"client.invite_admin",
            :"client.revoke_admin_invitation",
            :"client.renew_admin_invitation"
          ] do
        refute ApiaryProWeb.ActivityDescriber.offered?(operator.scope, action)
      end

      assert ApiaryProWeb.ActivityDescriber.offered?(operator.scope, :"client.invite_owner")
    end

    test "the operator's people read a client, and are told so", %{conn: conn} do
      operator = operator_fixture()
      client = client_fixture(operator.scope, "Acme")
      name = operator.organisation.name

      {:ok, lv, _html} =
        live(log_in_user(conn, operator.user), ~p"/#{client.organisation}/#{client.workspace}")

      assert has_element?(lv, "#operator-reader", "and nothing changed")
      refute has_element?(lv, "#operator-owner")

      owner = log_in_user(build_conn(), client.owner.user)
      {:ok, lv, _html} = live(owner, ~p"/#{client.organisation}/settings/ownership")
      assert has_element?(lv, "#operator", "to support its harness, and change nothing")
      {:ok, lv, _html} = live(owner, ~p"/#{client.organisation}/settings/people")
      assert has_element?(lv, "#operated-by", "Operated by #{name}")
    end
  end
end
