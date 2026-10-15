defmodule ApiaryWeb.AdapterRedirectController do
  # A link that names an organisation's connection to an integration by the connection's
  # public id (`GET /integrations/:connection_id`, `ac_…`), as an adapter gives one. Not a
  # page.
  #
  # To a signed-in person who reaches the connection's organisation and may read its
  # integrations there (`Apiary.Adapters.Connections.locate/2`), it leads to the
  # integration's page in that organisation. With `return`, what the adapter hands back
  # when the person comes back from it, it first takes the return
  # (`Apiary.Adapters.Connections.complete_return/4`) with the nonce the person's session
  # kept when they pressed Install (`ApiaryWeb.ConnectSession`), then leads there. A
  # return the person did not start in this browser is refused (403); a link that names
  # no connection they reach, and a return that is bad, expired or used, as a path that
  # does not exist, whoever asks, so the link does not tell whether one exists. Behind
  # sign-in: an anonymous visitor is sent to log in first. `return` is kept out of the
  # logs (`:filter_parameters`).
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  use ApiaryWeb, :controller
  use ApiaryWeb.Features, :factory

  alias Apiary.Adapters.Connections
  alias ApiaryWeb.ConnectSession

  def show(conn, %{"connection_id" => connection_id} = params) do
    case Connections.locate(conn.assigns.current_scope, connection_id) do
      {:ok, connection, scope} ->
        path = ~p"/#{scope.organisation}/settings/integrations/#{connection.adapter}"

        case params do
          %{"return" => token} -> complete(conn, connection, token, path)
          _none -> redirect(conn, to: path)
        end

      :error ->
        raise ApiaryWeb.NotFound
    end
  end

  defp complete(conn, connection, token, path) do
    session_nonce = ConnectSession.fetch(conn, connection.public_id)

    case Connections.complete_return(
           conn.assigns.current_scope,
           connection.public_id,
           token,
           session_nonce
         ) do
      {:ok, outcome} ->
        conn
        |> ConnectSession.drop(connection.public_id)
        |> told(outcome, connection.adapter.name)
        |> redirect(to: path)

      {:error, :wrong_person} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(403, wrong_person())

      {:error, :not_found} ->
        raise ApiaryWeb.NotFound
    end
  end

  # How the install ended: the integration's page does not say it.
  defp told(conn, _outcome, _name), do: conn

  # The answer to a return the person did not start in this browser: the status, in plain
  # text.
  defp wrong_person, do: Phoenix.Controller.status_message_from_template("403.html")
end
