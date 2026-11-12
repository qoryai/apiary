defmodule ApiaryPro.Invitations do
  @moduledoc """
  Invitations is what the edition adds to accepting an invitation
  (`Apiary.Organisations.accept_invitation/2`, and a sign-up with one): the workspace an
  invitation was sent from is granted to the person who joins, a row of workspace access
  (`ApiaryPro.WorkspaceAccess`); an invitation sent to the organisation alone, while it
  had no workspace, grants none. An operator's invitation of its client's first owner
  (`ApiaryPro.Operators.invite_owner/4`, with its row of
  `ApiaryPro.Operators.OperatorInvitation`) makes that person the client's owner.

  An operator's invitation stands only while the client has no owner and is still a
  client of the operator that sent it: `accepting/3` locks the client
  `FOR NO KEY UPDATE`, before the core holds it `FOR SHARE`, so two such acceptances, and a
  drop or a deletion of the client, are one after the other; otherwise it is
  `{:error, :invalid}`, as an expired one is. Once its person has joined, the operator's
  other pending invitations of an owner there go (`accepted/4`), each an entry of
  `invitation.revoke` by the person who joined, the reason `owner_joined`.
  """

  import Ecto.Query, warn: false

  alias Apiary.Audit
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Organisations.{Invitation, Membership, Organisation}
  alias ApiaryPro.Operators.OperatorInvitation
  alias ApiaryPro.Tenants.Tenant
  alias ApiaryPro.WorkspaceAccess

  @doc """
  accepting/3 is the level the person who accepts `invitation` joins at
  (`c:Apiary.Edition.accepting/3`): owner for an operator's invitation of its client's first
  owner, which it finds still valid, the client locked `FOR NO KEY UPDATE`, not
  suspended, still that operator's and with no owner, else `{:error, :invalid}`; member
  for every other.
  """
  # While `ApiaryPro.Flags.operator_infrastructure?/0` is on, the operator owns the client:
  # its invitation makes its first admin, while the client has no owner and no admin, so a
  # pending invitation of a first owner makes an admin too.
  @spec accepting(Ecto.Repo.t(), %Invitation{}, %User{} | nil) ::
          {:ok, :owner | :admin | :member} | {:error, :invalid}
  def accepting(repo, %Invitation{id: invitation_id, organisation_id: id}, _user) do
    case repo.get(OperatorInvitation, invitation_id) do
      nil -> {:ok, :member}
      %OperatorInvitation{operator_id: operator_id} -> accepting_owner(repo, id, operator_id)
    end
  end

  # The client's row locked `FOR NO KEY UPDATE`, then its tenant read under the lock: a
  # drop or a suspension, which lock the same row, came first and are seen, or wait.
  defp accepting_owner(repo, id, operator_id) do
    repo.one(from o in Organisation, where: o.id == ^id, select: o.id, lock: "FOR NO KEY UPDATE")

    query =
      from t in Tenant,
        where: t.organisation_id == ^id and is_nil(t.suspended_at),
        select: t.operator_id

    case {repo.all(query), ApiaryPro.Flags.operator_infrastructure?()} do
      {[^operator_id], true} ->
        if has_level?(repo, id, [:owner, :admin]), do: {:error, :invalid}, else: {:ok, :admin}

      {[^operator_id], false} ->
        if has_level?(repo, id, [:owner]), do: {:error, :invalid}, else: {:ok, :owner}

      _gone_suspended_or_left ->
        {:error, :invalid}
    end
  end

  defp has_level?(repo, organisation_id, levels),
    do:
      repo.exists?(
        from m in Membership,
          where: m.organisation_id == ^organisation_id and m.level in ^levels
      )

  @doc """
  accepted/4 is told the person who accepted `invitation` has joined, with `membership`
  (`c:Apiary.Edition.accepted/4`): they are added to the workspace it was sent from, none
  for an invitation sent without one; and for an operator's invitation of its client's
  first owner, its operator's other pending invitations of an owner there go, each an
  entry of `invitation.revoke` by `scope`, the person who joined, the reason
  `owner_joined`.
  """
  # The reason names the level the first person joined at: `admin_joined` for a first
  # admin, while the operator owns the client.
  @spec accepted(Ecto.Repo.t(), Scope.t(), %Invitation{}, %Membership{}) ::
          :ok | {:error, term}
  def accepted(repo, %Scope{} = scope, %Invitation{} = invitation, %Membership{} = membership) do
    with {:ok, _access} <- WorkspaceAccess.grant_invited(repo, invitation, membership),
         do: withdraw_other_owner_invitations(repo, scope, invitation, membership)
  end

  defp withdraw_other_owner_invitations(repo, scope, %Invitation{} = claimed, membership) do
    if repo.exists?(from o in OperatorInvitation, where: o.invitation_id == ^claimed.id),
      do: withdraw_other_owner_invitations_now(repo, scope, claimed, joined(membership)),
      else: :ok
  end

  defp joined(%Membership{level: :admin}), do: "admin_joined"
  defp joined(_owner), do: "owner_joined"

  # The claimed invitation's row of `OperatorInvitation` goes with it, when the core
  # deletes it after this.
  defp withdraw_other_owner_invitations_now(repo, scope, claimed, reason) do
    operators =
      from o in OperatorInvitation,
        where: o.organisation_id == ^claimed.organisation_id,
        select: o.invitation_id

    {_count, others} =
      repo.delete_all(
        from i in Invitation,
          where: i.organisation_id == ^claimed.organisation_id and i.id in subquery(operators),
          where: i.id != ^claimed.id and is_nil(i.accepted_at),
          select: i
      )

    Enum.reduce_while(others, :ok, fn invitation, :ok ->
      case Audit.record(repo, %{scope | workspace: nil}, :"invitation.revoke", invitation, %{
             details: %{reason: reason}
           }) do
        {:ok, _entry} -> {:cont, :ok}
        {:error, _changeset} = error -> {:halt, error}
      end
    end)
  end
end
