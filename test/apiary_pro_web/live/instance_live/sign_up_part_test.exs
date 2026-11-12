defmodule ApiaryProWeb.InstanceLive.SignUpPartTest do
  @moduledoc """
  Sign-up on Instance settings › Configuration (`ApiaryProWeb.InstanceLive.SignUpPart`),
  after the core's Invitations: a row for organisations and one for operators, each with
  its field unless the server's environment sets it; its Save, an instance admin's after
  a recent sign-in; what a save opens and closes, at once; and its entry on the Activity
  page. A test that needs an instance admin hides the suite's instance organisation inside
  its sandbox (`Apiary.EditionKit`), so the organisation it signs up is the instance's.
  """
  # Not async: the variables are the whole node's, and hiding the instance's organisation
  # acts on the row every test shares.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.AccountsFixtures
  import Apiary.OrganisationsFixtures
  import ApiaryPro.SignUpFixtures

  alias ApiaryPro.SignUp

  @organisations "Whether someone without an invitation may sign up and create an organisation, and whether someone signed in may create one from the organisation menu."
  @operators "Whether someone without an invitation may sign up and create an operator, an organisation that provides a harness its clients run, and whether someone signed in may create one from the organisation menu."
  @sudo "You must re-authenticate to access this page."

  defp text(view, selector),
    do:
      view
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.split()
      |> Enum.join(" ")

  defp save(view, attrs),
    do: view |> form("#config-sign-up-form", sign_up: attrs) |> render_submit()

  # The value the select of a row holds.
  defp selected(view, id),
    do:
      view
      |> element("##{id}-input option[selected]")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute("value")

  setup do
    unset_variables()
    Apiary.EditionKit.hide_instance_organisation()
    :ok
  end

  setup :register_and_log_in_user

  describe "the part" do
    test "comes after Invitations, each row with its field, Closed until one is saved",
         %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/instance/configuration")

      order =
        for id <- ["config-invitations", "config-sign-up", "config-note"] do
          {at, _length} = :binary.match(html, ~s(id="#{id}"))
          at
        end

      assert order == Enum.sort(order)
      assert text(view, "#config-sign-up-title") == "Sign-up"

      for {id, label, sentence} <- [
            {"config-sign-up-organisations", "Organisations", @organisations},
            {"config-sign-up-operators", "Operators", @operators}
          ] do
        assert text(view, "##{id} dt") == label
        assert has_element?(view, ~s(##{id} label[for="#{id}-input"]), label)
        assert text(view, "##{id} dd") =~ sentence
        assert has_element?(view, "##{id}-input option[value=closed]", "Closed")
        assert has_element?(view, "##{id}-input option[value=open]", "Open")
        assert selected(view, id) == ["closed"]
        # No source line and no hint: the field says the setting in effect.
        refute has_element?(view, "##{id}-source")
        refute has_element?(view, "##{id}-hint")
      end

      assert has_element?(view, "#config-sign-up-save button[type=submit]", "Save")
    end

    test "shows a setting the environment sets read only, with the variable that sets it",
         %{conn: conn} do
      put_variables(organisations: "open", operators: "")
      {:ok, view, _html} = live(conn, ~p"/instance/configuration")

      assert text(view, "#config-sign-up-organisations-value") == "Open"

      assert text(view, "#config-sign-up-organisations-source") ==
               "Set by SIGNUP_ORGANISATIONS"

      assert has_element?(view, "#config-sign-up-organisations-source code.q-mono")
      refute has_element?(view, "#config-sign-up-organisations-input")
      assert text(view, "#config-sign-up-organisations dd") =~ @organisations

      # Set empty is not set: the row has its field.
      assert selected(view, "config-sign-up-operators") == ["closed"]
      refute has_element?(view, "#config-sign-up-operators-source")
      assert has_element?(view, "#config-sign-up-save")
    end

    test "with both set by the environment, has no form and no Save", %{conn: conn} do
      put_variables(organisations: " closed ", operators: "OPEN")
      {:ok, view, _html} = live(conn, ~p"/instance/configuration")

      assert text(view, "#config-sign-up-organisations-value") == "Closed"
      assert text(view, "#config-sign-up-operators-value") == "Open"
      assert text(view, "#config-sign-up-operators-source") == "Set by SIGNUP_OPERATORS"
      refute has_element?(view, "#config-sign-up-form")
      refute has_element?(view, "#config-sign-up-save")
    end

    test "saves, with its toast, and shows what it saved", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/instance/configuration")

      save(view, %{organisations: "open", operators: "open"})
      assert text(view, "#flash-info") =~ "Sign-up saved."
      assert selected(view, "config-sign-up-organisations") == ["open"]
      assert selected(view, "config-sign-up-operators") == ["open"]
      assert SignUp.kinds() == [:organisation, :operator]

      # A save that changes nothing says the same.
      {:ok, view, _html} = live(conn, ~p"/instance/configuration")
      save(view, %{organisations: "open", operators: "open"})
      assert text(view, "#flash-info") =~ "Sign-up saved."
    end

    test "never saves a setting the environment sets", %{conn: conn} do
      put_variables(organisations: "closed")
      {:ok, view, _html} = live(conn, ~p"/instance/configuration")

      save(view, %{operators: "open"})
      assert text(view, "#flash-info") =~ "Sign-up saved."
      assert SignUp.load() == %{organisation: nil, operator: :open}
    end

    test "asks for a recent sign-in, as the core's parts do", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/instance/configuration")
      old = DateTime.add(DateTime.utc_now(:second), -21, :minute)

      # The part is given the page's scope when the page renders again.
      :sys.replace_state(view.pid, fn state ->
        scope = state.socket.assigns.current_scope
        scope = put_in(scope.user.authenticated_at, old)
        %{state | socket: Phoenix.Component.assign(state.socket, :current_scope, scope)}
      end)

      render_hook(view, "save", %{})
      save(view, %{organisations: "open", operators: "open"})

      assert assert_redirect(view, ~p"/users/log-in") == %{"error" => @sudo}
      assert SignUp.load() == %{organisation: nil, operator: nil}
    end
  end

  describe "a save applies at once" do
    test "opening offers sign-up, and the organisation menu's New organisation",
         %{conn: conn, scope: admin} do
      # Someone who signed up while the environment opened sign-up, which it no longer
      # does.
      put_variables(organisations: "open")
      %{user: person, scope: scope} = sign_up_fixture()
      unset_variables()
      person_conn = log_in_user(build_conn(), person)

      {:ok, sign_up, _html} = live(build_conn(), ~p"/users/register")
      assert has_element?(sign_up, "#sign-up-closed")
      {:ok, home, _html} = live(person_conn, ~p"/#{scope.organisation}")
      refute has_element?(home, "#organisation-menu-new")

      {:ok, view, _html} = live(conn, ~p"/instance/configuration")
      save(view, %{organisations: "open", operators: "open"})
      assert SignUp.kinds() == [:organisation, :operator]

      {:ok, sign_up, _html} = live(build_conn(), ~p"/users/register")
      refute has_element?(sign_up, "#sign-up-closed")
      assert has_element?(sign_up, "#registration_form [name='user[kind]']")
      assert build_conn() |> get(~p"/") |> html_response(200) =~ ~p"/users/register"
      {:ok, _lv, html} = live(build_conn(), ~p"/users/log-in")
      assert html =~ "Create an account"

      {:ok, home, _html} = live(person_conn, ~p"/#{scope.organisation}")
      assert has_element?(home, "#organisation-menu-new", "New organisation")
      {:ok, page, _html} = live(person_conn, ~p"/users/organisations")
      assert has_element?(page, "#organisations-new")

      # Closed again, nothing is offered on the next page loaded.
      {:ok, view, _html} = live(conn, ~p"/instance/configuration")
      save(view, %{organisations: "closed", operators: "closed"})

      {:ok, sign_up, _html} = live(build_conn(), ~p"/users/register")
      assert has_element?(sign_up, "#sign-up-closed")
      refute build_conn() |> get(~p"/") |> html_response(200) =~ ~p"/users/register"
      {:ok, home, _html} = live(person_conn, ~p"/#{scope.organisation}")
      refute has_element?(home, "#organisation-menu-new")
      assert admin.user.id != person.id
    end

    test "a sign-up page open when its kind closes is refused", %{scope: admin} do
      admin = put_in(admin.user.authenticated_at, DateTime.utc_now())
      {:ok, _} = SignUp.save(admin, %{"organisations" => "open", "operators" => "open"})

      {:ok, lv, _html} = live(build_conn(), ~p"/users/register")
      assert has_element?(lv, "#registration_form [name='user[kind]']")

      {:ok, _} = SignUp.save(admin, %{"operators" => "closed"})
      email = unique_user_email()

      lv
      |> form("#registration_form",
        user: %{
          "email" => email,
          "organisation_name" => unique_organisation_name(),
          "kind" => "operator"
        }
      )
      |> render_submit()

      # Refused inside the sign-up's transaction, as today; the page offers what is open
      # now.
      refute Apiary.Accounts.get_user_by_email(email)
      refute has_element?(lv, "#registration_form [name='user[kind]']")

      assert {:error, changeset} =
               Apiary.Organisations.sign_up_user(
                 %{email: email, organisation_name: unique_organisation_name(), kind: "operator"},
                 nil
               )

      assert %{kind: ["is not open for sign-up"]} =
               Apiary.DataCase.errors_on(changeset)
    end
  end

  describe "on the Activity page" do
    test "says the change, and each setting before and after", %{conn: conn, scope: scope} do
      admin = put_in(scope.user.authenticated_at, DateTime.utc_now())
      {:ok, _} = SignUp.save(admin, %{"organisations" => "open", "operators" => "open"})
      {:ok, _} = SignUp.save(admin, %{"operators" => "closed"})

      {:ok, view, _html} = live(conn, "/#{scope.organisation.slug}/audit-log")
      render_async(view)

      {:ok, %{entries: [closed, opened | _]}} =
        Apiary.Audit.list_entries(scope, %{action: "instance.change_sign_up"})

      assert has_element?(view, "#filter-action-form li", "Sign-up changed")

      for entry <- [opened, closed] do
        assert text(view, "#entry-#{entry.id}-action") =~
                 "Changed who may sign up"

        assert text(view, "#entry-#{entry.id}-actor") =~ scope.user.email
      end

      lines =
        view
        |> element("#entry-#{opened.id}-change")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("li, div, span")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      assert "Organisations: Closed → Open" in lines
      assert "Operators: Closed → Open" in lines

      assert text(view, "#entry-#{closed.id}-change") == "Operators: Open → Closed"
    end
  end
end
