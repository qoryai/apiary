defmodule ApiaryWeb.Features.Routes do
  @moduledoc """
  The instance's features at the door: a request for a route whose feature the instance
  does not have is answered as a path the router does not know, before any pipeline runs.

  It sits in the endpoint just before the router, and finds the route in the one the
  endpoint dispatches to (`ApiaryWeb.Edition.router/0`) unless given one. Behind it the
  pipelines would answer first, and differently from an unknown path: an anonymous
  visitor redirected to sign in, an unsigned gateway told `401`, a JSON error where the
  unknown path gets text, the browser's security headers set. Each is a sign the route
  exists. Raising `Phoenix.Router.NoRouteError` here makes the answer the one the router
  gives an unknown path.

  The route is found with `Phoenix.Router.route_info/4`, from the path's segments decoded
  as the router decodes them, so that a path with a character escaped is found as the
  route it is routed to. Its feature is read from the LiveView or controller that
  declares one (`use ApiaryWeb.Features`); a route whose module names several, with
  `any:`, passes when the instance has one of them. Below the
  instance, where a person may be shown less than the instance has, the gates of
  `ApiaryWeb.Features` still decide per scope, and they alone see a live navigation, which
  never reaches here. To a signed request of the server contract the gates answer as the
  instance: its access key follows the instance's features alone.

  One request passes on to its route with the feature off: a request that carries a
  request signature (`X-Qory-Signature-Ed25519`), on a route of the server contract that
  pipes through `:contract`, `:contract_events` or `:contract_registration`, or on a
  signed route of another contract, which this documentation does not name. Each of these
  contracts signs every answer to a verified request, `404` included, so that `404` comes
  once the request is verified, from the controller's gate; a request that does not verify
  is told `401`, as on any route of its contract.
  """
  @behaviour Plug

  # The pipelines of `ApiaryWeb.Routes` that verify a signed request of the server contract,
  # and `:contract_adapter` and `:contract_pool`, which verify an adapter's and a node
  # pool's (`ApiaryWeb.Contract.AdapterRequest`).
  @signed_pipelines [
    :contract,
    :contract_events,
    :contract_registration,
    :contract_adapter,
    :contract_pool
  ]

  @impl Plug
  def init(router) when is_atom(router), do: router
  def init([]), do: nil

  @impl Plug
  def call(conn, nil), do: call(conn, ApiaryWeb.Edition.router())

  def call(conn, router) do
    case decoded(conn.path_info) do
      {:ok, path} -> gate(conn, router, path)
      :error -> conn
    end
  end

  defp gate(conn, router, path) do
    route = Phoenix.Router.route_info(router, conn.method, path, conn.host)

    case feature(route) do
      nil ->
        conn

      gate ->
        cond do
          ApiaryWeb.Features.on?(gate) -> conn
          signed?(route, conn) -> conn
          true -> raise(Phoenix.Router.NoRouteError, conn: conn, router: router)
        end
    end
  end

  # The segments as the router matches them, each decoded (`URI.decode/1`), so that
  # `/v1/source%2Ditems` is found as the route it is routed to. On the Elixir this project
  # pins (`mise.toml`), `URI.decode/1` keeps a malformed escape as written, as the router
  # does, so the gate finds the same route. On an Elixir where it raises, the result is
  # `:error`: the gate passes the request on, and the router raises the same for any path.
  defp decoded(path_info) do
    {:ok, Enum.map(path_info, &URI.decode/1)}
  rescue
    ArgumentError -> :error
  end

  # The feature the matched route's module declares, or the features with `any:`
  # (`ApiaryWeb.Features.gate/1`), or nil for a route every instance has and for a path the
  # router does not know, which it answers itself.
  defp feature(%{phoenix_live_view: {live_view, _action, _opts, _extra}}),
    do: ApiaryWeb.Features.gate(live_view)

  defp feature(%{plug: plug}), do: ApiaryWeb.Features.gate(plug)
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
end
