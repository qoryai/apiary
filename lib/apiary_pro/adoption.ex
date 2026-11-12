defmodule ApiaryPro.Adoption do
  @moduledoc """
  Adoption gives each organisation of an instance upgraded from a release without
  tenants, such as Qory Apiary 0.1.0, its tenant and its workspace access: `run/0`, the
  edition's step after the migrations (`c:Apiary.Edition.after_migrate/0`), which
  `Apiary.Release.migrate/1` runs at boot and from `bin/migrate`. Upgrading is swapping
  the image and restarting. An instance goes back by deploying the previous image; the
  tables the upgrade added stay in place.

  - **A tenant for every organisation.** The edition reads what it knows of an
    organisation from its tenant (`ApiaryPro.Tenants.Tenant`), which it writes when it
    creates one. Every organisation without a tenant gets one of the kind `organisation`,
    with no operator and not suspended: what it was in the core; and its people lock
    beside it (`ApiaryPro.Tenants.PeopleLock`), as every tenant has.
  - **The instance organisation.** While no tenant is the instance organisation, the
    organisation the release before held as the instance owner, the oldest in use, which
    `c:Apiary.Edition.instance_organisation_id/0` returns in the core, becomes it, and
    keeps the kind `organisation`, as every organisation adopted does: its owners ran the
    instance before, and stay its instance admins. Adopting never makes it an operator;
    an instance admin may, where the instance has
    `managed_organisations` (`ApiaryPro.Operators.change_kind/3`). An instance with an
    instance organisation keeps it.
  - **What a member reached.** Before, every membership reached every workspace of its
    organisation; here a member reaches the workspaces they were added to
    (`ApiaryPro.WorkspaceAccess`). So each membership at `member` of an organisation
    adopted by this run is added to each workspace of it, and nobody loses what they
    reached. An organisation adopted before keeps its workspace access as it is: access
    taken away on purpose stays away.
  - **The trail.** Each organisation adopted gets one entry, `instance.adopt`, by the
    instance, in the organisation's trail: its kind, whether it is the instance organisation,
    and how many rows of workspace access it gave; so does the instance organisation made
    so when it had its tenant already.

  `run/0` is idempotent: a second run finds a tenant for every organisation and an
  instance organisation, and changes nothing. It runs in one transaction, under an
  advisory lock, so two nodes that boot at once adopt once, the second finding everything
  done. The rows of the organisations it adopts, and of the organisation it makes the
  instance organisation, whose flag is no key, are locked `FOR NO KEY UPDATE` at one
  point, in one pass in the lock order (`Apiary.Organisations.lock_order/1`), so their
  tenants are written under their rows' locks as every tenant is (`ApiaryPro.Tenants`,
  Locks), and a change that holds some of them waits, or is waited for, without a cycle.
  """

  import Ecto.Query, warn: false

  alias Apiary.{Audit, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Membership, Organisation, Workspace}
  alias ApiaryPro.Tenants
  alias ApiaryPro.Tenants.{PeopleLock, Tenant}
  alias ApiaryPro.WorkspaceAccess.Row

  # Rows an insert writes at once, well under what one statement may carry.
  @chunk 1_000

  @doc """
  run/0 adopts every organisation without a tenant, and makes the organisation the core
  holds as the instance owner the instance organisation while there is none, in
  one transaction under an advisory lock (the moduledoc). `:ok`, whatever it found to do;
  raises should the database refuse, which stops the boot, as a migration that fails does.
  """
  @spec run() :: :ok
  def run do
    {:ok, _adopted} =
      Repo.transact(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended('apiary:adoption', 0))")

        {read, claiming} = read_organisations()
        {:ok, adopt(read, claiming)}
      end)

    :ok
  end

  # The organisations without a tenant and, with no instance organisation, the one the
  # core's edition holds as its instance organisation, read without a lock: those
  # organisations, and the id of the one to make the instance organisation, or nil.
  defp read_organisations do
    claiming =
      unless Repo.exists?(from t in Tenant, where: t.instance_organisation),
        do: Apiary.Edition.Core.instance_organisation_id()

    read =
      Repo.all(
        from o in Organisation,
          as: :organisation,
          left_join: t in Tenant,
          on: t.organisation_id == o.id,
          where: is_nil(t.organisation_id) or o.id in ^List.wrap(claiming),
          select: o
      )

    {read, claiming}
  end

  @doc false
  # The rest of `run/0` after its read, in its transaction, for a test that changes what
  # the read found before the rows are locked. The organisations `read` locked
  # `FOR NO KEY UPDATE` at one point, in one statement, in the order of
  # `Apiary.Organisations.lock_order/1` (`ApiaryPro.Tenants.lock_organisations!/2`); an
  # organisation without a tenant is no client, and holds no other. Then those of them
  # without a tenant, read again under the lock, since another node may have written one
  # since the read, adopted; `claiming` made the instance organisation, if it is held; and
  # the workspace access and the entries of what was adopted. The ids adopted, in order.
  @spec adopt([%Organisation{}], Ecto.UUID.t() | nil) :: [Ecto.UUID.t()]
  def adopt(read, claiming) do
    held = read |> Enum.map(& &1.id) |> Tenants.lock_organisations!(:no_key_update) |> Map.keys()
    adopted = held |> without_tenant() |> adopt_organisations()
    instance_organisation = claim_instance_organisation(if claiming in held, do: claiming)
    access = grant_workspaces(adopted)
    :ok = record(adopted, instance_organisation, access)
    adopted
  end

  # Those of the organisations `ids` without a tenant, read under their locks, which every
  # write of a tenant takes first: their ids, in order.
  defp without_tenant(ids) do
    Repo.all(
      from o in Organisation,
        as: :organisation,
        where: o.id in ^ids,
        where:
          not exists(from t in Tenant, where: t.organisation_id == parent_as(:organisation).id),
        order_by: [asc: o.id],
        select: o.id
    )
  end

  # The organisations without a tenant, their rows locked, each given a tenant of the kind
  # `organisation` and its people lock beside it: their ids, in order.
  defp adopt_organisations(ids) do
    now = DateTime.utc_now()

    ids
    |> Enum.chunk_every(@chunk)
    |> Enum.each(fn chunk ->
      Repo.insert_all(
        Tenant,
        for id <- chunk do
          %{
            organisation_id: id,
            kind: :organisation,
            instance_organisation: false,
            inserted_at: now,
            updated_at: now
          }
        end,
        on_conflict: :nothing
      )

      Repo.insert_all(
        PeopleLock,
        for(id <- chunk, do: %{organisation_id: id, inserted_at: now}),
        on_conflict: :nothing
      )
    end)

    ids
  end

  # With no instance organisation, the organisation the core's edition holds as its
  # instance organisation made the edition's instance organisation, of the kind it has, its row
  # locked `FOR NO KEY UPDATE` with the rest (`adopt/2`), as a change of a tenant that is
  # no key locks it: its id, or nil when there is one already, or no organisation, or the
  # one named is a client or suspended, which the edition never made it (the database
  # would refuse).
  defp claim_instance_organisation(nil), do: nil

  defp claim_instance_organisation(id) do
    case Repo.update_all(
           from(t in Tenant,
             where: t.organisation_id == ^id,
             where: is_nil(t.operator_id) and is_nil(t.suspended_at)
           ),
           set: [instance_organisation: true, updated_at: DateTime.utc_now()]
         ) do
      {1, _} -> id
      _none -> nil
    end
  end

  # Each membership at `member` of an organisation adopted now, added to each workspace of
  # its organisation, marked for deletion or not, since restoring one gives it back as it
  # was: how many rows each organisation got.
  defp grant_workspaces([]), do: %{}

  defp grant_workspaces(adopted) do
    now = DateTime.utc_now()

    rows =
      Repo.all(
        from m in Membership,
          join: w in Workspace,
          on: w.organisation_id == m.organisation_id,
          where: m.organisation_id in ^adopted and m.level == :member,
          order_by: [asc: m.organisation_id, asc: w.id, asc: m.user_id],
          select: %{organisation_id: m.organisation_id, workspace_id: w.id, user_id: m.user_id}
      )

    rows
    |> Enum.chunk_every(@chunk)
    |> Enum.each(fn chunk ->
      Repo.insert_all(
        Row,
        Enum.map(chunk, &Map.merge(&1, %{id: Ecto.UUID.generate(), inserted_at: now})),
        on_conflict: :nothing
      )
    end)

    Enum.frequencies_by(rows, & &1.organisation_id)
  end

  # One entry for each organisation adopted, by the instance, in that organisation's
  # trail, with the kind its tenant has; and one for the instance organisation made so,
  # should it have had its tenant already.
  defp record(adopted, instance_organisation, access) do
    (adopted ++ List.wrap(instance_organisation))
    |> Enum.uniq()
    |> Enum.chunk_every(@chunk)
    |> Enum.flat_map(
      &Repo.all(
        from o in Organisation,
          join: t in Tenant,
          on: t.organisation_id == o.id,
          where: o.id in ^&1,
          order_by: o.id,
          select: {o, t.kind}
      )
    )
    |> Enum.reduce_while(:ok, fn {organisation, kind}, :ok ->
      instance_organisation? = organisation.id == instance_organisation

      case Audit.record(
             Repo,
             Scope.for_instance(organisation),
             :"instance.adopt",
             organisation,
             %{
               after: %{kind: kind},
               details: %{
                 instance_organisation: instance_organisation?,
                 workspace_access: Map.get(access, organisation.id, 0)
               }
             }
           ) do
        {:ok, _entry} -> {:cont, :ok}
        {:error, _changeset} = error -> {:halt, error}
      end
    end)
  end
end
