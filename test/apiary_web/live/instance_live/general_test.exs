defmodule ApiaryWeb.InstanceLive.GeneralTest do
  @moduledoc """
  Instance settings › General (`ApiaryWeb.InstanceLive.General`): the product's name on
  the instance, for the instance's admins, the Instance level's first section; its texts,
  its states and its errors; the rename on the Activity page; and a path that does not
  exist for anyone else. The suite's instance has had its first sign-up; a test that
  needs an instance admin hides its organisation inside its sandbox
  (`Apiary.EditionKit`), so the organisation it signs up is the instance's.
  """
  # Not async: hiding the instance's organisation acts on the row every test shares.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures, only: [member_fixture: 1]

  alias Apiary.ProductName

  @hint "Shown in the browser tab, the sidebar, the log-in pages and every email. Empty: Qory Apiary."
  @note "When a name other than Qory Apiary is set, the sidebar, the log-in pages and every email also say “Powered by Qory Apiary”."

  defp text(view, selector),
    do:
      view
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.split()
      |> Enum.join(" ")

  defp save(view, name),
    do: view |> form("#instance-name-form", instance: %{product_name: name}) |> render_submit()

  # Saves `name` and follows the page's reload: the flash it shows, and the page.
  defp save_and_reload(conn, view, name) do
    assert {:error, {:redirect, %{to: "/instance/general"}}} = save(view, name)
    flash = assert_redirect(view, "/instance/general")
    {:ok, view, html} = live(conn, ~p"/instance/general")
    {flash["info"], view, html}
  end

  describe "for an instance admin" do
    setup do
      Apiary.EditionKit.hide_instance_organisation()
      :ok
    end

    setup :register_and_log_in_user

    test "is the Instance level's first section, where /instance and the menu lead",
         %{conn: conn, scope: scope} do
      assert [%{key: :general, label: "General", path: "/instance/general"} | _] =
               sections = ApiaryWeb.Layouts.instance_sections(scope)

      assert [:mail, :configuration] = sections |> Enum.map(& &1.key) |> Enum.take(-2)
      assert conn |> get(~p"/instance") |> redirected_to(302) == "/instance/general"

      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")

      assert has_element?(
               view,
               "#sidebar #brand-menu a#brand-menu-instance[href='/instance/general']",
               "Instance settings"
             )
    end

    test "shows the form's texts, empty, with the edition's name", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/instance/general")

      assert html =~ ~r{<title[^>]*>\s*General · Instance settings · Qory Apiary\s*</title>}
      assert text(view, "h1#settings-section-title") == "General"

      assert text(view, "#settings-section-title + *") ==
               "The name this instance shows on its pages and in its email."

      # The breadcrumb: Instance settings, then the section, the page itself.
      assert has_element?(view, "#breadcrumb a[href='/instance/general']", "Instance settings")
      assert has_element?(view, "#breadcrumb [aria-current='page']", "General")

      # The second column lists it first, current.
      assert has_element?(
               view,
               "#instance-tabs a#instance-tab-general[href='/instance/general'][aria-current='page']",
               "General"
             )

      assert text(view, "label[for='instance_product_name']") == "Name"

      assert has_element?(
               view,
               "#instance-name-form input#instance_product_name[name='instance[product_name]'][placeholder='Qory Apiary']"
             )

      refute view |> element("#instance_product_name") |> render() =~ "value="
      assert render(view) =~ @hint
      assert text(view, "#instance-name-save") =~ "Save"
      assert text(view, "#instance-name-save .btn-busy") == "Saving"
      assert text(view, "#instance-name-save") =~ @note
    end

    test "saving a name says so, and the page then shows it, with Powered by",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/instance/general")
      {flash, view, html} = save_and_reload(conn, view, "Acme Agents")

      assert flash == "Instance renamed to Acme Agents."
      assert ProductName.get() == "Acme Agents"

      assert html =~ ~r{<title[^>]*>\s*General · Instance settings · Acme Agents\s*</title>}

      assert has_element?(
               view,
               "#instance_product_name[value='Acme Agents'][placeholder='Qory Apiary']"
             )

      assert text(view, "#sidebar #brand-menu-button") == "Acme Agents"
      assert has_element?(view, "#brand-menu-button[aria-label='Acme Agents menu']")
      assert has_element?(view, "#brand-menu ul[role='menu'][aria-label='Acme Agents']")
      assert has_element?(view, "#brand-menu-button .q-brand-name[title='Acme Agents']")
      assert text(view, "#sidebar #powered-by") == "Powered by Qory Apiary"
      assert text(view, "#brand-menu-powered") == "Powered by Qory Apiary"
      refute has_element?(view, "#powered-by a")
    end

    test "emptying the field goes back to the edition's name, without Powered by",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/instance/general")
      {_flash, view, _html} = save_and_reload(conn, view, "Acme Agents")
      {flash, view, html} = save_and_reload(conn, view, "")

      assert flash == "Instance renamed to Qory Apiary."
      assert ProductName.get() == nil
      assert html =~ ~r{<title[^>]*>\s*General · Instance settings · Qory Apiary\s*</title>}
      assert text(view, "#sidebar #brand-menu-button") == "Qory Apiary"
      refute has_element?(view, "#powered-by")
      refute has_element?(view, "#brand-menu-powered")
    end

    test "Qory Apiary typed in is saved as an empty field", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/instance/general")
      {flash, view, _html} = save_and_reload(conn, view, "Qory Apiary")

      assert flash == "Instance renamed to Qory Apiary."
      assert ProductName.get() == nil
      refute view |> element("#instance_product_name") |> render() =~ "value="
      refute has_element?(view, "#powered-by")
    end

    test "a name breaking the rules says why under the field, and saves nothing",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/instance/general")

      for {name, message} <- [
            {String.duplicate("a", 121), "should be at most 120 character(s)"},
            {"Acme\u0007Agents", "must not contain control characters"},
            {"Acme​Agents", "must not contain invisible characters"},
            {"Acme Agents‍", "must not start or end with a joining character"},
            {"https://acme.example",
             "must not contain a web address; a name like acme.io is fine"},
            {~s(Acme "Agents"), "must not contain quotation marks"}
          ] do
        html = save(view, name)
        assert is_binary(html), inspect(name)

        assert view |> element("#instance-name-form") |> render() =~
                 Phoenix.HTML.html_escape(message) |> Phoenix.HTML.safe_to_string(),
               inspect(name)
      end

      assert ProductName.get() == nil

      # A right name after an error saves.
      assert {:error, {:redirect, %{to: "/instance/general"}}} = save(view, "Acme Agents")

      assert %{"info" => "Instance renamed to Acme Agents."} =
               assert_redirect(view, "/instance/general")
    end

    test "the Activity page says the rename, and the name before and after",
         %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/instance/general")
      {_flash, view, _html} = save_and_reload(conn, view, "Acme Agents")
      {_flash, _view, _html} = save_and_reload(conn, view, "")

      {:ok, view, _html} = live(conn, "/#{scope.organisation.slug}/audit-log")
      render_async(view)

      {:ok, %{entries: [emptied, renamed | _]}} =
        Apiary.Audit.list_entries(scope, %{action: "instance.rename"})

      assert has_element?(view, "#filter-action-form li", "Instance renamed")
      assert text(view, "#entry-#{renamed.id}-action") =~ "Renamed the instance"
      assert text(view, "#entry-#{renamed.id}-change") == "Qory Apiary → Acme Agents"
      assert text(view, "#entry-#{emptied.id}-action") =~ "Renamed the instance"
      assert text(view, "#entry-#{emptied.id}-change") == "Acme Agents → Qory Apiary"
      assert text(view, "#entry-#{renamed.id}-actor") =~ scope.user.email
    end

    test "one who is no longer an instance admin, on the page, is answered not found",
         %{conn: conn, scope: scope} do
      {:ok, view, _html} = live(conn, ~p"/instance/general")
      # Another admin first: the instance keeps one.
      {:ok, _} = Apiary.Organisations.grant_instance_admin(member_fixture(scope).user)
      {:ok, _} = Apiary.Organisations.revoke_instance_admin(scope.user)
      refute Apiary.Access.instance_admin?(Apiary.Accounts.Scope.for_user(scope.user))

      assert {:error, {:live_redirect, %{to: "/instance/general"}}} = save(view, "Acme Agents")
      assert ProductName.get() == nil
    end
  end

  describe "for a plain member of the instance's organisation" do
    setup do
      Apiary.EditionKit.hide_instance_organisation()
      :ok
    end

    setup :register_and_log_in_user

    test "the page is not found, and General is no section of theirs",
         %{conn: conn, scope: scope} do
      member = member_fixture(scope)
      refute Apiary.Access.instance_admin?(member.scope)
      assert ApiaryWeb.Layouts.instance_sections(member.scope) == []

      conn = log_in_user(conn, member.user)
      assert_raise ApiaryWeb.NotFound, fn -> live(conn, ~p"/instance/general") end
    end
  end

  describe "for anyone else" do
    setup :register_and_log_in_user

    test "is not found for the owner of another organisation", %{conn: conn, scope: scope} do
      refute Apiary.Access.instance_admin?(scope)
      assert_raise ApiaryWeb.NotFound, fn -> live(conn, ~p"/instance/general") end
    end
  end

  test "sends a visitor to log in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/instance/general")
  end
end
