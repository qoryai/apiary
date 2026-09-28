defmodule ApiaryWeb.Features do
  @moduledoc """
  The web side of `Apiary.Features`: a page or an endpoint that belongs to a feature says so
  with `use ApiaryWeb.Features, :security`, and answers as a path that does not exist when
  the feature is off. Not *forbidden*: a feature that is off is absent.

  The `use` defines `__feature__/0`. `ApiaryWeb.Features.Routes`, in the endpoint, reads it
  for the route a request matches and answers for the instance before any pipeline runs;
  the router's test reads it so that no route is left without a feature or an explicit
  place among the routes every instance has. The `use` also adds a gate that asks
  `Apiary.Features.on?/2` with the caller's scope: an `on_mount` hook in a LiveView, which
  is what a live navigation meets, and a plug in a controller.

  The features are the core's and the edition's (`Apiary.Features.all/0`), and the
  edition's are known only once it runs: whether a page names a feature there is is
  checked at boot, over the routes of the router the instance serves (`boot!/0`), not when
  the page compiles.
  """

  @behaviour Plug

  alias Apiary.Features

  defmodule NotFound do
    @moduledoc "Raised where a feature is off, and rendered as the 404 of a path that does not exist."
    defexception message: "not found", plug_status: 404
  end

  defmacro __using__(feature) do
    unless is_atom(feature) and not is_nil(feature) do
      raise ArgumentError,
            "use ApiaryWeb.Features takes the name of a feature, got: #{inspect(feature)}"
    end

    # Which gate the caller can take is known from its imports, which are lexical and so
    # settled when this expands: a LiveView imports `on_mount/1`, a controller `plug/2`.
    gate =
      cond do
        Macro.Env.lookup_import(__CALLER__, {:on_mount, 1}) != [] ->
          quote do: on_mount({ApiaryWeb.Features, unquote(feature)})

        Macro.Env.lookup_import(__CALLER__, {:plug, 2}) != [] ->
          quote do: plug(ApiaryWeb.Features, unquote(feature))

        true ->
          raise ArgumentError, "use ApiaryWeb.Features belongs in a LiveView or a controller"
      end

    quote do
      unquote(gate)

      @doc false
      def __feature__, do: unquote(feature)
    end
  end

  @doc """
  boot!/0 checks that every route of the router the instance serves, whose LiveView or
  controller declares a feature, names one of `Apiary.Features.all/0`. Called at boot;
  raises on one that does not, so the instance does not start.
  """
  @spec boot!() :: :ok
  def boot!, do: check_routes!(ApiaryWeb.Edition.router())

  @doc """
  check_routes!/1 is `boot!/0`'s check over the routes of `router`: `:ok`, or an
  `ArgumentError` that names the first module whose feature is none of
  `Apiary.Features.all/0`.
  """
  @spec check_routes!(module) :: :ok
  def check_routes!(router) when is_atom(router) do
    all = Features.all()

    unknown =
      for route <- Phoenix.Router.routes(router),
          module = route_module(route),
          declares_feature?(module),
          module.__feature__() not in all,
          uniq: true,
          do: module

    case unknown do
      [] ->
        :ok

      [module | _] ->
        raise ArgumentError,
              "#{inspect(module)} uses ApiaryWeb.Features with #{inspect(module.__feature__())}, " <>
                "which is not one of #{inspect(all)}"
    end
  end

  defp route_module(%{metadata: %{phoenix_live_view: {live_view, _action, _opts, _extra}}}),
    do: live_view

  defp route_module(%{plug: plug}), do: plug

  defp declares_feature?(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :__feature__, 0)

  @doc false
  def on_mount(feature, _params, _session, socket) do
    if Features.on?(socket.assigns[:current_scope], feature) do
      {:cont, socket}
    else
      raise NotFound
    end
  end

  @impl Plug
  def init(feature) when is_atom(feature), do: feature

  @impl Plug
  def call(conn, feature) do
    if Features.on?(conn.assigns[:current_scope] || conn.assigns[:access_key], feature) do
      conn
    else
      absent(conn)
    end
  end

  # For a feature the instance has and a scope does not: `ApiaryWeb.Features.Routes` has
  # already answered for the instance, before any pipeline. The pipeline has run by now, so
  # this can only come close to an unknown path: its body and type, not the rendering in
  # the format the pipeline chose, which raising would give.
  defp absent(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(404, ApiaryWeb.ErrorHTML.render("404.html", %{}))
    |> Plug.Conn.halt()
  end
end
