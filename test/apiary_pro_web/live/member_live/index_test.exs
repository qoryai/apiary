defmodule ApiaryProWeb.MemberLive.IndexTest do
  @moduledoc """
  What the edition says in the People page's heading (`ApiaryProWeb.Slots.members_heading/1`):
  which workspaces each level reaches, under the edition's workspace access. The operator a
  client's heading names is pinned with the Ownership section
  (`ApiaryProWeb.SettingsLive.OwnershipTest`), a member's workspaces with their page
  (`ApiaryProWeb.MemberLive.WorkspacesTest`).
  """
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures

  test "the heading says which workspaces each level reaches, to every level, and names no operator of an organisation that is no client",
       %{conn: conn} do
    owner = sign_up_fixture()
    member = member_fixture(owner.scope, :member)

    for user <- [owner.user, member.user] do
      {:ok, lv, _html} = live(log_in_user(conn, user), ~p"/#{owner.organisation}/settings/people")

      assert has_element?(
               lv,
               "#workspace-reach",
               "Owners and admins reach every workspace; members, the workspaces they are added to."
             )

      refute has_element?(lv, "#operated-by")
    end
  end
end
