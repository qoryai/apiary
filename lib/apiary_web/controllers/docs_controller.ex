defmodule ApiaryWeb.DocsController do
  @moduledoc """
  The way in to the documentation every instance serves at `/docs`, and which of its trees
  that is.

  `mix docs` (`Mix.Tasks.Docs.All`) builds the guides and the module reference into
  `priv/static/docs` once for each set of features the documentation differs by, one tree
  per directory, in the release image too (a feature that is off is absent, from the
  documentation as well). `dir/0` is the tree for the instance's features, and the
  endpoint's `Plug.Static` for `/docs` reads its files from there. `docs` is therefore not
  in `ApiaryWeb.static_paths/0`: a tree is never reachable by its own directory.

  This controller answers what is not a file: `/docs` itself, which goes to the first page,
  and any path below it that was not found. When the documentation has not been built,
  which happens in a checkout before `mix docs`, the page says so and how to build it, with
  `404`.

  In the `:browser` pipeline without `:require_authenticated_user`: the documentation is
  for somebody who has not signed up yet, too.
  """
  use ApiaryWeb, :controller

  @doc "Redirects to the first page of the built documentation, or says it is not built."
  def index(conn, _params) do
    if built?() do
      redirect(conn, to: "/docs/index.html")
    else
      conn
      |> put_status(:not_found)
      |> render(:not_built, page_title: gettext("Documentation"))
    end
  end

  @doc "A path under `/docs` the endpoint found no file for."
  def missing(conn, params) do
    if built?() do
      conn
      |> put_status(:not_found)
      |> put_view(html: ApiaryWeb.ErrorHTML)
      |> render(:"404")
    else
      index(conn, params)
    end
  end

  @doc "Whether `mix docs` has built the tree this instance serves."
  @spec built?() :: boolean()
  def built?, do: File.regular?(Path.join(dir(), "index.html"))

  @doc """
  The directory of the documentation tree for `features`, by default the instance's
  (`Apiary.Features.enabled/0`): of the trees built, the one with the most features, all
  of them among `features`. The trees are built so that this is the one holding exactly
  what those features are owed. With none built it is the directory the tree for exactly
  `features` would have, which does not exist, so nothing is served from it.

  Read on every request under `/docs`, by the endpoint's `Plug.Static` too: a directory
  listing is cheap, and it follows the features wherever a test switches them. It is the
  instance's features, not a caller's: the documentation is public, served before sign-in,
  so it cannot know an organisation; one granted less than its instance reads the
  instance's documentation.
  """
  @spec dir([Apiary.Features.feature()]) :: Path.t()
  def dir(features \\ Apiary.Features.enabled()) do
    root = root()

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
  The name of the tree for `features`: `all` for every feature, as `QORY_FEATURES` says it;
  otherwise the features in the order of `Apiary.Features.all/0`, joined with `+`, as
  `observability+security`.
  """
  @spec tree_name([Apiary.Features.feature()]) :: String.t()
  def tree_name(features) do
    all = Apiary.Features.all()

    case Enum.filter(all, &(&1 in features)) do
      ^all -> "all"
      some -> Enum.map_join(some, "+", &to_string/1)
    end
  end

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
