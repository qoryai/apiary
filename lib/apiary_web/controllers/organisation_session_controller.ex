defmodule ApiaryWeb.OrganisationSessionController do
  @moduledoc """
  Keeps the active organisation in the session.
  """
  use ApiaryWeb, :controller

  alias Apiary.Organisations

  @doc """
  Switches the active organisation. The user must be a member of it.
  """
  def switch(conn, %{"organisation_id" => organisation_id}) when is_binary(organisation_id) do
    user = conn.assigns.current_scope.user

    member? =
      user
      |> Organisations.list_memberships()
      |> Enum.any?(&(&1.organisation_id == organisation_id))

    if member? do
      conn
      |> put_session(:organisation_id, organisation_id)
      |> redirect(to: ~p"/workspace")
    else
      not_a_member(conn)
    end
  end

  def switch(conn, _params), do: not_a_member(conn)

  defp not_a_member(conn) do
    conn
    |> put_flash(:error, gettext("You are not a member of that organisation."))
    |> redirect(to: ~p"/workspace")
  end

  @doc """
  A signed-in landing for an invitation link. The route sits behind
  `require_authenticated_user`, so a signed-out visitor is sent to log in and
  returns here, and from here to the invitation, once signed in.
  """
  def continue_invitation(conn, %{"token" => token}) do
    redirect(conn, to: ~p"/invitations/#{token}")
  end
end
