defmodule ApiaryWeb.InvitationController do
  @moduledoc """
  The signed-in landing of an invitation link.
  """
  use ApiaryWeb, :controller

  @doc """
  A signed-in landing for an invitation link. The route sits behind
  `require_authenticated_user`, so a signed-out visitor is sent to log in and
  returns here, and from here to the invitation, once signed in.
  """
  def continue(conn, %{"token" => token}) do
    redirect(conn, to: ~p"/invitations/#{token}")
  end
end
