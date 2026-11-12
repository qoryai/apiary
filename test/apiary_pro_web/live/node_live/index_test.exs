defmodule ApiaryProWeb.NodeLive.IndexTest do
  @moduledoc """
  The workspace's nodes under workspace access: a member removed from the workspace, while
  still a member of the organisation, is sent away from its nodes.
  """
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures

  alias ApiaryPro.WorkspaceAccess

  describe "a member removed from the workspace while the page is open" do
    setup %{conn: conn} do
      owner = sign_up_fixture()
      %{user: user, membership: membership, scope: scope} = member_fixture(owner.scope, :member)
      %{conn: log_in_user(conn, user), owner: owner, membership: membership, scope: scope}
    end

    test "is sent to / when the removal is announced", ctx do
      %{organisation: organisation, workspace: workspace} = ctx.scope
      {:ok, lv, _html} = live(ctx.conn, ~p"/#{organisation}/#{workspace}/machines")

      {:ok, _} = WorkspaceAccess.remove(ctx.owner.scope, ctx.membership.id, workspace.id)

      assert_redirect(lv, ~p"/")
    end
  end
end
