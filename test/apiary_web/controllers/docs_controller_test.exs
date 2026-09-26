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

  # A tree per set of features, as `mix docs` builds them, each page saying which it is.
  @every "all"
  @trees ["observability", "observability+security", @every]

  defp build(tmp_dir, trees) do
    for tree <- trees do
      File.mkdir_p!(Path.join(tmp_dir, tree))
      File.write!(Path.join([tmp_dir, tree, "index.html"]), "<html><body>#{tree}</body></html>")
    end

    :ok
  end

  describe "when the documentation is built" do
    setup %{tmp_dir: tmp_dir}, do: build(tmp_dir, @trees)

    test "/docs goes to its first page, signed in or not", %{conn: conn} do
      assert redirected_to(get(conn, ~p"/docs")) == "/docs/index.html"
    end

    test "a page that does not exist is not found", %{conn: conn} do
      conn = get(conn, "/docs/no-such-page.html")
      assert html_response(conn, 404) =~ "Not Found"
    end

    @tag with_features: Apiary.Features.all()
    test "an instance with every feature is served the tree of every feature", %{conn: conn} do
      assert served(conn, "/docs/index.html") == @every
    end

    @tag with_features: [:observability, :security]
    test "an instance with security and not every feature is served the security tree",
         %{conn: conn} do
      assert served(conn, "/docs/index.html") == "observability+security"
    end

    @tag with_features: [:observability]
    test "an instance without security is served the tree without it", %{conn: conn} do
      assert served(conn, "/docs/index.html") == "observability"
    end

    @tag with_features: [:observability, :managed_organisations]
    test "the tree is the richest the instance's features cover", %{conn: conn} do
      assert served(conn, "/docs/index.html") == "observability"
    end

    @tag with_features: [:observability]
    test "another tree is not reachable by its directory", %{conn: conn} do
      conn = get(conn, "/docs/observability+security/index.html")
      assert html_response(conn, 404) =~ "Not Found"
    end
  end

  describe "when only some trees are built" do
    setup %{tmp_dir: tmp_dir}, do: build(tmp_dir, ["observability", "observability+security"])

    @tag with_features: Apiary.Features.all()
    test "every feature is served the richest tree there is", %{conn: conn} do
      assert served(conn, "/docs/index.html") == "observability+security"
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

    @tag with_features: [:observability]
    test "so does a tree built for other features only", %{conn: conn, tmp_dir: tmp_dir} do
      build(tmp_dir, ["observability+security"])
      html = conn |> get(~p"/docs") |> html_response(404)
      assert html =~ "The documentation is not built"
    end
  end

  describe "the built documentation in the application" do
    # Under priv/static/docs itself, where `mix docs` builds: a tree is never served by
    # the endpoint's static files at its own path, only through /docs for the instance.
    setup do
      Application.delete_env(:apiary, :docs_root)
      dir = Application.app_dir(:apiary, "priv/static/docs/observability+security")
      name = "served-in-test-#{System.unique_integer([:positive])}.html"
      created? = not File.dir?(dir)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, name), "<html><body>served</body></html>")

      on_exit(fn ->
        File.rm(Path.join(dir, name))
        if created?, do: File.rm_rf(dir)
      end)

      %{name: name}
    end

    @tag with_features: [:observability, :security]
    test "is served under /docs from the instance's tree", %{conn: conn, name: name} do
      conn = get(conn, "/docs/#{name}")
      assert conn.status == 200
      assert conn.resp_body =~ "served"
      assert get_resp_header(conn, "content-type") == ["text/html"]
    end

    @tag with_features: [:observability]
    test "is not served to an instance without the tree's features", %{conn: conn, name: name} do
      assert conn |> get("/docs/#{name}") |> html_response(404)
      assert conn |> get("/docs/observability+security/#{name}") |> html_response(404)
    end
  end

  defp served(conn, path) do
    body = conn |> get(path) |> response(200)
    [_, tree] = Regex.run(~r{<body>(.*)</body>}, body)
    tree
  end

  test "the user menu links to it", %{conn: conn} do
    %{conn: conn} = register_and_log_in_user(%{conn: conn})
    {:ok, _lv, html} = live(conn, ~p"/workspace/settings")
    assert html =~ ~s(href="/docs")
  end
end
