defmodule ApiaryWeb.InstanceMailController do
  @moduledoc """
  The test link a save of Instance settings › Mail sends to the instance admin who saved
  (`Apiary.Mail.save_settings/3`). Not a page: a redirect.

      GET /instance/mail/confirm/:token

  Behind sign-in: a visitor is sent to log in first, and nothing changes. Followed by that
  admin, signed in as themselves, within its time, it turns mail on and confirms their
  address (`Apiary.Mail.turn_on/2`), and leads to the page with a line saying so. It signs
  no one in and changes no password. Followed by another instance admin, or once it has
  expired or been replaced, it changes nothing, and the page says the link no longer
  turns mail on; for anyone else it is a path that does not exist (`ApiaryWeb.NotFound`). The token
  is in the path, so `ApiaryWeb.RequestLog` logs the path without it.
  """
  use ApiaryWeb, :controller

  alias Apiary.{Access, Mail}

  def turn_on(conn, %{"token" => token}) do
    scope = conn.assigns.current_scope

    case Mail.turn_on(scope, token) do
      {:ok, _settings} ->
        conn
        |> put_flash(:info, gettext("Mail is on, and your email address is confirmed."))
        |> redirect(to: ~p"/instance/mail")

      :error ->
        if Access.instance_admin?(scope) do
          conn
          |> put_flash(:error, gettext("This link no longer turns mail on."))
          |> redirect(to: ~p"/instance/mail")
        else
          raise ApiaryWeb.NotFound
        end
    end
  end
end
