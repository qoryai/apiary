defmodule Apiary.Deletion do
  @moduledoc """
  Deleting a workspace or an organisation: marked first, purged after a grace period.

  ## Marked

  An owner or an admin deletes a workspace of the organisation (`delete_workspace/3`), an
  owner the organisation itself (`delete_organisation/2`), typing its slug to confirm.
  That only marks it: `deletion_marked_at`, `deletion_marked_by_id`, `purge_trigger` and
  `purge_after`, the grace period of `grace_days/0` from now. From then it is gone from
  every page, menu and switcher, its URLs answer not found
  (`Apiary.Organisations.resolve_scope/4`), its access keys are refused as a revoked key
  is (`Apiary.AccessKeys.fetch_for_verification/1`), its invitations accept no one, and
  `Apiary.Access` answers not found to anything asked of it, a page opened before the
  marking included, but cancelling the deletion and the purge. Nothing is removed yet.
  The organisation's last workspace in use is not deleted on its own,
  `{:error, :last_workspace}`: the organisation is. A workspace's members stay in the
  organisation; their access to the workspace goes with it, when it is purged.

  During the grace period the organisation's owners and admins see a marked workspace on
  the organisation's settings (`list_marked_workspaces/1`), its owners a marked
  organisation on their organisations page (`list_marked_organisations/1`), and cancel
  it (`restore_workspace/2`, `restore_organisation/2`), which brings everything back as
  it was, the access keys included. Once the grace period is over, or a purge has
  claimed it, a deletion can no longer be cancelled, `{:error, :purge_started}`.

  ## Purged

  A daily sweep (`Apiary.Deletion.PurgeSweep`) enqueues one purge job for every marked
  organisation and every marked workspace, of an organisation in use, whose grace period
  is over (`Apiary.Deletion.PurgeOrganisationJob`, `Apiary.Deletion.PurgeWorkspaceJob`),
  as the instance. A purge first claims its row, `purge_started_at`, in one statement
  that finds it still marked and past its grace period by the database's clock; a
  cancelling finds it unclaimed and in its grace period under the same row's lock, so of
  the two exactly one happens, and never half of each. It then deletes every row with the
  organisation key, table by table in the order of `Apiary.Deletion.Tables`, a batch at a
  time, each batch in its own short transaction, and then, in one transaction, the
  workspace's or the organisation's own row:

  - **A workspace** leaves an entry in its organisation's trail, `workspace.purge`, as
    its marking and its cancelling do (`workspace.delete`, `workspace.restore`); all
    three are the organisation's entries, with no workspace, so they outlive it.
  - **An organisation** takes its audit trail with it, and leaves one line at the
    instance (`Apiary.Deletion.PurgedOrganisation`): its id, when it was marked and by
    whom, when it was purged, and why. It is written in the transaction that deletes the
    organisation's row.

  A purge is safe to run twice, and to stop half way: the rows it deleted are gone, and
  the next run deletes the rest; one whose workspace or organisation is gone already has
  nothing left to do. `purge_now/3` purges an organisation at once, for an erasure
  request the instance received, and records who asked and why on the organisation's
  row, which the instance's line keeps, whichever run finishes the purge; an edition's
  own path to it takes the same steps
  (`lock_for_erasure/1`, `mark_for_erasure/2`, `purge_marked/2`).

  ## The edition's part

  The edition may refuse a deletion or a purge (`c:Apiary.Edition.deletion_refusal/2`),
  asked on the row locked for it, after the core's own refusals: the core's own edition
  refuses the instance's organisation, whose owners run the instance,
  `{:error, :instance_organisation}`. It is told of each marking, cancelling and purge in
  the transaction that makes it (`c:Apiary.Edition.deletion_changed/4`), and may name
  people beyond the organisation's members who hear of it once it commits.

  Backups taken before a purge still hold what it deleted until they expire; the
  instance's backup period bounds that, and the operations guide says so.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Apiary.{Access, AccessKeys, Audit, Organisations, Repo}
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Deletion.{PurgedOrganisation, Tables}
  alias Apiary.Organisations.{Membership, Organisation, Workspace}

  @default_grace_days 30
  @grace_min 1
  @grace_max 90
  @batch 2_000

  @typedoc """
  Why a deletion or a cancelling is refused: `Apiary.Access`'s answer, the core's own
  reasons, or the edition's (`c:Apiary.Edition.deletion_refusal/2`), such as
  `:instance_organisation`.
  """
  @type refusal ::
          Access.reason()
          | :confirmation
          | :last_workspace
          | :purge_started
          | :instance_organisation
          | atom

  ## Marking

  @doc """
  delete_workspace/3 marks a workspace of the scope's organisation for deletion
  (`workspace.delete`, an owner's or an admin's, asked of the organisation), when
  `confirmation` is its slug, and records it in the organisation's trail. `{:ok,
  workspace}`, marked; `{:error, reason}`: `:not_found` for a workspace the organisation
  does not hold in use, `:confirmation` for a confirmation that is not its slug,
  `:last_workspace` for the organisation's last workspace in use, the edition's refusal,
  and `Apiary.Access`'s answer.

  The people who reach the workspace are told (`Apiary.Organisations.membership_topic/1`),
  so their open pages leave it.
  """
  @spec delete_workspace(Scope.t(), String.t(), String.t() | nil) ::
          {:ok, %Workspace{}} | {:error, refusal}
  def delete_workspace(
        %Scope{organisation: %Organisation{id: organisation_id} = organisation} = scope,
        workspace_id,
        confirmation
      ) do
    Repo.transact(fn ->
      with :ok <- Access.authorize(scope, :"workspace.delete", organisation),
           {:ok, id} <- cast(workspace_id),
           # Every workspace of the organisation in use, locked: two deleting its last
           # two at once cannot both see the other left, and a write that holds a
           # workspace, such as the policy's, is done before its workspace is marked.
           workspaces = lock_workspaces(organisation_id),
           %Workspace{} = workspace <- Enum.find(workspaces, &(&1.id == id)) || not_found(),
           :ok <- confirm(workspace.slug, confirmation),
           :ok <- ensure_another_workspace(workspaces, workspace),
           :ok <- refuse(:delete, workspace),
           {:ok, marked} <- workspace |> mark_changeset(scope) |> Repo.update(),
           {:ok, _entry} <-
             Audit.record(
               Repo,
               scope,
               :"workspace.delete",
               marked,
               %{details: %{purge_after: marked.purge_after}},
               place: :organisation
             ),
           {:ok, told} <- changed(:marked, marked, scope) do
        {:ok, {marked, told}}
      end
    end)
    |> announce()
  end

  @doc """
  restore_workspace/2 cancels the deletion of a workspace of the scope's organisation
  (`workspace.restore`, an owner's or an admin's, asked of the organisation) while its
  grace period lasts and no purge has claimed it, and records it in the organisation's
  trail: the workspace, the access to it and its access keys are back as they were.
  `{:ok, workspace}`; `{:error, :not_found}` for a workspace that is not marked,
  `{:error, :purge_started}` once its grace period is over or a purge claimed it.
  """
  @spec restore_workspace(Scope.t(), String.t()) :: {:ok, %Workspace{}} | {:error, refusal}
  def restore_workspace(
        %Scope{organisation: %Organisation{id: organisation_id} = organisation} = scope,
        workspace_id
      ) do
    Repo.transact(fn ->
      with :ok <- Access.authorize(scope, :"workspace.restore", organisation),
           {:ok, id} <- cast(workspace_id),
           {:ok, workspace} <- lock_restorable(Workspace, id, organisation_id),
           {:ok, restored} <- workspace |> restore_changeset() |> Repo.update(),
           {:ok, _entry} <-
             Audit.record(
               Repo,
               scope,
               :"workspace.restore",
               restored,
               %{details: %{marked_at: workspace.deletion_marked_at}},
               place: :organisation
             ),
           {:ok, told} <- changed(:restored, restored, scope) do
        {:ok, {restored, told}}
      end
    end)
    |> announce()
  end

  @doc """
  delete_organisation/2 marks the scope's organisation, and so everything in it, for
  deletion (`organisation.delete`, an owner's), when `confirmation` is its slug, and
  records it in its trail. `{:ok, organisation}`, marked; `{:error, :confirmation}` for a
  confirmation that is not its slug, `{:error, :not_found}` for one marked already, the
  edition's refusal, and `Apiary.Access`'s answer. Every member is told, so their open
  pages leave it, and so is anyone the edition names.
  """
  @spec delete_organisation(Scope.t(), String.t() | nil) ::
          {:ok, %Organisation{}} | {:error, refusal}
  def delete_organisation(
        %Scope{organisation: %Organisation{id: id} = organisation} = scope,
        confirmation
      ) do
    Repo.transact(fn ->
      with :ok <- Access.authorize(scope, :"organisation.delete", organisation),
           %Organisation{} = organisation <-
             Repo.one(
               from o in Organisation,
                 where: o.id == ^id and is_nil(o.deletion_marked_at),
                 lock: "FOR NO KEY UPDATE"
             ) || not_found(),
           :ok <- confirm(organisation.slug, confirmation),
           :ok <- refuse(:delete, organisation),
           {:ok, marked} <- organisation |> mark_changeset(scope) |> Repo.update(),
           {:ok, _entry} <-
             Audit.record(Repo, scope, :"organisation.delete", marked, %{
               details: %{purge_after: marked.purge_after}
             }),
           {:ok, told} <- changed(:marked, marked, scope) do
        {:ok, {marked, told}}
      end
    end)
    |> announce()
  end

  @doc """
  restore_organisation/2 cancels the deletion of an organisation, by its id, for a person
  who is one of its owners (`organisation.restore`), while its grace period lasts and no
  purge has claimed it, and records it in its trail: the organisation is back as it was,
  its workspaces, members and access keys with it. A workspace marked on its own stays
  marked. `{:ok, organisation}`; `{:error, :not_found}` for an organisation the person is
  not a member of or that is not marked, `{:error, :purge_started}` once its grace period
  is over or a purge claimed it, and `Apiary.Access`'s answer.
  """
  @spec restore_organisation(Scope.t(), String.t()) ::
          {:ok, %Organisation{}} | {:error, refusal}
  def restore_organisation(%Scope{user: %User{}} = scope, organisation_id) do
    with {:ok, id} <- cast(organisation_id),
         {:ok, scope} <- marked_scope(scope, id) do
      Repo.transact(fn ->
        with :ok <- Access.authorize(scope, :"organisation.restore", scope.organisation),
             {:ok, organisation} <- lock_restorable(Organisation, id, id),
             {:ok, restored} <- organisation |> restore_changeset() |> Repo.update(),
             {:ok, _entry} <-
               Audit.record(Repo, scope, :"organisation.restore", restored, %{
                 details: %{marked_at: organisation.deletion_marked_at}
               }),
             {:ok, told} <- changed(:restored, restored, scope) do
          {:ok, {restored, told}}
        end
      end)
      |> announce()
    end
  end

  def restore_organisation(_scope, _organisation_id), do: {:error, :not_found}

  # The marked row, locked, while it may still be restored: unclaimed by a purge and in
  # its grace period, by the database's clock. A purge's claim waits for this lock, and
  # then finds the row restored; one that came first is seen, and the deletion stands.
  defp lock_restorable(schema, id, organisation_id) do
    query =
      from r in schema,
        where: r.id == ^id and not is_nil(r.deletion_marked_at),
        where:
          is_nil(r.purge_started_at) and
            r.purge_after > fragment("(clock_timestamp() AT TIME ZONE 'UTC')"),
        lock: "FOR NO KEY UPDATE"

    case Repo.one(in_organisation(query, schema, organisation_id)) do
      # Marked but no longer restorable: its purge claimed it, or its grace period is
      # over. Asked of the organisation's own rows only, so a workspace of another
      # organisation is not found, as it is when it may be restored.
      nil ->
        marked? =
          from(r in schema, where: r.id == ^id and not is_nil(r.deletion_marked_at))
          |> in_organisation(schema, organisation_id)
          |> Repo.exists?()

        if marked?, do: {:error, :purge_started}, else: not_found()

      row ->
        {:ok, row}
    end
  end

  defp in_organisation(query, Workspace, organisation_id),
    do: where(query, [w], w.organisation_id == ^organisation_id)

  defp in_organisation(query, _schema, _organisation_id), do: query

  # The person's scope in an organisation marked for deletion, as they reach it
  # (`Apiary.Organisations.put_reach/2`), which no page's path reaches while it is marked:
  # the organisation, and no workspace, since cancelling is the organisation's.
  defp marked_scope(%Scope{} = scope, organisation_id) do
    query =
      from o in Organisation,
        where: o.id == ^organisation_id and not is_nil(o.deletion_marked_at)

    with %Organisation{} = organisation <- Repo.one(query) || not_found(),
         {:ok, scope} <- Organisations.put_reach(scope, organisation) do
      {:ok, scope}
    else
      :error -> not_found()
      {:error, _reason} = error -> error
    end
  end

  ## What is pending

  @doc """
  list_marked_workspaces/1 is the workspaces of the scope's organisation marked for
  deletion, the soonest purged first, for the organisation's settings to show to its
  owners and admins, who may cancel them.
  """
  @spec list_marked_workspaces(Scope.t()) :: [%Workspace{}]
  def list_marked_workspaces(%Scope{organisation: %Organisation{id: organisation_id}}) do
    Repo.all(
      from w in Workspace,
        where: w.organisation_id == ^organisation_id and not is_nil(w.deletion_marked_at),
        order_by: [asc: w.purge_after, asc: w.id]
    )
  end

  @doc """
  list_marked_organisations/1 is the organisations marked for deletion that the scope's
  person may restore (`organisation.restore`, an owner's), the
  soonest purged first, for their organisations page: the one place a marked organisation
  still shows.
  """
  @spec list_marked_organisations(Scope.t()) :: [%Organisation{}]
  def list_marked_organisations(%Scope{user: %User{id: user_id}} = scope) do
    member_of = from m in Membership, where: m.user_id == ^user_id, select: m.organisation_id

    Repo.all(
      from o in Organisation,
        where: not is_nil(o.deletion_marked_at),
        where: o.id in subquery(member_of),
        order_by: [asc: o.purge_after, asc: o.id]
    )
    |> Enum.filter(fn organisation ->
      case Organisations.put_reach(scope, organisation) do
        {:ok, scope} -> Access.can?(scope, :"organisation.restore", organisation)
        :error -> false
      end
    end)
  end

  def list_marked_organisations(_scope), do: []

  ## Purging

  @doc """
  purge_workspace/1 purges the scope's workspace, marked for deletion and past its grace
  period (`workspace.purge`, the instance's): it claims the workspace first, so its
  deletion can no longer be cancelled, then deletes every row of it, table by table in
  the order of `Apiary.Deletion.Tables.workspace_tables/0`, a batch at a time, the access
  to it among them and nobody's membership, after the public keys of its nodes' access
  keys are made tombstones in the ledger, which outlives it
  (`Apiary.AccessKeys.retire_public_keys/2`), then the workspace's row, with the entry of
  `workspace.purge` in its organisation's trail in the same transaction. `{:ok,
  :purged}`; `{:ok, :not_due}`, touching nothing, for a workspace that is not marked
  (restored meanwhile) or not yet due; `{:ok, :gone}` for one that is gone already; the
  edition's refusal, touching nothing (`c:Apiary.Edition.deletion_refusal/2`). Safe to
  run again after it stopped half way.
  """
  @spec purge_workspace(Scope.t()) :: {:ok, :purged | :not_due | :gone} | {:error, term}
  def purge_workspace(
        %Scope{
          organisation: %Organisation{id: organisation_id},
          workspace: %Workspace{id: workspace_id} = workspace
        } = scope
      ) do
    with :ok <- Access.authorize(scope, :"workspace.purge", workspace),
         :ok <- refuse(:purge, workspace),
         :claimed <- claim(Workspace, workspace_id) do
      _retired = AccessKeys.retire_public_keys(organisation_id, workspace_id)
      deleted = delete_rows(Tables.workspace_tables(), organisation_id, workspace_id)

      Repo.transact(fn ->
        case lock_claimed(Workspace, workspace_id) do
          %Workspace{} = claimed ->
            with {:ok, told} <- changed(:purged, claimed, scope),
                 {:ok, _deleted} <- Repo.delete(claimed),
                 {:ok, _entry} <-
                   Audit.record(
                     Repo,
                     scope,
                     :"workspace.purge",
                     claimed,
                     %{
                       details: %{
                         marked_at: claimed.deletion_marked_at,
                         marked_by_id: claimed.deletion_marked_by_id,
                         requested_by_id: claimed.purge_requested_by_id,
                         trigger: claimed.purge_trigger,
                         rows: deleted
                       }
                     },
                     place: :organisation
                   ) do
              {:ok, {:purged, told}}
            end

          nil ->
            {:ok, {:gone, []}}
        end
      end)
      |> tell()
      |> log_purge("workspace", deleted)
    else
      outcome when outcome in [:gone, :not_due] -> {:ok, outcome}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  purge_organisation/1 purges the scope's organisation, marked for deletion and past its
  grace period (`organisation.purge`, the instance's): it claims the organisation first,
  so its deletion can no longer be cancelled, then deletes every row of it, table by
  table in the order of `Apiary.Deletion.Tables.tables/0`, a batch at a time, its
  workspaces and its audit trail among them, after the public keys of its nodes' access
  keys are made tombstones in the ledger, then the organisation's row, with the instance's line of
  it (`Apiary.Deletion.PurgedOrganisation`) written in the same transaction from what the
  row says: when it was marked, by whom, and why. `{:ok, :purged}`; `{:ok, :not_due}`,
  touching nothing, for an organisation not marked or not yet due; `{:ok, :gone}` for one
  that is gone already; the edition's refusal, touching nothing, for one it never lets go
  (`c:Apiary.Edition.deletion_refusal/2`), which nothing marks. Safe to run again after it
  stopped half way.
  """
  @spec purge_organisation(Scope.t()) :: {:ok, :purged | :not_due | :gone} | {:error, term}
  def purge_organisation(%Scope{organisation: %Organisation{id: id} = organisation} = scope) do
    with :ok <- Access.authorize(scope, :"organisation.purge", organisation),
         :ok <- refuse(:purge, organisation),
         :claimed <- claim(Organisation, id) do
      _retired = AccessKeys.retire_public_keys(id, nil)
      deleted = delete_rows(Tables.tables(), id, nil)

      Repo.transact(fn ->
        case lock_claimed(Organisation, id) do
          %Organisation{} = claimed ->
            line = %PurgedOrganisation{
              id: claimed.id,
              marked_at: claimed.deletion_marked_at,
              marked_by_id: claimed.deletion_marked_by_id,
              requested_by_id: claimed.purge_requested_by_id,
              purged_at: DateTime.utc_now(),
              trigger: claimed.purge_trigger
            }

            with {:ok, _line} <- Repo.insert(line, on_conflict: :nothing),
                 {:ok, told} <- changed(:purged, claimed, scope),
                 {:ok, _deleted} <- Repo.delete(claimed) do
              {:ok, {:purged, told}}
            end

          nil ->
            {:ok, {:gone, []}}
        end
      end)
      |> tell()
      |> log_purge("organisation", deleted)
    else
      outcome when outcome in [:gone, :not_due] -> {:ok, outcome}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  purge_now/3 purges `organisation` at once, for an erasure request the instance
  received: under the organisation's lock it is marked for erasure (`mark_for_erasure/2`),
  its grace period ending now, so no owner can cancel it any more, with why,
  `erasure_request`, and who asked, `requested_by`, the account of the instance admin who
  asked, or nil. Then it is purged as `purge_organisation/1` does (`purge_marked/2`);
  should that stop half way, the daily sweep finishes it, and the instance's line still
  says it was an erasure request. `origin` is where the request came from, for the trail
  it is recorded in until the purge. As the instance; an edition's release command is its
  caller. Refused, touching nothing, with the edition's refusal
  (`c:Apiary.Edition.deletion_refusal/2`), read under the row's lock: the instance's own
  organisation is never marked nor purged.
  """
  @spec purge_now(%Organisation{}, %User{} | nil, Scope.origin()) ::
          {:ok, :purged | :not_due | :gone} | {:error, refusal | term}
  def purge_now(%Organisation{} = organisation, requested_by \\ nil, origin \\ nil) do
    marked =
      Repo.transact(fn ->
        with {:ok, locked} <- lock_for_erasure(organisation.id),
             :ok <- mark_for_erasure(locked, requested_by),
             do: {:ok, locked}
      end)

    case marked do
      {:ok, _locked} -> purge_marked(organisation, origin)
      # Gone already: the purge that finished it says so.
      {:error, :not_found} -> purge_marked(organisation, origin)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  lock_for_erasure/1 locks the row of the organisation `organisation_id`, as a marking
  locks it, inside the caller's transaction, for `mark_for_erasure/2`: `{:ok,
  organisation}` as the row is now, or `{:error, :not_found}` once it is gone.
  """
  @spec lock_for_erasure(Ecto.UUID.t()) :: {:ok, %Organisation{}} | {:error, :not_found}
  def lock_for_erasure(organisation_id) do
    case Repo.one(
           from o in Organisation, where: o.id == ^organisation_id, lock: "FOR NO KEY UPDATE"
         ) do
      %Organisation{} = organisation -> {:ok, organisation}
      nil -> not_found()
    end
  end

  @doc """
  mark_for_erasure/2 marks `organisation`, whose row `lock_for_erasure/1` locked in the
  same transaction, for an erasure request: marked when it is not marked yet, its grace
  period ended now by the database's clock, with why, `erasure_request`, and who asked,
  `requested_by` or nil, beside who marked it, which stays as it was. `:ok`; the edition's
  refusal (`c:Apiary.Edition.deletion_refusal/2`) touches nothing. The edition hears of
  it with the purge that follows (`purge_marked/2`), not before.
  """
  @spec mark_for_erasure(%Organisation{}, %User{} | nil) :: :ok | {:error, refusal}
  def mark_for_erasure(%Organisation{id: id} = organisation, requested_by) do
    by = requested_by && requested_by.id

    with :ok <- refuse(:purge, organisation) do
      {_count, _} =
        Repo.update_all(
          from(o in Organisation,
            where: o.id == ^id,
            update: [
              set: [
                deletion_marked_at:
                  fragment(
                    "COALESCE(?, (clock_timestamp() AT TIME ZONE 'UTC'))",
                    o.deletion_marked_at
                  ),
                purge_requested_by_id: type(^by, :binary_id),
                purge_after: fragment("(clock_timestamp() AT TIME ZONE 'UTC')"),
                purge_trigger: "erasure_request"
              ]
            ]
          ),
          []
        )

      :ok
    end
  end

  @doc """
  purge_marked/2 purges `organisation`, marked for erasure (`mark_for_erasure/2`) and so
  due now, as `purge_organisation/1` does, as the instance, from `origin`.
  """
  @spec purge_marked(%Organisation{}, Scope.origin()) ::
          {:ok, :purged | :not_due | :gone} | {:error, term}
  def purge_marked(%Organisation{} = organisation, origin) do
    organisation
    |> Scope.for_instance()
    |> Scope.put_origin(origin)
    |> purge_organisation()
  end

  @doc """
  One page of the ids of the organisations marked for deletion whose grace period is
  over, in the order of their ids, as `Apiary.Organisations.page_organisation_ids/2`
  pages the organisations in use: for the purge sweep. Never one the edition refuses to
  purge (`c:Apiary.Edition.deletion_refusal/2`), which nothing marks, even marked behind
  the product's back; a page holds `limit` ids all the same, unless it is the last.
  """
  @spec page_organisations_due(Organisations.page_cursor(), pos_integer()) ::
          {[Ecto.UUID.t()], Organisations.page_cursor()}
  def page_organisations_due(cursor, limit), do: page_organisations_due(cursor, limit, [])

  defp page_organisations_due(cursor, limit, kept) do
    {rows, next} =
      from(o in Organisation,
        where: not is_nil(o.deletion_marked_at),
        where: o.purge_after <= fragment("(clock_timestamp() AT TIME ZONE 'UTC')"),
        select: {o.id, o}
      )
      |> page(cursor, limit)

    kept = kept ++ Enum.filter(rows, &is_nil(Apiary.Edition.deletion_refusal(:purge, &1)))

    cond do
      length(kept) >= limit ->
        kept = Enum.take(kept, limit)
        {Enum.map(kept, & &1.id), List.last(kept).id}

      length(rows) < limit ->
        {Enum.map(kept, & &1.id), next}

      true ->
        page_organisations_due(next, limit, kept)
    end
  end

  @doc """
  One page of the organisation and workspace ids of the workspaces marked for deletion
  whose grace period is over, of organisations that are not marked themselves (whose
  purge takes their workspaces), in the order of the workspaces' ids: for the purge
  sweep.
  """
  @spec page_workspaces_due(Organisations.page_cursor(), pos_integer()) ::
          {[{Ecto.UUID.t(), Ecto.UUID.t()}], Organisations.page_cursor()}
  def page_workspaces_due(cursor, limit) do
    from(w in Workspace,
      join: o in assoc(w, :organisation),
      where: not is_nil(w.deletion_marked_at),
      where: w.purge_after <= fragment("(clock_timestamp() AT TIME ZONE 'UTC')"),
      where: is_nil(o.deletion_marked_at),
      select: {w.id, {w.organisation_id, w.id}}
    )
    |> page(cursor, limit)
  end

  defp page(query, cursor, limit) do
    query = if cursor, do: where(query, [r], r.id > ^cursor), else: query
    rows = query |> order_by([r], asc: r.id) |> limit(^limit) |> Repo.all()

    case List.last(rows) do
      nil -> {[], cursor}
      {id, _ids} -> {Enum.map(rows, &elem(&1, 1)), id}
    end
  end

  # The purge's claim on the row: one statement that finds it still marked and past its
  # grace period by the database's clock, and sets `purge_started_at`, the first time. A
  # cancelling that holds the row's lock is waited for, and then the row is found restored.
  # A retry finds its own claim, and goes on.
  defp claim(schema, id) do
    {count, _} =
      Repo.update_all(
        from(r in schema,
          where: r.id == ^id and not is_nil(r.deletion_marked_at),
          where: r.purge_after <= fragment("(clock_timestamp() AT TIME ZONE 'UTC')"),
          update: [
            set: [
              purge_started_at:
                fragment(
                  "COALESCE(?, (clock_timestamp() AT TIME ZONE 'UTC'))",
                  r.purge_started_at
                )
            ]
          ]
        ),
        []
      )

    cond do
      count == 1 -> :claimed
      Repo.exists?(from r in schema, where: r.id == ^id) -> :not_due
      true -> :gone
    end
  end

  # `FOR UPDATE`: the row is deleted next, which takes that lock anyway; a change still
  # holding its key share, one that asked `Apiary.Access` before the marking, is waited for.
  defp lock_claimed(schema, id) do
    Repo.one(
      from r in schema,
        where: r.id == ^id and not is_nil(r.purge_started_at),
        lock: "FOR UPDATE"
    )
  end

  # Every row of the organisation key, table by table in delete order, a batch at a time: each
  # batch one statement in its own transaction, so no lock is held for longer than a
  # batch, and a purge stopped half way goes on where it stopped. Returns the rows deleted
  # by table, for the log and the workspace's entry. A batch names its rows by their place
  # in the table (`ctid`), which every table has whatever its key, an edition's among
  # them, and which Postgres reads straight to.
  defp delete_rows(tables, organisation_id, workspace_id) do
    for table <- tables, into: %{} do
      {table, delete_table(table, organisation_id, workspace_id, 0)}
    end
  end

  defp delete_table(table, organisation_id, workspace_id, deleted) do
    rows =
      from(r in table,
        where: r.organisation_id == type(^organisation_id, :binary_id),
        select: fragment("ctid"),
        limit: @batch
      )

    rows =
      if workspace_id,
        do: where(rows, [r], r.workspace_id == type(^workspace_id, :binary_id)),
        else: rows

    {count, _} = Repo.delete_all(from(r in table, where: fragment("ctid") in subquery(rows)))

    if count < @batch,
      do: deleted + count,
      else: delete_table(table, organisation_id, workspace_id, deleted + count)
  end

  # The ids only, as every line: the log names no organisation or workspace by its name.
  defp log_purge({:ok, :purged} = result, kind, deleted) do
    Logger.info(
      "#{kind} purged rows=#{deleted |> Map.values() |> Enum.sum()} " <>
        Enum.map_join(Enum.reject(deleted, &(elem(&1, 1) == 0)), " ", fn {table, n} ->
          "#{table}=#{n}"
        end)
    )

    result
  end

  defp log_purge(result, _kind, _deleted), do: result

  ## The grace period

  @doc """
  grace_days/0 is how many days a workspace or an organisation marked for deletion is
  kept before it is purged: `DELETION_GRACE_DAYS`, checked at boot (`boot!/0`),
  #{@default_grace_days} when unset.
  """
  @spec grace_days() :: pos_integer
  def grace_days do
    case Application.fetch_env(:apiary, :deletion_grace_days) do
      {:ok, days} -> days
      :error -> boot!()
    end
  end

  @doc """
  parse_grace_days/1 reads a value of `DELETION_GRACE_DAYS`: `{:ok, days}`, a whole number
  of days from #{@grace_min} to #{@grace_max}, or #{@default_grace_days} for nil or a
  blank value; `{:error, reason}` otherwise. Not 0, since a deletion must be restorable;
  not more than #{@grace_max}, since an organisation that leaves is owed its deletion.
  """
  @spec parse_grace_days(String.t() | nil) :: {:ok, pos_integer} | {:error, String.t()}
  def parse_grace_days(nil), do: {:ok, @default_grace_days}

  def parse_grace_days(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:ok, @default_grace_days}

      trimmed ->
        case Integer.parse(trimmed) do
          {days, ""} when days >= @grace_min and days <= @grace_max ->
            {:ok, days}

          _other ->
            {:error,
             "it is a number of days from #{@grace_min} to #{@grace_max}, got: #{inspect(trimmed)}"}
        end
    end
  end

  @doc """
  boot!/0 reads `DELETION_GRACE_DAYS` as `config/runtime.exs` left it, checks it and fixes
  the grace period for the life of the node; it returns it. Called at boot; raises on a
  value `parse_grace_days/1` refuses, so the instance does not start.
  """
  @spec boot!() :: pos_integer
  def boot! do
    case parse_grace_days(Application.get_env(:apiary, :deletion_grace_setting)) do
      {:ok, days} ->
        Application.put_env(:apiary, :deletion_grace_days, days)
        days

      {:error, reason} ->
        raise ArgumentError, """
        environment variable DELETION_GRACE_DAYS is not valid: #{reason}.
        Leave it unset for #{@default_grace_days} days, or set it, for example:
        DELETION_GRACE_DAYS=14
        """
    end
  end

  ## Helpers

  @doc """
  mark_changeset/2 is the change that marks `row`, a workspace or an organisation, for
  deletion by `scope`'s person (nil for the instance), its grace period of `grace_days/0`
  from now: for an edition's own path to a marking, which asks `Apiary.Access` and records
  it as the core's do.
  """
  @spec mark_changeset(%Workspace{} | %Organisation{}, Scope.t()) :: Ecto.Changeset.t()
  def mark_changeset(row, %Scope{} = scope) do
    now = DateTime.utc_now()

    Ecto.Changeset.change(row,
      deletion_marked_at: now,
      deletion_marked_by_id: scope.user && scope.user.id,
      purge_after: DateTime.add(now, grace_days() * 86_400, :second),
      purge_trigger: "grace_period",
      purge_requested_by_id: nil,
      purge_started_at: nil
    )
  end

  defp restore_changeset(row) do
    Ecto.Changeset.change(row,
      deletion_marked_at: nil,
      deletion_marked_by_id: nil,
      purge_after: nil,
      purge_trigger: nil,
      purge_requested_by_id: nil,
      purge_started_at: nil
    )
  end

  defp confirm(slug, confirmation) when is_binary(confirmation) do
    if String.trim(confirmation) == slug, do: :ok, else: {:error, :confirmation}
  end

  defp confirm(_slug, _confirmation), do: {:error, :confirmation}

  # Every workspace of the organisation in use, locked, in the order of their ids. `FOR NO
  # KEY UPDATE`: marking changes no key, and the lock needs only to exclude another marking
  # and a policy write, which hold the same.
  defp lock_workspaces(organisation_id) do
    Repo.all(
      from w in Workspace,
        where: w.organisation_id == ^organisation_id and is_nil(w.deletion_marked_at),
        order_by: [asc: w.id],
        lock: "FOR NO KEY UPDATE"
    )
  end

  defp ensure_another_workspace(workspaces, %Workspace{id: id}) do
    if Enum.any?(workspaces, &(&1.id != id)), do: :ok, else: {:error, :last_workspace}
  end

  # An id as a page writes it; `Ecto.UUID.cast/1` would take any sixteen bytes for one.
  defp cast(id) when is_binary(id) and byte_size(id) == 36 do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> not_found()
    end
  end

  defp cast(_id), do: not_found()

  defp not_found, do: {:error, :not_found}

  # What the edition says of the deletion: nil, or its refusal.
  defp refuse(what, subject) do
    case Apiary.Edition.deletion_refusal(what, subject) do
      nil -> :ok
      reason when is_atom(reason) -> {:error, reason}
    end
  end

  # The edition told of a change, inside its transaction: `{:ok, memberships}`, the people
  # beyond the organisation's members it names to hear of it once it commits.
  defp changed(event, subject, scope) do
    case Apiary.Edition.deletion_changed(Repo, event, subject, scope) do
      :ok -> {:ok, []}
      {:ok, told} when is_list(told) -> {:ok, told}
      {:error, _reason} = error -> error
    end
  end

  # Everyone who reaches the workspace or the organisation hears of it once the change
  # commits: every member of the organisation, whose open pages load their scope again and
  # leave what they may no longer see, and whoever the edition named.
  defp announce({:ok, {%{organisation_id: organisation_id} = row, told}}),
    do: announce_organisation(organisation_id, row, told)

  defp announce({:ok, {%Organisation{id: id} = row, told}}),
    do: announce_organisation(id, row, told)

  defp announce(result), do: result

  defp announce_organisation(organisation_id, row, told) do
    members = Repo.all(from m in Membership, where: m.organisation_id == ^organisation_id)
    Organisations.broadcast_membership_changes(members ++ told)
    {:ok, row}
  end

  # A purge's outcome, once it commits: whoever the edition named hears of it.
  defp tell({:ok, {outcome, told}}) do
    Organisations.broadcast_membership_changes(told)
    {:ok, outcome}
  end

  defp tell(result), do: result
end
