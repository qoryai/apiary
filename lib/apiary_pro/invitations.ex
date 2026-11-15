defmodule ApiaryPro.Invitations do
  @moduledoc """
  Invitations is what the edition adds to accepting an invitation
  (`Apiary.Organisations.accept_invitation/2`, and a sign-up with one): the workspace an
  invitation was sent from is granted to the person who joins, a row of workspace access
  (`ApiaryPro.WorkspaceAccess`); an invitation sent to the organisation alone, while it
  had no workspace, grants none.
  """

  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Invitation, Membership}
  alias ApiaryPro.WorkspaceAccess

  @doc """
  accepted/4 runs once the person who accepted `invitation` has joined, with `membership`
  (`c:Apiary.Edition.accepted/4`): they are added to the workspace it was sent from, none
  for an invitation sent without one.
  """
  @spec accepted(Ecto.Repo.t(), Scope.t(), %Invitation{}, %Membership{}) ::
          :ok | {:error, term}
  def accepted(repo, %Scope{}, %Invitation{} = invitation, %Membership{} = membership) do
    with {:ok, _access} <- WorkspaceAccess.grant_invited(repo, invitation, membership),
         do: :ok
  end
end
