defmodule ApiaryPro.Deletion do
  @moduledoc """
  The edition's part in deleting and purging organisations (`Apiary.Deletion`): what
  it refuses (`refusal/2`, the edition's `c:Apiary.Edition.deletion_refusal/2`), whom it
  tells of a change (`changed/4`, the edition's `c:Apiary.Edition.deletion_changed/4`), an
  operator's deleting of a client it created and nobody else is in (`delete_client/3`),
  and an instance admin's purge on an erasure request (`purge_on_request/3`).

  The instance organisation holds the instance admins, and an instance without it would
  give its next sign-up the instance: it is never marked nor purged,
  `:instance_organisation`. An operator is deleted once it has no clients, `:has_clients`:
  each is deleted or dropped first, and the database keeps the reference until then. A
  client's operator reads it through the operator, so the operator's people hear of its
  marking and its cancelling, and of its workspaces', as its members do.
  """

  import Ecto.Query, warn: false

  alias Apiary.{Access, Audit, Deletion, Organisations, Repo}
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Organisations.{Invitation, Membership, Organisation, Workspace}
  alias ApiaryPro.{PolicyRequests, Reach, Tenants}
  alias ApiaryPro.Tenants.Tenant

  @doc """
  refusal/2 is why `subject` may not be deleted or purged, or nil:
  `:instance_organisation` for the instance organisation, `:has_clients` for an operator
  that still has clients. Asked on the row locked for the change, whose tenant it reads
  under the lock when the organisation carries none (`ApiaryPro.Tenants`).
  """
  @spec refusal(:delete | :purge, %Organisation{} | %Workspace{}) ::
          nil | :instance_organisation | :has_clients
  def refusal(_what, %Organisation{} = organisation) do
    cond do
      Tenants.instance_organisation?(organisation) ->
        :instance_organisation

      Tenants.operator?(organisation) and ApiaryPro.Operators.has_clients?(organisation) ->
        :has_clients

      true ->
        nil
    end
  end

  def refusal(_what, _subject), do: nil

  @doc """
  changed/4 is what the edition does when a workspace or an organisation is marked for
  deletion or restored, inside the transaction: the people of its organisation's operator,
  for a client, are told once it commits, `{:ok, memberships}`. Nothing for a purge.
  """
  @spec changed(Ecto.Repo.t(), :marked | :restored | :purged, term, Scope.t()) ::
          :ok | {:ok, [%Membership{}]}
  def changed(repo, event, subject, _scope) when event in [:marked, :restored],
    do: {:ok, operator_people(repo, organisation_id(subject))}

  def changed(_repo, :purged, _subject, _scope), do: :ok

  defp organisation_id(%Organisation{id: id}), do: id
  defp organisation_id(%Workspace{organisation_id: id}), do: id

  # The memberships of the organisation's operator, for a client; none otherwise.
  defp operator_people(repo, organisation_id) do
    repo.all(
      from m in Membership,
        join: t in Tenant,
        on: t.operator_id == m.organisation_id,
        where: t.organisation_id == ^organisation_id
    )
  end

  @doc """
  delete_client/3 marks the client `client_id` of the scope's organisation, an operator,
  for deletion (`client.delete`, an owner's of the operator), while the client has no
  owner yet, when `confirmation` is its name: nobody else is in it, so its operator, which
  created it, deletes it rather than drops it. It is purged after the grace period, as an
  organisation its owner deletes; its pending invitations are deleted at once, each an
  entry of `invitation.revoke` in its trail, the reason `client_deleted`. An entry of
  `client.delete` in the operator's trail, which outlives the client's, names it.

  `{:ok, client}`, marked; `{:error, :has_owner}` for a client that has an owner, which
  its operator drops instead (`ApiaryPro.Transfers.drop/3`); `{:error, :confirmation}` for a
  confirmation that is not its name; `{:error, :not_found}` for an organisation that is
  no client of the operator, or one marked already, and `Apiary.Access`'s answer.
  """
  # While `ApiaryPro.Flags.operator_infrastructure?/0` is on, the client must have no
  # membership at all, else `{:error, :has_people}`, and the entry's details say
  # so (`"guard" => "no_people"`).
  @spec delete_client(Scope.t(), Ecto.UUID.t(), String.t() | nil) ::
          {:ok, %Organisation{}} | {:error, :has_owner | :has_people | Deletion.refusal()}
  def delete_client(
        %Scope{organisation: %Organisation{id: operator_id}} = scope,
        client_id,
        confirmation
      ) do
    owns? = ApiaryPro.Flags.operator_infrastructure?()

    with {:ok, id} <- cast(client_id) do
      Repo.transact(fn ->
        # The lock order (docs/access.md): the client's row `FOR NO KEY UPDATE`, which an
        # acceptance of its first owner's invitation holds too, and the operator's
        # `FOR SHARE`, at one point, in the lock order.
        held =
          Tenants.lock_organisations!([id, operator_id], fn
            ^id -> :no_key_update
            _operator -> :share
          end)

        with %Organisation{deletion_marked_at: nil} = client <- held[id] || not_found(),
             true <- Tenants.operator_id(client) == operator_id || not_found(),
             %Organisation{} = operator <- held[operator_id] || not_found(),
             :ok <- Access.authorize(scope, :"client.delete", operator),
             :ok <- ensure_nobody(client, owns?),
             :ok <- confirm(client.name, confirmation),
             {:ok, marked} <- client |> Deletion.mark_changeset(scope) |> Repo.update(),
             :ok <- delete_invitations(Reach.in_client(scope, marked)),
             {:ok, _withdrawn} <-
               PolicyRequests.withdraw_for_client(scope, marked, operator, "deleted"),
             {:ok, _entry} <-
               Audit.record(
                 Repo,
                 Scope.in_organisation(scope, operator),
                 :"client.delete",
                 operator,
                 %{details: deleted_details(marked, owns?)}
               ) do
          {:ok, marked}
        else
          %Organisation{} -> not_found()
          {:error, _reason} = error -> error
        end
      end)
      |> announce()
    end
  end

  def delete_client(_scope, _client_id, _confirmation), do: not_found()

  # No owner yet; while the operator owns its clients, no membership at all.
  defp ensure_nobody(%Organisation{id: id}, false) do
    if Repo.exists?(from m in Membership, where: m.organisation_id == ^id and m.level == :owner),
      do: {:error, :has_owner},
      else: :ok
  end

  defp ensure_nobody(%Organisation{id: id}, true) do
    if Repo.exists?(from m in Membership, where: m.organisation_id == ^id),
      do: {:error, :has_people},
      else: :ok
  end

  defp deleted_details(marked, false),
    do: %{organisation_id: marked.id, purge_after: marked.purge_after}

  defp deleted_details(marked, true),
    do: %{organisation_id: marked.id, purge_after: marked.purge_after, guard: "no_people"}

  # The pending invitations of the scope's organisation, deleted with its deletion, each
  # with a separate entry.
  defp delete_invitations(%Scope{organisation: %Organisation{id: id}} = scope) do
    {_count, deleted} =
      Repo.delete_all(
        from i in Invitation,
          where: i.organisation_id == ^id and is_nil(i.accepted_at),
          select: i
      )

    Enum.reduce_while(deleted, :ok, fn invitation, :ok ->
      case Audit.record(Repo, scope, :"invitation.revoke", invitation, %{
             details: %{reason: "client_deleted"}
           }) do
        {:ok, _entry} -> {:cont, :ok}
        {:error, _changeset} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  purge_on_request/3 purges the organisation `organisation_id` at once, on an erasure
  request, for an instance admin on Instance settings › Organisations
  (`instance.purge_organisation`, an owner's of the instance organisation, asked in it),
  when `confirmation` is its slug:
  under the organisation's lock it is marked for erasure as `Apiary.Deletion.purge_now/3`
  marks it (`Apiary.Deletion.mark_for_erasure/2`), the instance admin as who asked, and an
  entry of `instance.purge_organisation` is written in the instance organisation's trail,
  by them, which names the organisation by its id, in the same transaction: the
  organisation's trail goes with it. Then it is purged; the instance's line of it
  (`Apiary.Deletion.PurgedOrganisation`) says who asked.

  `{:ok, :purged}`, or `{:ok, :gone}` should a purge have finished it meanwhile;
  `{:error, :confirmation}` for a confirmation that is not its slug, `{:error,
  :has_clients}` for an operator that still has clients, `{:error, :not_found}` for one
  that is not there, and `Apiary.Access`'s answer: `{:error, :forbidden}` for the instance
  organisation, which is never purged.
  """
  @spec purge_on_request(Scope.t(), String.t(), String.t() | nil) ::
          {:ok, :purged | :not_due | :gone} | {:error, Deletion.refusal() | term}
  def purge_on_request(%Scope{user: %User{} = user} = scope, organisation_id, confirmation) do
    with {:ok, id} <- cast(organisation_id),
         {:ok, organisation} <-
           Repo.transact(fn ->
             with {:ok, locked} <- Deletion.lock_for_erasure(id),
                  :ok <- Access.authorize(scope, :"instance.purge_organisation", locked),
                  :ok <- confirm(locked.slug, confirmation),
                  :ok <- Deletion.mark_for_erasure(locked, user),
                  {:ok, _entry} <-
                    Audit.record(
                      Repo,
                      scope,
                      :"instance.purge_organisation",
                      scope.organisation,
                      %{details: %{organisation_id: locked.id, trigger: "erasure_request"}}
                    ) do
               {:ok, locked}
             end
           end) do
      # Who is told is read before the purge deletes the memberships that name them.
      told = told_of(organisation.id)

      organisation
      |> Deletion.purge_marked(scope.origin)
      |> tap(fn _outcome -> Organisations.broadcast_membership_changes(told) end)
    end
  end

  def purge_on_request(_scope, _organisation_id, _confirmation), do: {:error, :forbidden}

  defp confirm(expected, confirmation) when is_binary(confirmation) do
    if String.trim(confirmation) == expected, do: :ok, else: {:error, :confirmation}
  end

  defp confirm(_expected, _confirmation), do: {:error, :confirmation}

  # An id as a page writes it; `Ecto.UUID.cast/1` would take any sixteen bytes for one.
  defp cast(id) when is_binary(id) and byte_size(id) == 36 do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> not_found()
    end
  end

  defp cast(_id), do: not_found()

  defp not_found, do: {:error, :not_found}

  # A client marked: the client's members and its operator's hear of it, once it commits.
  defp announce({:ok, %Organisation{id: id}} = result) do
    Organisations.broadcast_membership_changes(told_of(id))
    result
  end

  defp announce(result), do: result

  # The memberships whose people hear of a change to the organisation: the organisation's,
  # and its operator's for a client.
  defp told_of(organisation_id) do
    operator =
      from t in Tenant,
        where: t.organisation_id == ^organisation_id and not is_nil(t.operator_id),
        select: t.operator_id

    Repo.all(
      from m in Membership,
        where: m.organisation_id == ^organisation_id or m.organisation_id in subquery(operator)
    )
  end
end
