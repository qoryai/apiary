defmodule ApiaryPro.WorkspaceAccess do
  @moduledoc """
  WorkspaceAccess is which workspaces a member reaches: one row per
  person and workspace (`ApiaryPro.WorkspaceAccess.Row`). An owner and an admin reach
  every workspace of the organisation and need none (`ApiaryPro.Reach`); a member reaches
  the workspaces they were added to. An invitation is sent from a workspace and grants it,
  or is sent to an organisation with no workspace and grants none
  (`ApiaryPro.Invitations`); an owner or an admin adds a member to another and removes
  them from one (`add/3`, `remove/3`), each with its entry.

  The scope carries the person's row for its workspace in its `edition` map (`of/1`),
  which `Apiary.Access` asks through `c:Apiary.Edition.reaches_workspace?/3`. An addition
  and a removal are announced on the person's `Apiary.Organisations.membership_topic/1`,
  so their open pages load their scope again.
  """

  import Ecto.Query, warn: false

  alias Apiary.{Access, Audit, Organisations, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Invitation, Membership, Organisation, Workspace}
  alias ApiaryPro.WorkspaceAccess.Row

  @doc "of/1 is the scope's person's row of workspace access to its workspace, or nil."
  @spec of(Scope.t() | nil) :: Row.t() | nil
  def of(%Scope{edition: edition}), do: Map.get(edition, :workspace_access)
  def of(_scope), do: nil

  @doc "put/2 is the scope carrying `row` as its person's workspace access to its workspace."
  @spec put(Scope.t(), Row.t() | nil) :: Scope.t()
  def put(%Scope{edition: edition} = scope, row),
    do: %{scope | edition: Map.put(edition, :workspace_access, row)}

  @doc """
  add/3 adds the person of the membership `membership_id` to the workspace
  `workspace_id` of the scope's organisation (`workspace_access.add`): one row of
  workspace access, and its entry, which names the person by user id. An owner adds
  anyone, an admin members only. A person already added changes nothing and leaves no
  entry: `{:ok, access}` with the row they had. `{:error, :not_found}` for a membership
  or a workspace that is not the organisation's.
  """
  @spec add(Scope.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Row.t()} | {:error, :not_found | :forbidden | term}
  def add(%Scope{} = scope, membership_id, workspace_id) do
    fn ->
      # The membership is held `FOR SHARE`: its removal waits for the row to be written, and
      # one that came first is seen, rather than a row the key refuses.
      with {:ok, membership} <- get_member(scope, membership_id, lock: :share),
           :ok <- Access.authorize(scope, :"workspace_access.add", membership),
           {:ok, workspace} <- get_workspace(scope, workspace_id) do
        case insert(membership, workspace) do
          {:ok, nil} ->
            {:ok,
             Repo.get_by!(Row,
               organisation_id: membership.organisation_id,
               workspace_id: workspace.id,
               user_id: membership.user_id
             )}

          {:ok, access} ->
            with {:ok, _entry} <-
                   Audit.record(Repo, scope, :"workspace_access.add", access, %{
                     details: %{user_id: membership.user_id}
                   }),
                 do: {:ok, access}
        end
      end
    end
    |> Repo.transact()
    |> announce()
  end

  @doc """
  remove/3 removes the person of the membership `membership_id` from the workspace
  `workspace_id` of the scope's organisation (`workspace_access.remove`): their row of
  workspace access is deleted, with an entry that names them by user id. An owner removes
  anyone, an admin members only. The person stays a member of the organisation; a level
  that reaches every workspace still reaches it. `{:error, :not_found}` for a person who
  was not added to it.

  The row is locked first, so a change that asked `Apiary.Access` about it, and holds it
  `FOR SHARE` (`Apiary.Access.reload/2`), is written before the person is removed.
  """
  @spec remove(Scope.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Row.t()} | {:error, :not_found | :forbidden | term}
  def remove(%Scope{} = scope, membership_id, workspace_id) do
    fn ->
      with {:ok, membership} <- get_member(scope, membership_id),
           :ok <- Access.authorize(scope, :"workspace_access.remove", membership),
           {:ok, workspace} <- get_workspace(scope, workspace_id),
           %Row{} = access <-
             Repo.one(
               from a in Row,
                 where:
                   a.organisation_id == ^membership.organisation_id and
                     a.workspace_id == ^workspace.id and a.user_id == ^membership.user_id,
                 lock: "FOR UPDATE"
             ),
           {:ok, removed} <- Repo.delete(access),
           {:ok, _entry} <-
             Audit.record(Repo, scope, :"workspace_access.remove", access, %{
               details: %{user_id: membership.user_id}
             }) do
        {:ok, removed}
      else
        nil -> {:error, :not_found}
        {:error, _reason} = error -> error
      end
    end
    |> Repo.transact()
    |> announce()
  end

  @doc """
  level_changed/4 keeps a person made a member, from a level that reached every
  workspace, in a workspace (`c:Apiary.Edition.membership_changed/5`, `:level`): they
  keep the rows they have; one who has none is added to the scope's workspace, the one the
  change was made from, else to the organisation's first, so they are not locked out of
  every workspace, with a separate entry (`workspace_access.add`, by whoever changed
  the level, the reason `demoted`). Inside the transaction that changed the level. `:ok`.
  """
  @spec level_changed(Ecto.Repo.t(), Scope.t(), %Membership{}, %Membership{}) ::
          :ok | {:error, term}
  def level_changed(repo, %Scope{} = scope, %Membership{} = old, %Membership{} = new) do
    if Access.reaches_every_workspace?(old.level) and
         not Access.reaches_every_workspace?(new.level) and
         not repo.exists?(
           from a in Row,
             where: a.organisation_id == ^new.organisation_id and a.user_id == ^new.user_id
         ) do
      workspace = scope.workspace || scope |> Organisations.list_workspaces() |> List.first()

      case workspace && insert(new, workspace) do
        nil ->
          :ok

        {:ok, nil} ->
          :ok

        {:ok, access} ->
          with {:ok, _entry} <-
                 Audit.record(repo, scope, :"workspace_access.add", access, %{
                   details: %{user_id: new.user_id, reason: "demoted"}
                 }),
               do: :ok
      end
    else
      :ok
    end
  end

  @doc """
  grant_invited/3 adds the person who accepted `invitation` to the workspace it was sent
  from: one row of workspace access, which the membership they joined with needs, whatever
  its level. An invitation sent while the organisation had no workspace
  (`workspace_id` nil) grants none: `{:ok, nil}`, and nothing is inserted. Inside the
  acceptance's transaction.
  """
  @spec grant_invited(Ecto.Repo.t(), %Invitation{}, %Membership{}) ::
          {:ok, Row.t() | nil} | {:error, Ecto.Changeset.t()}
  def grant_invited(_repo, %Invitation{workspace_id: nil}, %Membership{}), do: {:ok, nil}

  def grant_invited(repo, %Invitation{} = invitation, %Membership{} = membership) do
    repo.insert(%Row{
      organisation_id: invitation.organisation_id,
      workspace_id: invitation.workspace_id,
      user_id: membership.user_id
    })
  end

  # A row of workspace access for the membership's person in `workspace`: `{:ok, access}`,
  # or `{:ok, nil}` when they have it already, a concurrent addition's included, which
  # inserts nothing rather than abort the transaction on the unique index.
  defp insert(%Membership{} = membership, %Workspace{id: workspace_id}) do
    key = [
      organisation_id: membership.organisation_id,
      workspace_id: workspace_id,
      user_id: membership.user_id
    ]

    row = Map.new([id: Ecto.UUID.generate(), inserted_at: DateTime.utc_now()] ++ key)

    case Repo.insert_all(Row, [row],
           on_conflict: :nothing,
           conflict_target: [:organisation_id, :workspace_id, :user_id],
           returning: true
         ) do
      {1, [access]} -> {:ok, access}
      {0, []} -> {:ok, nil}
    end
  end

  defp get_member(scope, membership_id, opts \\ [])

  defp get_member(
         %Scope{organisation: %Organisation{id: organisation_id}},
         membership_id,
         opts
       ) do
    with {:ok, membership_id} <- Ecto.UUID.cast(membership_id),
         query =
           from(m in Membership,
             where: m.id == ^membership_id and m.organisation_id == ^organisation_id
           ),
         query = if(opts[:lock] == :share, do: lock(query, "FOR SHARE"), else: query),
         %Membership{} = membership <- Repo.one(query) do
      {:ok, membership}
    else
      _ -> {:error, :not_found}
    end
  end

  defp get_member(_scope, _membership_id, _opts), do: {:error, :not_found}

  defp get_workspace(%Scope{organisation: %Organisation{id: organisation_id}}, workspace_id) do
    with {:ok, workspace_id} <- Ecto.UUID.cast(workspace_id),
         %Workspace{} = workspace <-
           Repo.get_by(Workspace, id: workspace_id, organisation_id: organisation_id) do
      {:ok, workspace}
    else
      _ -> {:error, :not_found}
    end
  end

  defp announce({:ok, %Row{user_id: user_id, organisation_id: organisation_id}} = result) do
    Phoenix.PubSub.broadcast(
      Apiary.PubSub,
      Organisations.membership_topic(user_id),
      {:membership_changed, %{organisation_id: organisation_id}}
    )

    result
  end

  defp announce(result), do: result
end
