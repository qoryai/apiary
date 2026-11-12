defmodule ApiaryProWeb.SettingsLiveTest do
  @moduledoc """
  The workspace's settings under workspace access: a member removed from the workspace,
  while still a member of the organisation, no longer changes anything there.
  """
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures

  describe "a person removed from the workspace while the page is open" do
    test "a change it asks for is refused and the page sent to /", %{conn: conn} do
      owner = sign_up_fixture()
      %{user: user, scope: scope} = member_fixture(owner.scope, :member)

      {:ok, lv, _html} =
        live(log_in_user(conn, user), ~p"/#{scope.organisation}/#{scope.workspace}/settings")

      Apiary.Repo.delete!(ApiaryPro.WorkspaceAccess.of(scope))

      render_hook(lv, "save_retention", %{"retention" => %{"events_retention_days" => "30"}})
      {path, flash} = assert_redirect(lv)
      assert path == ~p"/"
      assert flash["error"] =~ "no longer have access"
    end
  end
end
