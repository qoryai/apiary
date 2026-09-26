defmodule ApiaryWeb.LingoTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  use Gettext, backend: ApiaryWeb.Gettext

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
      %{conn: conn} = register_and_log_in_user(%{conn: conn})
      {:ok, view, _html} = live(conn, ~p"/workspace/settings")
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
end
