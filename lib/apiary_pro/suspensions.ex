defmodule ApiaryPro.Suspensions do
  @moduledoc """
  Suspending and activating a person's account and an organisation, an operator among
  them: instance actions of the instance organisation's owners, the instance admins, on
  Instance settings' pages, each asked of `Apiary.Access` in the instance organisation. A
  membership in one organisation is suspended by that organisation's owners and admins
  (`Apiary.Organisations.suspend_member/2`).

  **A suspension pauses; it removes nothing.** An account's suspension is a separate
  row (`ApiaryPro.Suspensions.AccountSuspension`), inserted by the suspension and deleted
  by the activation; an organisation's is its tenant's `suspended_at` and
  `suspended_by_id` (`ApiaryPro.Tenants.Tenant`), which activating empties. Memberships,
  workspace access, history, access keys and the managing relationship all stay.
  "Activating" is only the end of a suspension. Each suspension and each activation is an
  audit entry, written in its transaction.

  - **An account** (`suspend_account/2`, `instance.suspend_account`) signs in nowhere, its
    sessions are ended and its open pages disconnected, and it acts nowhere: every
    membership of it counts as none (`Apiary.Access.reload/2`). Its access keys are not
    the account's: a key belongs to a node of a workspace, so the keys it added keep working. The
    entry is the instance organisation's, and names the account by id.
  - **An organisation or an operator** (`suspend_organisation/2`,
    `instance.suspend_organisation`) is read-only: its people sign in and read everything,
    under a notice, and change nothing; it sends no invitation and accepts none; its access
    keys are refused as a revoked key is, so no run starts or reports. A suspended
    operator's people read its clients no more, and its workspaces are suspended
    with it; its clients keep running, their keys and their people working as before. The
    entry is the suspended organisation's.

  **The last owner.** Nobody suspends the instance organisation, nor their account,
  and the account of the instance organisation's last owner who may act is not suspended,
  `{:error, :last_owner}`: the release command is the way back. Anywhere else the instance
  admins may leave an organisation, a client as any other, without an owner who may act,
  by suspending the account of its only owner: it runs below the owner level, its admins
  told so (`owner_suspended?/1`), until an instance admin activates it again or transfers
  the ownership to one of its admins (`ApiaryPro.Transfers.arbitrate/4`).

  **What a suspension leaves out.** The core asks through the suspension refinements of
  `Apiary.Edition`, which leave out of its queries what a suspension stops:
  `active_accounts/2`, `active_organisations/2`, and `account_refusal/1` at sign-in.

  **Race safety.** A suspension locks the row of what it suspends `FOR NO KEY UPDATE`
  before it asks, in the lock order of docs/access.md: an organisation's row first; an
  account's after the owners' memberships it may count. It then writes the tenant, or
  inserts or deletes the account's suspension, under that lock: the absence of a row
  cannot be locked, so the account's and the organisation's rows stay the ones to lock. A
  change that holds the row while it is written (`Apiary.Access.reload/2` with
  `lock: :share`, which holds the organisation, its operator and the account `FOR SHARE`,
  and reads the suspensions after its locks) is written first, and one asked after the
  suspension waits for it and then sees it; a row that only names it does not wait.
  """

  import Ecto.Query, warn: false

  alias Apiary.{Access, Audit, Organisations, Repo}
  alias Apiary.Accounts.{Scope, User, UserToken}
  alias Apiary.Organisations.{Membership, Organisation}
  alias ApiaryPro.Suspensions.AccountSuspension
  alias ApiaryPro.Tenants
  alias ApiaryPro.Tenants.Tenant

  @typedoc """
  An account on Instance settings › Accounts: how many memberships it holds, and since when it is
  suspended, nil for one in use.
  """
  @type account_row :: %{
          user: %User{},
          memberships: non_neg_integer,
          suspended_at: DateTime.t() | nil
        }

  @doc """
  list_accounts/1 is every account on the instance that is not deleted, by email address,
  each with how many memberships it holds and since when it is suspended, nil for one in
  use (`instance.read`, an owner's of the instance organisation, asked in it).
  `{:ok, rows}`; `{:error, :not_found}` anywhere but in the instance organisation, and
  `Apiary.Access`'s answer otherwise.
  """
  @spec list_accounts(Scope.t()) :: {:ok, [account_row]} | {:error, Access.reason()}
  def list_accounts(%Scope{organisation: %Organisation{} = here} = scope) do
    with :ok <- Access.authorize(scope, :"instance.read", here) do
      rows =
        Repo.all(
          from u in User,
            left_join: m in Membership,
            on: m.user_id == u.id,
            left_join: s in AccountSuspension,
            on: s.user_id == u.id,
            where: is_nil(u.deleted_at),
            group_by: [u.id, s.user_id],
            order_by: [asc: u.email, asc: u.id],
            select: %{user: u, memberships: count(m.id), suspended_at: s.suspended_at}
        )

      {:ok, rows}
    end
  end

  def list_accounts(_scope), do: {:error, :not_found}

  @doc """
  left_without_owner/1 is the organisations in use that the account `user_id` would leave
  without an owner who may act, were it suspended, by name: those where its owner's
  membership is in use and no other owner may act. For Instance settings › Accounts, which says so
  before it suspends the account.
  """
  @spec left_without_owner(Ecto.UUID.t()) :: [%Organisation{}]
  def left_without_owner(user_id) do
    case Ecto.UUID.cast(user_id) do
      {:ok, id} ->
        others =
          from(m in Membership,
            join: u in assoc(m, :user),
            as: :account,
            where: m.organisation_id == parent_as(:organisation).id,
            where: m.level == :owner and m.user_id != ^id,
            where: is_nil(m.suspended_at) and is_nil(u.deleted_at)
          )
          |> active_accounts(:account)

        Repo.all(
          from o in Organisation,
            as: :organisation,
            join: m in Membership,
            on: m.organisation_id == o.id and m.user_id == ^id,
            where: m.level == :owner and is_nil(m.suspended_at),
            where: is_nil(o.deletion_marked_at) and not exists(others),
            order_by: [asc: o.name, asc: o.id]
        )

      :error ->
        []
    end
  end

  @doc """
  suspend_account/2 suspends the account `user_id` (`instance.suspend_account`, an
  instance admin's, asked in the instance organisation): it signs in nowhere, and every
  membership it holds counts as none. Its session tokens are deleted, and returned, so the
  caller disconnects their open pages (`ApiaryWeb.UserAuth.disconnect_sessions/1`). The
  entry is the instance organisation's, `details.user_id` naming the account.

  The account's row is locked `FOR NO KEY UPDATE` and its suspension inserted under the
  lock (Race safety, above). Before it, in the lock order of docs/access.md: every
  organisation the account is a member of and the instance organisation, in one pass, the
  instance organisation `FOR SHARE` and the rest `FOR KEY SHARE`; then the people locks of
  exactly those organisations `FOR UPDATE` (`ApiaryPro.Tenants.lock_people/2`), so a
  write in a client that relies on the person's level in its operator waits for the
  suspension, or came first; then the instance organisation's owners
  (`Apiary.Organisations.lock_owners/1`), whose people locks are among those held.

  `{:ok, %{user: user, tokens: tokens}}`, tokens empty for an account suspended already,
  which changes nothing and leaves no entry; `{:error, :last_owner}` for the last owner of
  the instance organisation who may act; `{:error, :forbidden}` for the instance admin's
  account; `{:error, :not_found}` for an account that is not there or is deleted, and
  `Apiary.Access`'s answer otherwise.
  """
  @spec suspend_account(Scope.t(), Ecto.UUID.t()) ::
          {:ok, %{user: %User{}, tokens: [%UserToken{}]}}
          | {:error, :last_owner | Access.reason() | term}
  def suspend_account(%Scope{organisation: %Organisation{} = here} = scope, user_id) do
    with {:ok, id} <- cast(user_id) do
      Repo.transact(fn ->
        # The lock order (docs/access.md): the organisations and their people locks, then
        # the instance organisation's owners, as a demotion locks them, then the account.
        instance = instance_scope(scope)
        :ok = lock_people_of_account(id, instance.organisation)

        with :ok <- Organisations.lock_owners(instance),
             %User{} = user <- lock_account(id) || {:error, :not_found},
             :ok <- Access.authorize(scope, :"instance.suspend_account", user) do
          cond do
            account_suspension(id) ->
              {:ok, %{user: user, tokens: []}}

            last_instance_owner?(here, user) ->
              {:error, :last_owner}

            true ->
              with {:ok, suspension} <-
                     Repo.insert(%AccountSuspension{
                       user_id: id,
                       suspended_at: DateTime.utc_now(),
                       suspended_by_id: scope.user.id
                     }),
                   tokens = Repo.all(from t in UserToken, where: t.user_id == ^id),
                   {_count, _} =
                     Repo.delete_all(
                       from t in UserToken, where: t.user_id == ^id and t.context == "session"
                     ),
                   {:ok, _entry} <-
                     Audit.record(Repo, scope, :"instance.suspend_account", here, %{
                       before: %{suspended_at: nil},
                       after: %{suspended_at: suspension.suspended_at},
                       details: %{user_id: id}
                     }) do
                {:ok, %{user: user, tokens: Enum.filter(tokens, &(&1.context == "session"))}}
              end
          end
        end
      end)
      |> tap(fn
        {:ok, %{user: %User{id: id}}} -> tell_person(id)
        _refused -> :ok
      end)
    end
  end

  @doc """
  activate_account/2 ends the suspension of the account `user_id`
  (`instance.activate_account`): it signs in again, and its memberships count as they
  did: its suspension is deleted, under the account's row locked `FOR NO KEY UPDATE`. The
  entry is the instance organisation's. `{:ok, user}`, nothing changed and no entry for an
  account not suspended; `{:error, :not_found}` for one that is not there or is deleted,
  and `Apiary.Access`'s answer otherwise.
  """
  @spec activate_account(Scope.t(), Ecto.UUID.t()) ::
          {:ok, %User{}} | {:error, Access.reason() | term}
  def activate_account(%Scope{organisation: %Organisation{} = here} = scope, user_id) do
    with {:ok, id} <- cast(user_id) do
      Repo.transact(fn ->
        # The lock order (docs/access.md): the organisations the account owns and their
        # owners' memberships of it, then the account.
        owned = lock_owned(id)

        with %User{} = user <- lock_account(id) || {:error, :not_found},
             :ok <- Access.authorize(scope, :"instance.activate_account", user) do
          case account_suspension(id) do
            nil ->
              {:ok, user}

            %AccountSuspension{} = suspension ->
              with {:ok, _deleted} <- Repo.delete(suspension),
                   # An owner who may act again: the arbiter's offers there lapse.
                   {:ok, _withdrawn} <- ApiaryPro.Transfers.withdraw_overruled(owned, scope),
                   {:ok, _entry} <-
                     Audit.record(Repo, scope, :"instance.activate_account", here, %{
                       before: %{suspended_at: suspension.suspended_at},
                       after: %{suspended_at: nil},
                       details: %{user_id: id}
                     }) do
                {:ok, user}
              end
          end
        end
      end)
    end
  end

  @doc """
  suspend_organisation/2 suspends the organisation `organisation_id`, of either kind,
  never the instance organisation (`instance.suspend_organisation`, an instance admin's,
  asked in the instance organisation): read-only until it is activated, its access keys
  refused. A suspended operator's people lose their reach into its clients, which keep
  running. Its people's open pages follow, and say so. The entry is the suspended
  organisation's.

  `{:ok, organisation}`, nothing changed and no entry for one suspended already;
  `{:error, :forbidden}` for the instance organisation; `{:error, :not_found}` for one
  that is not there or is marked for deletion, and `Apiary.Access`'s answer otherwise.
  """
  @spec suspend_organisation(Scope.t(), Ecto.UUID.t()) ::
          {:ok, %Organisation{}} | {:error, Access.reason() | term}
  def suspend_organisation(%Scope{} = scope, organisation_id) do
    set_organisation(scope, organisation_id, :"instance.suspend_organisation", fn
      %Tenant{suspended_at: nil} = tenant ->
        Tenants.suspension_changeset(tenant, :suspend, scope.user.id)

      _suspended ->
        nil
    end)
  end

  @doc """
  activate_organisation/2 ends the suspension of the organisation `organisation_id`
  (`instance.activate_organisation`): it works again, its access keys with it, and a
  suspended operator's people reach its clients again. The entry is the organisation's.
  `{:ok, organisation}`, nothing changed and no entry for one not suspended;
  `{:error, :not_found}` for one that is not there, and `Apiary.Access`'s answer
  otherwise.
  """
  @spec activate_organisation(Scope.t(), Ecto.UUID.t()) ::
          {:ok, %Organisation{}} | {:error, Access.reason() | term}
  def activate_organisation(%Scope{} = scope, organisation_id) do
    set_organisation(scope, organisation_id, :"instance.activate_organisation", fn
      %Tenant{suspended_at: %DateTime{}} = tenant ->
        Tenants.suspension_changeset(tenant, :activate, nil)

      _active ->
        nil
    end)
  end

  # The organisation locked `FOR NO KEY UPDATE`, the lock order's first row, and its
  # tenant read under the lock: a change that holds it `FOR SHARE` (`Apiary.Access.reload/2` with
  # `lock: :share`, an invitation's acceptance) is waited for, then the question, then the
  # change of its tenant `changes` gives, if any, written under the lock. A row that only
  # names it, `FOR KEY SHARE`, does not wait.
  defp set_organisation(scope, organisation_id, action, changes) do
    with {:ok, id} <- cast(organisation_id) do
      Repo.transact(fn ->
        with %Organisation{} = organisation <-
               Tenants.lock_organisation(id, "FOR NO KEY UPDATE") || {:error, :not_found},
             :ok <- not_marked(organisation, action),
             :ok <- Access.authorize(scope, action, organisation) do
          case changes.(Tenants.tenant(organisation)) do
            nil ->
              {:ok, organisation}

            changeset ->
              with {:ok, tenant} <- Repo.insert_or_update(changeset),
                   changed = Tenants.put_tenant(organisation, tenant),
                   {:ok, _withdrawn} <- withdraw_offers(changed, action, scope),
                   {:ok, _entry} <-
                     Audit.record(
                       Repo,
                       scope |> Scope.in_organisation(changed) |> Scope.put_origin(nil),
                       action,
                       changed,
                       %{
                         before: %{suspended_at: Tenants.suspended_at(organisation)},
                         after: %{suspended_at: tenant.suspended_at}
                       }
                     ) do
                {:ok, changed}
              end
          end
        end
      end)
      |> tap(fn
        {:ok, %Organisation{id: id}} -> tell_people_of(id)
        _refused -> :ok
      end)
    end
  end

  # A suspended operator takes on no client: the offers to it are withdrawn, and the
  # organisations that made them may offer themselves elsewhere.
  defp withdraw_offers(%Organisation{} = organisation, :"instance.suspend_organisation", scope) do
    if Tenants.operator?(organisation),
      do: ApiaryPro.Transfers.withdraw_offers_to(organisation, "operator_suspended", scope),
      else: {:ok, 0}
  end

  defp withdraw_offers(_organisation, _action, _scope), do: {:ok, 0}

  # An organisation marked for deletion is gone but for its purge: it is not suspended;
  # one suspended before its marking may still be activated.
  defp not_marked(%Organisation{deletion_marked_at: nil}, _action), do: :ok
  defp not_marked(_marked, :"instance.activate_organisation"), do: :ok
  defp not_marked(_marked, _action), do: {:error, :not_found}

  # The organisations of which the account holds an owner's membership, held
  # `FOR SHARE`: an acceptance of the arbiter's offer there, which locks the owners for
  # update, waits for the activation, or comes first and is seen. The organisation rows
  # first, `FOR SHARE`, in the order of `Apiary.Organisations.lock_order/1`, the clients
  # before the rest, so a client comes before its operator, each in the order of their
  # ids; then the memberships, as the lock order has them.
  defp lock_owned(user_id) do
    owned =
      from m in Membership,
        where: m.user_id == ^user_id and m.level == :owner,
        select: m.organisation_id

    Tenants.lock_organisations!(Repo.all(owned), :share)

    Repo.all(
      from m in Membership,
        where: m.user_id == ^user_id and m.level == :owner,
        order_by: [asc: m.id],
        select: m.organisation_id,
        lock: "FOR SHARE"
    )
  end

  # Every organisation the account is a member of, and the instance organisation, in one
  # statement in the lock order (`ApiaryPro.Tenants.lock_organisations!/2`): the clients
  # first, so a client comes before its operator, then the rest, each in the order of their
  # ids; the
  # instance organisation `FOR SHARE`, as `Apiary.Organisations.lock_owners/1` holds it
  # next, and the rest `FOR KEY SHARE`, which waits only for a change that takes an
  # organisation `FOR UPDATE`. Then the people locks of exactly the organisations held,
  # `FOR UPDATE`: an organisation joined after they were read is not held, and its row is
  # not taken; the account's row, which every locked write reads last, keeps such a write
  # from acting for the person.
  defp lock_people_of_account(user_id, instance) do
    instance_ids = if instance, do: [instance.id], else: []

    member_of =
      Repo.all(from m in Membership, where: m.user_id == ^user_id, select: m.organisation_id)

    held =
      Tenants.lock_organisations!(member_of ++ instance_ids, fn id ->
        if id in instance_ids, do: :share, else: :key_share
      end)

    Tenants.lock_people(Map.keys(held), :update)
  end

  # The account, while it is not deleted, `FOR NO KEY UPDATE`, the lock order's last: a
  # change that holds it `FOR SHARE` while it is written (`Apiary.Access.reload/2`) is
  # written first; a row that only names it, `FOR KEY SHARE`, does not wait. Its
  # suspension is read and written under this lock.
  defp lock_account(id) do
    Repo.one(
      from u in User, where: u.id == ^id and is_nil(u.deleted_at), lock: "FOR NO KEY UPDATE"
    )
  end

  # The account's suspension, as the database has it now: its row, or nil.
  defp account_suspension(user_id), do: Repo.get(AccountSuspension, user_id)

  # Whether `user` is an owner of the instance organisation who may act, and the only one:
  # the instance keeps an admin, and the release command is the way back.
  defp last_instance_owner?(%Organisation{} = here, %User{id: id}) do
    with true <- Tenants.instance_organisation?(here),
         %Membership{} = membership <-
           Repo.one(
             from m in Membership,
               where: m.organisation_id == ^here.id and m.user_id == ^id and m.level == :owner,
               where: is_nil(m.suspended_at)
           ) do
      not Organisations.other_active_owner?(membership)
    else
      _no -> false
    end
  end

  defp instance_scope(%Scope{organisation: organisation} = scope) do
    if Tenants.instance_organisation?(organisation),
      do: scope,
      else: %{scope | organisation: nil}
  end

  # The person's open pages load their scope again, and leave what they no longer reach.
  defp tell_person(user_id) do
    Repo.all(from m in Membership, where: m.user_id == ^user_id)
    |> Organisations.broadcast_membership_changes()
  end

  # Everyone of the organisation, who read its clients through it for an operator: each
  # page follows its person's memberships.
  defp tell_people_of(organisation_id) do
    Repo.all(from m in Membership, where: m.organisation_id == ^organisation_id)
    |> Organisations.broadcast_membership_changes()
  end

  defp cast(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  active_accounts/2 narrows `query` to the accounts that are not suspended, the account
  at the named binding `binding` (`c:Apiary.Edition.active_accounts/2`): those with no
  row of `ApiaryPro.Suspensions.AccountSuspension`. A statement that locks the account
  reads this as it was when the statement began: a caller that must see a suspension
  written while it waited for the lock reads it in a statement after the lock.
  """
  @spec active_accounts(Ecto.Queryable.t(), atom) :: Ecto.Query.t()
  def active_accounts(query, binding) do
    where(
      query,
      not exists(from s in AccountSuspension, where: s.user_id == parent_as(^binding).id)
    )
  end

  @doc """
  active_organisations/2 narrows `query` to the organisations that are not suspended, the
  organisation at the named binding `binding` (`c:Apiary.Edition.active_organisations/2`):
  those whose tenant is not suspended, an organisation without a tenant among them. As
  with `active_accounts/2`, a statement that locks the organisation reads this as it was
  when the statement began.
  """
  @spec active_organisations(Ecto.Queryable.t(), atom) :: Ecto.Query.t()
  def active_organisations(query, binding) do
    where(
      query,
      not exists(
        from t in Tenant,
          where: t.organisation_id == parent_as(^binding).id and not is_nil(t.suspended_at)
      )
    )
  end

  @doc """
  account_refusal/1 is why an account whose password or log-in link was right may not
  sign in (`c:Apiary.Edition.account_refusal/1`): `:suspended` for a suspended account,
  which signs in nowhere until an instance admin activates it; nil otherwise.
  """
  @spec account_refusal(%User{}) :: :suspended | nil
  def account_refusal(%User{id: id}), do: if(account_suspended?(id), do: :suspended)

  @doc "account_suspended?/1 says whether the account `user_id` is suspended, as the database has it now."
  @spec account_suspended?(Ecto.UUID.t()) :: boolean
  def account_suspended?(user_id),
    do: Repo.exists?(from s in AccountSuspension, where: s.user_id == ^user_id)

  @doc """
  owner_suspended?/1 says whether no owner may act in `organisation` because of a
  suspension, as the database has it now: it has owners, and they are all suspended,
  their memberships or their accounts. It then runs below the owner level: its admins and
  members work, and what only an owner does waits (the actions of this module), until the
  instance admins offer its ownership to one of its admins (`ApiaryPro.Transfers`). A page
  tells its admins. A client's operator has no part in it: a client's owners are the client's.
  """
  # While `ApiaryPro.Flags.operator_infrastructure?/0` is on, a client is its operator's,
  # so false for a client: the instance's arbiter has no part in it.
  @spec owner_suspended?(%Organisation{}) :: boolean
  def owner_suspended?(%Organisation{id: id} = organisation) do
    if ApiaryPro.Flags.operator_infrastructure?() and Tenants.client?(organisation),
      do: false,
      else: owners_suspended?(id)
  end

  defp owners_suspended?(id) do
    owners = from m in Membership, where: m.organisation_id == ^id and m.level == :owner

    Repo.exists?(owners) and
      not Repo.exists?(
        from(m in owners,
          join: u in User,
          as: :account,
          on: u.id == m.user_id,
          where: is_nil(m.suspended_at) and is_nil(u.deleted_at)
        )
        |> active_accounts(:account)
      )
  end
end
