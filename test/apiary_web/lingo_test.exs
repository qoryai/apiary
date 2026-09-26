defmodule ApiaryWeb.LingoTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Ecto.Query, only: [from: 2]
  use Gettext, backend: ApiaryWeb.Gettext

  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Organisations.Workspace
  alias ApiaryWeb.Lingo

  doctest ApiaryWeb.Lingo

  # A locale no domain has, so a test sees the plug or the hook replace it.
  @elsewhere "xx@nowhere"

  describe "the locale" do
    test "the software domain is the default, and the only catalogue" do
      assert ApiaryWeb.Gettext.__gettext__(:default_locale) == "en@software"
      assert Gettext.known_locales(ApiaryWeb.Gettext) == ["en@software"]
      assert Lingo.locale_for(nil) == Lingo.default_locale()
    end

    test "the software domain keeps workspace and organisation, and names the system" do
      Gettext.with_locale(ApiaryWeb.Gettext, "en@software", fn ->
        assert gettext("Workspace name") == "Workspace name"
        assert gettext("Organisation name") == "Organisation name"
        assert gettext("Name, such as system-token") == "Name, such as forge-token"
      end)
    end

    test "a changeset error in engine words is translated too" do
      assert ApiaryWeb.CoreComponents.translate_error(
               {"is already the name of a workspace in this organisation", []}
             ) == "is already the name of a workspace in this organisation"
    end

    test "plural forms work for a locale with a domain" do
      Gettext.with_locale(ApiaryWeb.Gettext, "en@software", fn ->
        assert ngettext("%{count} day", "%{count} days", 1) == "1 day"
        assert ngettext("%{count} day", "%{count} days", 2) == "2 days"
      end)

      # The rules are the language's, whatever the domain.
      assert ApiaryWeb.Gettext.Plural.init(%{locale: "de@software"}) == "de"
      assert ApiaryWeb.Gettext.Plural.nplurals("de") == 2
      assert ApiaryWeb.Gettext.Plural.plural_forms_header("pt_BR@marketing") =~ "nplurals=2"
    end
  end

  describe "locale_for/1: the person's language, the workspace's domain" do
    test "no user reads the default locale" do
      assert Lingo.locale_for(nil) == "en@software"
      assert Lingo.locale_for(%Scope{}) == "en@software"
    end

    test "outside a workspace, the user's language in the default domain" do
      assert Lingo.locale_for(%Scope{user: %User{language: "en"}}) == "en@software"
    end

    test "in a workspace, the user's language in the workspace's domain" do
      scope = %Scope{user: %User{language: "en"}, workspace: %Workspace{domain: "software"}}
      assert Lingo.locale_for(scope) == "en@software"

      scope = %Scope{scope | workspace: %Workspace{domain: "example"}}
      assert Lingo.locale_for(scope) == "en@example"
    end

    test "a language without a catalogue reads English, in the workspace's domain" do
      scope = %Scope{user: %User{language: "xx"}, workspace: %Workspace{domain: "example"}}
      assert Lingo.locale_for(scope) == "en@example"
      assert Lingo.locale_for(%Scope{user: %User{language: nil}}) == "en@software"
    end

    test "a workspace's stored domain decides, as the scope loads it" do
      %{scope: scope, workspace: workspace} = Apiary.OrganisationsFixtures.sign_up_fixture()
      assert Lingo.locale_for(scope) == "en@software"

      Apiary.Repo.update_all(
        from(w in Workspace, where: w.id == ^workspace.id),
        set: [domain: "example"]
      )

      scope = Apiary.Organisations.load_scope(Scope.for_user(scope.user))
      assert Lingo.locale_for(scope) == "en@example"
    end

    test "a locale of a domain without a catalogue falls back to the source text" do
      Gettext.with_locale(ApiaryWeb.Gettext, "en@example", fn ->
        assert gettext("Workspace name") == "Workspace name"
      end)
    end
  end

  describe "locale_for/2: a render for a recipient" do
    test "reads the recipient's language and the scope's domain" do
      recipient = %User{language: "en"}
      assert Lingo.locale_for(nil, recipient) == "en@software"

      scope = %Scope{user: %User{language: "xx"}, workspace: %Workspace{domain: "example"}}
      assert Lingo.locale_for(scope, recipient) == "en@example"
    end

    test "with_locale/3 renders for the recipient and restores the caller's locale" do
      Gettext.put_locale(ApiaryWeb.Gettext, @elsewhere)

      assert Lingo.with_locale(nil, %User{language: "en"}, fn ->
               Gettext.get_locale(ApiaryWeb.Gettext)
             end) == "en@software"

      assert Gettext.get_locale(ApiaryWeb.Gettext) == @elsewhere
    end
  end

  describe "the plug" do
    test "sets the locale of a request from its scope", %{conn: conn} do
      Gettext.put_locale(ApiaryWeb.Gettext, @elsewhere)
      conn = Lingo.call(conn, Lingo.init([]))
      assert Gettext.get_locale(ApiaryWeb.Gettext) == "en@software"
      assert conn.halted == false
    end

    test "runs in the browser pipeline, also before sign-in", %{conn: conn} do
      Gettext.put_locale(ApiaryWeb.Gettext, @elsewhere)
      conn = get(conn, ~p"/users/log-in")
      assert html_response(conn, 200)
      assert Gettext.get_locale(ApiaryWeb.Gettext) == "en@software"
    end
  end

  describe "the on_mount hook" do
    test "sets the locale of a LiveView from its scope" do
      Gettext.put_locale(ApiaryWeb.Gettext, @elsewhere)
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, current_scope: nil}}
      assert {:cont, ^socket} = Lingo.on_mount(:default, %{}, %{}, socket)
      assert Gettext.get_locale(ApiaryWeb.Gettext) == "en@software"
    end

    test "every LiveView runs it, in its own process", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users/log-in")
      {:dictionary, dictionary} = Process.info(view.pid, :dictionary)
      assert {ApiaryWeb.Gettext, "en@software"} in dictionary
    end

    test "a workspace's page reads the domain's words", %{conn: conn} do
      %{conn: conn, scope: scope} = register_and_log_in_user(%{conn: conn})
      {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings")
      {:dictionary, dictionary} = Process.info(view.pid, :dictionary)
      assert {ApiaryWeb.Gettext, "en@software"} in dictionary
      assert has_element?(view, "h2", "Workspace name")
    end
  end

  test "with_locale/2 renders in the scope's locale and restores the caller's" do
    Gettext.put_locale(ApiaryWeb.Gettext, @elsewhere)
    assert Lingo.with_locale(nil, fn -> gettext("Workspace") end) == "Workspace"
    assert Gettext.get_locale(ApiaryWeb.Gettext) == @elsewhere
  end

  describe "the time zone for ApiaryWeb.Format" do
    alias ApiaryWeb.Format

    test "put_locale/1 sets the person's zone beside the locale, and UTC without one" do
      Lingo.put_locale(%Scope{user: %User{language: "en", time_zone: "Europe/Berlin"}})
      assert Format.time_zone() == "Europe/Berlin"

      Lingo.put_locale(nil)
      assert Format.time_zone() == "Etc/UTC"
    end

    test "a zone the database does not know reads UTC" do
      Lingo.put_locale(%Scope{user: %User{language: "en", time_zone: "Mars/Base"}})
      assert Format.time_zone() == "Etc/UTC"
    end

    test "with_locale/2,3 render in the scope's or the recipient's zone and restore the caller's" do
      Format.put_time_zone("Asia/Tokyo")
      caller = %Scope{user: %User{language: "en", time_zone: "Europe/Berlin"}}
      recipient = %User{language: "en", time_zone: "America/Lima"}

      assert Lingo.with_locale(caller, &Format.time_zone/0) == "Europe/Berlin"
      assert Lingo.with_locale(caller, recipient, &Format.time_zone/0) == "America/Lima"
      assert Format.time_zone() == "Asia/Tokyo"
    end
  end
end
