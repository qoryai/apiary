defmodule ApiaryWeb.SettingsLiveTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures

  alias Apiary.Accounts.Scope
  alias Apiary.Organisations

  describe "as an owner" do
    setup :register_and_log_in_user

    test "renames the apiary and the hive", %{conn: conn, user: user, scope: scope} do
      {:ok, lv, html} = live(conn, ~p"/hive/settings")

      assert html =~ ~r/<abbr[^>]*data-tip="organisation"/
      assert html =~ ~r/<abbr[^>]*data-tip="team"/
      assert html =~ scope.organisation.name
      assert html =~ scope.hive.name

      html = lv |> form("#organisation-form", organisation: %{name: "Acme"}) |> render_submit()
      assert html =~ "Apiary renamed to Acme"

      html = lv |> form("#hive-form", hive: %{name: "Platform"}) |> render_submit()
      assert html =~ "Hive renamed to Platform"

      reloaded = Organisations.load_scope(Scope.for_user(user))
      assert reloaded.organisation.name == "Acme"
      assert reloaded.hive.name == "Platform"
    end

    test "refuses an empty name", %{conn: conn, user: user, scope: scope} do
      {:ok, lv, _html} = live(conn, ~p"/hive/settings")

      html = lv |> form("#organisation-form", organisation: %{name: ""}) |> render_submit()
      assert html =~ "can&#39;t be blank"

      html = lv |> form("#hive-form", hive: %{name: ""}) |> render_submit()
      assert html =~ "can&#39;t be blank"

      reloaded = Organisations.load_scope(Scope.for_user(user))
      assert reloaded.organisation.name == scope.organisation.name
      assert reloaded.hive.name == scope.hive.name
    end

    test "lists the owners", %{conn: conn, user: user, scope: scope} do
      %{user: member} = member_fixture(scope, :member)
      %{user: other_owner} = member_fixture(scope, :owner)

      {:ok, lv, _html} = live(conn, ~p"/hive/settings")

      assert has_element?(lv, "#owners", user.email)
      assert has_element?(lv, "#owners", other_owner.email)
      refute has_element?(lv, "#owners", member.email)
    end
  end

  describe "as a member" do
    setup %{conn: conn} do
      owner = sign_up_fixture()
      %{user: user} = member_fixture(owner.scope, :member)
      %{conn: log_in_user(conn, user), owner: owner}
    end

    test "sees the names read-only", %{conn: conn, owner: owner} do
      {:ok, lv, html} = live(conn, ~p"/hive/settings")

      assert html =~ "Only owners can change these settings"
      assert has_element?(lv, "input#organisation_name[disabled]")
      assert has_element?(lv, "input#hive_name[disabled]")
      refute has_element?(lv, "button", "Save")
      assert has_element?(lv, "#owners", owner.user.email)
    end
  end
end
