defmodule ApiaryWeb.Features.Routes do
  @moduledoc """
  The instance's features at the door: a request for a route whose feature the instance
  does not have is answered as a path the router does not know, before any pipeline runs.

  It sits in the endpoint just before the router, and finds the route in the one the
  endpoint dispatches to (`ApiaryWeb.Edition.router/0`) unless given one. Behind it the
  pipelines would answer first, and differently from an unknown path: an anonymous
  visitor redirected to sign in, an unsigned gateway told `401`, a JSON error where the
  unknown path gets text, the browser's security headers set. Each is a sign the route
  exists. Raising `Phoenix.Router.NoRouteError` here makes the answer the router's own.

  The route is found with `Phoenix.Router.route_info/4` and its feature read from the
  LiveView or controller that declares one (`use ApiaryWeb.Features`). Below the instance,
  where an organisation may have less than the instance, the gates of `ApiaryWeb.Features`
  still decide per scope, and they alone see a live navigation, which never reaches here.

  One request passes on to its route with the feature off: a request of the server
  contract that carries a request signature (`X-Qory-Signature-Ed25519`), on a route that
  pipes through `:contract` or `:contract_limited`. The contract signs every answer to a
  verified request, `404` included, so that `404` comes once the request is verified, from
  the controller's gate; a request that does not verify is told `401`, as on any route of
  the contract.
  """
  @behaviour Plug

  alias Apiary.Features

  # The pipelines of `ApiaryWeb.Routes` that verify a signed request of the server contract.
  @signed_pipelines [:contract, :contract_limited]

  @impl Plug
  def init(router) when is_atom(router), do: router
  def init([]), do: nil

  @impl Plug
  def call(conn, nil), do: call(conn, ApiaryWeb.Edition.router())

  def call(conn, router) do
    route = Phoenix.Router.route_info(router, conn.method, conn.path_info, conn.host)

    case feature(route) do
      nil ->
        conn

      feature ->
        cond do
          Features.on?(feature) -> conn
          signed?(route, conn) -> conn
          true -> raise(Phoenix.Router.NoRouteError, conn: conn, router: router)
        end
    end
  end

  # The feature the matched route's module declares, or nil for a route every instance has
  # and for a path the router does not know, which it answers itself.
  defp feature(%{phoenix_live_view: {live_view, _action, _opts, _extra}}), do: declared(live_view)
  defp feature(%{plug: plug}), do: declared(plug)
  defp feature(_route), do: nil

  # A signed request of the server contract goes on to be verified: the contract signs
  # every answer to a verified request, its 404 among them, and the controller's gate
  # (`ApiaryWeb.Features`) sends that 404 once `ApiaryWeb.Contract.SignedRequest` has
  # verified it. An unsigned one is answered here, as an unknown path.
  defp signed?(%{pipe_through: pipelines}, conn) do
    Enum.any?(pipelines, &(&1 in @signed_pipelines)) and
      Plug.Conn.get_req_header(conn, "x-qory-signature-ed25519") != []
  end

  defp signed?(_route, _conn), do: false

  defp declared(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__feature__, 0),
      do: module.__feature__()
  end
end
