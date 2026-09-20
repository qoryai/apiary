defmodule ApiaryWeb.DocsControllerTest do
  # Not async: it points the application at a documentation directory of its own.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest, only: [live: 2]

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    Application.put_env(:apiary, :docs_root, tmp_dir)
    on_exit(fn -> Application.delete_env(:apiary, :docs_root) end)
    :ok
  end

  describe "when the documentation is built" do
    setup %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "index.html"), "<html></html>")
    end

    test "/docs goes to its first page, signed in or not", %{conn: conn} do
      assert redirected_to(get(conn, ~p"/docs")) == "/docs/index.html"
    end

    test "a page that does not exist is not found", %{conn: conn} do
      conn = get(conn, "/docs/no-such-page.html")
      assert html_response(conn, 404) =~ "Not Found"
    end
  end

  describe "when it is not" do
    test "/docs says so, and how to build it", %{conn: conn} do
      html = conn |> get(~p"/docs") |> html_response(404)
      assert html =~ "The documentation is not built"
      assert html =~ "mix docs"
    end

    test "so does every path below it", %{conn: conn} do
      html = conn |> get("/docs/no-such-page.html") |> html_response(404)
      assert html =~ "The documentation is not built"
    end
  end

  test "the user menu links to it", %{conn: conn} do
    %{conn: conn} = register_and_log_in_user(%{conn: conn})
    {:ok, _lv, html} = live(conn, ~p"/hive/settings")
    assert html =~ ~s(href="/docs")
  end
end
