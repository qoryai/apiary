defmodule ApiaryPro.Tenants do
  @moduledoc """
  Tenants is what the edition keeps of an organisation beyond the core's: its kind, its
  operator when it is a client, and its suspension. Each organisation has a separate
  row, a tenant (`ApiaryPro.Tenants.Tenant`), written in the transaction that creates the
  organisation (`organisation_created/2`), or by `ApiaryPro.Adoption` for one created
  before the instance had tenants.

  Every organisation has a `kind`: `:organisation`, an ordinary one, or `:operator`, which
  also manages client organisations. One organisation is the **instance organisation**,
  `instance_organisation: true`: the instance owner, whose owners are the instance admins
  (`c:Apiary.Edition.instance_organisation_id/0`). The first sign-up of an instance, its
  set-up by its set-up link (`Apiary.Setup`), creates it (`organisation_created/2`), of
  the kind `first_sign_up_kind/0` gives: an operator where the instance has
  `managed_organisations`, an organisation otherwise. Its
  kind is the instance admins' to change afterwards, as any other organisation's
  (`ApiaryPro.Operators.change_kind/3`). A partial unique index lets one tenant carry the
  flag, and nothing in the product unsets it.

  An organisation of the kind `:organisation` may be a **client** of an operator,
  `operator_id`: the managing relationship, one level deep. The database keeps it so: the
  operator is an organisation of the kind `:operator`, and only an organisation of the
  kind `:organisation` has one, so an operator is never a client, a client never becomes
  an operator, and an operator with clients does not become an organisation or go while
  one references it. The instance organisation, made an operator, may be the operator
  of clients too, and is never a client itself, which a check keeps. A client owns its
  people as any organisation, and its operator's people read it (`ApiaryPro.Reach`). Set
  at creation; emptied when the client is dropped (`ApiaryPro.Transfers`). Nothing here is ever cast from a
  form.

  **On the organisation.** The tenant travels on the organisation it describes, in its
  `edition` map under `:tenant` (`Apiary.Organisations.Organisation`): `put/1` reads the
  tenants of one organisation or of a list in one read, and `put_tenant/2` puts one read
  already. `tenant/1` and the questions after it (`kind/1`, `operator?/1`,
  `instance_organisation?/1`, `client?/1`, `operator_id/1`, `suspended?/1`) answer from
  the organisation as it carries it, and read its tenant when it carries none. An
  organisation without a row, which only a database written before the instance had
  tenants has, is an organisation of the kind `:organisation` with no operator, as
  the adoption makes it.

  **Locks.** A tenant is written only under its organisation's row locked for update: an
  operator's change, a suspension and its end, and the adoption's flag of the instance
  organisation `FOR NO KEY UPDATE`, a change of kind `FOR UPDATE`. So the organisation's
  row stays the one to lock (docs/access.md, The lock order): a reader that holds it
  `FOR SHARE` reads a tenant nobody changes until it commits, in a statement after the
  lock (`lock_organisation/2`).

  **People locks.** Each tenant has a separate row beside it, its people lock
  (`ApiaryPro.Tenants.PeopleLock`), written with its tenant, or by the migration for a
  tenant written before it, and gone with it. `lock_rows/1` takes those a change needs,
  at the change's one point (`c:Apiary.Edition.lock_rows/1`), and `lock_people/1` locks
  those of some organisations, in the order of their ids.
  """

  use Gettext, backend: ApiaryProWeb.Gettext

  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias Apiary.Repo
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Organisations.Organisation
  alias ApiaryPro.{Grants, SignUp}
  alias ApiaryPro.Tenants.{PeopleLock, Tenant}

  @kinds Tenant.kinds()
  @model_chains Tenant.model_chains()

  @typedoc "A kind of `kinds/0`."
  @type kind :: Tenant.kind()

  @doc "kinds/0 is the kinds of organisation: an ordinary organisation, and an operator."
  @spec kinds() :: [kind]
  def kinds, do: @kinds

  ## On the organisation

  @doc """
  tenant/1 is the tenant of `organisation`, as the organisation carries it in its
  `edition`, or read now when it carries none: the defaults, an organisation of no
  operator, for one without a row, and for one not inserted yet.
  """
  @spec tenant(%Organisation{}) :: Tenant.t()
  def tenant(%Organisation{edition: %{tenant: %Tenant{} = tenant}}), do: tenant
  def tenant(%Organisation{id: nil}), do: %Tenant{}
  def tenant(%Organisation{id: id}), do: Repo.get(Tenant, id) || %Tenant{organisation_id: id}

  @doc """
  put/1 is `organisation`, or each of a list of organisations, carrying its tenant as the
  database has it now, read in one statement for them all.
  """
  @spec put(%Organisation{}) :: %Organisation{}
  @spec put([%Organisation{}]) :: [%Organisation{}]
  def put(%Organisation{} = organisation), do: hd(put([organisation]))

  def put([]), do: []

  def put(organisations) when is_list(organisations) do
    ids = organisations |> Enum.map(& &1.id) |> Enum.reject(&is_nil/1)

    by_id =
      Repo.all(from t in Tenant, where: t.organisation_id in ^ids)
      |> Map.new(&{&1.organisation_id, &1})

    Enum.map(organisations, fn organisation ->
      put_tenant(
        organisation,
        by_id[organisation.id] || %Tenant{organisation_id: organisation.id}
      )
    end)
  end

  @doc """
  ensure/1 is each of `organisations` carrying its tenant: those that carry one keep it,
  and the tenants of the others are read in one statement (`put/1`).
  """
  @spec ensure([%Organisation{}]) :: [%Organisation{}]
  def ensure(organisations) when is_list(organisations) do
    missing =
      organisations
      |> Enum.reject(&match?(%Organisation{edition: %{tenant: %Tenant{}}}, &1))
      |> put()
      |> Map.new(&{&1.id, &1})

    Enum.map(organisations, &Map.get(missing, &1.id, &1))
  end

  @doc "put_tenant/2 is `organisation` carrying `tenant`, read or written already."
  @spec put_tenant(%Organisation{}, Tenant.t()) :: %Organisation{}
  def put_tenant(%Organisation{edition: edition} = organisation, %Tenant{} = tenant),
    do: %{organisation | edition: Map.put(edition, :tenant, tenant)}

  @doc """
  new/1 is an organisation not inserted yet, of the kind `kind` and of no operator: what
  `organisation.create` is asked of before it exists (`ApiaryPro.Access`).
  """
  @spec new(kind) :: %Organisation{}
  def new(kind), do: put_tenant(%Organisation{}, %Tenant{kind: kind})

  @doc "kind/1 is the kind of `organisation`, as it carries its tenant (`tenant/1`)."
  @spec kind(%Organisation{}) :: kind
  def kind(%Organisation{} = organisation), do: tenant(organisation).kind

  @doc "operator?/1 says whether `organisation` is of the kind `:operator`."
  @spec operator?(term) :: boolean
  def operator?(%Organisation{} = organisation), do: kind(organisation) == :operator
  def operator?(_other), do: false

  @doc """
  instance_organisation?/1 says whether `organisation` is the instance organisation, whose
  owners are the instance admins, of either kind. False for anything but an organisation.
  """
  @spec instance_organisation?(term) :: boolean
  def instance_organisation?(%Organisation{} = organisation),
    do: tenant(organisation).instance_organisation == true

  def instance_organisation?(_other), do: false

  @doc "client?/1 says whether an organisation is a client of an operator."
  @spec client?(term) :: boolean
  def client?(%Organisation{} = organisation), do: is_binary(operator_id(organisation))
  def client?(_organisation), do: false

  @doc "operator_id/1 is the id of the operator of `organisation`, a client; nil for any other."
  @spec operator_id(%Organisation{}) :: Ecto.UUID.t() | nil
  def operator_id(%Organisation{} = organisation), do: tenant(organisation).operator_id

  @doc "operator_since/1 is since when `organisation` is its operator's client, or nil."
  @spec operator_since(%Organisation{}) :: DateTime.t() | nil
  def operator_since(%Organisation{} = organisation), do: tenant(organisation).operator_since

  # model_chain/1 is whose model providers the runs of `organisation` use, as it carries its
  # tenant: `:operator` for a client its operator lets work on the operator's, `:organisation`
  # for any other.
  @doc false
  @spec model_chain(%Organisation{}) :: Tenant.model_chain()
  def model_chain(%Organisation{} = organisation), do: tenant(organisation).model_chain

  # model_chain_of/1 is `model_chain/1` of the organisation `organisation_id`, read now with
  # one statement and no lock: `:operator` only for a client with that switch, `:organisation`
  # for any other, an organisation that is not there included.
  @doc false
  @spec model_chain_of(Ecto.UUID.t()) :: Tenant.model_chain()
  def model_chain_of(organisation_id) do
    Repo.one(
      from t in Tenant,
        where: t.organisation_id == ^organisation_id and not is_nil(t.operator_id),
        select: t.model_chain
    ) || :organisation
  end

  # operator_on_chain_of/1 is the operator of the organisation `organisation_id`, read now
  # with one statement and no lock, when it is a client whose switch is `:operator`
  # (`model_chain_of/1`); nil for any other, an organisation that is not there included.
  @doc false
  @spec operator_on_chain_of(Ecto.UUID.t()) :: Ecto.UUID.t() | nil
  def operator_on_chain_of(organisation_id) do
    Repo.one(
      from t in Tenant,
        where:
          t.organisation_id == ^organisation_id and not is_nil(t.operator_id) and
            t.model_chain == :operator,
        select: t.operator_id
    )
  end

  @doc """
  suspended?/1 says whether `organisation` is suspended (`ApiaryPro.Suspensions`), as it
  carries its tenant. False for anything but an organisation.
  """
  @spec suspended?(term) :: boolean
  def suspended?(%Organisation{} = organisation), do: not is_nil(suspended_at(organisation))
  def suspended?(_other), do: false

  @doc "suspended_at/1 is when `organisation` was suspended, or nil."
  @spec suspended_at(%Organisation{}) :: DateTime.t() | nil
  def suspended_at(%Organisation{} = organisation), do: tenant(organisation).suspended_at

  ## Reads

  @doc """
  lock_organisation/2 locks the row of the organisation `id` in `mode` (`"FOR SHARE"`,
  `"FOR NO KEY UPDATE"` or `"FOR UPDATE"`), then reads its tenant, in a separate statement
  once the lock is held, so a change of the tenant that took the organisation first is
  seen, and one after waits: the organisation carrying its tenant, or nil for one that is
  not there.
  """
  @spec lock_organisation(Ecto.UUID.t(), String.t()) :: %Organisation{} | nil
  def lock_organisation(id, "FOR SHARE"),
    do: locked(from(o in Organisation, where: o.id == ^id, lock: "FOR SHARE"))

  def lock_organisation(id, "FOR NO KEY UPDATE"),
    do: locked(from(o in Organisation, where: o.id == ^id, lock: "FOR NO KEY UPDATE"))

  def lock_organisation(id, "FOR UPDATE"),
    do: locked(from(o in Organisation, where: o.id == ^id, lock: "FOR UPDATE"))

  @doc """
  lock_organisations/2 locks the rows of the organisations `ids`, those still there,
  through `Apiary.Organisations.lock_organisations/2`: at a change's one point for its
  organisation rows, in the order of `Apiary.Organisations.lock_order/1`, in one
  statement, each in `mode` (`:key_share`, `:share`, `:no_key_update` or `:update`, or a
  function of an organisation's id that answers its mode). Then each of them is read,
  carrying its tenant, in a statement after the lock, so a change of the tenant that took
  the organisation first is seen (docs/access.md, The lock order).

  `{:ok, organisations}`, a map of the organisations locked by their ids;
  `{:error, :busy}` for a deadlock Postgres broke, once the core took the rows again, for
  a caller whose page says to try again. Any other error of the database is raised.
  """
  @spec lock_organisations([Ecto.UUID.t()], atom | (Ecto.UUID.t() -> atom)) ::
          {:ok, %{Ecto.UUID.t() => %Organisation{}}} | {:error, :busy}
  def lock_organisations(ids, mode) when is_list(ids) do
    case Apiary.Organisations.lock_organisations(Enum.uniq(ids), mode) do
      {:ok, held} ->
        {:ok,
         Repo.all(from o in Organisation, where: o.id in ^held) |> put() |> Map.new(&{&1.id, &1})}

      {:error, %Postgrex.Error{postgres: %{code: :deadlock_detected}}} ->
        {:error, :busy}

      {:error, exception} ->
        raise exception
    end
  end

  @doc """
  lock_organisations!/2 is `lock_organisations/2` for a caller with no answer that says to
  try again: the organisations locked, by their ids, and a deadlock raised as any other
  error of the database is.
  """
  @spec lock_organisations!([Ecto.UUID.t()], atom | (Ecto.UUID.t() -> atom)) ::
          %{Ecto.UUID.t() => %Organisation{}}
  def lock_organisations!(ids, mode) when is_list(ids) do
    case Apiary.Organisations.lock_organisations(Enum.uniq(ids), mode) do
      {:ok, held} ->
        Repo.all(from o in Organisation, where: o.id in ^held) |> put() |> Map.new(&{&1.id, &1})

      {:error, exception} ->
        raise exception
    end
  end

  defp locked(query) do
    case Repo.one(query) do
      nil -> nil
      organisation -> put(organisation)
    end
  end

  @doc """
  instance_organisation/0 is the instance organisation, carrying its tenant: the
  organisation the instance's first sign-up created, whose owners are the instance admins,
  of either kind; nil before that sign-up.
  """
  @spec instance_organisation() :: %Organisation{} | nil
  def instance_organisation do
    case Repo.one(
           from o in Organisation,
             join: t in Tenant,
             on: t.organisation_id == o.id,
             where: t.instance_organisation,
             select: {o, t}
         ) do
      {organisation, tenant} -> put_tenant(organisation, tenant)
      nil -> nil
    end
  end

  @doc """
  instance_organisation_id/0 is the id of the instance organisation, nil before the
  instance's first sign-up (`c:Apiary.Edition.instance_organisation_id/0`).
  """
  @spec instance_organisation_id() :: Ecto.UUID.t() | nil
  def instance_organisation_id,
    do: Repo.one(from t in Tenant, where: t.instance_organisation, select: t.organisation_id)

  ## People locks

  @doc """
  lock_rows/1 takes the edition's rows for a change (`c:Apiary.Edition.lock_rows/1`): people
  locks (`ApiaryPro.Tenants.PeopleLock`), all of a change's at its one point, once the
  core holds the organisation rows and before any workspace, membership or account, in
  the order of their ids and each in the strongest mode the change needs
  (`lock_people/1`). It never locks a membership or a row of the core's.

  - `{:places, scope}`, a write that must stay allowed for the scope's person: when the
    scope has a person and its organisation is a client, its operator's row
    `FOR SHARE`, so a change of the operator's people waits for the write, or came first
    and the write reads it. The operator is read under the client's row, which the core
    holds `FOR SHARE` and every change of a client's operator locks for update first. The
    rows do not depend on the scope's workspace: a repeat in the same change takes the
    same rows in the same mode.
  - `{:people, scope, organisation}`, a change of the organisation's people: the rows
    `{:places, scope}` takes for that scope, `FOR SHARE`, and the organisation's row
    `FOR UPDATE` when it is an operator, read under its row, which the core holds; all of
    them at once.
  - `{:account, user_id, organisation_ids}`, an account's deletion: the rows of exactly
    the organisations the core holds for it, `FOR UPDATE`. The account's memberships are
    not read again here: an organisation joined since the core read them is not held, and
    its row is not taken.

  `:ok`.
  """
  @spec lock_rows(Apiary.Edition.lock_about()) :: :ok
  def lock_rows({:places, scope}), do: lock_people(places_rows(scope))

  def lock_rows({:people, scope, %Organisation{id: id}}) do
    own = if operator_now?(id), do: [{id, :update}], else: []
    lock_people(places_rows(scope) ++ own)
  end

  def lock_rows({:account, _user_id, organisation_ids}) when is_list(organisation_ids),
    do: lock_people(organisation_ids, :update)

  # The rows a write that must stay allowed for the scope's person takes: its operator's,
  # when the scope's organisation is a client, read now.
  defp places_rows(%Scope{user: %User{}, organisation: %Organisation{id: id}})
       when is_binary(id) do
    case Repo.one(from t in Tenant, where: t.organisation_id == ^id, select: t.operator_id) do
      nil -> []
      operator_id -> [{operator_id, :share}]
    end
  end

  defp places_rows(_scope), do: []

  # Whether the organisation `id` is an operator, read now.
  defp operator_now?(id),
    do: Repo.exists?(from t in Tenant, where: t.organisation_id == ^id and t.kind == :operator)

  @doc """
  lock_people/2 locks the people locks (`ApiaryPro.Tenants.PeopleLock`) of the
  organisations `ids`, all in `mode`, `FOR SHARE` with `:share` and `FOR UPDATE` with
  `:update`, as `lock_people/1` does. `:ok`.
  """
  @spec lock_people([Ecto.UUID.t()], :share | :update) :: :ok
  def lock_people(ids, mode) when is_list(ids) and mode in [:share, :update],
    do: lock_people(Enum.map(ids, &{&1, mode}))

  @doc """
  lock_people/1 locks the people locks (`ApiaryPro.Tenants.PeopleLock`) of some
  organisations, each given with its mode, `:share` for `FOR SHARE` and `:update` for
  `FOR UPDATE`: each row once, in the stronger of the modes it is given in, and all of
  them in the order of their ids, so two transactions that lock some of the same rows
  take them in one order and never wait on each other in a cycle. The rows stay locked
  until the transaction it runs in ends.

  A tenant without its people lock, written by a node that ran before every tenant had
  one, gets it here first, the missing ones inserted in the order of their ids, then it
  is locked as the others are: a row is never passed over for being missing. The two
  passes are one point: whatever an insert waits for, another transaction's insert of
  the same row or its tenant's key, it waits for in the insert pass, before any row of
  the lock pass is held, and the rows that pass holds are new ones no other transaction
  can have locked. An organisation without a tenant has no row to lock: it is neither an operator
  nor a client, and no change takes its row. `:ok`.
  """
  @spec lock_people([{Ecto.UUID.t(), :share | :update}]) :: :ok
  def lock_people(rows) when is_list(rows) do
    rows =
      rows
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn {id, modes} -> {id, if(:update in modes, do: :update, else: :share)} end)
      |> Enum.sort()

    case rows do
      [] ->
        :ok

      rows ->
        :ok = insert_missing(Enum.map(rows, &elem(&1, 0)))

        rows
        |> Enum.chunk_by(&elem(&1, 1))
        |> Enum.each(fn [{_id, mode} | _] = run ->
          lock_run(Enum.map(run, &elem(&1, 0)), mode)
        end)
    end
  end

  # The people locks missing among the tenants of `ids`, inserted in the order of their
  # ids. One inserted meanwhile by another transaction is waited for and left as it is.
  defp insert_missing(ids) do
    missing =
      from t in Tenant,
        as: :tenant,
        where: t.organisation_id in ^ids,
        where:
          not exists(
            from p in PeopleLock,
              where: p.organisation_id == parent_as(:tenant).organisation_id
          ),
        order_by: [asc: t.organisation_id],
        select: %{
          organisation_id: t.organisation_id,
          inserted_at: type(^DateTime.utc_now(), :utc_datetime_usec)
        }

    {_count, _} =
      Repo.insert_all(PeopleLock, missing,
        on_conflict: :nothing,
        conflict_target: :organisation_id
      )

    :ok
  end

  # One run of rows of the same mode, already in order. Postgres sorts the rows before it
  # locks them, so they are locked in this order.
  defp lock_run(ids, mode) do
    query =
      from p in PeopleLock,
        where: p.organisation_id in ^ids,
        order_by: [asc: p.organisation_id],
        select: p.organisation_id

    _locked =
      case mode do
        :share -> Repo.all(lock(query, "FOR SHARE"))
        :update -> Repo.all(lock(query, "FOR UPDATE"))
      end

    :ok
  end

  ## Writes

  @doc """
  kind_changeset/2 changes the kind of the organisation of `tenant`: an organisation made
  an operator, or an operator made an organisation, the instance organisation as any
  other. The database refuses a client made an operator (the check) and an operator with
  clients made an organisation (the foreign key), each an error on `kind`.
  """
  @spec kind_changeset(Tenant.t(), kind) :: Ecto.Changeset.t()
  def kind_changeset(%Tenant{} = tenant, kind) when kind in @kinds do
    tenant
    |> change(kind: kind)
    |> check_constraint(:kind,
      name: :tenants_client_kind_check,
      message: dgettext_noop("errors", "cannot be an operator: it is a client of one")
    )
    |> foreign_key_constraint(:kind,
      name: :tenants_operator_fkey,
      message: dgettext_noop("errors", "cannot be an organisation while it has clients")
    )
  end

  @doc """
  operator_changeset/2 makes the organisation of `tenant` a client of `operator`, an
  organisation of the kind `:operator`, from now on (`operator_since`), or, with nil, a
  client of no operator. The foreign key and the check answer for an operator that is
  none, on `operator_id`, and a check for the instance organisation, which is no client.
  """
  @spec operator_changeset(Tenant.t(), %Organisation{} | nil) :: Ecto.Changeset.t()
  # With nil, `model_chain` is set back to `:organisation`.
  def operator_changeset(%Tenant{} = tenant, nil),
    do: change(tenant, operator_id: nil, operator_since: nil, model_chain: :organisation)

  def operator_changeset(%Tenant{} = tenant, %Organisation{id: operator_id}) do
    tenant
    |> change(kind: :organisation, operator_id: operator_id, operator_since: DateTime.utc_now())
    |> operator_constraints()
    |> check_constraint(:operator_id,
      name: :tenants_instance_organisation_not_client,
      message: dgettext_noop("errors", "cannot be changed: it is the instance owner")
    )
  end

  # model_chain_changeset/2 sets whose model providers the runs of the organisation of
  # `tenant` use, `:organisation` or `:operator`. The database refuses `:operator` for a
  # tenant with no operator, on `model_chain`.
  @doc false
  @spec model_chain_changeset(Tenant.t(), Tenant.model_chain()) :: Ecto.Changeset.t()
  def model_chain_changeset(%Tenant{} = tenant, chain) when chain in @model_chains do
    tenant
    |> change(model_chain: chain)
    |> check_constraint(:model_chain, name: :tenants_model_chain_operator_check)
  end

  @doc """
  suspension_changeset/3 suspends the organisation of `tenant` now, by `suspended_by_id`,
  with `:suspend`, or ends its suspension, with `:activate`. The database refuses the
  instance organisation's suspension, on `suspended_at`.
  """
  @spec suspension_changeset(Tenant.t(), :suspend | :activate, Ecto.UUID.t() | nil) ::
          Ecto.Changeset.t()
  def suspension_changeset(%Tenant{} = tenant, :suspend, suspended_by_id) do
    tenant
    |> change(suspended_at: DateTime.utc_now(), suspended_by_id: suspended_by_id)
    |> check_constraint(:suspended_at,
      name: :tenants_instance_organisation_not_suspended,
      message: dgettext_noop("errors", "cannot be changed: it is the instance owner")
    )
  end

  def suspension_changeset(%Tenant{} = tenant, :activate, _suspended_by_id),
    do: change(tenant, suspended_at: nil, suspended_by_id: nil)

  defp operator_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:operator_id,
      name: :tenants_operator_fkey,
      message: dgettext_noop("errors", "is not an operator")
    )
    |> check_constraint(:operator_id,
      name: :tenants_client_kind_check,
      message: dgettext_noop("errors", "is not an operator")
    )
  end

  ## Creation

  @doc """
  first_sign_up_kind/0 is the kind of the instance organisation the instance's first
  sign-up creates: `:operator` where the instance has `managed_organisations`, among the
  features it was started with (`QORY_FEATURES`, `Apiary.Features.on?/1`), so its owners
  may create clients from it at once; `:organisation` otherwise, an organisation like any
  other, with no Clients page. The instance admins may change it later
  (`ApiaryPro.Operators.change_kind/3`).
  """
  @spec first_sign_up_kind() :: kind
  def first_sign_up_kind,
    do: if(Apiary.Features.on?(:managed_organisations), do: :operator, else: :organisation)

  @doc """
  organisation_created/2 adds the edition's steps to the transaction that creates an organisation
  (`c:Apiary.Edition.organisation_created/2`): its tenant, what it is, and the features it
  is granted, so every organisation the instance creates has its tenant from its first
  transaction. `how`:

  - `:first_sign_up`, the instance's first sign-up: the instance organisation, flagged as
    the instance owner, of the kind `first_sign_up_kind/0` gives, whatever the sign-up
    asked;
  - `{:sign_up, extra}`, a later sign-up: the kind `extra["kind"]` asks for, when the
    instance's setting for it is open (`ApiaryPro.SignUp.kinds/0`), or the one kind open
    when it asks for none; refused on `kind` otherwise, `choose what to create` where two
    are open, and `is not open for sign-up on this instance` for a closed one;
  - `{:kind, kind}`, of `kind`, which the caller asked `Apiary.Access` for: a signed-in
    person's new organisation (`ApiaryPro.Organisations.create_organisation/2`), or one an
    instance admin creates (`ApiaryPro.Operators.create_organisation/2`);
  - `{:client, operator}`, a client of `operator` (`ApiaryPro.Operators.create_client/3`).

  The step `:tenant` is the new organisation carrying its tenant. A new operator that is
  not the instance organisation is granted what the instance has, and a client what its
  operator has (`ApiaryPro.Grants.written_out/3`); an organisation follows the instance,
  and the instance organisation has what the instance has, whatever its kind
  (`ApiaryPro.Features`). The organisation's entry records its kind, and whether it is the
  instance organisation or the operator of a client.
  """
  @spec organisation_created(Ecto.Multi.t(), term) :: Ecto.Multi.t()
  def organisation_created(multi, :first_sign_up) do
    multi
    |> Ecto.Multi.run(:kind, fn _repo, _changes -> {:ok, first_sign_up_kind()} end)
    |> insert_tenant(fn organisation, %{kind: kind} ->
      new_tenant(organisation, kind, instance_organisation: true)
    end)
    |> Ecto.Multi.run(:organisation_entry, fn _repo, %{tenant: organisation} ->
      {:ok, %{after: %{kind: kind(organisation)}, details: %{instance_organisation: true}}}
    end)
  end

  def organisation_created(multi, {:sign_up, extra}) when is_map(extra) do
    multi
    |> Ecto.Multi.run(:kind, fn _repo, _changes -> sign_up_kind(extra["kind"]) end)
    |> kind_steps()
  end

  def organisation_created(multi, {:kind, kind}) when kind in @kinds do
    multi
    |> Ecto.Multi.put(:kind, kind)
    |> kind_steps()
  end

  def organisation_created(multi, {:client, %Organisation{} = operator}) do
    multi
    |> insert_tenant(fn organisation, _changes -> new_client(organisation, operator) end)
    |> Ecto.Multi.run(:grants, fn _repo, %{tenant: client} ->
      Grants.written_out(client, {:client, operator})
    end)
    |> Ecto.Multi.put(:organisation_entry, %{
      after: %{kind: :organisation},
      details: %{operator_id: operator.id}
    })
  end

  # The kind the `:kind` step gives, and what it is granted: a new operator what the
  # instance has; an organisation follows the instance.
  defp kind_steps(multi) do
    multi
    |> insert_tenant(fn organisation, %{kind: kind} -> new_tenant(organisation, kind, []) end)
    |> Ecto.Multi.run(:grants, fn _repo, %{tenant: organisation} ->
      if operator?(organisation),
        do: Grants.written_out(organisation, :operator),
        else: {:ok, nil}
    end)
    |> Ecto.Multi.run(:organisation_entry, fn _repo, %{tenant: organisation} ->
      {:ok, %{after: %{kind: kind(organisation)}, details: %{instance_organisation: false}}}
    end)
  end

  # The step `:tenant`: the tenant `changeset_fun` gives the new organisation, of the
  # changes so far, inserted, and its people lock beside it (`PeopleLock`); the
  # organisation carrying its tenant.
  defp insert_tenant(multi, changeset_fun) do
    Ecto.Multi.run(multi, :tenant, fn repo, %{organisation: organisation} = changes ->
      with {:ok, tenant} <- repo.insert(changeset_fun.(organisation, changes)),
           {:ok, _people_lock} <-
             repo.insert(%PeopleLock{organisation_id: tenant.organisation_id}) do
        {:ok, put_tenant(organisation, tenant)}
      end
    end)
  end

  # A new organisation's tenant: of `kind`, and with `instance_organisation: true` the
  # instance organisation. The unique index answers for a second instance organisation.
  defp new_tenant(%Organisation{id: id}, kind, opts) do
    %Tenant{organisation_id: id}
    |> change(
      kind: kind,
      instance_organisation: Keyword.get(opts, :instance_organisation, false)
    )
    |> unique_constraint(:instance_organisation,
      name: :tenants_one_instance_organisation_index,
      message: dgettext_noop("errors", "could not be signed up just now; please try again")
    )
  end

  # A new client's tenant, of `operator`, from now on.
  defp new_client(%Organisation{id: id}, %Organisation{id: operator_id}) do
    %Tenant{organisation_id: id}
    |> change(kind: :organisation, operator_id: operator_id, operator_since: DateTime.utc_now())
    |> operator_constraints()
  end

  # The kind a later sign-up creates, of those the instance's settings open, read inside
  # its transaction.
  defp sign_up_kind(requested) do
    open = SignUp.kinds()
    kind = Enum.find(@kinds, &(Atom.to_string(&1) == requested))

    cond do
      not is_nil(kind) and kind in open -> {:ok, kind}
      requested in [nil, ""] and length(open) == 1 -> {:ok, hd(open)}
      match?([_, _ | _], open) -> {:error, {:kind, SignUp.choose_what_to_create()}}
      true -> {:error, {:kind, SignUp.not_open()}}
    end
  end
end
