defmodule ApiaryWeb.DocsController do
  @moduledoc """
  The way in to the documentation every instance serves at `/docs`.

  The guides and the module reference are built by `mix docs` into `priv/static/docs`,
  in the release image too, and the endpoint serves the files from there. This controller
  answers what is not a file: `/docs` itself, which goes to the first page, and any path
  below it that was not found. When the documentation has not been built, which happens
  in a checkout before `mix docs`, the page says so and how to build it, with `404`.

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
      |> render(:not_built, page_title: "Documentation")
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

  @doc """
  Whether `mix docs` has built the documentation this instance serves. The tests point
  `config :apiary, :docs_root` at a directory of their own; nothing else sets it.
  """
  @spec built?() :: boolean()
  def built? do
    :apiary
    |> Application.get_env(:docs_root, Application.app_dir(:apiary, "priv/static/docs"))
    |> Path.join("index.html")
    |> File.regular?()
  end
end
