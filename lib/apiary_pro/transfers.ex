defmodule ApiaryPro.Transfers do
  @moduledoc """
  A client's parting from its operator, and an organisation's ownership when its owners
  cannot act.

  **An operator drops a client** (`drop/3`, `client.drop`, an owner's of the operator),
  at once, confirmed by typing the client's name, which the function checks, while the
  client has an owner; one with none yet is deleted instead
  (`ApiaryPro.Deletion.delete_client/3`). The client is an organisation with no operator
  from then on: the operator's people read it no more, and the grants the operator made
  it go, so it has what an organisation with no operator has
  (`ApiaryPro.Grants.written_out/3`). A client that leaves its operator is parted the same
  way.

  **The arbiter** (`arbitrate/4`, `instance.transfer`, an instance admin's, on Instance
  settings › Organisations). When an organisation has owners and none of them may act
  (`ApiaryPro.Suspensions.owner_suspended?/1`), a client as any other, an instance admin
  offers its ownership to one of its admins, with a reason, replacing any offer pending
  (`ApiaryPro.Transfers.Transfer`, one per organisation). The admin accepts (`accept/1`,
  `organisation.accept_transfer`, which the offer allows and no role): they become an
  owner. The offer lapses once an owner may act again.

  Every drop, arbitration, lapse and acceptance is an audit entry, in its transaction: a
  drop in the client and in the operator; an arbitration, its lapse and its acceptance in
  the organisation.

  **Race safety.** Every change takes its rows in the lock order of docs/access.md, a
  client's row before its operator's. `accept/1` first reads the offer without a lock: a
  person it is not offered to, and an organisation with no offer, get not found and take
  no lock. It then takes the organisation and its operator `FOR SHARE` and locks its
  owners' memberships, in the order `Apiary.Organisations.lock_owners/1` takes them, then
  the membership of the person who accepts, their account, and the offer. `drop/3` locks
  the client's row `FOR NO KEY UPDATE`, which a change of its operator needs and a write in
  flight that has it `FOR SHARE` is waited for by, then takes the operator's `FOR SHARE`,
  which a change of its kind and its suspension wait for, or come first and are seen. A
  deadlock or a serialisation failure Postgres breaks all the same is taken again, twice
  at most, and `{:error, :busy}` after; inside a caller's transaction, which it would roll
  back with it, it is not taken again, and returns `{:error, :busy}` at once.
  """

  import Ecto.Query, warn: false

  alias Apiary.{Access, Audit, Features, Organisations, Repo}
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Organisations.{Membership, Organisation}
  alias Apiary.Stacks.Stack
  alias ApiaryPro.{Grants, HarnessAssignments, PolicyRequests, Suspensions, Tenants}
  alias ApiaryPro.Transfers.Transfer

  @reason_max 500

  # Hidden (`ApiaryPro.Flags.transfers?/0`), so not in the published documentation: an
  # organisation offered to an operator, on its Clients page.
  @typedoc false
  @type offer_row :: %{transfer: Transfer.t(), organisation: %Organisation{}}

  @doc "reason_max/0 is the most characters the arbiter's reason for a transfer holds."
  @spec reason_max() :: pos_integer
  def reason_max, do: @reason_max

  ## Reading

  @doc """
  pending/1 is the pending offer of the scope's organisation, with its recipient loaded,
  or nil. For its settings page.
  """
  @spec pending(Scope.t()) :: Transfer.t() | nil
  def pending(%Scope{organisation: %Organisation{id: id}}) do
    Repo.one(
      from t in Transfer,
        where: t.organisation_id == ^id,
        preload: [:operator, :recipient]
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

  # Hidden (`ApiaryPro.Flags.transfers?/0`), so not in the published documentation.
  #
  # list_offers/1 is the organisations offered to the scope's organisation, an operator,
  # oldest first (`client.read`), each with its offer: for its Clients page, where an owner
  # accepts them. `{:ok, rows}`; `{:error, :not_found}` in an organisation that is no
  # operator, and `Apiary.Access`'s answer otherwise.
  @doc false
  @spec list_offers(Scope.t()) :: {:ok, [offer_row]} | {:error, Access.reason()}
  def list_offers(%Scope{organisation: %Organisation{id: operator_id} = operator} = scope) do
    with :ok <- Access.authorize(scope, :"client.read", operator) do
      rows =
        Repo.all(
          from t in Transfer,
            join: o in assoc(t, :organisation),
            where: t.kind == :to_operator and t.operator_id == ^operator_id,
            where: is_nil(o.deletion_marked_at),
            order_by: [asc: t.inserted_at, asc: t.id],
            select: %{transfer: t, organisation: o}
        )

      {:ok, rows}
    end
  end

  def list_offers(_scope), do: {:error, :not_found}

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

  # Hidden pending rework (`ApiaryPro.Flags.transfers?/0`), so not in the published
  # documentation.
  #
  # offer_to_operator/2 offers the scope's organisation, of the kind `organisation` and no
  # client, to the operator whose slug is `operator_slug` (`organisation.transfer`, an
  # owner's, with `managed_organisations`): a pending offer an owner of the operator accepts
  # with `accept_client/2`; its people keep their levels. An entry of
  # `organisation.transfer` in its trail, which names the operator by id.
  #
  # `{:ok, transfer}`; `{:error, :operator}` for an organisation that is an operator itself,
  # which is never a client; `{:error, :client}` for a client, which leaves its operator
  # first; `{:error, :no_operator}` for a slug that names no operator in use and not
  # suspended; `{:error, :pending}` while an offer is pending; `{:error, :not_found}` where
  # `managed_organisations` is off, and `Apiary.Access`'s answer otherwise.
  @doc false
  @spec offer_to_operator(Scope.t(), String.t()) ::
          {:ok, Transfer.t()}
          | {:error, :operator | :client | :no_operator | :pending | Access.reason() | term}
  def offer_to_operator(%Scope{organisation: %Organisation{id: id}} = scope, operator_slug) do
    if Features.visible?(scope, :managed_organisations) do
      retrying(fn ->
        # The lock order (docs/access.md): the organisation's row `FOR NO KEY UPDATE` and
        # the operator's `FOR SHARE`, which a change of its kind and its suspension lock
        # for update, and withdraw the offers made to it, so they wait for this one, or
        # come first and are seen here; both at one point, in the lock order.
        operator_id = operator_id_by_slug(operator_slug)

        with {:ok, held} <- lock_pair(id, :no_key_update, operator_id, :share),
             %Organisation{} = organisation <- held[id] || {:error, :not_found},
             :ok <- Access.authorize(scope, :"organisation.transfer", organisation),
             :ok <- independent(organisation),
             {:ok, operator} <- operator_by_slug(held[operator_id], operator_slug),
             :ok <- none_pending(organisation),
             {:ok, transfer} <-
               Repo.insert(%Transfer{
                 organisation_id: organisation.id,
                 kind: :to_operator,
                 operator_id: operator.id,
                 offered_by_id: scope.user.id
               }),
             {:ok, _entry} <-
               Audit.record(Repo, scope, :"organisation.transfer", transfer, %{
                 details: %{kind: :to_operator, operator_id: operator.id}
               }) do
          {:ok, transfer}
        end
      end)
      |> tell()
    else
      {:error, :not_found}
    end
  end

  def offer_to_operator(_scope, _slug), do: {:error, :not_found}

  # Hidden pending rework (`ApiaryPro.Flags.transfers?/0`), so not in the published
  # documentation.
  #
  # withdraw/1 withdraws the pending offer of the scope's organisation to an operator
  # (`organisation.withdraw_transfer`, an owner's). An arbiter's offer is not theirs to
  # withdraw, `{:error, :forbidden}`. An entry of `organisation.withdraw_transfer` in the
  # organisation's trail.
  #
  # `{:ok, transfer}`, as it was; `{:error, :not_found}` with none pending, one accepted
  # meanwhile included, and `Apiary.Access`'s answer otherwise.
  @doc false
  @spec withdraw(Scope.t()) :: {:ok, Transfer.t()} | {:error, Access.reason() | term}
  def withdraw(%Scope{organisation: %Organisation{id: id}} = scope) do
    retrying(fn ->
      with %Organisation{} = organisation <-
             lock_row(id, "FOR NO KEY UPDATE") || {:error, :not_found},
           :ok <- Access.authorize(scope, :"organisation.withdraw_transfer", organisation),
           %Transfer{} = transfer <- lock_pending(organisation) || {:error, :not_found},
           :ok <- if(transfer.arbitrated, do: {:error, :forbidden}, else: :ok),
           {:ok, withdrawn} <- Repo.delete(transfer),
           {:ok, _entry} <-
             Audit.record(Repo, scope, :"organisation.withdraw_transfer", transfer, %{
               details: %{
                 kind: transfer.kind,
                 user_id: transfer.recipient_id,
                 operator_id: transfer.operator_id
               }
             }) do
        {:ok, withdrawn}
      end
    end)
    |> tell()
  end

  def withdraw(_scope), do: {:error, :not_found}

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

  # Hidden pending rework, so not in the published documentation.
  #
  # withdraw_offers_to/3 withdraws every pending offer of an organisation to `operator`,
  # which can take on no client any more: it was made an organisation, `reason`
  # `"operator_made_organisation"`, or suspended, `"operator_suspended"`. For the
  # transaction of that change, which asked `Apiary.Access` and locked the operator's row
  # for update, so no offer to it is made or accepted meanwhile. Each is an entry of
  # `organisation.withdraw_transfer` in the offered organisation's trail, with the reason,
  # by `actor`, the instance admin who made the change, or by the instance without one; the
  # organisation may be offered again at once. `{:ok, count}`.
  @doc false
  @spec withdraw_offers_to(%Organisation{}, String.t(), Scope.t() | nil) ::
          {:ok, non_neg_integer} | {:error, term}
  def withdraw_offers_to(%Organisation{id: operator_id}, reason, actor \\ nil)
      when is_binary(reason) do
    Repo.all(
      from t in Transfer,
        where: t.operator_id == ^operator_id and t.kind == :to_operator,
        order_by: [asc: t.id],
        preload: [:organisation],
        lock: "FOR UPDATE OF t0"
    )
    |> withdraw_all(reason, actor)
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

  # Hidden (`ApiaryPro.Flags.transfers?/0`), so not in the published documentation.
  #
  # accept_client/2 accepts the organisation `organisation_id`, offered to the scope's
  # organisation, an operator (`client.accept`, an owner's of the operator): it becomes a
  # client of the operator, whose people read it from then on; the organisation's people
  # keep their levels, its owners its owners, and it has what the operator grants it. The
  # offer is deleted. An entry of `client.accept` in the operator's trail and one in the
  # organisation's, each naming the other.
  #
  # `{:ok, organisation}`; `{:error, :not_found}` with no such offer pending, one withdrawn
  # meanwhile included, or an organisation marked for deletion; `{:error, :changed}` for an
  # organisation that became an operator or a client meanwhile; `{:error, :suspended}` for
  # a suspended organisation; `Apiary.Access`'s answer otherwise, which refuses in an
  # operator made an organisation or suspended meanwhile.
  @doc false
  @spec accept_client(Scope.t(), Ecto.UUID.t()) ::
          {:ok, %Organisation{}}
          | {:error, :not_found | :changed | :suspended | Access.reason() | term}
  def accept_client(%Scope{organisation: %Organisation{id: operator_id}} = scope, organisation_id) do
    with {:ok, id} <- cast(organisation_id) do
      retrying(fn ->
        # The lock order (docs/access.md): the offered organisation's row
        # `FOR NO KEY UPDATE` and the operator's `FOR SHARE`, which a change of its kind
        # and its suspension wait for, or come first and the question reads them, both at
        # one point, in the lock order. Then, once the organisation held is still one with
        # no operator, the offer.
        with {:ok, held} <- lock_pair(id, :no_key_update, operator_id, :share),
             %Organisation{deletion_marked_at: nil} = organisation <-
               held[id] || {:error, :not_found},
             %Organisation{} <- held[operator_id] || {:error, :not_found},
             :ok <- Access.authorize(scope, :"client.accept", scope.organisation),
             :ok <- offered_to(organisation, operator_id),
             :ok <- still_independent(organisation),
             %Transfer{kind: :to_operator, operator_id: ^operator_id} = transfer <-
               lock_pending(organisation) || {:error, :not_found},
             {:ok, tenant} <-
               organisation
               |> Tenants.tenant()
               |> Tenants.operator_changeset(scope.organisation)
               |> Repo.insert_or_update(),
             client = Tenants.put_tenant(organisation, tenant),
             {:ok, _features} <- Grants.written_out(client, {:client, scope.organisation}),
             {:ok, _deleted} <- Repo.delete(transfer),
             {:ok, _entry} <-
               Audit.record(Repo, scope, :"client.accept", scope.organisation, %{
                 details: %{organisation_id: client.id}
               }),
             {:ok, _entry} <-
               Audit.record(
                 Repo,
                 Scope.in_organisation(scope, client),
                 :"client.accept",
                 client,
                 %{before: %{operator_id: nil}, after: %{operator_id: operator_id}}
               ) do
          {:ok, client}
        else
          %Organisation{} -> {:error, :not_found}
          %Transfer{} -> {:error, :not_found}
          {:error, _reason} = error -> error
        end
      end)
      |> tap(fn
        {:ok, client} -> tell_people_of([client.id, operator_id])
        _refused -> :ok
      end)
    end
  end

  ## Parting

  # Hidden pending rework (`ApiaryPro.Flags.transfers?/0`), so not in the published
  # documentation.
  #
  # leave/2 takes the scope's organisation, a client, away from its operator at once
  # (`organisation.leave_operator`, an owner's of the client), when `confirmation` is the
  # operator's name: it is an organisation with no operator from then on, the operator's
  # people read it no more, and the grants the operator made it go, so it has what an
  # organisation with no operator has. An entry of `organisation.leave_operator` in its
  # trail and one in the operator's, each naming the other.
  #
  # `{:ok, organisation}`; `{:error, :confirmation}` for a confirmation that is not the
  # operator's name, asked after the role; `{:error, :not_found}` for an organisation with
  # no operator, one marked for deletion included, and `Apiary.Access`'s answer otherwise.
  @doc false
  @spec leave(Scope.t(), String.t() | nil) ::
          {:ok, %Organisation{}} | {:error, :confirmation | Access.reason() | term}
  def leave(%Scope{organisation: %Organisation{id: id}} = scope, confirmation) do
    retrying(fn ->
      # The lock order (docs/access.md): the client's row `FOR NO KEY UPDATE` and its
      # operator's `FOR SHARE`, at one point, in the lock order. The operator is read
      # first, without a lock; once the client is held it changes no more, so one that
      # changed in between is a change to try again.
      operator_id = Tenants.operator_id(%Organisation{id: id})

      with {:ok, held} <- lock_pair(id, :no_key_update, operator_id, :share),
           %Organisation{} = client <- held[id] || {:error, :not_found},
           :ok <- Access.authorize(scope, :"organisation.leave_operator", client),
           :ok <- same_operator(client, operator_id),
           %Organisation{} = operator <- held[operator_id] || {:error, :not_found},
           :ok <- confirm(operator.name, confirmation) do
        part(scope, :"organisation.leave_operator", client, operator)
      end
    end)
    |> told()
  end

  def leave(_scope, _confirmation), do: {:error, :not_found}

  @doc """
  drop/3 takes the client `client_id` away from the scope's organisation, its operator,
  at once (`client.drop`, an owner's of the operator), when `confirmation` is the
  client's name: it is an organisation with no operator from then on, its people
  keeping their levels. An entry of `client.drop` in the
  operator's trail and one in the client's, each naming the other.

  `{:ok, organisation}`, the client as it is now; `{:error, :no_owner}` for a client that
  has no owner yet, which would be left with nobody in it, and which its operator deletes
  instead (`ApiaryPro.Deletion.delete_client/3`); `{:error, :confirmation}` for a
  confirmation that is not the client's name, asked after the role;
  `{:error, :not_found}` for an organisation that is no client of the operator, or one
  marked for deletion; `{:error, :busy}` as above, and `Apiary.Access`'s answer otherwise.
  """
  @spec drop(Scope.t(), Ecto.UUID.t(), String.t() | nil) ::
          {:ok, %Organisation{}}
          | {:error, :confirmation | :busy | Access.reason() | term}
  def drop(%Scope{organisation: %Organisation{id: operator_id}} = scope, client_id, confirmation) do
    with {:ok, id} <- cast(client_id) do
      retrying(fn ->
        # The lock order (docs/access.md): the client's row `FOR NO KEY UPDATE` and the
        # operator's `FOR SHARE`, at one point, in the lock order.
        with {:ok, held} <- lock_pair(id, :no_key_update, operator_id, :share),
             %Organisation{deletion_marked_at: nil} = client <-
               held[id] || {:error, :not_found},
             true <- Tenants.operator_id(client) == operator_id || {:error, :not_found},
             %Organisation{} = operator <- held[operator_id] || {:error, :not_found},
             :ok <- Access.authorize(scope, :"client.drop", operator),
             :ok <- owned(client),
             :ok <- confirm(client.name, confirmation) do
          part(scope, :"client.drop", client, operator)
        else
          %Organisation{} -> {:error, :not_found}
          {:error, _reason} = error -> error
        end
      end)
      |> told()
    end
  end

  def drop(_scope, _client_id, _confirmation), do: {:error, :not_found}

  # A client with an owner, who is left in charge of it once it is dropped.
  defp owned(%Organisation{id: id}) do
    if Repo.exists?(from m in Membership, where: m.organisation_id == ^id and m.level == :owner),
      do: :ok,
      else: {:error, :no_owner}
  end

  # The other side's name, typed to confirm a parting.
  defp confirm(name, confirmation) when is_binary(confirmation) do
    if String.trim(confirmation) == name, do: :ok, else: {:error, :confirmation}
  end

  defp confirm(_name, _confirmation), do: {:error, :confirmation}

  # A client parted from its operator, by `action`: no operator, what an organisation with
  # no operator has, and an entry in each trail, the client's first.
  defp part(scope, action, client, operator) do
    with {:ok, tenant} <-
           client |> Tenants.tenant() |> Tenants.operator_changeset(nil) |> Repo.update(),
         parted = Tenants.put_tenant(client, tenant),
         {:ok, _features} <- Grants.written_out(parted, :left),
         {:ok, _withdrawn} <-
           PolicyRequests.withdraw_for_client(scope, parted, operator, parting_reason(action)),
         {:ok, _removed} <- remove_operator_harness(operator, parted),
         {:ok, _entry} <-
           Audit.record(Repo, Scope.in_organisation(scope, parted), action, parted, %{
             before: %{operator_id: operator.id},
             after: %{operator_id: nil}
           }),
         {:ok, _entry} <-
           Audit.record(Repo, Scope.in_organisation(scope, operator), action, operator, %{
             details: %{organisation_id: parted.id}
           }) do
      {:ok, {parted, operator}}
    end
  end

  # The harness documents the operator owns in the client and its assignments of harness
  # sources to it go in the same transaction; the documents the client's people saved stay.
  #
  # What the operator set in the client for its runs' harness goes with the operator: the
  # harness documents it owns there, and its assignments of harness sources. A row that
  # sets a workflow too stays, without its document. The documents the client's people
  # saved stay, and so does every workflow.
  defp remove_operator_harness(operator, client) do
    owned =
      from s in Stack,
        where: s.organisation_id == ^client.id and s.owner_organisation_id == ^operator.id,
        where: not is_nil(s.harness)

    {_deleted, _rows} = Repo.delete_all(from s in owned, where: is_nil(s.workflow))
    {_kept, _rows} = Repo.update_all(owned, set: [harness: nil])

    HarnessAssignments.delete_all(operator.id, client.id)
  end

  defp parting_reason(:"organisation.leave_operator"), do: "left"
  defp parting_reason(:"client.drop"), do: "dropped"

  # The people of both, told once it is written, so their pages load their scope again:
  # the operator's leave the client's pages, and the client's see it has no operator.
  defp told({:ok, {organisation, operator}}) do
    tell_people_of([organisation.id, operator.id])
    {:ok, organisation}
  end

  defp told(result), do: result

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
  defp lock_row(nil, _how), do: nil
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

  # A client whose operator is still the one read before its row was held.
  defp same_operator(client, operator_id) do
    cond do
      is_nil(Tenants.operator_id(client)) -> {:error, :not_found}
      Tenants.operator_id(client) == operator_id -> :ok
      true -> {:error, :busy}
    end
  end

  # An offer of the organisation to the operator pending, read without a lock, so that an
  # organisation with none is not found before its state is read; the offer is locked
  # later, in its place in the lock order, and read again then.
  defp offered_to(%Organisation{id: id}, operator_id) do
    if Repo.exists?(
         from t in Transfer,
           where:
             t.organisation_id == ^id and t.kind == :to_operator and
               t.operator_id == ^operator_id
       ),
       do: :ok,
       else: {:error, :not_found}
  end

  defp lock_pending(%Organisation{id: id}) do
    Repo.one(from t in Transfer, where: t.organisation_id == ^id, lock: "FOR UPDATE")
  end

  defp none_pending(%Organisation{id: id}) do
    if Repo.exists?(from t in Transfer, where: t.organisation_id == ^id),
      do: {:error, :pending},
      else: :ok
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

  # An organisation of the kind `organisation` that is no client may be offered to an
  # operator.
  defp independent(%Organisation{} = organisation) do
    cond do
      Tenants.operator?(organisation) -> {:error, :operator}
      Tenants.client?(organisation) -> {:error, :client}
      true -> :ok
    end
  end

  defp still_independent(%Organisation{} = organisation) do
    cond do
      Tenants.suspended?(organisation) -> {:error, :suspended}
      independent(organisation) != :ok -> {:error, :changed}
      Tenants.instance_organisation?(organisation) -> {:error, :changed}
      true -> :ok
    end
  end

  # The organisation the slug names, in use, read without a lock: its id, or nil.
  defp operator_id_by_slug(slug) when is_binary(slug) do
    Repo.one(
      from o in Organisation,
        where: o.slug == ^String.trim(slug) and is_nil(o.deletion_marked_at),
        select: o.id
    )
  end

  defp operator_id_by_slug(_slug), do: nil

  # The operator the slug names, as it is held, its tenant read once the lock is held: an
  # operator in use and not suspended, which the slug still names.
  defp operator_by_slug(%Organisation{} = operator, slug) when is_binary(slug) do
    if operator.slug == String.trim(slug) and is_nil(operator.deletion_marked_at) and
         Tenants.operator?(operator) and not Tenants.suspended?(operator),
       do: {:ok, operator},
       else: {:error, :no_operator}
  end

  defp operator_by_slug(_operator, _slug), do: {:error, :no_operator}

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
