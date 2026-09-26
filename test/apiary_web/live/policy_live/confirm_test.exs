defmodule ApiaryWeb.PolicyLive.ConfirmTest do
  use ApiaryWeb.ConnCase, async: true

  # The security policy: left out of a run without the security feature.
  @moduletag needs: :security

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures

  alias Apiary.Policy

  setup :register_and_log_in_user

  setup do
    Application.put_env(:apiary, ApiaryWeb.PolicyLive, reload_window: 0, nav_window: 0)
    :ok
  end

  # `/workspace/policy?confirm=enforce` is the
  # overview's one-click nudge (brief-overview ol 3).
  describe "?confirm=enforce" do
    test "lands with the enforce confirm open for an owner, and drops the parameter", %{
      conn: conn,
      scope: scope
    } do
      {:ok, _} = Policy.allow(scope, nil, %{host: "api.example"})

      {:ok, view, _html} = live(conn, ~p"/workspace/policy?confirm=enforce")
      assert_patch(view, ~p"/workspace/policy")
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
        live(log_in_user(build_conn(), member), ~p"/workspace/policy?confirm=enforce")

      assert_patch(view, ~p"/workspace/policy")
      refute has_element?(view, "#mode-enforce")

      {:ok, view, _html} = live(conn, ~p"/workspace/policy?confirm=observe")
      refute has_element?(view, "#mode-enforce")

      {:ok, _} = Policy.set_mode(scope, "enforce")
      {:ok, view, _html} = live(conn, ~p"/workspace/policy?confirm=enforce")
      assert_patch(view, ~p"/workspace/policy")
      refute has_element?(view, "#mode-enforce")
    end
  end
end
