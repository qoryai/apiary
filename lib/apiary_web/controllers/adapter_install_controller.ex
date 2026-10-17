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
  #      answers, the adapter's connect address with the pass;
  #   4. while the organisation is connected to it already, the person is sent to the
  #      integration's page; when the adapter cannot be connected yet (it declared no
  #      address, holds no key in use, or no pass could be made), to Add an integration.
  #      Neither changes anything.
  #
  # The address is outside the console, and the console's pages say `form-action 'self'`
  # (`ApiaryWeb.ContentSecurityPolicy`), which a browser applies to the redirects that
  # follow a form's POST too. So the person is not sent there by a redirect: the answer is
  # a page with no text that refreshes to it at once (`<meta http-equiv="refresh">`), a
  # new navigation, not a form's. It says `Referrer-Policy: no-referrer`, so the address is not
  # told which page sent the person, and `Cache-Control: no-store`, so the pass is kept by
  # no cache. The pass is never logged.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :factory

  alias Apiary.{Access, Adapters}
  alias Apiary.Nodes.Node
  alias ApiaryWeb.ConnectSession

  def create(conn, %{"adapter_id" => adapter_id}) do
    scope = conn.assigns.current_scope

    with :ok <- Access.authorize(scope, :"adapter.connect", scope.organisation),
         %Node{} = adapter <- Adapters.get_adapter(scope, adapter_id) || {:error, :not_found},
         {:ok, url, session} <- Adapters.connect(scope, adapter) do
      conn
      |> ConnectSession.put(session)
      |> send_on(url)
    else
      {:error, :forbidden} ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(403, ApiaryWeb.ErrorHTML.render("403.html", %{}))

      {:error, :not_found} ->
        raise ApiaryWeb.NotFound

      {:error, :connected} ->
        redirect(conn,
          to: ~p"/#{scope.organisation}/settings/integrations/#{adapter_id}"
        )

      {:error, reason} when reason in [:no_connect_url, :no_key, :invalid, :too_long] ->
        redirect(conn, to: ~p"/#{scope.organisation}/settings/integrations/new")
    end
  end

  # The page that sends the person on to `url`, the connect address the adapter declared,
  # held to `Apiary.Adapters.Wire.url?/1` and stored under
  # `Apiary.Nodes.Node.connect_url_changeset/2`, with the pass, escaped as an attribute.
  defp send_on(conn, url) do
    content = Phoenix.HTML.attributes_escape(content: "0;url=" <> url)

    conn
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("text/html")
    |> send_resp(
      200,
      [
        ~s(<!DOCTYPE html><html><head><meta charset="utf-8">),
        ~s(<meta name="referrer" content="no-referrer">),
        ~s(<meta http-equiv="refresh"),
        Phoenix.HTML.safe_to_string(content),
        ~s(></head><body></body></html>)
      ]
    )
  end
end
