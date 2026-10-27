defmodule ApiaryWeb.AdapterInstallController do
  # Install: `POST /:org/settings/integrations/:adapter_id/install`, where an owner or an
  # admin of the organisation connects it to an integration, named by its adapter's public
  # id (`na_…`). Not a page: the form that posts here is the integration's, with the
  # session's CSRF token, which the `:browser` pipeline checks first.
  #
  # In order:
  #
  #   1. a person whose membership `Apiary.Access` does not let connect an integration
  #      (`adapter.connect`, asked of the organisation) is answered `403`, before anything
  #      is looked up;
  #   2. an adapter the person does not find (`Apiary.Adapters.get_adapter/2`: deleted, of
  #      another kind, or none) is a path that does not exist, `404`;
  #   3. `Apiary.Adapters.connect/2` starts the connection and makes its connect pass. The
  #      nonce it gives is kept in the person's session (`ApiaryWeb.ConnectSession`), so
  #      the return comes back in this browser, and the person is sent to the address it
  #      answers, the adapter's connect address with the pass. With `back` one of
  #      `ApiaryWeb.ConnectSession.backs/0`, such as "set-up" from the workspace
  #      set-up's Work source step, the session keeps it beside the nonce, and the return
  #      leads there (`ApiaryWeb.AdapterRedirectController`); any other `back` is
  #      ignored. Neither the pass nor the connect address carries it;
  #   4. when the organisation's connected connection cannot take a new pass yet, as for
  #      a second press in the same second, the person is sent to the integration's page;
  #      when the adapter cannot be connected yet (it declared no address, holds no key in
  #      use, or no pass could be made), or the organisation is not offered it (not
  #      configured, or serving none of its workspaces' domains,
  #      `Apiary.Adapters.offered?/2`), to Add an integration. Neither changes anything.
  #
  # The address is outside the console, so the person is sent there by a page that
  # refreshes to it (`ApiaryWeb.SendOn`), told no referrer and kept by no cache. The pass
  # is never logged.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :factory

  alias Apiary.{Access, Adapters}
  alias Apiary.Nodes.Node
  alias ApiaryWeb.{ConnectSession, SendOn}

  def create(conn, %{"adapter_id" => adapter_id} = params) do
    scope = conn.assigns.current_scope

    with :ok <- Access.authorize(scope, :"adapter.connect", scope.organisation),
         %Node{} = adapter <- Adapters.get_adapter(scope, adapter_id) || {:error, :not_found},
         {:ok, url, session} <- Adapters.connect(scope, adapter) do
      conn
      |> ConnectSession.put(session, params["back"])
      |> SendOn.send_on(url)
    else
      {:error, :forbidden} ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(403, ApiaryWeb.ErrorHTML.render("403.html", %{}))

      {:error, :not_found} ->
        raise ApiaryWeb.NotFound

      {:error, :too_soon} ->
        redirect(conn,
          to: ~p"/#{scope.organisation}/settings/integrations/#{adapter_id}"
        )

      {:error, reason}
      when reason in [:no_connect_url, :no_key, :not_offered, :invalid, :too_long] ->
        redirect(conn, to: ~p"/#{scope.organisation}/settings/integrations/new")
    end
  end
end
