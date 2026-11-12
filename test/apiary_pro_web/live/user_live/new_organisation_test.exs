defmodule ApiaryProWeb.UserLive.NewOrganisationTest do
  @moduledoc """
  The organisation switcher's New organisation entry, and the page it leads to: there
  where the instance's sign-up settings open a kind, absent where they open none, and the
  organisation it creates, which the person is taken to.
  """
  # Not async: the sign-up settings are the node's.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ApiaryPro.SignUpFixtures, only: [open!: 1]
  import Apiary.AccountsFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Organisations, Repo}
  alias Apiary.Organisations.Organisation

  setup :register_and_log_in_user

  defp organisations, do: Repo.aggregate(Organisation, :count)

  # The names of the fields the form asks, in their order.
  defp field_names(view) do
    view
    |> element("#new-organisation-form")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("input:not([type=hidden]), select, textarea")
    |> LazyHTML.attribute("name")
    |> Enum.uniq()
  end

  describe "the page's layout" do
    # The core's Your settings pages carry the sidebar of the workspace the person came
    # from, and their sections as a second column, Organisations current. The page is one
    # of them: it adds no sidebar of its own and takes none away.
    test "is the layout of the core's Organisations page, with the Your settings column",
         %{conn: conn} do
      open!([:organisation])

      ids = fn path ->
        {:ok, lv, _html} = live(conn, path)

        lv
        |> element("#sidebar")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[id]")
        |> LazyHTML.attribute("id")
      end

      assert ids.(~p"/users/organisations/new") == ids.(~p"/users/organisations")

      {:ok, lv, _html} = live(conn, ~p"/users/organisations/new")
      assert has_element?(lv, "#nav-group-account")
      assert has_element?(lv, "#nav-user_organisations[aria-current]")
      assert has_element?(lv, "#new-organisation-form")
    end
  end

  describe "the switcher's entry" do
    # The workspace's set-up is finished, so a link to it leads to the Overview.
    setup do: Apiary.Edition.put_test_stub(Apiary.EditionStubs.SetUpFinished)

    test "is there where a kind is open, with one organisation too, and opens the form", %{
      conn: conn,
      scope: scope
    } do
      open!([:organisation])
      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")

      # One place and the entry: the breadcrumb has the switcher, its trigger a button.
      refute has_element?(view, "#organisation-block")
      assert has_element?(view, "#breadcrumb #breadcrumb-menus button#organisation-menu-button")

      assert has_element?(
               view,
               "#organisation-menu a#organisation-menu-new[href='/users/organisations/new']",
               "New organisation"
             )

      assert {:error, {:live_redirect, %{to: "/users/organisations/new"}}} =
               view |> element("#organisation-menu-new") |> render_click()

      {:ok, form, _html} = live(conn, ~p"/users/organisations/new")
      assert has_element?(form, "#new-organisation #new-organisation-form")

      # A page of the person's Organisations: the sidebar stays the workspace's they came
      # from, and their settings are the second column, Organisations marked as the page's
      # parent.
      assert has_element?(form, "aside#sidebar[aria-label='Workspace'] #nav-overview")

      assert has_element?(
               form,
               "#nav-group-account #nav-user_organisations[aria-current='true']"
             )

      refute has_element?(form, "#settings-tabs")
      assert has_element?(form, "#breadcrumb", "Your settings")

      # A form as a page of its own: the breadcrumb's Organisations leads back, then its
      # title, the form, then Create organisation and Cancel back to Organisations; no
      # Back and no card.
      assert has_element?(form, "#breadcrumb a[href='/users/organisations']", "Organisations")
      # The frame writes the level and the section; the page only its act.
      assert ApiaryProWeb.Trail.crumbs(form) == [
               "Your settings",
               "Organisations",
               "New organisation"
             ]

      # A phone's bar keeps Organisations as the page's parent, a link back.
      assert ApiaryProWeb.Trail.up(form) == {"Organisations", "/users/organisations"}

      assert has_element?(form, "#main #new-organisation h1", "New organisation")
      assert page_title(form) == "New organisation · Your settings · Qory Apiary"

      # Nothing under the title: the page's facts are under About organisations, with the
      # settings named by their level.
      refute has_element?(form, "#new-organisation #set-up-line")
      refute has_element?(form, "#new-organisation", "You are its first owner")
      assert has_element?(form, "#set-up-context h2", "About organisations")

      assert has_element?(
               form,
               "#set-up-context",
               "You become the first owner. You invite its people from Organisation settings › People."
             )

      assert has_element?(
               form,
               "#set-up-context",
               "Work happens in workspaces. You choose what its first one does on the organisation's overview."
             )

      assert has_element?(
               form,
               "#set-up-context",
               "Owners rename the organisation later in Organisation settings."
             )

      refute has_element?(form, "#set-up-context", "from Settings ›")
      refute has_element?(form, "#new-organisation-back")

      refute has_element?(form, "#main .card")

      assert has_element?(
               form,
               "#new-organisation #new-organisation-form .q-save button#create-organisation[type=submit]",
               "Create organisation"
             )

      assert has_element?(
               form,
               "#new-organisation-save a#new-organisation-save-cancel[href='/users/organisations']",
               "Cancel"
             )

      # The name alone: the type is asked on the workspace set-up page.
      assert field_names(form) == ["organisation[name]"]
      # One kind open: nothing to choose, and the name takes the focus.
      refute has_element?(form, "#new-organisation-form input[name='organisation[kind]']")
      assert has_element?(form, "#new-organisation-form input#organisation_name[phx-mounted]")
      refute has_element?(form, "#organisation_name-hint")
    end

    test "is absent where both settings are closed, and one organisation is text again", %{
      conn: conn,
      scope: scope
    } do
      open!([])
      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")

      refute has_element?(view, "#organisation-menu-new")
      refute has_element?(view, "#organisation-menu")

      # The organisation's segment is a link to its home, with no chevron to open. The
      # workspace's chevron is the owner's New workspace (`workspace_switcher_entries/1`),
      # the workspace menu's one entry beside its one workspace.
      org = scope.organisation.slug

      assert has_element?(
               view,
               "#breadcrumb a[href='/#{org}']",
               scope.organisation.name
             )

      refute has_element?(view, "#organisation-menu-button")
      assert has_element?(view, "#breadcrumb a[href='/#{org}/#{scope.workspace.slug}']")
      assert has_element?(view, "#breadcrumb button#workspace-menu-button")
      assert has_element?(view, "#workspace-menu .q-switcher-foot a#workspace-menu-new")

      {:ok, page, _html} = live(conn, ~p"/users/organisations")
      refute has_element?(page, "#organisations-new")
    end

    test "is last in a switcher of several places", %{conn: conn, user: user, scope: scope} do
      open!([:organisation])
      other = sign_up_fixture()
      %{token: token} = invitation_fixture(other.scope, %{"email" => user.email})
      {:ok, _membership} = Organisations.accept_invitation(user, token)

      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")

      assert has_element?(
               view,
               "#organisation-menu .q-switcher-foot a#organisation-menu-new:last-child"
             )

      assert has_element?(view, "#switch-#{other.organisation.slug}_#{other.workspace.slug}")
    end
  end

  describe "the form" do
    test "creates the organisation, and takes the person to it", %{conn: conn, user: user} do
      open!([:organisation])
      {:ok, view, _html} = live(conn, ~p"/users/organisations")

      assert {:error, {:live_redirect, %{to: to}}} =
               view |> element("#organisations-new") |> render_click()

      assert to == ~p"/users/organisations/new"
      {:ok, view, _html} = live(conn, to)

      assert view
             |> form("#new-organisation-form", organisation: %{name: ""})
             |> render_change() =~ "can&#39;t be blank"

      view
      |> form("#new-organisation-form", organisation: %{name: "Kestrel Works"})
      |> render_submit()

      [organisation] =
        user
        |> Organisations.list_memberships()
        |> Enum.map(& &1.organisation)
        |> Enum.filter(&(&1.name == "Kestrel Works"))

      assert ApiaryPro.Tenants.kind(organisation) == :organisation
      {path, flash} = assert_redirect(view)
      assert path == ~p"/#{organisation}"
      refute Organisations.has_workspace?(organisation)
      assert flash["info"] == "Kestrel Works is created, and you are its owner."

      # The overview shows the kind cards; the software card links to the type's page, and
      # Create workspace there creates the first workspace and opens its Name step.
      {:ok, overview, _html} = live(conn, path)
      assert has_element?(overview, "#set-up-card-software-link")

      assert {:error, {:live_redirect, %{to: type_page}}} =
               overview |> element("#set-up-card-software-link") |> render_click()

      {:ok, type_view, _html} = live(conn, type_page)

      {:ok, name_step, _html} =
        type_view
        |> element("#workspace-type-create")
        |> render_click()
        |> follow_redirect(conn)

      assert Organisations.has_workspace?(organisation)

      name_step |> form("#set-up-form", workspace: %{name: "Main"}) |> render_submit()
      assert_redirect(name_step)
    end

    test "refuses a name another organisation has, with its address", %{conn: conn} do
      open!([:organisation])
      organisation_fixture(%{organisation_name: "Acme"})
      {:ok, view, _html} = live(conn, ~p"/users/organisations/new")
      count = organisations()

      html =
        view
        |> form("#new-organisation-form", organisation: %{name: "Acme"})
        |> render_submit()

      assert html =~ "Choose another name. Another organisation has the address /acme."
      assert has_element?(view, "#organisation_name-error", "Choose another name.")
      assert organisations() == count
    end

    test "asks which kind where both are open, and makes an operator", %{conn: conn, user: user} do
      open!([:organisation, :operator])
      {:ok, view, _html} = live(conn, ~p"/users/organisations/new")

      # The core's choice field: a button, and a panel of radios, a title and a line each.
      assert has_element?(view, "#new-organisation-form #organisation_kind-choice", "Kind")

      assert has_element?(
               view,
               "#new-organisation-form button#organisation_kind",
               "Choose a kind"
             )

      refute has_element?(view, "#new-organisation-form", "What are you creating?")

      assert has_element?(
               view,
               "#new-organisation-form input[type=radio][name='organisation[kind]'][value='organisation']"
             )

      assert has_element?(
               view,
               "#new-organisation-form input[type=radio][name='organisation[kind]'][value='operator']"
             )

      assert has_element?(
               view,
               "#new-organisation-form",
               "For a team that works in workspaces."
             )

      assert has_element?(
               view,
               "#new-organisation-form",
               "Creates and runs organisations for clients."
             )

      assert field_names(view) == ["organisation[kind]", "organisation[name]"]
      # The kind comes first, so the name does not take the focus.
      assert has_element?(view, "#new-organisation-form input#organisation_name")
      refute has_element?(view, "#new-organisation-form input#organisation_name[phx-mounted]")

      view
      |> form("#new-organisation-form", organisation: %{name: "Tern Ops", kind: "operator"})
      |> render_submit()

      assert {_path, _flash} = assert_redirect(view)

      assert [%{organisation: %Organisation{} = created}] =
               user
               |> Organisations.list_memberships()
               |> Enum.filter(&(&1.organisation.name == "Tern Ops"))

      assert ApiaryPro.Tenants.kind(created) == :operator
    end

    test "where both are open, no kind and an empty name are both answered under their fields",
         %{conn: conn} do
      open!([:organisation, :operator])
      {:ok, view, _html} = live(conn, ~p"/users/organisations/new")
      count = organisations()

      view |> form("#new-organisation-form", organisation: %{name: ""}) |> render_submit()

      assert has_element?(view, "#organisation_kind-error", "choose what to create")
      assert has_element?(view, "#organisation_name-error")
      assert organisations() == count
    end

    test "is not open where both settings are closed", %{conn: conn} do
      open!([])

      assert {:error, {:live_redirect, %{to: "/users/organisations", flash: flash}}} =
               live(conn, ~p"/users/organisations/new")

      assert flash["error"] =~ "You cannot create a new organisation here. Contact support."
    end

    test "refuses a forged kind whose setting is closed, and creates nothing", %{conn: conn} do
      open!([:organisation])
      {:ok, view, _html} = live(conn, ~p"/users/organisations/new")
      before = organisations()

      render_submit(view, "create", %{
        "organisation" => %{"name" => "Forged", "kind" => "operator"}
      })

      assert {path, flash} = assert_redirect(view)
      assert path == ~p"/users/organisations"
      assert flash["error"] =~ "You cannot create a new organisation here. Contact support."
      assert organisations() == before
    end

    test "refuses once both settings closed after the page opened", %{conn: conn} do
      open!([:organisation])
      {:ok, view, _html} = live(conn, ~p"/users/organisations/new")
      before = organisations()
      open!([])

      view
      |> form("#new-organisation-form", organisation: %{name: "Too late"})
      |> render_submit()

      assert {path, flash} = assert_redirect(view)
      assert flash["error"] =~ "You cannot create a new organisation here. Contact support."
      {:ok, page, _html} = live(conn, path)
      refute has_element?(page, "#organisations-new")
      assert organisations() == before
    end
  end

  test "a person in no organisation is offered a way to create one" do
    open!([:organisation])
    user = user_fixture()
    conn = log_in_user(build_conn(), user)

    {:ok, view, _html} = live(conn, ~p"/users/organisations")
    assert has_element?(view, "h1", "You are not part of an organisation yet")

    assert {:error, {:live_redirect, %{to: to}}} =
             view |> element("#organisations-new") |> render_click()

    {:ok, view, _html} = live(conn, to)

    view
    |> form("#new-organisation-form", organisation: %{name: "First of mine"})
    |> render_submit()

    assert [%{organisation: %{name: "First of mine"} = organisation}] =
             Organisations.list_memberships(user)

    assert {path, _flash} = assert_redirect(view)
    assert path == ~p"/#{organisation}"
  end
end
