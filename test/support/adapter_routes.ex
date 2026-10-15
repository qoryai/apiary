defmodule ApiaryWeb.AdapterRoutes do
  @moduledoc """
  The paths of an organisation's integrations, mounted for the tests until the router
  holds them: a router of the core's routes with the integrations' pages in the
  `live_session :workspace`, after the organisation's own pages, as an edition's router
  adds a page (`ApiaryWeb.Routes`), and an endpoint that dispatches to it. A test module
  that visits them sets `@endpoint ApiaryWeb.AdapterRoutes.Endpoint` and calls `start!/0`
  in its setup.

  The router's paths, actions and modules are the ones the router will hold; once it
  does, this module goes, and the tests take `ApiaryWeb.Endpoint` again.
  """

  defmodule Router do
    @moduledoc false
    use ApiaryWeb, :router

    import ApiaryWeb.Routes

    pipelines()
    public_routes()
    account_routes()
    visitor_routes()
    instance_routes()

    organisation_routes do
      live "/:org/settings/integrations", ApiaryWeb.AdapterLive.Index, :index
      live "/:org/settings/integrations/new", ApiaryWeb.AdapterLive.Index, :new
      live "/:org/settings/integrations/:adapter_id", ApiaryWeb.AdapterLive.Show, :collections

      live "/:org/settings/integrations/:adapter_id/node-pools",
           ApiaryWeb.AdapterLive.Show,
           :pools

      live "/:org/settings/integrations/:adapter_id/settings",
           ApiaryWeb.AdapterLive.Show,
           :settings

      live "/:org/settings/integrations/:adapter_id/settings/rename",
           ApiaryWeb.AdapterLive.Show,
           :rename

      live "/:org/settings/integrations/:adapter_id/settings/remove",
           ApiaryWeb.AdapterLive.Show,
           :remove

      live "/:org/settings/integrations/:adapter_id/access-key",
           ApiaryWeb.AdapterLive.AccessKey,
           :index

      live "/:org/settings/integrations/:adapter_id/access-key/new-code",
           ApiaryWeb.AdapterLive.AccessKey,
           :new_code

      live "/:org/settings/integrations/:adapter_id/access-key/keys/:key_id/revoke",
           ApiaryWeb.AdapterLive.AccessKey,
           :revoke

      live "/:org/settings/integrations/:adapter_id/access-key/codes/:code_id/revoke",
           ApiaryWeb.AdapterLive.AccessKey,
           :revoke_code
    end
  end

  defmodule Endpoint do
    @moduledoc false
    # `ApiaryWeb.Endpoint`'s session, security policy and feature gate, in front of the
    # router above.
    use Phoenix.Endpoint, otp_app: :apiary

    @session_options [
      store: :cookie,
      key: "_apiary_key",
      signing_salt: "pFOPn1LM",
      same_site: "Lax"
    ]

    socket "/live", Phoenix.LiveView.Socket,
      websocket: [connect_info: [:peer_data, :user_agent, session: @session_options]]

    plug ApiaryWeb.ContentSecurityPolicy
    plug Plug.RequestId

    plug Plug.Parsers,
      parsers: [:urlencoded, :multipart, :json],
      pass: ["*/*"],
      json_decoder: Phoenix.json_library()

    plug Plug.MethodOverride
    plug Plug.Head
    plug Plug.Session, @session_options
    plug ApiaryWeb.Features.Routes, ApiaryWeb.AdapterRoutes.Router
    plug ApiaryWeb.AdapterRoutes.Router
  end

  @doc """
  start!/0 starts the endpoint, once for the whole suite, with `ApiaryWeb.Endpoint`'s
  configuration and no server.
  """
  def start! do
    :global.trans({__MODULE__, self()}, fn ->
      if Process.whereis(Endpoint) do
        :ok
      else
        config = Application.get_env(:apiary, ApiaryWeb.Endpoint, [])
        Application.put_env(:apiary, Endpoint, Keyword.put(config, :server, false))

        case Endpoint.start_link() do
          {:ok, pid} ->
            # Kept apart from the test that started it, which ends before the suite does.
            Process.unlink(pid)
            :ok

          {:error, {:already_started, _pid}} ->
            :ok
        end
      end
    end)
  end
end
