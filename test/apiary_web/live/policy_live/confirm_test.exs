defmodule ApiaryWeb.PolicyLive.ConfirmTest do
  use ApiaryWeb.ConnCase, async: true

  # The security policy: left out of a run without the security feature.
  @moduletag needs: :security

  import Phoenix.LiveViewTest
  import Phoenix.Component, only: [sigil_H: 2]
  import Apiary.OrganisationsFixtures

  alias Apiary.Policy

  setup :register_and_log_in_user

  setup do
    Application.put_env(:apiary, ApiaryWeb.PolicyLive, reload_window: 0, nav_window: 0)
    :ok
  end

  # The confirm in place, as the policy pages and an edition's pages call it.
  describe "confirm_panel" do
    test "an effect describes the confirm and its Cancel" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <ApiaryWeb.PolicyLive.Views.confirm_panel id="ask" question="Enforce?" return="mode">
          <:effect>Runs are denied what no rule allows.</:effect>
          <p id="ask-more">You can switch back.</p>
          <:action><button id="ask-confirm">Enforce</button></:action>
        </ApiaryWeb.PolicyLive.Views.confirm_panel>
        """)

      document = LazyHTML.from_fragment(html)

      assert LazyHTML.text(LazyHTML.query(document, "p#ask-effect")) =~
               "Runs are denied what no rule allows."

      assert LazyHTML.attribute(LazyHTML.query(document, "section#ask"), "aria-describedby") ==
               ["ask-effect"]

      assert LazyHTML.attribute(LazyHTML.query(document, "#ask-cancel"), "aria-describedby") ==
               ["ask-effect"]

      assert Enum.count(LazyHTML.query(document, "#ask-more")) == 1
    end

    test "renders without an effect, and is described by nothing" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <ApiaryWeb.PolicyLive.Views.confirm_panel id="ask" question="Leave acme?" return="leave">
          <p id="ask-more">The workspaces of acme stay.</p>
          <:action><button id="ask-confirm">Leave</button></:action>
        </ApiaryWeb.PolicyLive.Views.confirm_panel>
        """)

      document = LazyHTML.from_fragment(html)

      assert Enum.count(LazyHTML.query(document, "section#ask:not([aria-describedby])")) == 1
      assert Enum.count(LazyHTML.query(document, "#ask-cancel:not([aria-describedby])")) == 1
      assert Enum.count(LazyHTML.query(document, "#ask-effect")) == 0

      assert LazyHTML.text(LazyHTML.query(document, "#ask-more")) =~
               "The workspaces of acme stay."

      assert Enum.count(LazyHTML.query(document, "#ask-confirm")) == 1
    end
  end

  # `/:org/:workspace/policy?confirm=enforce` is the overview's one-click nudge.
  describe "?confirm=enforce" do
    test "lands with the enforce confirm open for an owner, and drops the parameter", %{
      conn: conn,
      scope: scope
    } do
      {:ok, _} = Policy.allow(scope, nil, %{host: "api.example"})

      {:ok, view, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/policy?confirm=enforce")

      assert_patch(view, ~p"/#{scope.organisation}/#{scope.workspace}/policy")
      render_async(view, 5_000)

      assert has_element?(view, "#mode-enforce", "Set the workspace's default to enforce")
      assert has_element?(view, "#mode-confirm", "Set the default to enforce")

      view |> element("#mode-confirm") |> render_click()
      assert Policy.get_mode(scope) == "enforce"
      refute has_element?(view, "#mode-enforce")
    end

    test "asks nothing of a member, of a workspace that enforces, or for another value", %{
      conn: conn,
      scope: scope
    } do
      {:ok, _} = Policy.allow(scope, nil, %{host: "api.example"})

      %{user: member} = member_fixture(scope, :member)

      {:ok, view, _html} =
        live(
          log_in_user(build_conn(), member),
          ~p"/#{scope.organisation}/#{scope.workspace}/policy?confirm=enforce"
        )

      assert_patch(view, ~p"/#{scope.organisation}/#{scope.workspace}/policy")
      refute has_element?(view, "#mode-enforce")

      {:ok, view, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/policy?confirm=observe")

      refute has_element?(view, "#mode-enforce")

      {:ok, _} = Policy.set_mode(scope, "enforce")

      {:ok, view, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/policy?confirm=enforce")

      assert_patch(view, ~p"/#{scope.organisation}/#{scope.workspace}/policy")
      refute has_element?(view, "#mode-enforce")
    end
  end
end
