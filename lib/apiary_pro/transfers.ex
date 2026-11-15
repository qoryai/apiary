defmodule ApiaryPro.Transfers do
  @moduledoc """
  An organisation's ownership when its owners cannot act.

  **The arbiter** (`arbitrate/4`, `instance.transfer`, an instance admin's, on Instance
  settings › Organisations). When an organisation has owners and none of them may act
  (`ApiaryPro.Suspensions.owner_suspended?/1`), a client as any other, an instance admin
  offers its ownership to one of its admins, with a reason, replacing any offer pending
  (`ApiaryPro.Transfers.Transfer`, one per organisation). The admin accepts (`accept/1`,
  `organisation.accept_transfer`, which the offer allows and no role): they become an
  owner. The offer lapses once an owner may act again.

  Every arbitration, lapse and acceptance is an audit entry in the organisation, in its
  transaction.

  **Race safety.** Every change takes its rows in the lock order of docs/access.md, a
  client's row before its operator's. `accept/1` first reads the offer without a lock: a
  person it is not offered to, and an organisation with no offer, get not found and take
  no lock. It then takes the organisation and its operator `FOR SHARE` and locks its
  owners' memberships, in the order `Apiary.Organisations.lock_owners/1` takes them, then
  the membership of the person who accepts, their account, and the offer. A deadlock or a
  serialisation failure Postgres breaks all the same is taken again, twice at most, and
  `{:error, :busy}` after; inside a caller's transaction, which it would roll back with
  it, it is not taken again, and returns `{:error, :busy}` at once.
  """

  import Ecto.Query, warn: false

  alias Apiary.{Access, Audit, Organisations, Repo}
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Organisations.{Membership, Organisation}
  alias ApiaryPro.{Suspensions, Tenants}
  alias ApiaryPro.Transfers.Transfer

  @reason_max 500

  @doc "reason_max/0 is the most characters the arbiter's reason for a transfer holds."
  @spec reason_max() :: pos_integer
  def reason_max, do: @reason_max

  ## Reading

  @doc """
  pending/1 is the pending offer of the scope's organisation to one of its admins, with
  its recipient loaded, or nil. For its settings page.
  """
  @spec pending(Scope.t()) :: Transfer.t() | nil
  def pending(%Scope{organisation: %Organisation{id: id}}) do
    Repo.one(
      from t in Transfer,
        where: t.organisation_id == ^id and t.kind == :to_admin,
        preload: [:recipient]
    )
  end

  def pending(_scope), do: nil

  @doc """
  acceptance_refused/2 says why an offer to the scope's person would be refused if they
  accepted it now, as the database has it, or nil: `:suspended`, the organisation is
  suspended; `:has_owner`, one of its owners may act again, whom the instance does not
  overrule. For the page that offers the Accept button: it says why instead.
  """
  @spec acceptance_refused(Scope.t(), Transfer.t() | nil) :: nil | :suspended | :has_owner
  def acceptance_refused(%Scope{organisation: %Organisation{id: id}}, %Transfer{} = transfer) do
    organisation = Organisation |> Repo.get!(id) |> Tenants.put()

    cond do
      Tenants.suspended?(organisation) -> :suspended
      transfer.arbitrated and not Suspensions.owner_suspended?(organisation) -> :has_owner
      true -> nil
    end
  end

  def acceptance_refused(_scope, _transfer), do: nil

  @doc """
  arbitration_candidates/2 is the admins of the organisation `organisation_id` an instance
  admin may offer its ownership to (`instance.transfer`, asked in the instance
  organisation), by when they joined, each with their account: memberships at admin,
  neither they nor their account suspended. `{:ok, memberships}`, and `Apiary.Access`'s
  answer otherwise.
  """
  @spec arbitration_candidates(Scope.t(), Ecto.UUID.t()) ::
          {:ok, [%Membership{}]} | {:error, Access.reason()}
  def arbitration_candidates(%Scope{} = scope, organisation_id) do
    with {:ok, id} <- cast(organisation_id),
         %Organisation{} = organisation <- Repo.get(Organisation, id) || {:error, :not_found},
         :ok <- Access.authorize(scope, :"instance.transfer", organisation),
         do: {:ok, admins(organisation)}
  end

  defp admins(%Organisation{id: id}) do
    from(m in Membership,
      join: u in assoc(m, :user),
      as: :account,
      where: m.organisation_id == ^id and m.level == :admin and is_nil(m.suspended_at),
      where: is_nil(u.deleted_at),
      order_by: [asc: m.inserted_at, asc: m.id],
      preload: [user: u]
    )
    |> Suspensions.active_accounts(:account)
    |> Repo.all()
  end

  ## Offering

  @doc """
  arbitrate/4 is the arbiter's transfer (`instance.transfer`, an instance admin's, asked
  in the instance organisation, of the organisation `organisation_id`): its ownership
  offered to the admin of the membership `membership_id`, with `reason`, which the entry
  keeps. For an organisation whose owners are all suspended, a client as any other; never
  the instance organisation. It replaces an offer pending, which its entry names. The
  admin accepts with `accept/1`. An entry of `instance.transfer` in the organisation's
  trail, by the instance admin.

  `{:ok, transfer}`; `{:error, :has_owner}` for an organisation that has an owner who may
  act, or none at all, which the instance does not overrule; `{:error, :not_admin}` for a
  membership that is not an admin's in use; `{:error, :reason}` for a reason blank or
  longer than #{@reason_max} characters; `{:error, :suspended}` for a suspended
  organisation, which is activated first; `Apiary.Access`'s answer otherwise.
  """
  @spec arbitrate(Scope.t(), Ecto.UUID.t(), Ecto.UUID.t(), String.t() | nil) ::
          {:ok, Transfer.t()}
          | {:error, :has_owner | :not_admin | :reason | :suspended | Access.reason() | term}
  def arbitrate(%Scope{} = scope, organisation_id, membership_id, reason) do
    with {:ok, id} <- cast(organisation_id),
         {:ok, reason} <- reason(reason) do
      retrying(fn ->
        with %Organisation{} = organisation <-
               lock_row(id, "FOR NO KEY UPDATE") || {:error, :not_found},
             :ok <- Access.authorize(scope, :"instance.transfer", organisation),
             false <- Tenants.suspended?(organisation) && {:error, :suspended},
             :ok <- arbitrable(organisation),
             {:ok, membership} <- admin(organisation, membership_id),
             {:ok, replaced} <- replace_pending(organisation),
             {:ok, transfer} <-
               Repo.insert(%Transfer{
                 organisation_id: organisation.id,
                 kind: :to_admin,
                 recipient_id: membership.user_id,
                 offered_by_id: scope.user.id,
                 arbitrated: true,
                 reason: reason
               }),
             {:ok, _entry} <-
               Audit.record(
                 Repo,
                 scope |> Scope.in_organisation(organisation) |> Scope.put_origin(nil),
                 :"instance.transfer",
                 transfer,
                 %{
                   details: %{
                     user_id: membership.user_id,
                     operator_id: Tenants.operator_id(organisation),
                     reason: reason,
                     replaced: replaced && replaced.id
                   }
                 }
               ) do
          {:ok, transfer}
        end
      end)
      |> tell()
    end
  end

  @doc """
  membership_activated/1 is told a membership's suspension ended
  (`c:Apiary.Edition.membership_changed/5`, `:activated`): an owner who may act again
  withdraws the arbiter's pending offer of their organisation, by the instance
  (`withdraw_overruled/2`). `:ok`.
  """
  @spec membership_activated(%Membership{}) :: :ok | {:error, term}
  def membership_activated(%Membership{level: :owner, organisation_id: organisation_id}) do
    with {:ok, _withdrawn} <- withdraw_overruled([organisation_id], nil), do: :ok
  end

  def membership_activated(%Membership{}), do: :ok

  @doc """
  withdraw_overruled/2 withdraws the arbiter's pending offer of each organisation of
  `organisation_ids` that has an owner who may act again, an owner's
  membership or account activated: the instance does not overrule an owner. For the
  transaction of that activation. Each is an entry of `organisation.withdraw_transfer` in
  the organisation's trail, the reason `owner_activated`, by `actor`, the instance admin
  who activated an account, or by the instance. `{:ok, count}`.
  """
  @spec withdraw_overruled([Ecto.UUID.t()], Scope.t() | nil) ::
          {:ok, non_neg_integer} | {:error, term}
  def withdraw_overruled([], _actor), do: {:ok, 0}

  def withdraw_overruled(organisation_ids, actor) do
    Repo.all(
      from t in Transfer,
        join: o in assoc(t, :organisation),
        where: t.organisation_id in ^organisation_ids and t.arbitrated,
        order_by: [asc: t.id],
        preload: [organisation: o],
        lock: "FOR UPDATE OF t0"
    )
    |> Enum.reject(&Suspensions.owner_suspended?(&1.organisation))
    |> withdraw_all("owner_activated", actor)
  end

  defp withdraw_all(offers, reason, actor) do
    Enum.reduce_while(offers, {:ok, 0}, fn transfer, {:ok, count} ->
      with {:ok, _deleted} <- Repo.delete(transfer),
           {:ok, _entry} <-
             Audit.record(
               Repo,
               withdrawer(actor, transfer.organisation),
               :"organisation.withdraw_transfer",
               transfer,
               %{
                 details: %{
                   kind: transfer.kind,
                   user_id: transfer.recipient_id,
                   operator_id: transfer.operator_id,
                   arbitrated: transfer.arbitrated,
                   reason: reason
                 }
               }
             ) do
        {:cont, {:ok, count + 1}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # The instance admin who acted, in the organisation whose offer lapses, with no address
  # in its trail; or the instance.
  defp withdrawer(%Scope{user: %User{}} = actor, organisation),
    do: actor |> Scope.in_organisation(organisation) |> Scope.put_origin(nil)

  defp withdrawer(_actor, organisation), do: Scope.for_instance(organisation)

  ## Accepting

  @doc """
  accept/1 accepts the ownership of the scope's organisation the arbiter offered the
  scope's person, an admin of it (`organisation.accept_transfer`, which the offer allows,
  and no role): they become an owner, and the offer is deleted. A client stays its
  operator's. An entry of `organisation.accept_transfer` in the organisation's trail.
  `Apiary.Access.check/3` checks the offer without a lock first, for anyone it is not
  offered to, then checks the offer, locked, with the person's membership, locked.

  `{:ok, organisation}`; `{:error, :not_found}` with no offer to them pending, one
  withdrawn meanwhile included, or an organisation marked for deletion;
  `{:error, :forbidden}` for the person it is offered to, once they are no admin there in
  use;
  `{:error, :suspended}` for a suspended organisation; `{:error, :has_owner}` once an
  owner may act again.
  """
  @spec accept(Scope.t()) ::
          {:ok, %Organisation{}}
          | {:error, :not_found | :forbidden | :suspended | :has_owner | term}
  def accept(%Scope{user: %User{}, organisation: %Organisation{}} = scope) do
    with :ok <- offer_found(scope), do: accept_locked(scope)
  end

  def accept(_scope), do: {:error, :not_found}

  # The offer read without a lock, so that a person it is not offered to, and an organisation
  # with no offer, take no lock. Any result but `:not_found` goes on to the locks: the check
  # that counts is `accept_locked/1`'s, on the offer and the membership it locked. The scope
  # is the one `accept_locked/1` checks, without the membership it locks.
  defp offer_found(%Scope{organisation: %Organisation{id: id} = organisation} = scope) do
    offer = Repo.get_by(Transfer, organisation_id: id)
    in_place = Scope.in_organisation(scope, organisation)

    if offer &&
         Access.check(in_place, :"organisation.accept_transfer", offer) != {:error, :not_found},
       do: :ok,
       else: {:error, :not_found}
  end

  defp accept_locked(
         %Scope{user: %User{id: user_id}, organisation: %Organisation{id: id}} = scope
       ) do
    retrying(fn ->
      # The lock order (docs/access.md): the organisation's row `FOR SHARE`, and a
      # client's operator's, which the suspension of either waits for, at one point, in
      # the lock order; `Apiary.Organisations.lock_owners/1` takes them again in the same
      # mode, then the owners' memberships; then the person's membership, then their
      # account, then the offer. The operator is read first, without a lock; once the
      # client is held it changes no more, so one that came in between is a change to try
      # again.
      operator_id = Tenants.operator_id(%Organisation{id: id})

      with {:ok, held} <- lock_pair(id, :share, operator_id, :share),
           %Organisation{deletion_marked_at: nil} = organisation <-
             held[id] || {:error, :not_found},
           :ok <- held_operator(organisation, operator_id),
           :ok <- Organisations.lock_owners(%Scope{organisation: organisation}),
           membership = locked_membership_in_use(organisation, user_id),
           %Transfer{} = transfer <- lock_pending(organisation) || {:error, :not_found},
           :ok <-
             Access.check(
               %{Scope.in_organisation(scope, organisation) | membership: membership},
               :"organisation.accept_transfer",
               transfer
             ),
           false <- Tenants.suspended?(organisation) && {:error, :suspended},
           :ok <- not_overruling(organisation),
           {:ok, owner} <-
             membership |> Membership.changeset(%{level: :owner}) |> Repo.update(),
           {:ok, _deleted} <- Repo.delete(transfer),
           {:ok, _entry} <-
             Audit.record(
               Repo,
               Scope.in_organisation(scope, organisation),
               :"organisation.accept_transfer",
               organisation,
               %{
                 before: %{level: membership.level},
                 after: %{level: owner.level},
                 details: %{user_id: user_id, arbitrated: transfer.arbitrated}
               }
             ) do
        {:ok, organisation}
      else
        %Organisation{} -> {:error, :not_found}
        {:error, _reason} = error -> error
      end
    end)
    |> tap(fn
      {:ok, organisation} -> tell_people_of([organisation.id])
      _refused -> :ok
    end)
  end

  ## Helpers

  # A transaction taken again when Postgres broke a deadlock or a serialisation failure by
  # rolling it back, at most twice, and `{:error, :busy}` after that: a page says to try
  # again, and never shows the database's error. Called inside a caller's transaction, it
  # is not taken again: the caller's transaction is rolled back with it, which only the
  # caller may begin again, so the answer is `{:error, :busy}` at once.
  @retry_codes [:deadlock_detected, :serialization_failure]

  defp retrying(fun) do
    attempts = if Repo.in_transaction?(), do: 1, else: 3
    retrying(fun, attempts)
  end

  defp retrying(fun, attempts) do
    Repo.transact(fun)
  rescue
    error in Postgrex.Error ->
      if error.postgres[:code] in @retry_codes do
        if attempts > 1, do: retrying(fun, attempts - 1), else: {:error, :busy}
      else
        reraise error, __STACKTRACE__
      end
  end

  # The arbiter's offer stands while no owner may act; once one may again, the instance
  # does not overrule them.
  defp not_overruling(organisation) do
    if Suspensions.owner_suspended?(organisation), do: :ok, else: {:error, :has_owner}
  end

  # The organisation's row locked `how`, carrying its tenant read under the lock
  # (`ApiaryPro.Tenants.lock_organisation/2`).
  defp lock_row(id, how), do: Tenants.lock_organisation(id, how)

  # Two organisations' rows, `id`'s in `mode` and `other`'s in `other_mode`, at a change's
  # one point, in the lock order (`ApiaryPro.Tenants.lock_organisations/2`); `other` may be
  # nil, or `id` itself, which is then held in `mode`: `{:ok, held}`, the organisations
  # held by their ids, each carrying its tenant, or `{:error, :busy}` for a deadlock that
  # outlived the core's one retry, which is not taken again here.
  defp lock_pair(id, mode, other, other_mode) do
    Tenants.lock_organisations(Enum.reject([id, other], &is_nil/1), fn
      ^id -> mode
      _other -> other_mode
    end)
  end

  # An organisation whose operator, if it has one, is the one read before its row was held,
  # and held with it.
  defp held_operator(organisation, operator_id) do
    if Tenants.operator_id(organisation) in [nil, operator_id], do: :ok, else: {:error, :busy}
  end

  defp lock_pending(%Organisation{id: id}) do
    Repo.one(from t in Transfer, where: t.organisation_id == ^id, lock: "FOR UPDATE")
  end

  # An arbiter's offer replaces the one pending, which is deleted: its entry names it.
  defp replace_pending(organisation) do
    case lock_pending(organisation) do
      nil -> {:ok, nil}
      %Transfer{} = transfer -> Repo.delete(transfer)
    end
  end

  # The admin of the organisation behind a membership: in use, their account too.
  defp admin(%Organisation{id: organisation_id}, membership_id) do
    with {:ok, membership_id} <- cast(membership_id),
         %Membership{} = membership <-
           from(m in Membership,
             join: u in assoc(m, :user),
             as: :account,
             where: m.id == ^membership_id and m.organisation_id == ^organisation_id,
             where: m.level == :admin and is_nil(m.suspended_at),
             where: is_nil(u.deleted_at)
           )
           |> Suspensions.active_accounts(:account)
           |> Repo.one() do
      {:ok, membership}
    else
      _ -> {:error, :not_admin}
    end
  end

  # The accepting person's membership, not suspended, locked for the change of its level;
  # then their account, not deleted, held `FOR SHARE`, which its deletion and suspension
  # wait for: memberships before accounts, as the lock order has them. Its suspension is
  # read once the lock is held, in a separate statement. Nil when any of these is not in
  # use: `Apiary.Access.check/3` then finds no level. It checks the level too.
  defp locked_membership_in_use(%Organisation{id: organisation_id}, user_id) do
    with %Membership{} = membership <-
           Repo.one(
             from m in Membership,
               where: m.organisation_id == ^organisation_id and m.user_id == ^user_id,
               where: is_nil(m.suspended_at),
               lock: "FOR UPDATE"
           ),
         %User{} <-
           Repo.one(
             from u in User,
               where: u.id == ^user_id and is_nil(u.deleted_at),
               lock: "FOR SHARE"
           ),
         false <- Suspensions.account_suspended?(user_id) do
      membership
    else
      _suspended_or_gone -> nil
    end
  end

  # An organisation whose owners are all suspended, a client as any other. While
  # `ApiaryPro.Flags.operator_infrastructure?/0` is on, a client is its operator's, which
  # the instance does not overrule.
  defp arbitrable(%Organisation{} = organisation) do
    cond do
      ApiaryPro.Flags.operator_infrastructure?() and Tenants.client?(organisation) ->
        {:error, :has_owner}

      Suspensions.owner_suspended?(organisation) ->
        :ok

      true ->
        {:error, :has_owner}
    end
  end

  defp reason(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> {:error, :reason}
      reason -> if String.length(reason) > @reason_max, do: {:error, :reason}, else: {:ok, reason}
    end
  end

  defp reason(_reason), do: {:error, :reason}

  # The people an offer concerns, told once it is written, so their pages show it.
  defp tell({:ok, %Transfer{} = transfer} = result) do
    tell_people_of(Enum.reject([transfer.organisation_id, transfer.operator_id], &is_nil/1))
    result
  end

  defp tell(result), do: result

  defp tell_people_of(organisation_ids) do
    Repo.all(from m in Membership, where: m.organisation_id in ^organisation_ids)
    |> Organisations.broadcast_membership_changes()
  end

  defp cast(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end
end
