defmodule ApiaryWeb.Features.Routes do
  @moduledoc """
  The instance's features at the door: a request for a route whose feature the instance
  does not have is answered as a path the router does not know, before any pipeline runs
  (decision 0070).

  It sits in the endpoint just before the router. Behind it the pipelines would answer
  first, and differently from an unknown path: an anonymous visitor redirected to sign in,
  an unsigned runner told `401`, a JSON error where the unknown path gets text, the
  browser's security headers set. Each is a sign the route exists. Raising
  `Phoenix.Router.NoRouteError` here makes the answer the router's own.

  The route is found with `Phoenix.Router.route_info/4` and its feature read from the
  LiveView or controller that declares one (`use ApiaryWeb.Features`). Below the instance,
  where an organisation may have less than the instance, the gates of `ApiaryWeb.Features`
  still decide per scope, and they alone see a live navigation, which never reaches here.
  """
  @behaviour Plug

  alias Apiary.Features

  @impl Plug
  def init(router) when is_atom(router), do: router

  @impl Plug
  def call(conn, router) do
    case feature(router, conn) do
      nil ->
        conn

      feature ->
        if Features.on?(feature),
          do: conn,
          else: raise(Phoenix.Router.NoRouteError, conn: conn, router: router)
    end
  end

  # The feature the matched route's module declares, or nil for a route every instance has
  # and for a path the router does not know, which it answers itself.
  defp feature(router, conn) do
    case Phoenix.Router.route_info(router, conn.method, conn.path_info, conn.host) do
      %{phoenix_live_view: {live_view, _action, _opts, _extra}} -> declared(live_view)
      %{plug: plug} -> declared(plug)
      _ -> nil
    end
  end

  defp declared(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__feature__, 0),
      do: module.__feature__()
  end
end
