defmodule Apiary.Environments do
  @moduledoc false

  # The environment records of the collections (`Apiary.Environments.Record`), one per
  # node pool and collection: what the last prebuild of a collection's target built for a
  # pool, for which `environment_ref`, and how its last build failed.
  #
  # The reads here serve the paths that queue, record and use a build: they ask nothing
  # of `Apiary.Access`, and whoever answers a person with them asks it first. A person's
  # Rebuild (`rebuild/2`) and what a target's page says (`section/2`) ask it themselves.
  #
  # ## A run held for its build: `holds?/1`, `held/1`, `hold_builds/3`, `queue_builds/2`
  #
  # A pool builds a collection's `environment_ref` when a run needs it, and never ahead
  # of one: a listing, an assign and a new node pool queue no build. A build pushes its
  # image to the instance's registry, so an instance without one
  # (`Apiary.Registry.configured?/0`) holds no run, its claims queue no build, and a
  # Rebuild there answers `{:error, :not_found}`: the rules here that ask whether a domain
  # has prebuilds (`holds?/1`) read no, and the runs start in the pool's default image.
  # A target's page shows that, with no Rebuild (`section/2`, `:no_registry`). A claim
  # there takes no prebuild
  # (`Apiary.Dispatches.waiting_query/1`). In a workspace whose
  # domain has prebuilds (`holds?/1`, `Apiary.Lingo.Domain.prebuilds?/1`), a waiting run
  # that is not a prebuild, of a work item whose target a live collection of the
  # workspace with an `environment_ref` has, is held for a node pool while no record of
  # such a collection for that pool keeps an image whose `built_ref` is its collection's
  # `environment_ref`, built for the target (`held/1`, a subquery on the run as
  # `:run`). A claim of the pool takes no held run (`Apiary.Dispatches.claim/3`); a run
  # whose target no collection names, or of a workspace whose domain has no prebuilds, is
  # never held and starts in the pool's default image. On an instance with the feature
  # `security`, a run whose target's run configuration in force names an image in its
  # `security_policy` is never held either (`unset_by_policy/1`): it starts in that
  # image, so it needs no build, queues none and ends with no build's failure.
  #
  # Whenever a run is held and no prebuild of its collection's `environment_ref` for the
  # pool waits, is claimed or is handed over, the pool's next claim queues one: before it
  # locks the pool's row, `hold_builds(workspace_id, pool_id, now)` reads those
  # collections without a lock, with the collections of the pool's prebuilds whose
  # dispatch lapsed at `now`, whose prebuilds its free writes, and holds their
  # connections `FOR SHARE`, by id, then all of them `FOR SHARE`, by id, in one
  # statement (`Apiary.Dispatches.Slots`). After the pool's row, its free locks the
  # records of the pool's lapsed prebuilds, then `make_records(collections, pool)`
  # inserts the missing records of those collections a build is due for on the pool,
  # with no live prebuild of their ref for it, by collection, before the free locks any
  # run, as a Rebuild locks records and then inserts the missing ones. After the free,
  # `queue_builds(collections, pool)` checks again and queues a prebuild of each for the
  # collection's `environment_ref` (`Apiary.Dispatches.queue_prebuild/3`, whose record then
  # exists, so the claim inserts no record after runs). So a key change while runs wait is
  # built by the next claim of each pool, and the claim ends a waiting prebuild of the old ref
  # `superseded` when it takes it. A listing's part holds its connection `FOR UPDATE`, then
  # its collections `FOR UPDATE`, to change their `environment_ref`: the part and the claim
  # take turns at the connection, and whichever comes second waits there holding no row the
  # first needs. The instance's pool (`workspace_id` nil) does the same for the runs of
  # every workspace it serves, those with no pool in use, and its prebuilds and records
  # are in their collection's workspace.
  # The claim locks no existing record for the build it queues: its check of the live
  # prebuilds and the pool's row, which a free of lapsed leases of the pool also holds,
  # keep it from queuing beside one that waits again; every other path that queues a
  # prebuild holds the record `FOR UPDATE` first, and the index of the waiting prebuilds,
  # one per collection, pool and `environment_ref`, takes what is left.
  #
  # `claim_image(pool, work_item)` is what a claim gives an explore run it takes:
  # `{:ok, image}` for the image `image_for/3` reads in the work item's workspace, `{:ok, nil}` for the pool's default
  # where nothing holds the run, and `:held` where a build that landed or a key that
  # changed after the claim's read holds it again: the claim then leaves it waiting.
  # `Apiary.Dispatches.Handover` writes the image on the registered run
  # (`configured_image`), which its attach gives the run (`Apiary.Runs.Attach`).
  #
  # ## A build given back: `lock_record/2`
  #
  # `lock_record(pool_id, collection_id)` locks the record of a prebuild's pool and
  # collection `FOR UPDATE`, inside the caller's transaction: a starter's release of the
  # prebuild holds it before the free of its run and before its run of the queue, as a
  # free of lapsed leases holds it (`Apiary.Dispatches.Release`, `Apiary.Dispatches.Slots`).
  # A release records no failure: a starter releases a prebuild only before its handover,
  # and the prebuild waits again. A record whose `failure_cause` is `released` was written
  # before that rule.
  #
  # ## A build ended: `hold_build/2`, `record_end_failure/3` and `build_failed/6`
  #
  # The end of a prebuild after its handover (`Apiary.Dispatches.RunEnd`) first calls
  # `hold_build(pool_id, collection_id)`: the connections of the live collections of the
  # prebuild's target that name an `environment_ref` `FOR SHARE`, by id, then those
  # collections `FOR SHARE`, by id, as a Rebuild holds them; then the work items in Explore of
  # the workspace with that target and a waiting run, read without a lock, `FOR KEY SHARE`, by
  # id; then the record `FOR UPDATE` (`lock_record/2`), before the run of the queue.
  #
  # `record_end_failure(record, cause, now)` records the last build as failed, with `now`
  # and no reason: `lost` when the prebuild's gateway never attached it by its run key's
  # `attach_by`, `timed_out` when it had no exit by its backstop, and, when its exit ends
  # it, `failed` for a `failed` exit and `lost` for a `lost` one. The last good build is
  # left as it was. A prebuild whose ref is older than the image's, or that made the
  # image, records nothing (`newer_build?/2`, `built_by?/2`).
  #
  # `build_failed(record, dispatch_run, cause, collections, work_item_ids, now)` then
  # acts on the runs held for the build, only while the prebuild's `environment_ref` is
  # still its collection's. The first loss of that ref, `lost` with a `lost_ref` that is
  # not the ref, on a live pool, sets `lost_ref` and queues one more prebuild of the ref
  # for the pool. A failure (`failed`, or `timed_out`: a build past its backstop), a
  # second loss, or a loss on a deleted pool clears `lost_ref`; then, unless a live pool
  # keeps an image of the target from its collection's `environment_ref`, the waiting runs
  # of those work items, held for the target, end `build_failed` with the outcome `error`
  # (`Apiary.Dispatches.end_held/4`). A prebuild of another pool, in any state, keeps no
  # run held: its starter can be offline, or its pool deleted. A run that comes to wait
  # later is held again, and the next claim of each pool queues its build.
  #
  # ## A run's image: `image_for/2`
  #
  # `image_for(pool, target)` is the image a run of `pool` for `target` starts in: of the
  # live collections assigned to the pool's workspace with that target and an
  # `environment_ref`, and of their records for the pool built for that target
  # (`built_target_system`, `built_target_path`) whose `built_ref` is the collection's
  # `environment_ref`, the one built last (`built_at`) gives its `image`; nil when there
  # is none, and nil when that image is not under the organisation's place in the
  # registry, `<QORY_REGISTRY>/<instance>/<organisation>/` (`Apiary.Registry.Names`): a
  # build's image is checked against the place its prebuild was sent
  # (`Apiary.Dispatches.Built`), and an image stored before that check may be elsewhere.
  # Such an image still counts as built for `held/1`, so a claim gives its run the pool's
  # default.
  #
  # ## A build recorded: `record_build/4`
  #
  # `record_build(dispatch_run, build, built_target, now)` records the build of a prebuild
  # on the record of its pool and collection, which the caller locked first
  # (`lock_record/2`): `image`, `size`, `commit`, `reported_ref`, the `environment_ref`
  # the job reported, kept as it is, `built_ref`, the `environment_ref` the prebuild was
  # queued for, `built_at`, `now`, the built target (`built_target_system`,
  # `built_target_path`), the registered run's target, and `built_queued_at`, when the
  # run took the `environment_ref` it built (`environment_ref_at`). The last failure and
  # `lost_ref` are cleared; nothing is queued. A record that is missing is made with the
  # build. The image serves a run only through `built_ref`: the reported ref is stored as
  # the job reports it, with no check.
  #
  # ## A build whose ref is older than the image's: `newer_build?/2`
  #
  # `newer_build?(record, dispatch_run)` is whether the image `record` keeps was made by a
  # prebuild that took its `environment_ref` after `dispatch_run` took its
  # (`built_queued_at` later than the run's `environment_ref_at`), asked under the record's
  # lock: an older build never replaces a newer one. Then neither a build nor a failure
  # of `dispatch_run` is written on the record, and the run ends as it would otherwise. A
  # record that is missing, or keeps no `built_queued_at`, is never newer.
  #
  # `built_by?(record, dispatch_run)` is whether the image `record` keeps was made by
  # `dispatch_run`: its `built_queued_at` is the run's `environment_ref_at`. The end of
  # that prebuild by a `failed` or `lost` exit then records no failure, so its build
  # stays the last good one in either order of its report and its exit
  # (`Apiary.Dispatches.RunEnd`), and a second report of it writes nothing
  # (`Apiary.Dispatches.Built`).
  #
  # ## An image missing: `hold_missing/3`, `lock_missing/3` and `forget_image/3`
  #
  # A run that is not a prebuild, started in the image its pool's record gave it
  # (`runs.configured_image`), whose exit is `failed` with the reason `image_missing`:
  # the registry has no such image. The end of its run of the queue
  # (`Apiary.Dispatches.RunEnd`) first calls `hold_missing(pool_id, target, image)`: the
  # collections of the records of the pool that claimed the run whose image is that
  # image, built for the run's target, read without a lock, held `FOR SHARE`, by id,
  # after their connections, `FOR SHARE`, by id, as a Rebuild holds them. It then locks
  # its work item `FOR UPDATE`, then calls `lock_missing(pool_id, target, image)`: those
  # records `FOR UPDATE`, by collection, before the run of the queue.
  # `forget_image(records, collections, now)` then clears the build of each record,
  # `image`, `size`, `commit`, `built_at`, `reported_ref`, `built_ref`, the built target
  # and `built_queued_at`, so `image_for/2` gives that image to no run; the last failure
  # is left as it is. The prebuild that made the image does not store it again: a
  # projection stores a run's build only in the pass that folds its report of the lowest
  # sequence, and a rebuild of the run's projection stores none
  # (`Apiary.Runs.Projector`). For each record whose collection is one of `collections`,
  # live, assigned to the pool's workspace, whose domain has prebuilds, with a target and
  # an `environment_ref`, and whose pool is live, it queues a prebuild of the
  # collection's `environment_ref` for the pool, unless one of that ref waits: the next
  # build makes the image again. A record whose collection is not one of
  # `collections`, its build landed after `hold_missing/3` read the records, is cleared
  # and queues nothing: the next claim of the pool queues its build for a run held for
  # it. The end then queues the next run of the take in with the attempt total raised by
  # one (`Apiary.Dispatches.requeue_for_image/1`), held for that build, unless the run
  # that ended came from such a requeue.
  #
  # ## A member's Rebuild: `rebuild/2`
  #
  # `rebuild(scope, target)` is the Rebuild of a target's page
  # (`target.rebuild_environment`, asked of the target's workspace): for each live
  # collection assigned to the target's workspace with the target's system and path and an
  # `environment_ref`, and each live node pool of that workspace, it queues a prebuild of
  # the collection's `environment_ref` held for the pool, changed or not, making the
  # record when there is none. A pool whose prebuild of that ref waits unclaimed is left
  # as it is. Before the records, it locks the connections of the collections
  # `FOR SHARE`, by id, then the collections `FOR SHARE`, by id, in the order a Backlog
  # switch holds them (`Apiary.Adapters.Collections`); then their records `FOR UPDATE`,
  # by collection and then pool, in one statement; then it queues the prebuilds: the
  # order of `Apiary.Dispatches.Slots`, connections before collections before records
  # before runs. So a listing's part, which holds its connection `FOR UPDATE` and then
  # its collections, and a Rebuild take turns: a part that changes a collection's
  # `environment_ref` either commits first, and the Rebuild reads the collection as it
  # left it, or waits for the Rebuild to commit, and the next claim of each pool then
  # queues the new ref's build for a run held for it. One audit entry about the target,
  # with how many prebuilds it queued, and none when it queued none. It answers
  # `{:ok, count}`, `Apiary.Access`'s refusal, or `{:error, :not_found}` for a target that
  # names no environment in its workspace, whose workspace has no node pool, or whose
  # workspace's domain has no prebuilds.
  #
  # ## What a target's page says: `section/2`
  #
  # `section(scope, target)` is the environment of a target of the scope's workspace, to a
  # person who may read the workspace's work items (`work_item.read`, the feature
  # `factory`'s), in a workspace whose domain has prebuilds, nil for anyone else and in
  # any other workspace: `state`, `:no_pool` where the workspace has no live
  # node pool, `:no_environment` where no live collection assigned to the workspace with the
  # target names an `environment_ref`, no pool's record of one keeps an image, and no prebuild
  # of one waits, is claimed or is handed over, `:no_registry` where one of those
  # collections names an `environment_ref` on an instance without a registry
  # (`Apiary.Registry.configured?/0`), with no pool lines: no build runs there and the
  # target's runs start in the pool's default image; else `:pools`; `named`, whether one of those
  # collections names an `environment_ref`; and `pools`, one line for each live pool of the
  # workspace, by id. Where the run configuration in force for the target names an image in
  # its `security_policy` (`Apiary.Policy.ComposedConfiguration.names_image?/1`), on an
  # instance with the feature `security`, every pool's `serves` is `:policy`, with no image.
  # Else, where the target names an environment, a pool's line gives the image a run of the
  # target on the pool is given (`image_for/2`): the newest record of those collections for
  # the pool built for the target whose `built_ref` is its collection's `environment_ref`,
  # with its image, `built_at` and `commit`, and `serves` `:image`; where that record's
  # image is outside the organisation's place in the registry (`own?/2`), `serves`
  # `:default`, with no image, as the run starts in the pool's default; where there is none,
  # `serves` is `:held`, as the target's runs wait for that build (`held/1`), with no image,
  # whatever older image a record keeps. Where the target names none, `serves` is `:retired`
  # where a record of the pool keeps an image, else `:default`. `failure` is the cause of the
  # last failure those records keep, where it failed after the newest build any of them keeps,
  # nil for none; `running` and `waiting` are whether a prebuild of those collections, held
  # for the pool, is claimed or handed over, and waits unclaimed.

  import Ecto.Query, only: [dynamic: 2, from: 2]

  alias Apiary.{Access, Audit, Dispatches, Features, InstanceConfig, Policy, Registry, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Collection, Connection}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Environments.Record
  alias Apiary.Lingo.Domain
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Workspace
  alias Apiary.Policy.{ComposedConfiguration, RunConfiguration}
  alias Apiary.Registry.Names
  alias Apiary.Runs.Target
  alias Apiary.WorkItems.WorkItem

  # fetch/2 is the record of the pool `pool_id` and the collection `collection_id`, or nil.
  @doc false
  @spec fetch(Ecto.UUID.t(), Ecto.UUID.t()) :: Record.t() | nil
  def fetch(pool_id, collection_id) when is_binary(pool_id) and is_binary(collection_id),
    do: Repo.get_by(Record, pool_id: pool_id, source_collection_id: collection_id)

  # for_collection/1 is every record of the collection `collection_id`, of any pool and
  # workspace, the oldest first.
  @doc false
  @spec for_collection(Ecto.UUID.t()) :: [Record.t()]
  def for_collection(collection_id) when is_binary(collection_id) do
    Repo.all(
      from r in Record,
        where: r.source_collection_id == ^collection_id,
        order_by: [asc: r.inserted_at, asc: r.id]
    )
  end

  ## A build given back

  # lock_record/2 locks the record of the pool `pool_id` and the collection
  # `collection_id` `FOR UPDATE`, inside the caller's transaction: the record, or nil.
  @doc false
  @spec lock_record(Ecto.UUID.t(), Ecto.UUID.t()) :: Record.t() | nil
  def lock_record(pool_id, collection_id) when is_binary(pool_id) and is_binary(collection_id) do
    in_transaction!("lock_record/2")

    Repo.one(
      from r in Record,
        where: r.pool_id == ^pool_id and r.source_collection_id == ^collection_id,
        lock: "FOR UPDATE"
    )
  end

  # hold_build/2 holds, inside the caller's transaction, what the end of a prebuild of the
  # node pool `pool_id` and the collection `collection_id` holds before its run of the
  # queue (the moduledoc): the connections of the target's collections `FOR SHARE`, then
  # those collections `FOR SHARE`, by id (`hold_named/1`); then the work items in Explore
  # with the collection's target and a waiting run, in its workspace, read without a lock,
  # `FOR KEY SHARE`, by id; then the record `FOR UPDATE` (`lock_record/2`):
  # `{:build, record, collections, work_item_ids}`. A collection with no workspace or no
  # target holds its record alone.
  @doc false
  @spec hold_build(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:build, Record.t() | nil, [Collection.t()], [Ecto.UUID.t()]}
  def hold_build(pool_id, collection_id) when is_binary(pool_id) and is_binary(collection_id) do
    in_transaction!("hold_build/2")

    case Repo.get(Collection, collection_id) do
      %Collection{workspace_id: workspace_id, target_system: system, target_path: path} =
          collection
      when is_binary(workspace_id) and is_binary(system) and is_binary(path) ->
        collections =
          hold_named(%Target{
            organisation_id: collection.organisation_id,
            workspace_id: workspace_id,
            system: system,
            path: path
          })

        waiting =
          from r in DispatchRun,
            where: r.work_item_id == parent_as(:work_item).id,
            where: r.step != ^DispatchRun.prebuild() and fragment("? = 'waiting'", r.state),
            select: 1

        work_item_ids =
          Repo.all(
            from w in WorkItem,
              as: :work_item,
              where: w.workspace_id == ^workspace_id and w.state == :exploring,
              where: w.target_system == ^system and w.target_path == ^path,
              where: exists(waiting),
              select: w.id
          )

        locked =
          Repo.all(
            from w in WorkItem,
              where: w.id in ^work_item_ids,
              order_by: w.id,
              lock: "FOR KEY SHARE",
              select: w.id
          )

        {:build, lock_record(pool_id, collection_id), collections, locked}

      _no_workspace_or_target ->
        {:build, lock_record(pool_id, collection_id), [], []}
    end
  end

  # build_failed/5 applies the end of the prebuild `dispatch_run`, whose last build
  # `record_end_failure/3` recorded as failed by `failure`, to the runs held for its
  # build, inside the caller's transaction, under what `hold_build/2` held: `collections`
  # and the work items `work_item_ids` (the moduledoc). The first loss (`:lost`) of an
  # `environment_ref` that is still its collection's queues one more prebuild of it for
  # the pool; a failure (`:failed` or `:timed_out`), a second loss, or a loss on a
  # deleted pool ends the waiting runs held for the target `build_failed`, unless a live
  # pool has an image for the target from its collection's `environment_ref`. A prebuild
  # of another pool, in any state, keeps no run held. What changed, for
  # `Apiary.Dispatches.broadcast/1`.
  @doc false
  @spec build_failed(
          Record.t(),
          DispatchRun.t(),
          :lost | :timed_out | :failed,
          [Collection.t()],
          [Ecto.UUID.t()],
          DateTime.t()
        ) :: [Ecto.UUID.t() | tuple]
  def build_failed(
        %Record{} = record,
        %DispatchRun{environment_ref: ref} = dispatch_run,
        failure,
        collections,
        work_item_ids,
        %DateTime{} = now
      ) do
    in_transaction!("build_failed/6")
    pool = Repo.get(Node, record.pool_id)

    case Enum.find(collections, &(&1.id == dispatch_run.source_collection_id)) do
      %Collection{environment_ref: ^ref} = collection ->
        if failure == :lost and record.lost_ref != ref and
             match?(%Node{kind: :pool, deleted_at: nil}, pool) do
          {1, _rows} =
            Repo.update_all(from(r in Record, where: r.id == ^record.id),
              set: [lost_ref: ref, updated_at: now]
            )

          {:ok, run} = Dispatches.queue_prebuild(collection, pool, ref)
          [run.workspace_id]
        else
          {_count, _rows} =
            Repo.update_all(
              from(r in Record, where: r.id == ^record.id and not is_nil(r.lost_ref)),
              set: [lost_ref: nil, updated_at: now]
            )

          end_held(collection, work_item_ids, now)
        end

      _no_longer_its_ref ->
        []
    end
  end

  # The waiting runs held for the target of `collection` end `build_failed`, unless a
  # live pool of its workspace has an image for the target from its collection's
  # `environment_ref`, which a claim of that pool gives them.
  defp end_held(%Collection{} = collection, work_item_ids, now) do
    target = %{system: collection.target_system, path: collection.target_path}

    served? =
      Repo.exists?(
        from [r, c] in served(collection.workspace_id, target.system, target.path),
          join: n in Node,
          on: n.id == r.pool_id and n.kind == :pool and is_nil(n.deleted_at),
          where: r.built_ref == c.environment_ref
      )

    if served?,
      do: [],
      else: Dispatches.end_held(work_item_ids, collection.workspace_id, target, now)
  end

  # record_end_failure/3 records the last build of `record`, locked by `lock_record/2`,
  # as failed by the end of its prebuild, `cause` (`:lost`, `:timed_out` or `:failed`), at
  # `now`, inside the caller's transaction (the moduledoc).
  @doc false
  @spec record_end_failure(Record.t(), :lost | :timed_out | :failed, DateTime.t()) :: :ok
  def record_end_failure(%Record{id: id}, cause, %DateTime{} = now)
      when is_binary(id) and cause in [:lost, :timed_out, :failed] do
    in_transaction!("record_end_failure/3")

    {1, _rows} =
      Repo.update_all(from(r in Record, where: r.id == ^id),
        set: [failure_cause: cause, failure_reason: nil, failed_at: now, updated_at: now]
      )

    :ok
  end

  ## A run's image

  # image_for/2 is the image a run of `pool`, a workspace's pool, for `target` starts in,
  # or nil (the moduledoc).
  @doc false
  @spec image_for(Node.t(), %{system: String.t(), path: String.t()}) :: String.t() | nil
  def image_for(%Node{kind: :pool, workspace_id: workspace_id} = pool, target)
      when is_binary(workspace_id),
      do: image_for(pool, workspace_id, target)

  # image_for/3 is the image a run of `pool` in the workspace `workspace_id` for `target`
  # starts in, or nil: the instance's pool's runs are in many workspaces. Only an image
  # under the workspace's organisation in the registry (`own?/2`) is given.
  @doc false
  @spec image_for(Node.t(), Ecto.UUID.t(), %{system: String.t(), path: String.t()}) ::
          String.t() | nil
  def image_for(%Node{kind: :pool} = pool, workspace_id, %{system: system, path: path} = target)
      when is_binary(workspace_id) and is_binary(system) and is_binary(path) do
    image = stored_image(pool, workspace_id, target)
    if own?(image, workspace_id), do: image
  end

  # The image the newest build of `target` for `pool` stored, whatever its place: what
  # holds a run (`held/1`) reads too.
  defp stored_image(%Node{id: pool_id}, workspace_id, %{system: system, path: path}) do
    Repo.one(
      from [r, c] in served(workspace_id, system, path),
        where: r.pool_id == ^pool_id and r.built_ref == c.environment_ref,
        order_by: [desc: r.built_at, desc: r.id],
        limit: 1,
        select: r.image
    )
  end

  # Whether `image` is under the registry's place of the organisation of the workspace
  # `workspace_id`, `<QORY_REGISTRY>/<instance>/<organisation>/`
  # (`Apiary.Registry.Names`): the only place a prebuild of the organisation is sent to
  # push (`Apiary.Dispatches.Built`). An image stored before that check, at another
  # place, is given to no run. False on an instance without a registry (`placed?/2`
  # alone does not ask).
  defp own?(image, workspace_id), do: Registry.configured?() and placed?(image, workspace_id)

  # Whether `image` is under that place, whatever the feature `registry` says: false
  # where `QORY_REGISTRY` is unset, and where the instance's registry name is not made
  # yet, as no image can be under it. The name is read, never made, here.
  defp placed?(image, workspace_id) when is_binary(image) do
    with {:ok, %{service: service}} <-
           Registry.parse(Application.get_env(:apiary, :registry_setting)),
         instance when is_binary(instance) <- InstanceConfig.read_registry_instance(),
         organisation_id when is_binary(organisation_id) <-
           Repo.one(from w in Workspace, where: w.id == ^workspace_id, select: w.organisation_id) do
      String.starts_with?(
        image,
        "#{service}/#{instance}/#{Names.organisation(organisation_id)}/"
      )
    else
      _no_registry_name_or_workspace -> false
    end
  end

  defp placed?(nil, _workspace_id), do: false

  # The records of the workspace `workspace_id` that keep an image built for the target
  # `system` and `path`, of a live collection with that target and an `environment_ref`,
  # each joined to its collection (the moduledoc): `image_for/2` gives the newest of a
  # pool's whose `built_ref` is its collection's `environment_ref`, and `section/2`
  # shows the newest of a pool's.
  defp served(workspace_id, system, path) do
    from r in Record,
      join: c in Collection,
      on: c.id == r.source_collection_id,
      where: not is_nil(r.image),
      where: r.built_target_system == ^system and r.built_target_path == ^path,
      where: c.workspace_id == ^workspace_id and is_nil(c.ended_at),
      where: not is_nil(c.environment_ref),
      where: c.target_system == ^system and c.target_path == ^path
  end

  # claim_image/2 is the image a claim of `pool` gives an explore run of `work_item`
  # (the moduledoc): `{:ok, image}` for the image `image_for/2` reads for its target,
  # `{:ok, nil}` for a run that starts in the pool's default, and `:held` for a run held
  # for the pool's build of its target (`held/1`). A stored image outside the
  # organisation's place in the registry (`own?/2`) holds no run, as `held/1` reads it,
  # and is not given: the run starts in the pool's default.
  @doc false
  @spec claim_image(Node.t(), WorkItem.t()) :: {:ok, String.t() | nil} | :held
  def claim_image(
        %Node{kind: :pool} = pool,
        %WorkItem{workspace_id: workspace_id, target_system: system, target_path: path} =
          work_item
      )
      when is_binary(workspace_id) and is_binary(system) and is_binary(path) do
    target = %{system: system, path: path}

    cond do
      not prebuilt?(workspace_id) -> {:ok, nil}
      image = stored_image(pool, workspace_id, target) -> {:ok, own_image(image, workspace_id)}
      named?(workspace_id, target) and unset_by_policy?(workspace_id, work_item) -> :held
      true -> {:ok, nil}
    end
  end

  def claim_image(%Node{}, %WorkItem{}), do: {:ok, nil}

  # own_image/2 is `image` where it is under the registry's place of the organisation of
  # the workspace `workspace_id` (`placed?/2`), else nil: what a run is given of an image
  # a claim read. An attach reads its run's `configured_image` through it too: the claim
  # that set it had a registry, and the attach checks the image's place alone.
  @doc false
  @spec own_image(String.t() | nil, Ecto.UUID.t()) :: String.t() | nil
  def own_image(image, workspace_id) when is_binary(workspace_id),
    do: if(placed?(image, workspace_id), do: image)

  # Whether the run configuration in force for the target of `work_item`, of the
  # workspace `workspace_id`, names no image (`unset_by_policy/1`).
  defp unset_by_policy?(workspace_id, %WorkItem{id: id}) do
    Repo.exists?(
      from w in WorkItem,
        as: :work_item,
        where: w.id == ^id,
        where: ^unset_by_policy(workspace_id)
    )
  end

  # Whether a live collection assigned to the workspace `workspace_id` with the target
  # has an `environment_ref`.
  defp named?(workspace_id, %{system: system, path: path}) do
    Repo.exists?(
      from c in Collection,
        where: c.workspace_id == ^workspace_id and is_nil(c.ended_at),
        where: c.target_system == ^system and c.target_path == ^path,
        where: not is_nil(c.environment_ref)
    )
  end

  ## A build whose ref is older than the image's

  # newer_build?/2 is whether the image of `record`, locked by `lock_record/2`, was made by
  # a prebuild that took its `environment_ref` after `dispatch_run` took its (the
  # moduledoc).
  @doc false
  @spec newer_build?(Record.t() | nil, Apiary.Dispatches.DispatchRun.t()) :: boolean
  def newer_build?(
        %Record{built_queued_at: %DateTime{} = built_queued_at},
        %Apiary.Dispatches.DispatchRun{environment_ref_at: %DateTime{} = ref_at}
      ),
      do: DateTime.compare(ref_at, built_queued_at) == :lt

  def newer_build?(_record, %Apiary.Dispatches.DispatchRun{}), do: false

  # built_by?/2 is whether the image of `record`, locked by `lock_record/2`, was made by
  # the prebuild `dispatch_run`: the record's `built_queued_at` is when `dispatch_run`
  # took its `environment_ref` (the moduledoc).
  @doc false
  @spec built_by?(Record.t() | nil, Apiary.Dispatches.DispatchRun.t()) :: boolean
  def built_by?(
        %Record{built_queued_at: %DateTime{} = built_queued_at},
        %Apiary.Dispatches.DispatchRun{environment_ref_at: %DateTime{} = ref_at}
      ),
      do: DateTime.compare(ref_at, built_queued_at) == :eq

  def built_by?(_record, %Apiary.Dispatches.DispatchRun{}), do: false

  ## An image missing

  # hold_missing/3 holds `FOR SHARE`, inside the caller's transaction, the collections of
  # the records of the node pool `pool_id` whose image is `image`, built for `target`,
  # read without a lock, by id, after their connections `FOR SHARE`, by id (the
  # moduledoc): the collections held. A collection of a connection the first read did not
  # find is left out, as its connection is not held.
  @doc false
  @spec hold_missing(Ecto.UUID.t(), %{system: String.t(), path: String.t()}, String.t()) ::
          [Collection.t()]
  def hold_missing(pool_id, %{system: system, path: path}, image)
      when is_binary(pool_id) and is_binary(system) and is_binary(path) and is_binary(image) do
    in_transaction!("hold_missing/3")

    collection_ids =
      from r in Record,
        where: r.pool_id == ^pool_id and r.image == ^image,
        where: r.built_target_system == ^system and r.built_target_path == ^path,
        select: r.source_collection_id

    collections = from c in Collection, where: c.id in subquery(collection_ids), order_by: c.id

    connection_ids =
      Repo.all(from c in collections, select: c.connection_id)
      |> Enum.uniq()
      |> Enum.sort()

    held =
      Repo.all(
        from k in Connection,
          where: k.id in ^connection_ids,
          order_by: k.id,
          lock: "FOR SHARE",
          select: k.id
      )

    Repo.all(from c in collections, where: c.connection_id in ^held, lock: "FOR SHARE")
  end

  # lock_missing/3 locks `FOR UPDATE`, inside the caller's transaction, the records of the
  # node pool `pool_id` whose image is `image`, built for `target`, by collection: the
  # records (the moduledoc).
  @doc false
  @spec lock_missing(Ecto.UUID.t(), %{system: String.t(), path: String.t()}, String.t()) ::
          [Record.t()]
  def lock_missing(pool_id, %{system: system, path: path}, image)
      when is_binary(pool_id) and is_binary(system) and is_binary(path) and is_binary(image) do
    in_transaction!("lock_missing/3")

    Repo.all(
      from r in Record,
        where: r.pool_id == ^pool_id and r.image == ^image,
        where: r.built_target_system == ^system and r.built_target_path == ^path,
        order_by: [r.source_collection_id, r.pool_id],
        lock: "FOR UPDATE"
    )
  end

  # forget_image/3 clears the image of `records`, locked by `lock_missing/3`, at `now`,
  # and queues a prebuild of the collection of each record for its pool where one is due
  # and the collection is one of `collections`, held by `hold_missing/3`, inside the
  # caller's transaction (the moduledoc): the prebuilds it queued.
  @doc false
  @spec forget_image([Record.t()], [Collection.t()], DateTime.t()) ::
          [Apiary.Dispatches.DispatchRun.t()]
  def forget_image([], _collections, %DateTime{}), do: []

  def forget_image(records, collections, %DateTime{} = now)
      when is_list(records) and is_list(collections) do
    in_transaction!("forget_image/3")
    ids = Enum.map(records, & &1.id)

    {_count, _rows} =
      Repo.update_all(from(r in Record, where: r.id in ^ids),
        set: [
          image: nil,
          size: nil,
          commit: nil,
          built_at: nil,
          reported_ref: nil,
          built_ref: nil,
          built_target_system: nil,
          built_target_path: nil,
          built_queued_at: nil,
          updated_at: now
        ]
      )

    pools =
      Map.new(
        Repo.all(from n in Node, where: n.id in ^Enum.map(records, & &1.pool_id)),
        &{&1.id, &1}
      )

    collections = Map.new(collections, &{&1.id, &1})

    for %Record{} = record <- records,
        %Collection{} = collection <- [collections[record.source_collection_id]],
        %Node{kind: :pool, deleted_at: nil} = pool <- [pools[record.pool_id]],
        rebuilt?(collection, pool),
        run <- requeue(collection, [pool], now),
        do: run
  end

  # A collection whose image a prebuild for `pool` builds again: live, assigned to the
  # pool's workspace, whose domain has prebuilds, with a target and an `environment_ref`.
  defp rebuilt?(%Collection{} = collection, %Node{workspace_id: workspace_id}) do
    due?(collection) and collection.workspace_id == workspace_id and
      not is_nil(collection.environment_ref) and prebuilt?(workspace_id)
  end

  ## A build recorded

  # record_build/4 records the build of the prebuild `dispatch_run`, built for
  # `built_target` (nil for none), at `now`, inside the caller's transaction, which locked
  # the record first (the moduledoc).
  @doc false
  @spec record_build(
          Apiary.Dispatches.DispatchRun.t(),
          %{
            image: String.t(),
            size: pos_integer,
            commit: String.t(),
            environment_ref: String.t()
          },
          %{system: String.t(), path: String.t()} | nil,
          DateTime.t()
        ) :: :ok
  def record_build(
        %Apiary.Dispatches.DispatchRun{pool_id: pool_id, source_collection_id: collection_id} =
          run,
        %{image: image, size: size, commit: commit, environment_ref: reported_ref},
        built_target,
        %DateTime{} = now
      )
      when is_binary(pool_id) and is_binary(collection_id) do
    in_transaction!("record_build/4")

    {system, path} =
      if built_target, do: {built_target.system, built_target.path}, else: {nil, nil}

    built = [
      image: image,
      size: size,
      commit: commit,
      built_at: now,
      reported_ref: reported_ref,
      built_ref: run.environment_ref,
      built_target_system: system,
      built_target_path: path,
      built_queued_at: run.environment_ref_at,
      failure_cause: nil,
      failure_reason: nil,
      failed_at: nil,
      lost_ref: nil,
      updated_at: now
    ]

    row =
      Map.new(built)
      |> Map.merge(%{
        id: Ecto.UUID.generate(),
        organisation_id: run.organisation_id,
        workspace_id: run.workspace_id,
        pool_id: pool_id,
        source_collection_id: collection_id,
        inserted_at: now
      })

    {1, _rows} =
      Repo.insert_all(Record, [row],
        on_conflict: [set: built],
        conflict_target: [:pool_id, :source_collection_id]
      )

    :ok
  end

  ## A member's Rebuild

  # rebuild/2 queues a prebuild of `target`'s environment for each node pool of its
  # workspace whose prebuild of it does not wait unclaimed, changed or not (the moduledoc).
  @doc false
  @spec rebuild(Scope.t(), Target.t()) :: {:ok, non_neg_integer} | {:error, Access.reason()}
  def rebuild(%Scope{} = scope, %Target{} = target) do
    Repo.transact(fn ->
      with :ok <- Access.authorize(scope, :"target.rebuild_environment", target),
           true <- prebuilt?(target.workspace_id) || [],
           [_ | _] = collections <- hold_named(target),
           :ok <- lock_records(collections),
           [_ | _] = pools <- Map.get(pools([target.workspace_id]), target.workspace_id, []) do
        now = DateTime.utc_now()
        queued = for collection <- collections, run <- requeue(collection, pools, now), do: run
        :ok = audit_rebuild(scope, target, length(queued))
        {:ok, length(queued)}
      else
        [] -> {:error, :not_found}
        {:error, _reason} = refused -> refused
      end
    end)
  end

  # The live collections assigned to the workspace of `target` with its system and path,
  # by id.
  defp target_collections(%Target{} = target) do
    from c in Collection,
      where: c.organisation_id == ^target.organisation_id,
      where: c.workspace_id == ^target.workspace_id and is_nil(c.ended_at),
      where: c.target_system == ^target.system and c.target_path == ^target.path,
      order_by: c.id
  end

  # Those of them that name an `environment_ref`.
  defp named_collections(%Target{} = target),
    do: from(c in target_collections(target), where: not is_nil(c.environment_ref))

  # The named collections of `target`, held `FOR SHARE`, by id, after their connections,
  # `FOR SHARE`, by id, as a Backlog switch holds them (`Apiary.Adapters.Collections`): a
  # listing's part holds its connection `FOR UPDATE` before its collections, by ref, so
  # the Rebuild waits for the part at the connection, before it holds any collection. A
  # collection of a connection the first read did not find is left out, as its
  # connection is not held.
  defp hold_named(%Target{organisation_id: organisation_id} = target) do
    connection_ids =
      Repo.all(from c in named_collections(target), select: c.connection_id)
      |> Enum.uniq()
      |> Enum.sort()

    held =
      Repo.all(
        from k in Connection,
          where: k.id in ^connection_ids and k.organisation_id == ^organisation_id,
          order_by: k.id,
          lock: "FOR SHARE",
          select: k.id
      )

    Repo.all(
      from c in named_collections(target),
        where: c.connection_id in ^held,
        order_by: c.id,
        lock: "FOR SHARE"
    )
  end

  # Queues a prebuild of `collection`, held, for its `environment_ref`, for each of
  # `pools` whose prebuild of that ref does not wait: the prebuilds queued.
  defp requeue(%Collection{environment_ref: ref} = collection, pools, _now) do
    waiting =
      Repo.all(
        from r in DispatchRun,
          where: r.source_collection_id == ^collection.id and r.step == ^DispatchRun.prebuild(),
          where: r.environment_ref == ^ref and fragment("? = 'waiting'", r.state),
          select: r.pool_id
      )
      |> MapSet.new()

    for pool <- pools, not MapSet.member?(waiting, pool.id) do
      {:ok, run} = Dispatches.queue_prebuild(collection, pool, ref)
      run
    end
  end

  # The one entry of a Rebuild that queued `count` prebuilds, about the target; none when
  # it queued none.
  defp audit_rebuild(_scope, _target, 0), do: :ok

  defp audit_rebuild(scope, target, count) do
    {:ok, _entry} =
      Audit.record(Repo, scope, :"target.rebuild_environment", target, %{
        details: %{count: count}
      })

    :ok
  end

  ## What a target's page says

  @typedoc "A node pool's line of a target's environment (the moduledoc)."
  @type pool_line :: %{
          id: Ecto.UUID.t(),
          name: String.t(),
          serves: :image | :held | :default | :retired | :policy,
          image: String.t() | nil,
          built_at: DateTime.t() | nil,
          commit: String.t() | nil,
          failure: :released | :lost | :timed_out | :failed | nil,
          running: boolean,
          waiting: boolean
        }

  @typedoc "A target's environment, as its page says it (the moduledoc)."
  @type section :: %{
          state: :no_pool | :no_environment | :no_registry | :pools,
          named: boolean,
          pools: [pool_line]
        }

  # section/2 is the environment of `target`, a target of the scope's workspace, to a
  # person who may read its work items, nil for anyone else (the moduledoc).
  @doc false
  @spec section(Scope.t(), Target.t()) :: section | nil
  def section(
        %Scope{
          organisation: %{id: organisation_id},
          workspace: %Workspace{id: workspace_id} = workspace
        } = scope,
        %Target{organisation_id: organisation_id, workspace_id: workspace_id} = target
      ) do
    if Access.can?(scope, :"work_item.read", workspace) and Domain.prebuilds?(workspace),
      do: read_section(target)
  end

  def section(%Scope{}, %Target{}), do: nil

  defp read_section(%Target{} = target) do
    collections = Repo.all(target_collections(target))
    named = for %Collection{environment_ref: ref, id: id} <- collections, ref != nil, do: id
    pools = Map.get(pools([target.workspace_id]), target.workspace_id, [])
    ids = Enum.map(collections, & &1.id)
    pool_ids = Enum.map(pools, & &1.id)

    records =
      Repo.all(
        from r in Record,
          where: r.source_collection_id in ^ids and r.pool_id in ^pool_ids,
          order_by: r.id
      )
      |> Enum.group_by(& &1.pool_id)

    runs =
      Repo.all(
        from r in DispatchRun,
          where: r.source_collection_id in ^ids and r.pool_id in ^pool_ids,
          where: r.step == ^DispatchRun.prebuild(),
          where: r.state in [:waiting, :claimed, :handed_over],
          select: {r.pool_id, r.source_collection_id, r.state}
      )
      |> Enum.group_by(&elem(&1, 0))

    served =
      Repo.all(
        from [r, c] in served(target.workspace_id, target.system, target.path),
          where: r.pool_id in ^pool_ids and r.built_ref == c.environment_ref,
          distinct: r.pool_id,
          order_by: [desc: r.built_at, desc: r.id]
      )
      |> Map.new(&{&1.pool_id, &1})

    policy? = policy_image?(target)

    lines =
      for pool <- pools do
        pool_line(
          pool,
          named,
          Map.get(records, pool.id, []),
          Map.get(runs, pool.id, []),
          if(policy?, do: :policy, else: given(Map.get(served, pool.id), target.workspace_id))
        )
      end

    case section_state(pools, named, lines) do
      :pools when named != [] ->
        if Registry.configured?(),
          do: %{state: :pools, named: true, pools: lines},
          else: %{state: :no_registry, named: true, pools: []}

      state ->
        %{state: state, named: named != [], pools: lines}
    end
  end

  # The record a pool's line shows as the image runs start in: `record` where its image
  # is under the organisation's place in the registry (`own?/2`), `:foreign` where it is
  # not, as no run is given it; nil for none.
  defp given(%Record{image: image} = record, workspace_id),
    do: if(own?(image, workspace_id), do: record, else: :foreign)

  defp given(nil, _workspace_id), do: nil

  defp section_state([], _named, _lines), do: :no_pool

  defp section_state(_pools, [], lines) do
    if Enum.all?(lines, &(&1.serves == :default and not &1.running and not &1.waiting)),
      do: :no_environment,
      else: :pools
  end

  defp section_state(_pools, _named, _lines), do: :pools

  # Whether the run configuration in force for `target` names an image in its
  # `security_policy`, which a run of the target then starts in; never on an instance
  # without the feature `security`, where no run configuration is served.
  defp policy_image?(
         %Target{organisation_id: organisation_id, workspace_id: workspace_id} = target
       ) do
    Features.on?(:security) and
      case Policy.in_force(organisation_id, workspace_id, target.id) do
        {:ok, %RunConfiguration{document: document}} ->
          ComposedConfiguration.names_image?(document)

        {:error, _reason} ->
          false
      end
  end

  # A pool's line: of the records and prebuilds of the collections that name an
  # `environment_ref`, where one does; of every collection of the target, where none does.
  # `served` is `:policy` where the policy names the image, else the record `image_for/2`
  # reads for the pool, whose `built_ref` is its collection's `environment_ref`, nil for
  # none.
  defp pool_line(%Node{} = pool, named, records, runs, served) do
    {records, runs} =
      if named == [],
        do: {records, runs},
        else:
          {Enum.filter(records, &(&1.source_collection_id in named)),
           Enum.filter(runs, &(elem(&1, 1) in named))}

    built = if match?(%Record{}, served), do: served

    %{
      id: pool.id,
      name: pool.name,
      serves: serves(served, named, records),
      image: built && built.image,
      built_at: built && built.built_at,
      commit: built && built.commit,
      failure: last_failure(records, newest_built_at(records)),
      running: Enum.any?(runs, &(elem(&1, 2) in [:claimed, :handed_over])),
      waiting: Enum.any?(runs, &(elem(&1, 2) == :waiting))
    }
  end

  defp serves(:policy, _named, _records), do: :policy

  defp serves(_served, [], records) do
    if Enum.any?(records, &(&1.image != nil)), do: :retired, else: :default
  end

  defp serves(%Record{}, _named, _records), do: :image
  defp serves(:foreign, _named, _records), do: :default
  defp serves(nil, _named, _records), do: :held

  # The newest `built_at` of `records`, nil where none keeps a build.
  defp newest_built_at(records) do
    records
    |> Enum.map(& &1.built_at)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  # The cause of the newest failure of `records`, where it failed after `built_at`, the
  # newest build any of them keeps; nil otherwise.
  defp last_failure(records, built_at) do
    case records
         |> Enum.filter(&(&1.failure_cause != nil))
         |> Enum.max_by(& &1.failed_at, DateTime, fn -> nil end) do
      %Record{failure_cause: cause, failed_at: failed_at} ->
        if is_nil(built_at) or DateTime.after?(failed_at, built_at), do: cause

      nil ->
        nil
    end
  end

  ## A run held for its build

  # The condition `unset_by_policy/1` writes: the run configuration in force for the
  # workspace and the target, given in that order, names no image.
  @image_in_force """
  NOT COALESCE((
    SELECT jsonb_typeof(c.document::jsonb -> 'security_policy') = 'object'
      AND jsonb_exists(c.document::jsonb -> 'security_policy', 'image')
    FROM run_configurations AS c
    LEFT JOIN targets AS t ON t.id = c.target_id
    WHERE c.workspace_id = ?
      AND (c.target_id IS NULL OR (t.system = ? AND t.path = ?))
    ORDER BY c.target_id IS NULL, c.version DESC
    LIMIT 1
  ), false)
  """

  # holds?/1 is whether the runs of the workspace `workspace_id` wait for their target's
  # build: its domain has prebuilds, on an instance with a registry (the moduledoc).
  @doc false
  @spec holds?(Ecto.UUID.t()) :: boolean
  def holds?(workspace_id) when is_binary(workspace_id), do: prebuilt?(workspace_id)

  # held/1 is the query of the work item of a run of the queue bound `:run`, for
  # `exists/1`, when the run is held for the node pool `pool_id`: the run's workspace has
  # a domain with prebuilds, its work item's target has a live collection assigned to the
  # run's workspace with an `environment_ref`, no such collection has a record for the
  # pool whose image was built for the target from that `environment_ref`, and the run
  # configuration in force for the target names no image (`unset_by_policy/1`; the
  # moduledoc). It reads the run's workspace, so one query serves the instance's pool,
  # whose runs are in many workspaces.
  @doc false
  @spec held(Ecto.UUID.t()) :: Ecto.Query.t()
  def held(pool_id) when is_binary(pool_id) do
    from w in WorkItem,
      as: :work_item,
      join: s in Workspace,
      as: :workspace,
      on: s.id == parent_as(:run).workspace_id,
      join: c in Collection,
      on:
        c.workspace_id == s.id and is_nil(c.ended_at) and
          not is_nil(c.environment_ref) and c.target_system == w.target_system and
          c.target_path == w.target_path,
      left_join: e in Record,
      on:
        e.source_collection_id == c.id and e.pool_id == ^pool_id and not is_nil(e.image) and
          e.built_ref == c.environment_ref and e.built_target_system == w.target_system and
          e.built_target_path == w.target_path,
      where: w.id == parent_as(:run).work_item_id,
      where: ^prebuilt_domain(),
      where: ^unset_by_policy(:workspace),
      group_by: w.id,
      having: count(e.id) == 0,
      select: w.id
  end

  # The condition, on a workspace bound `:workspace`, that its domain has prebuilds
  # (`Apiary.Lingo.Domain.prebuilds?/1`), on an instance with a registry
  # (`Apiary.Registry.configured?/0`): a stored name no domain has any more reads as the
  # default's, as `Apiary.Lingo.Domain.for_workspace/1` reads it.
  defp prebuilt_domain do
    prebuilt = for {name, domain} <- Domain.domains(), domain.prebuilds?(), do: name
    default = Domain.default().prebuilds?()

    if Registry.configured?() do
      dynamic(
        [workspace: s],
        s.domain in ^prebuilt or
          (type(^default, :boolean) and (s.domain not in ^Domain.names() or is_nil(s.domain)))
      )
    else
      dynamic([workspace: _s], false)
    end
  end

  # unset_by_policy/1 is the condition, on a work item bound `:work_item` of the
  # workspace `workspace_id`, or of the workspace bound `:workspace` when given
  # `:workspace`, that the run configuration in force for its target, the target's newest
  # version or else the workspace's (`Apiary.Policy.in_force/3`), names no image in its
  # `security_policy` (`Apiary.Policy.ComposedConfiguration.names_image?/1`): a run of
  # such a target starts in the policy's image, so it is held for no build. Always true on
  # an instance without the feature `security`, where no run configuration is served.
  @doc false
  @spec unset_by_policy(Ecto.UUID.t() | :workspace) :: Ecto.Query.dynamic_expr()
  def unset_by_policy(:workspace) do
    if Features.on?(:security) do
      dynamic(
        [work_item: w, workspace: s],
        fragment(@image_in_force, s.id, w.target_system, w.target_path)
      )
    else
      dynamic([work_item: _w], true)
    end
  end

  def unset_by_policy(workspace_id) when is_binary(workspace_id) do
    if Features.on?(:security) do
      dynamic(
        [work_item: w],
        fragment(
          @image_in_force,
          type(^workspace_id, Ecto.UUID),
          w.target_system,
          w.target_path
        )
      )
    else
      dynamic([work_item: _w], true)
    end
  end

  # hold_builds/3 holds `FOR SHARE`, by id, inside the caller's transaction, the
  # collections a claim of the node pool `pool_id` of the workspace `workspace_id` at
  # `now` writes the prebuilds of, read without a lock first, and answers those a build
  # for the pool is due for: each collection of the target of a waiting run held for the
  # pool, of a work item in Explore, with no prebuild of its `environment_ref` for the
  # pool waiting, claimed or handed over. It holds with them the collections of the
  # pool's claimed prebuilds whose dispatch lapsed at `now`
  # (`Apiary.Dispatches.Slots.lapsed_collections/2`), whose prebuilds the claim's free
  # writes, in the same statement, so every collection lock the claim takes comes first,
  # in id order. It holds their connections `FOR SHARE`, by id, first, as `hold_named/1`
  # does. Of the due ones, it answers those still live and assigned to a workspace the
  # pool serves as read once held, since an assign may have changed one while the claim
  # waited for it. A claim calls it before it locks the pool's row (the moduledoc).
  # `workspace_id` is nil for the instance's pool, which serves every workspace with no
  # pool in use (`served/2`).
  @doc false
  @spec hold_builds(Ecto.UUID.t() | nil, Ecto.UUID.t(), DateTime.t()) :: [Collection.t()]
  def hold_builds(workspace_id, pool_id, %DateTime{} = now)
      when (is_binary(workspace_id) or is_nil(workspace_id)) and is_binary(pool_id) do
    in_transaction!("hold_builds/3")
    lapsed = Apiary.Dispatches.Slots.lapsed_collections(pool_id, now)

    due =
      if is_nil(workspace_id) or prebuilt?(workspace_id),
        do: due_builds(workspace_id, pool_id),
        else: []

    all = Enum.uniq(due ++ lapsed)

    connection_ids =
      Repo.all(from c in Collection, where: c.id in ^all, select: c.connection_id)
      |> Enum.uniq()
      |> Enum.sort()

    _connections =
      Repo.all(
        from k in Connection,
          where: k.id in ^connection_ids,
          order_by: k.id,
          lock: "FOR SHARE",
          select: k.id
      )

    held = Repo.all(from c in Collection, where: c.id in ^all, order_by: c.id, lock: "FOR SHARE")
    served = served(workspace_id, held)
    Enum.filter(held, &(&1.id in due and due?(&1) and MapSet.member?(served, &1.workspace_id)))
  end

  # The workspaces, of those `collections` are assigned to, that a node pool serves: its
  # workspace `workspace_id`, or, for the instance's pool (nil), each with no pool in use
  # in a place in use (`Apiary.Dispatches.no_pool_in_use/0`,
  # `Apiary.Dispatches.in_use_place/0`).
  defp served(workspace_id, _collections) when is_binary(workspace_id),
    do: MapSet.new([workspace_id])

  # The conditions read the collection's `workspace_id` and `organisation_id` as a run's,
  # so it is bound `:run`.
  defp served(nil, collections) do
    ids = Enum.map(collections, & &1.id)

    Repo.all(
      from c in Collection,
        as: :run,
        where: c.id in ^ids and not is_nil(c.workspace_id),
        where: ^Dispatches.no_pool_in_use(),
        where: ^Dispatches.in_use_place(),
        distinct: true,
        select: c.workspace_id
    )
    |> MapSet.new()
  end

  # The ids of the collections a build for the node pool `pool_id` of the workspace
  # `workspace_id`, or for the instance's pool (nil), is due for, read without a lock
  # (`hold_builds/3`).
  defp due_builds(workspace_id, pool_id) do
    live_build =
      from b in DispatchRun,
        where: b.source_collection_id == parent_as(:collection).id,
        where: b.pool_id == ^pool_id and b.step == ^DispatchRun.prebuild(),
        where: b.environment_ref == parent_as(:collection).environment_ref,
        where: b.state in [:waiting, :claimed, :handed_over],
        select: 1

    Repo.all(
      from r in DispatchRun,
        as: :run,
        join: w in WorkItem,
        on: w.id == r.work_item_id,
        join: c in Collection,
        as: :collection,
        on:
          c.workspace_id == r.workspace_id and is_nil(c.ended_at) and
            not is_nil(c.environment_ref) and c.target_system == w.target_system and
            c.target_path == w.target_path,
        where: ^runs_served(workspace_id),
        where: r.step != ^DispatchRun.prebuild(),
        where: fragment("? = 'waiting'", r.state) and w.state == :exploring,
        where: exists(held(pool_id)),
        where: not exists(live_build),
        distinct: true,
        select: c.id
    )
  end

  # The waiting runs, bound `:run`, a node pool takes: of its workspace, or, for the
  # instance's pool (nil), of every workspace with no pool in use in a place in use.
  defp runs_served(workspace_id) when is_binary(workspace_id),
    do: dynamic([run: r], r.workspace_id == ^workspace_id)

  defp runs_served(nil),
    do: dynamic([run: _r], ^Dispatches.no_pool_in_use() and ^Dispatches.in_use_place())

  # make_records/2 inserts the environment record of each of `collections`, held by
  # `hold_builds/3`, that a build is due for on the node pool `pool`, with no live
  # prebuild of its ref for the pool (`to_queue/3`), where there is none, by collection,
  # as `Apiary.Dispatches.queue_prebuild/3` inserts it, inside the caller's transaction.
  # A claim calls it inside its free, once the records of its
  # lapsed prebuilds are locked and before any run is (`Apiary.Dispatches.Slots.free/3`),
  # so the prebuilds `queue_builds/2` queues later insert no record after runs are
  # locked, and the claim locks existing records and then inserts missing ones, as a
  # Rebuild does (the moduledoc). A collection it leaves out has a live prebuild of its
  # ref, so its record exists already, or no build is due for it, so `queue_builds/2`
  # queues none.
  @doc false
  @spec make_records([Collection.t()], Node.t()) :: :ok
  def make_records(collections, %Node{} = pool) do
    case to_queue(collections, pool, "make_records/2") do
      [] -> :ok
      due -> insert_records(due, pool.id)
    end
  end

  defp insert_records(collections, pool_id) do
    now = DateTime.utc_now()

    rows =
      for %Collection{} = collection <- Enum.sort_by(collections, & &1.id) do
        %{
          id: Ecto.UUID.generate(),
          organisation_id: collection.organisation_id,
          workspace_id: collection.workspace_id,
          pool_id: pool_id,
          source_collection_id: collection.id,
          inserted_at: now,
          updated_at: now
        }
      end

    {_count, _rows} =
      Repo.insert_all(Record, rows,
        on_conflict: :nothing,
        conflict_target: [:pool_id, :source_collection_id]
      )

    :ok
  end

  # queue_builds/2 queues, inside the caller's transaction, a prebuild of each of
  # `collections`, held by `hold_builds/3`, for the node pool `pool`, whose row the
  # caller locked after them, for the collection's `environment_ref`, where the
  # collection is still live, assigned to the pool's workspace, with that target and an
  # `environment_ref`, and no prebuild of that ref for the pool waits, is claimed or
  # handed over (the moduledoc): the prebuilds queued.
  @doc false
  @spec queue_builds([Collection.t()], Node.t()) :: [DispatchRun.t()]
  def queue_builds(collections, %Node{} = pool) do
    for collection <- to_queue(collections, pool, "queue_builds/2") do
      {:ok, run} = Dispatches.queue_prebuild(collection, pool, collection.environment_ref)
      run
    end
  end

  # Those of `collections` a build is due for on the node pool `pool`, as
  # `make_records/2` and `queue_builds/2` read them when each runs: each live, assigned
  # to the pool's workspace, with a target and an `environment_ref`, with no prebuild of
  # that ref for the pool waiting, claimed or handed over. None for a deleted pool. It
  # reads inside the caller's transaction; `what`, the caller, is named in the error
  # raised outside one.
  defp to_queue([], %Node{}, _what), do: []

  defp to_queue(collections, %Node{kind: :pool, deleted_at: nil} = pool, what) do
    in_transaction!(what)
    ids = Enum.map(collections, & &1.id)

    live =
      Repo.all(
        from b in DispatchRun,
          join: c in Collection,
          on: c.id == b.source_collection_id,
          where: b.source_collection_id in ^ids and b.pool_id == ^pool.id,
          where: b.step == ^DispatchRun.prebuild() and b.environment_ref == c.environment_ref,
          where: b.state in [:waiting, :claimed, :handed_over],
          select: b.source_collection_id
      )
      |> MapSet.new()

    served = served(pool.workspace_id, collections)

    Enum.filter(
      collections,
      &(due?(&1) and MapSet.member?(served, &1.workspace_id) and not MapSet.member?(live, &1.id))
    )
  end

  defp to_queue(_collections, %Node{}, _what), do: []

  ## Helpers

  # A live collection assigned to a workspace, with a target and an `environment_ref`.
  defp due?(%Collection{
         ended_at: nil,
         workspace_id: workspace_id,
         target_system: system,
         environment_ref: ref
       }),
       do: is_binary(workspace_id) and is_binary(system) and is_binary(ref)

  defp due?(%Collection{}), do: false

  # Those of `workspace_ids` whose domain has prebuilds (`Apiary.Lingo.Domain.prebuilds?/1`),
  # read without a lock: a workspace's domain never changes. None on an instance without
  # a registry (`Apiary.Registry.configured?/0`): a prebuild pushes its image there.
  defp prebuilt_workspaces(workspace_ids) do
    if Registry.configured?() do
      Repo.all(from w in Workspace, where: w.id in ^workspace_ids)
      |> Enum.filter(&Domain.prebuilds?/1)
      |> MapSet.new(& &1.id)
    else
      MapSet.new()
    end
  end

  defp prebuilt?(workspace_id),
    do: MapSet.member?(prebuilt_workspaces([workspace_id]), workspace_id)

  # The live node pools of `workspace_ids`, by workspace, each list by id.
  defp pools(workspace_ids) do
    Repo.all(
      from n in Node,
        where: n.workspace_id in ^workspace_ids and n.kind == :pool and is_nil(n.deleted_at),
        order_by: n.id
    )
    |> Enum.group_by(& &1.workspace_id)
  end

  # Locks the records of `collections`, of every pool, `FOR UPDATE`, by collection and
  # then pool, in one statement, before any of them is written (the moduledoc).
  defp lock_records(collections) do
    ids = Enum.map(collections, & &1.id)

    _locked =
      Repo.all(
        from r in Record,
          where: r.source_collection_id in ^ids,
          order_by: [r.source_collection_id, r.pool_id],
          lock: "FOR UPDATE",
          select: r.id
      )

    :ok
  end

  defp in_transaction!(what) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "Apiary.Environments.#{what} runs inside the caller's transaction")
  end
end
