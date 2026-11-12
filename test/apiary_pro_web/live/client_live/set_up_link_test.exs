defmodule ApiaryProWeb.ClientLive.SetUpLinkTest do
  @moduledoc """
  A client with no workspace has Set up in its row's menu on its operator's Clients page,
  a link to the client's overview, `/:org`, whose kind cards create the first workspace, for
  a person
  `workspace.create` allows in the client: while `ApiaryPro.Flags.operator_infrastructure?/0`
  is on, an owner of the operator; with it off, nobody on the operator's page, because the
  client's owner creates the workspace.
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

    test "an owner of the operator sees Set up on a client with no workspace and opens the overview",
         %{conn: conn, operator: operator, empty: empty} do
      lv = clients(conn, operator.user, operator)
      set_up = ~p"/#{empty}"

      assert has_element?(lv, "#client-#{empty.id}-set-up[href='#{set_up}']", "Set up")

      assert {:ok, page, _html} =
               lv
               |> element("#client-#{empty.id}-set-up")
               |> render_click()
               |> follow_redirect(log_in_user(conn, operator.user))

      assert has_element?(page, "#set-up-card-software-link")
    end

    test "an admin of the operator, who is no owner, does not see it",
         %{conn: conn, operator: operator, empty: empty} do
      %{user: admin} = member_fixture(operator.scope, :admin)

      lv = clients(conn, admin, operator)

      assert has_element?(lv, "#client-#{empty.id}-menu")
      refute has_element?(lv, "#client-#{empty.id}-set-up")
    end

    test "a client with a workspace has no Set up, and the link goes once Main exists",
         %{conn: conn, operator: operator, empty: empty} do
      full = client_fixture(operator.scope, "Beta")

      lv = clients(conn, operator.user, operator)
      assert has_element?(lv, "#client-#{empty.id}-set-up")
      assert has_element?(lv, "#client-#{full.organisation.id}-menu")
      refute has_element?(lv, "#client-#{full.organisation.id}-set-up")

      {:ok, _workspace} =
        Apiary.Organisations.create_first_workspace(scope_in(operator.user, empty), %{
          "domain" => Apiary.Lingo.Domain.default().name()
        })

      lv = clients(conn, operator.user, operator)
      assert has_element?(lv, "#client-#{empty.id}-menu")
      refute has_element?(lv, "#client-#{empty.id}-set-up")
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
