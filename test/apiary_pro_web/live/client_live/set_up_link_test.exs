defmodule ApiaryProWeb.ClientLive.SetUpLinkTest do
  @moduledoc """
  A client with no workspace has Set up in its row's menu on its operator's Clients page,
  a link to the client's overview, `/:org`, whose kind cards create the first workspace, for
  a person `workspace.create` allows in the client. The operator's people reach only the
  workspaces the operator operates, so nobody on the operator's page sees it, with
  `ApiaryPro.Flags.operator_infrastructure?/0` on or off: the client's owners and admins
  create the workspace.
  """
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures, only: [member_fixture: 2]
  import ApiaryPro.OperatorsFixtures

  alias Apiary.Features
  alias ApiaryPro.Flags

  @moduletag with_features: Features.all()

  setup do
    operator = operator_fixture()

    {%{organisation: empty}, _token} =
      create_client_fixture(operator.scope, %{
        "name" => "Acme",
        "email" => Apiary.AccountsFixtures.unique_user_email()
      })

    %{operator: operator, empty: empty}
  end

  defp clients(conn, user, operator) do
    {:ok, lv, _html} = live(log_in_user(conn, user), ~p"/#{operator.organisation}/clients")
    render_async(lv)
    lv
  end

  describe "while the operator owns its clients" do
    setup do: Flags.put_operator_infrastructure(true)

    test "an owner or an admin of the operator does not see it: the operator's people reach only the workspaces it operates",
         %{conn: conn, operator: operator, empty: empty} do
      %{user: admin} = member_fixture(operator.scope, :admin)

      for user <- [operator.user, admin] do
        lv = clients(conn, user, operator)
        assert has_element?(lv, "#client-#{empty.id}-menu")
        refute has_element?(lv, "#client-#{empty.id}-set-up")
      end
    end

    test "a client with a workspace has no Set up", %{conn: conn, operator: operator} do
      full = client_fixture(operator.scope, "Beta")

      lv = clients(conn, operator.user, operator)
      assert has_element?(lv, "#client-#{full.organisation.id}-menu")
      refute has_element?(lv, "#client-#{full.organisation.id}-set-up")
    end
  end

  describe "while the flag is off" do
    setup do: Flags.put_operator_infrastructure(false)

    test "an owner of the operator does not see it: the client's owner creates the workspace",
         %{conn: conn, operator: operator, empty: empty} do
      lv = clients(conn, operator.user, operator)

      assert has_element?(lv, "#client-#{empty.id}-menu")
      refute has_element?(lv, "#client-#{empty.id}-set-up")
    end
  end
end
