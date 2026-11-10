defmodule ApiaryWeb.DocsController do
  @moduledoc """
  The way in to the documentation every instance serves at `/docs`, and which of its trees
  that is.

  `mix docs` (`Mix.Tasks.Docs.All`) builds the guides and the module reference into
  `priv/static/docs` once for each set of features the documentation differs by, one tree
  per directory, in the release image too (a feature that is off is absent, from the
  documentation as well). `dir/0` is the tree for the instance's features, and the
  endpoint's `Plug.Static` for `/docs` reads its files from there. `docs` is therefore not
  in `ApiaryWeb.static_paths/0`: a tree is never reachable by its directory.

  This controller answers what is not a file: `/docs` itself, which goes to the first page,
  and any path below it that was not found. When the documentation has not been built,
  which happens in a checkout before `mix docs`, the page says so and how to build it, with
  `404`.

  In the `:browser` pipeline without `:require_authenticated_user`: the documentation is
  for somebody who has not signed up yet, too.

  ## The guides for instance admins

  Some guides are for whoever runs the instance (`admin_guides/0`): `install.md` and
  `hosting-checklist.md`, and an edition's (`c:ApiaryWeb.Edition.admin_guides/0`).
  `mix docs` builds each tree twice: the public tree without them, so its pages, sidebar
  and search never list them, and the tree for instance admins with every guide, under
  `admin/` of the same root (`admin_dir/1`). The endpoint serves only the public tree, so
  an admin guide's address under `/docs` is not found there. `admin/2` serves the admins'
  tree at `/docs/admin`, to a signed-in instance admin, who may read the instance
  (`instance.read`, asked in their instance scope, `Apiary.Access.instance_scope/1`)
  only, and answers anyone else 404, signed in or not; `/docs` itself leads an instance
  admin there. Whoever runs the server without signing in reads the guides in the
  repository's `guides` directory.
  """
  use ApiaryWeb, :controller

  # The core's guides for instance admins, by file name.
  @admin_guides ["install.md", "hosting-checklist.md"]

  @doc """
  Redirects to the first page of the built documentation: the admins' tree for an
  instance admin, where it is built, else the public tree; or says it is not built.
  """
  def index(conn, _params) do
    cond do
      admin?(conn) and admin_built?() -> redirect(conn, to: "/docs/admin/index.html")
      built?() -> redirect(conn, to: "/docs/index.html")
      true -> not_built(conn)
    end
  end

  @doc "A path under `/docs` the endpoint found no file for."
  def missing(conn, params) do
    if built?(), do: not_found(conn), else: index(conn, params)
  end

  @doc """
  A path under `/docs/admin`: for a signed-in instance admin, the file of the admins' tree
  (`admin_dir/0`), `/docs/admin` itself leading to its first page, and 404 for a path with
  no file; for anyone else, 404, as for a path that does not exist. The answer is marked
  `private`, so no shared cache keeps it for another person.
  """
  def admin(conn, params) do
    cond do
      not admin?(conn) -> not_found(conn)
      not admin_built?() -> redirect(conn, to: "/docs")
      Map.get(params, "path", []) == [] -> redirect(conn, to: "/docs/admin/index.html")
      true -> serve_admin(conn)
    end
  end

  defp serve_admin(conn) do
    static =
      Plug.Static.init(
        at: "/docs/admin",
        from: admin_dir(),
        cache_control_for_etags: "private",
        cache_control_for_vsn_requests: "private"
      )

    case Plug.Static.call(conn, static) do
      %Plug.Conn{halted: true} = served -> served
      _not_found -> not_found(conn)
    end
  end

  defp admin?(conn),
    do: ApiaryWeb.Access.instance_can?(conn.assigns[:current_scope], :"instance.read")

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> put_view(html: ApiaryWeb.ErrorHTML)
    |> put_format("html")
    |> render(:"404")
  end

  defp not_built(conn) do
    conn
    |> put_status(:not_found)
    |> render(:not_built, page_title: gettext("Documentation"))
  end

  @doc """
  The guides only instance admins read, by file name: the core's, `install.md` and
  `hosting-checklist.md`, then the edition's (`c:ApiaryWeb.Edition.admin_guides/0`), which
  extend the core's list and never replace it. `mix docs.all` reads it to split the
  trees.
  """
  @spec admin_guides() :: [String.t()]
  def admin_guides, do: Enum.uniq(@admin_guides ++ ApiaryWeb.Edition.admin_guides())

  @doc "Whether `mix docs` has built the tree this instance serves."
  @spec built?() :: boolean()
  def built?, do: File.regular?(Path.join(dir(), "index.html"))

  @doc "Whether `mix docs` has built the admins' tree for this instance's features."
  @spec admin_built?() :: boolean()
  def admin_built?, do: File.regular?(Path.join(admin_dir(), "index.html"))

  @doc """
  The directory of the documentation tree for `features`, by default the instance's
  (`Apiary.Features.enabled/0`): of the trees built, the one with the most features, all
  of them among `features`. The trees are built so that this is the one holding exactly
  what those features are owed. With none built it is the directory the tree for exactly
  `features` would have, which does not exist, so nothing is served from it.

  Read on every request under `/docs`, by the endpoint's `Plug.Static` too: a directory
  listing is cheap, and it follows the features wherever a test switches them. It is the
  instance's features, not a caller's: the documentation is public, served before sign-in,
  so it cannot know an organisation; one with fewer features than its instance reads the
  instance's documentation.
  """
  @spec dir([Apiary.Features.feature()]) :: Path.t()
  def dir(features \\ Apiary.Features.enabled()), do: tree_dir(root(), features)

  @doc """
  The directory of the admins' tree for `features`, by default the instance's: as
  `dir/1`, among the trees under `admin/` of the root, which hold every guide, the
  admins' guides (`admin_guides/0`) included.
  """
  @spec admin_dir([Apiary.Features.feature()]) :: Path.t()
  def admin_dir(features \\ Apiary.Features.enabled()),
    do: tree_dir(Path.join(root(), "admin"), features)

  defp tree_dir(root, features) do
    tree =
      case File.ls(root) do
        {:ok, names} ->
          names
          |> Enum.flat_map(&tree_features/1)
          |> Enum.filter(&(&1 -- features == []))
          |> Enum.max_by(&length/1, fn -> features end)

        {:error, _} ->
          features
      end

    Path.join(root, tree_name(tree))
  end

  @doc """
  The name of the tree for `features`, of which it reads only the ones the documentation
  differs by (`Apiary.Features.documented/0`): `all` for every one of those, opt-in
  (`Apiary.Features.opt_in/0`) or not; otherwise those in the order of
  `Apiary.Features.all/0`, joined with `+`, as `observability+security`.
  """
  @spec tree_name([Apiary.Features.feature()]) :: String.t()
  def tree_name(features) do
    documented = Apiary.Features.documented()

    case Enum.filter(documented, &(&1 in features)) do
      ^documented -> "all"
      some -> Enum.map_join(some, "+", &to_string/1)
    end
  end

  # The tree `all` is every feature the documentation differs by, whether or not
  # `QORY_FEATURES=all` turns each on.
  defp tree_features("all"), do: [Apiary.Features.documented()]

  defp tree_features(name) do
    case Apiary.Features.parse(String.replace(name, "+", ",")) do
      {:ok, features} -> if tree_name(features) == name, do: [features], else: []
      {:error, _} -> []
    end
  end

  # The tests point `config :apiary, :docs_root` at a directory of their own; nothing else
  # sets it.
  defp root do
    Application.get_env(:apiary, :docs_root, Application.app_dir(:apiary, "priv/static/docs"))
  end
end
