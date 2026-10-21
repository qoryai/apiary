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
  # kept when they pressed Install (`ApiaryWeb.ConnectSession`), and says how the install
  # ended there. A return the person did not start in this browser is answered with a
  # page that says so; a link that names no connection they reach, and a return that is
  # bad, expired or used, as a path that does not exist, whoever asks, so the link does
  # not tell whether one exists. Behind sign-in: an anonymous visitor is sent to log in
  # first. `return` is kept out of the logs (`:filter_parameters`). Every answer of this
  # controller, the redirect, after a return or not, the 403 page and the 404 alike, says
  # `Referrer-Policy: no-referrer`, so no page it leads to sends the link, with its
  # `return`, on as a referrer.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  use ApiaryWeb, :controller

  plug :no_referrer

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

  defp no_referrer(conn, _opts), do: put_resp_header(conn, "referrer-policy", "no-referrer")

  # How the install ended, said on the integration's page.
  defp told(conn, :linked, name) do
    put_flash(conn, :info, gettext("%{integration} is connected.", integration: name))
  end

  defp told(conn, :cancelled, name) do
    put_flash(
      conn,
      :info,
      gettext("You cancelled the install on %{integration}. Nothing has changed.",
        integration: name
      )
    )
  end

  defp told(conn, {:refused, reason}, name), do: put_flash(conn, :error, refused(reason, name))

  defp refused(:person_not_permitted, name) do
    gettext(
      "%{integration} doesn't confirm that you administer that account. Ask an admin of the account to install it.",
      integration: name
    )
  end

  defp refused(:grant_taken, _name),
    do: gettext("That account is already connected to another organisation.")

  defp refused(:grant_not_confirmed, name) do
    gettext(
      "%{integration} couldn't confirm that installation for you. Install it again from Integrations.",
      integration: name
    )
  end

  defp refused(:grant_suspended, name) do
    gettext(
      "That installation is suspended on %{integration}. Lift the suspension there, then install it again.",
      integration: name
    )
  end

  defp refused(:permission_missing, name) do
    gettext(
      "An owner of the account must approve the updated permissions on %{integration}, then install it again.",
      integration: name
    )
  end

  defp refused(:pass_expired, _name),
    do: gettext("The install took too long and expired. Install it again from Integrations.")

  defp refused(:source_unavailable, _name),
    do: gettext("The installation couldn't be completed just now. Press Install to try again.")

  # The page for a return the person did not start in this browser.
  defp wrong_person do
    gettext(
      "Only the person who started this install can finish it, in the browser they started it in. To install it yourself, start again from Integrations."
    )
  end
end
