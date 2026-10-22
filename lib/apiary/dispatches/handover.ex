defmodule Apiary.Dispatches.Handover do
  @moduledoc false

  # A node pool's starter on a dispatch its pool claimed (the provisioner contract,
  # `contracts/provisioner/v1`), and the run a claim registers. `Apiary.Dispatches` calls
  # `register/2` inside its claim's transaction for the run the claim took, and delegates
  # `dispatched/3`, the starter started the machine for the dispatch
  # (`dispatched.schema.json`), here.
  #
  # ## What `dispatched/3` and a release ask first
  #
  # A `dispatch_id` not of a dispatch's shape is `{:error, :forbidden}`, looked up nowhere.
  # Then, in one transaction:
  #
  #   1. the key read again as a request's verification reads it
  #      (`Apiary.Dispatches.current_key/1`): revoked, of a pool deleted, or of a place out
  #      of use since, `{:error, :unauthorized}`;
  #   2. the dispatch by its public id, read without a lock, and the action,
  #      `dispatch.dispatched` or `dispatch.release`, asked of it (`Apiary.Access`): an
  #      unknown dispatch, one another pool claimed and any refusal of the key are one
  #      answer, `{:error, :forbidden}`, so nobody learns whether an id exists;
  #   3. the slots due freed for the dispatch's run (`Apiary.Dispatches.Slots.free/2`), so
  #      a lease that lapsed and was not yet swept lapses now, before anything is judged:
  #      its run waits again, or a prebuild ends `superseded`;
  #   4. the run of the queue locked `FOR UPDATE` (`Apiary.Dispatches.RunEnd.lock/1`), then
  #      the dispatch, and the clock read once both are held;
  #   5. a dispatch that ended, or of a run that ended, is `{:error, :gone}`.
  #
  # The release asks the same, in the same transaction (`transact/5`), and holds one row
  # between steps 2 and 3: its run's work item or environment record
  # (`Apiary.Dispatches.Release`).
  #
  # ## `dispatched/3`
  #
  # Then a dispatch handed over is `:ok`: the first `dispatched` sets `dispatched_at` and
  # the job's `external_*`, when the body has them, and a later one changes nothing,
  # whatever the clock. A dispatch not handed over whose lease lapsed, `stale_at` set or
  # the clock at or past `lease_until`, is `{:error, :lease_expired}`. Else the
  # `dispatched` sets `dispatched_at` and the job's `external_*`, and hands the dispatch
  # over: `handed_over_at` the clock, the run of the queue `handed_over`. From then on the
  # dispatch keeps no lease: it never goes stale, and its slot stays held until its run
  # ends (`Apiary.Dispatches.RunEnd`). The run counts toward its pool's limit by its
  # dispatch, never as an instance (`Apiary.Nodes.instances_in_use/2`).
  #
  # ## At the claim: `register/2`
  #
  # For the run of the queue the claim took and its dispatch, the first of these that
  # applies:
  #
  #   1. what the run is formed from, which the claim cannot form: the run of the queue
  #      and its dispatch end, in the claim's transaction, with a cause the run of the
  #      queue keeps, a stale dispatch of it `run_ended`, and the slot the dispatch took is
  #      freed once (`end_claimed/3`); the claim then takes the next waiting run. A
  #      prebuild whose collection ended, is assigned to no workspace or another one, or
  #      has no target ends `collection_ended`: its assignment, its workspace, its end and
  #      its target are read, never its Backlog switch or whether it has items. Run
  #      variables of the target, and of the further paths its runs also read where the
  #      workspace's domain has a label for them (`Apiary.Targets.further_repositories/1`),
  #      that break the domain's rules (`Apiary.Lingo.Domain.run_variables/3`) end it
  #      `variables_invalid`; an explore run whose work item's ticket is no longer kept,
  #      `ticket_gone`; one whose input cannot be formed (`Apiary.Dispatches.Inputs`), or
  #      whose work item has no target in a domain that requires one
  #      (`Apiary.Lingo.Domain.target_required?/1`), `inputs_invalid`; an explore run
  #      whose model choice cannot be formed (`Apiary.Dispatches.RunSettings`):
  #      `provider_gone`, `runtime_unserved`, `key_gone` or `model_gone`; and, checked
  #      last, with the features `factory` and `secrets` on, an explore run whose model
  #      choice has a provider, while one of the gateway's active keys the run key lists
  #      was made without the stored-secrets flag (`allow_secrets`), or the provider's key
  #      may not be sealed for a gateway of the gateway's organisation
  #      (`Apiary.Runs.ProviderCredential.sealable_to?/3`): `secrets_not_allowed`, as such
  #      a gateway never receives the run's model key, and the run never starts on a model
  #      nobody chose;
  #   2. the run key cannot be made for the gateway's address
  #      (`Apiary.Runs.Registration.issue_grant/3`), the run settings take more than 64
  #      KiB, the input does not fit 1 MiB with every comment left out, the run's model
  #      choices changed while the claim read them, or anything else fails:
  #      `{:error, :unavailable}`, and the claim's transaction rolls back.
  #
  # Else the run is registered, as a registration through the gateway by the pool:
  # `pending`, its `node_run_id` the run's `run_id`, on the pool, its instance the run's
  # `run_id` too, under the pool's key, its labels the target's
  # (`Apiary.Lingo.Domain.target_labels/1`) and, where the domain has one and gives the
  # run variables, the label of its paths (`Apiary.Lingo.Domain.paths_label/1`) with its
  # QORY_RUN_REPOSITORIES as the value, `about` the step and, for an explore run, its
  # work item, its run variables (`registration_variables`), none where the domain gives
  # none, its registration digest the SHA-256 of the claim's body, with no heartbeat
  # interval, no answer digest and no contract version until its attach; with the
  # gateway and a run code in place of a run key (`Apiary.Runs.RunCode`): the code's
  # SHA-256, its expiry 15 minutes after the claim, the grant its run key will be made
  # from at the code's redemption, `run_key_issued_at` the claim and `attach_by` the
  # code's expiry. A run key of the grant is made all the same, and given to nobody, so a
  # grant no run key can be made for refuses the claim as step 2 says. The run key's
  # instance id is the run's id. The dispatch stays claimed, and so does the run of the
  # queue.
  #
  # An explore run has `run_settings` with the features `factory` and `secrets` on
  # (`Apiary.Dispatches.RunSettings`), and keeps them on its registered run, with the
  # provider's row id, its keys' secret's row id, the chosen key's value id, the
  # provider's chain and the API of the provider the run uses; later reads take those,
  # never the choices. Its input is formed with the name of the workspace's domain
  # (`Apiary.Lingo.Domain.name/1`) and the run's target, or none for an explore run whose
  # work item has none, and takes what the rest of the run's documents leave of their
  # limit: it leaves out its oldest comments first (`comments_omitted`). The documents'
  # limit is what the 201 to the code's redemption leaves them within 1 MiB, the rest of
  # that 201 measured with a run key of the run's grant, less 1,024 bytes. The claim
  # encodes the documents once and keeps the bytes on the registered run
  # (`runs.run_documents`), which every redemption answers as they are.
  #
  # **The registered run lives as long as the claim.** While its run of the queue is
  # claimed, a registered run has neither attached nor had its code redeemed. When the run
  # of the queue leaves `claimed` other than by its handover, its lease lapsed
  # (`Apiary.Dispatches.Slots`), its starter released it (`Apiary.Dispatches.Release`) or
  # its work item was closed (`Apiary.Dispatches.cancel_for_close/2`), the registered run
  # is deleted with its run code, in the same transaction (`drop/1`): the code redeems no
  # more, and a run that waits again is registered anew, with a new code, by the claim
  # that takes it next. A dispatch is handed over at its first `dispatched`, or at the
  # first redemption of its run code (`Apiary.Runs.RunCode.redeem/2`), whichever comes
  # first.
  #
  # A refusal of `dispatched/3` commits what the lapse of step 3 wrote. Once the
  # transaction commits, the workspaces whose queue or slots changed are told. An
  # exception in the transaction rolls it back, is logged by its module alone, never the
  # key or the body, and is `{:error, :unavailable}`. The telling, after the commit, never
  # changes the answer: a failure of it is logged by its module, or its kind, alone.
  #
  # Locks of `register/2`, after those the claim holds (`Apiary.Dispatches`: the pool's
  # row, the gateway's row `FOR SHARE`, the records a lapse needs, the run of the queue it
  # took, and the dispatch it wrote): the rows of the model providers an explore run's
  # choices name `FOR SHARE`, then the rows of their keys' secrets `FOR SHARE`
  # (`Apiary.Dispatches.RunSettings`), then the registered run, inserted. A change of a
  # provider or of its keys locks nothing of the queue, so it and a claim take turns at
  # the provider's row alone. Nothing else is locked: not the pool's connection, its
  # collection, the work item or the workspace.

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Apiary.{
    Access,
    AccessKeys,
    Dispatches,
    Gateways,
    Nodes,
    PublicId,
    Repo,
    Runs,
    Stacks,
    Targets
  }

  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.Collection

  alias Apiary.Dispatches.{
    Dispatch,
    DispatchRun,
    Inputs,
    RunEnd,
    RunSettings,
    Slots
  }

  alias Apiary.Lingo.Domain
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Workspace
  alias Apiary.Runs.{About, ProviderCredential, Registration, Run, RunCode, RunVariables, Target}
  alias Apiary.WorkItems.WorkItem
  alias ApiaryWeb.Contract.DispatchAnswer

  @prebuild DispatchRun.prebuild()
  # The causes a claimed run ends for when the claim cannot form what it is made from.
  @unformed [:variables_invalid, :ticket_gone, :inputs_invalid] ++
              RunSettings.causes() ++ [:secrets_not_allowed]
  # What the log says when an action's transaction fails.
  @failed %{
    "dispatch.dispatched": "a dispatched could not be recorded",
    "dispatch.release": "a release could not be made"
  }
  # The attach window of the run key made, and given to nobody, at the claim, in seconds.
  @attach_seconds 600
  # The most bytes the 201 to the run code's redemption takes, encoded: 1 MiB, what the
  # gateway's relay passes back.
  @answer_bytes 1_048_576
  # The bytes kept free in that 201 beside what the claim measures: a second key of the
  # server's, should it rotate before the redemption, and the digits of the run key's times.
  @answer_margin 1_024

  @typedoc """
  A run registered at its claim: the registered run, its run code, the address of the
  gateway the claim resolved to, and what the run's documents are made from
  (`ApiaryWeb.Contract.DispatchAnswer.documents/1`).
  """
  @type registered :: %{
          run: Run.t(),
          run_code: String.t(),
          gateway_url: String.t(),
          documents: map
        }

  @type refusal ::
          :unauthorized
          | :forbidden
          | :gone
          | :lease_expired
          | :unavailable

  # unformed/0 is every cause a claimed run ends for when the claim cannot form what it
  # is made from, each with the outcome `error` on a run that is not a prebuild.
  @doc false
  @spec unformed() :: [atom]
  def unformed, do: @unformed

  # dispatched/3 records that the starter started the machine for the dispatch
  # `dispatch_id` of the pool of `access_key`, with the job's `external` (nil for none):
  # the moduledoc.
  @doc false
  @spec dispatched(AccessKey.t(), term, %{external: map | nil}) ::
          :ok | {:error, refusal}
  def dispatched(%AccessKey{key_id: key_id}, dispatch_id, %{} = meta) do
    if Dispatch.public_id?(dispatch_id) do
      key_id
      |> transact(dispatch_id, :"dispatch.dispatched", nil, fn locked ->
        with :ok <- not_ended(locked) do
          record_dispatched(locked, meta[:external])
        end
      end)
      |> answered()
    else
      {:error, :forbidden}
    end
  end

  # register/2 registers the run of the queue `claimed.run`, which the claim took, with
  # a run code, through the gateway `claimed.gateway`, inside the claim's transaction:
  # `{:ok, registered}`, `{:ended, workspace_ids}` when the run could not be formed and
  # ended, or `{:error, :unavailable}` (the moduledoc). `claimed` has the key, the
  # dispatch, the run of the queue, the gateway and its workspace, the gateway's active
  # keys, at most two, the clock and the claim's body.
  @doc false
  @spec register(map, DateTime.t()) ::
          {:ok, registered} | {:ended, [Ecto.UUID.t()]} | {:error, :unavailable}
  def register(%{run: %DispatchRun{} = dispatch_run} = claimed, %DateTime{} = now) do
    case RunSettings.hold(dispatch_run) do
      :unstable ->
        Logger.error(
          "a claim could not be made: the run's model choices changed while the claim read them"
        )

        {:error, :unavailable}

      held ->
        claimed
        |> Map.merge(%{held: held, now: now})
        |> register_held()
    end
  end

  defp register_held(%{gateway: {gateway, workspace}, keys: keys} = locked) do
    pool = locked.key.node

    grant =
      Registration.through_grant(gateway, keys, %{
        run_id: locked.run.run_id,
        workspace: workspace.public_id,
        node_id: pool.public_id,
        instance_id: locked.run.run_id
      })

    # The run key of the grant, given to nobody: the 201 to the code's redemption carries
    # a run key of this grant, as long, and the documents take what the rest leaves.
    issued = Registration.issue_grant(grant, locked.now, @attach_seconds)
    locked = Map.put(locked, :documents_limit, documents_limit(locked.run, issued))

    case locked |> formed(workspace) |> sealable(gateway, workspace, keys) do
      {:end, cause} ->
        {:ended, end_claimed(locked.run, cause, locked.now)}

      :unavailable ->
        Logger.error("a claim could not be made: the run's documents do not fit their limit")
        {:error, :unavailable}

      :unstable ->
        Logger.error(
          "a claim could not be made: the run's model choices changed while the claim read them"
        )

        {:error, :unavailable}

      {:ok, formed} ->
        documents = formed.answer |> DispatchAnswer.documents() |> Jason.encode!()

        with {:ok, _given_to_nobody} <- issued,
             :ok <- within(documents, locked.documents_limit) do
          %{code: code, through: through} = RunCode.issue(grant, locked.now)

          run =
            insert_run(
              locked,
              formed,
              through |> Map.put(:gateway_id, gateway.id) |> Map.put(:run_documents, documents)
            )

          {:ok,
           %{run: run, run_code: code, gateway_url: grant.gateway_url, documents: formed.answer}}
        end
    end
  end

  # The most bytes the run's documents take, encoded: what the 201 to the code's
  # redemption leaves them, measured with the run key `issued` and the server's keys as
  # they are now, less `@answer_margin`. A run key that cannot be made measures nothing:
  # the claim is refused after the run is formed.
  defp documents_limit(%DispatchRun{run_id: run_id}, {:ok, %{run_key: run_key}}) do
    rest =
      Apiary.Contract.Enrolment.run_answer_body(%{
        run_id: run_id,
        run_key: run_key,
        documents: "{}",
        apiary_public_key: Apiary.SigningKey.apiary_public_key()
      })

    answer_limit() - (byte_size(rest) - 2) - @answer_margin
  end

  defp documents_limit(_dispatch_run, _not_issued), do: answer_limit() - @answer_margin

  defp within(documents, limit) when byte_size(documents) <= limit, do: :ok

  defp within(_documents, _limit) do
    Logger.error("a claim could not be made: the run's documents do not fit their limit")
    {:error, :unavailable}
  end

  # drop/1 deletes the runs registered for the runs of the queue `dispatch_run_ids` that
  # never attached and whose run code was never redeemed, with their run codes, inside
  # the caller's transaction, which holds those runs of the queue: what a run of the
  # queue leaving `claimed` other than by its handover does (the moduledoc). The ids of
  # the runs deleted.
  @doc false
  @spec drop([Ecto.UUID.t()]) :: [Ecto.UUID.t()]
  def drop([]), do: []

  def drop(dispatch_run_ids) when is_list(dispatch_run_ids) do
    {_count, ids} =
      Repo.delete_all(
        from(r in Run,
          where: r.dispatch_run_id in ^dispatch_run_ids,
          where: is_nil(r.attached_at) and is_nil(r.run_code_public_key),
          select: r.id
        )
      )

    ids
  end

  # hand_over/2 hands the claimed dispatch `dispatch` of the run of the queue
  # `dispatch_run` over at `now`, inside the caller's transaction, which holds both: at
  # its first `dispatched`, or at the first redemption of its run's code
  # (`Apiary.Runs.RunCode`).
  @doc false
  @spec hand_over(DispatchRun.t(), Dispatch.t(), DateTime.t()) :: :ok
  def hand_over(%DispatchRun{id: run_id}, %Dispatch{id: id}, %DateTime{} = now) do
    {1, _rows} =
      Repo.update_all(from(d in Dispatch, where: d.id == ^id),
        set: [handed_over_at: now, updated_at: now]
      )

    {1, _rows} =
      Repo.update_all(from(r in DispatchRun, where: r.id == ^run_id),
        set: [state: :handed_over, updated_at: now]
      )

    :ok
  end

  ## What dispatched and a release ask first

  # transact/5 is the transaction of the moduledoc's five first steps, then `fun` on what
  # they hold, for the action `action` of the key `key_id` on the dispatch `dispatch_id`;
  # the release shares it (`Apiary.Dispatches.Release`). `hold`, when given, is called
  # once the action was asked and before the slots due are freed, on the dispatch's run of
  # the queue read without a lock, for its columns that never change (its step, its work
  # item, its take in, its collection and its pool): what it locks comes first, and what
  # it answers is `held` in what `fun` is given. `fun` answers `{:done, value, changed}`,
  # committed; `{:refused, reason}` or `{:ended, changed}`, committed, as a refusal; or
  # `{:error, :unavailable}`, rolled back. An exception rolls it back and is
  # `{:error, :unavailable}`: only a failure here is answered so, as what follows the
  # commit never fails the answer.
  @doc false
  @spec transact(String.t(), String.t(), atom, (DispatchRun.t() -> term) | nil, (map -> term)) ::
          {:ok, {:done, term, [Ecto.UUID.t()]} | {:refused, refusal, [Ecto.UUID.t()]}}
          | {:error, refusal}
  def transact(key_id, dispatch_id, action, hold, fun) do
    Repo.transact(fn ->
      with {:ok, key} <- Dispatches.current_key(key_id),
           {:ok, dispatch} <- dispatch_of(key, dispatch_id, action) do
        held = hold(hold, dispatch)
        freed = Slots.free({:runs, [dispatch.dispatch_run_id]}, Dispatches.now())
        dispatch_run = RunEnd.lock(dispatch.dispatch_run_id)

        dispatch =
          Repo.one!(from d in Dispatch, where: d.id == ^dispatch.id, lock: "FOR UPDATE")

        locked = %{
          key: key,
          dispatch: dispatch,
          run: dispatch_run,
          held: held,
          now: Dispatches.now()
        }

        case fun.(locked) do
          {:done, value, changed} -> {:ok, {:done, value, freed ++ changed}}
          {:ended, changed} -> {:ok, {:refused, :gone, freed ++ changed}}
          {:refused, reason} -> {:ok, {:refused, reason, freed}}
          {:error, :unavailable} = error -> error
        end
      end
    end)
  rescue
    exception -> unavailable(@failed[action], exception)
  end

  # What `hold` locks, on the dispatch's run of the queue read without a lock: only the
  # columns a run of the queue never changes are read from it.
  defp hold(nil, _dispatch), do: nil

  defp hold(hold, %Dispatch{dispatch_run_id: id}) do
    hold.(
      Repo.one!(
        from r in DispatchRun,
          where: r.id == ^id,
          select:
            struct(r, [
              :id,
              :workspace_id,
              :step,
              :work_item_id,
              :take_in,
              :source_collection_id,
              :pool_id
            ])
      )
    )
  end

  # answered/1 is what a transaction of `transact/5` answers, once committed: the value,
  # or the refusal; the workspaces whose queue or slots changed are told first.
  @doc false
  @spec answered({:ok, tuple} | {:error, refusal}) :: term
  def answered({:ok, {:done, value, changed}}) do
    broadcast(changed)
    value
  end

  def answered({:ok, {:refused, reason, changed}}) do
    broadcast(changed)
    {:error, reason}
  end

  def answered({:error, _reason} = error), do: error

  # The dispatch by its public id, unlocked, when the key may take `action` on it: one
  # answer for an unknown one, another pool's and a refusal.
  defp dispatch_of(key, dispatch_id, action) do
    scope = Scope.for_access_key(key)

    with %Dispatch{} = dispatch <- Repo.get_by(Dispatch, public_id: dispatch_id),
         :ok <- Access.authorize(scope, action, dispatch) do
      {:ok, dispatch}
    else
      _unknown_or_refused -> {:error, :forbidden}
    end
  end

  # not_ended/1: a dispatch that ended, or of a run that ended, is gone.
  @doc false
  @spec not_ended(map) :: :ok | {:refused, :gone}
  def not_ended(%{dispatch: %Dispatch{ended_at: %DateTime{}}}), do: {:refused, :gone}
  def not_ended(%{run: %DispatchRun{state: :ended}}), do: {:refused, :gone}
  def not_ended(_locked), do: :ok

  # lease_held/1: stale, or past its lease and not yet swept, is lapsed either way.
  @doc false
  @spec lease_held(map) :: :ok | {:refused, :lease_expired}
  def lease_held(%{dispatch: %Dispatch{stale_at: %DateTime{}}}), do: {:refused, :lease_expired}

  def lease_held(%{dispatch: %Dispatch{lease_until: lease_until}, now: now}) do
    if DateTime.compare(now, lease_until) == :lt, do: :ok, else: {:refused, :lease_expired}
  end

  ## Dispatched

  # A dispatch handed over keeps no lease: its first `dispatched` is recorded, and a
  # later one changes nothing, whatever the clock.
  defp record_dispatched(%{dispatch: %Dispatch{handed_over_at: %DateTime{}}} = locked, external) do
    if is_nil(locked.dispatch.dispatched_at), do: set_dispatched(locked, external)
    {:done, :ok, []}
  end

  # The first `dispatched` of a claimed dispatch, within its lease, hands it over.
  defp record_dispatched(locked, external) do
    with :ok <- lease_held(locked) do
      set_dispatched(locked, external)
      :ok = hand_over(locked.run, locked.dispatch, locked.now)
      {:done, :ok, [locked.dispatch.workspace_id]}
    end
  end

  defp set_dispatched(%{dispatch: dispatch, now: now}, external) do
    external =
      case external do
        %{type: type, ref: ref, url: url} ->
          [external_type: type, external_ref: ref, external_url: url]

        nil ->
          []
      end

    {1, _rows} =
      Repo.update_all(from(d in Dispatch, where: d.id == ^dispatch.id),
        set: [dispatched_at: now, updated_at: now] ++ external
      )
  end

  ## At the claim

  # gateway/1 is the gateway the choice of `pool`, the claiming key's node pool, resolves
  # to now (`Apiary.Gateways.resolve/1`), read `FOR SHARE` as its deletion holds it
  # `FOR UPDATE`, with its workspace and its active keys, at most two, oldest first; or
  # `{:error, :no_gateway}`: the choice is direct, no default gateway resolves, a named
  # gateway may not serve the workspace, or the gateway has no active key. Inside the
  # claim's transaction.
  @doc false
  @spec gateway(Node.t()) ::
          {:ok, {Node.t(), Workspace.t()}, [AccessKey.t()]} | {:error, :no_gateway}
  def gateway(%Node{} = pool) do
    workspace = Repo.get!(Workspace, pool.workspace_id)

    with {:gateway, %Node{id: id}} <- Gateways.resolve(%{pool | workspace: workspace}),
         %Node{} = gateway <- Repo.one(from n in Node, where: n.id == ^id, lock: "FOR SHARE"),
         true <- Gateways.may_serve?(gateway, workspace),
         [_ | _] = keys <- AccessKeys.active_keys(gateway) do
      {:ok, {gateway, workspace}, Enum.take(keys, 2)}
    else
      _direct_or_none -> {:error, :no_gateway}
    end
  end

  # A run formed with a model provider, with the features under which it is given its
  # credential (`Apiary.Runs.ProviderCredential.applies?/0`), ends `secrets_not_allowed`
  # when one of `keys`, the gateway's keys its run key lists, was made without
  # `allow_secrets`, as either key may attach the run; or when the provider's key may not
  # be sealed for the gateway's organisation.
  defp sealable(
         {:ok, %{settings: %{columns: %{provider_chain: chain}}}} = ok,
         %Node{organisation_id: gateway_organisation_id},
         %Workspace{organisation_id: organisation_id},
         keys
       ) do
    cond do
      not ProviderCredential.applies?() -> ok
      not Enum.all?(keys, & &1.allow_secrets) -> {:end, :secrets_not_allowed}
      ProviderCredential.sealable_to?(chain, gateway_organisation_id, organisation_id) -> ok
      true -> {:end, :secrets_not_allowed}
    end
  end

  defp sealable(formed, _gateway, _workspace, _keys), do: formed

  # What the run is formed from, or the cause its run of the queue ends for.
  defp formed(%{run: %DispatchRun{step: @prebuild} = dispatch_run}, workspace) do
    case collection(dispatch_run) do
      {:ok, target} ->
        formed(dispatch_run, workspace, target, nil, nil, nil, fn _domain ->
          {:ok, Inputs.prebuild(dispatch_run.environment_ref)}
        end)

      :ended ->
        {:end, :collection_ended}
    end
  end

  # An explore run has its work item's target, nil for none; a work item without one in
  # a domain that requires a target ends `inputs_invalid`. Its run settings come next
  # (`Apiary.Dispatches.RunSettings`), which can end it with one of the causes
  # `RunSettings.causes/0` lists, or refuse the claim. The run's documents and the input
  # get the same target and the same domain, and the input the bytes of the documents'
  # limit that the rest of the documents leave.
  defp formed(%{run: %DispatchRun{} = dispatch_run, held: held} = locked, workspace) do
    work_item = Repo.get!(WorkItem, dispatch_run.work_item_id)
    target = target(work_item)
    stack = stack(locked.key, workspace, target)

    with false <- is_nil(target) and Domain.target_required?(workspace),
         {:ok, settings} <- RunSettings.build(held) do
      formed(dispatch_run, workspace, target, work_item, settings, stack, fn domain ->
        rest = %{
          dispatch_run: dispatch_run,
          documents_limit: locked.documents_limit,
          domain: domain,
          target: target,
          work_item: work_item,
          run_settings: settings && settings.wire,
          stack: stack
        }

        Inputs.explore(work_item, dispatch_run, %{domain: domain, target: target}, budget(rest))
      end)
    else
      true -> {:end, :inputs_invalid}
      {:end, _cause} = ended -> ended
      :unavailable -> :unavailable
      :unstable -> :unstable
    end
  end

  # The bytes of the documents' limit that the rest of the run's documents leave its
  # input: the limit less the documents encoded with an empty input.
  defp budget(%{dispatch_run: dispatch_run, documents_limit: limit} = rest) do
    empty =
      rest
      |> Map.merge(%{step: dispatch_run.step, inputs: Jason.OrderedObject.new([])})
      |> DispatchAnswer.documents()
      |> Jason.encode!()

    max(limit - (byte_size(empty) - 2), 1)
  end

  # answer_limit/0 is the most bytes the 201 to a run code's redemption takes, encoded:
  # 1 MiB. A test sets `config :apiary, Apiary.Dispatches.Handover, answer_limit: bytes`
  # (`Application.put_env/3`, in a module that is not async), to see the input cut.
  defp answer_limit do
    :apiary
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:answer_limit, @answer_bytes)
  end

  # The stack, the workflow and `harness_hidden` of an explore run of `workspace`, the
  # key's workspace, in the key's organisation, at `target` (`Apiary.Stacks.for_run/3`);
  # nil for none.
  defp stack(%AccessKey{organisation: organisation}, %Workspace{} = workspace, target),
    do: Stacks.for_run(organisation, workspace, target)

  # `target` is nil for a run without one: no run variables, labels or further paths.
  # `inputs` is given the name of the workspace's domain.
  defp formed(dispatch_run, workspace, target, work_item, settings, stack, inputs) do
    picked = further_repositories(workspace, target)
    domain = Domain.name(workspace)

    with {:variables, {:ok, variables}} <-
           {:variables, Domain.run_variables(workspace, target, picked)},
         {:inputs, {:ok, inputs}} <- {:inputs, inputs.(domain)} do
      about = about(dispatch_run, work_item)
      :ok = About.validate(about)

      {:ok,
       %{
         labels: labels(workspace, target, variables),
         about: about,
         variables: variables,
         workspace: workspace,
         settings: settings,
         answer: %{
           dispatch_run: dispatch_run,
           step: dispatch_run.step,
           domain: domain,
           target: target,
           work_item: work_item,
           run_settings: settings && settings.wire,
           stack: stack,
           inputs: inputs
         }
       }}
    else
      {:variables, {:error, _rule}} -> {:end, :variables_invalid}
      {:inputs, {:error, :answer_too_large}} -> :unavailable
      {:inputs, {:error, cause}} -> {:end, cause}
    end
  end

  # A work item's target, or nil for one without.
  defp target(%WorkItem{target_system: nil}), do: nil

  defp target(%WorkItem{target_system: system, target_path: path}),
    do: %{system: system, path: path}

  # The run's labels: the target's (`Apiary.Lingo.Domain.target_labels/1`) and, where the
  # domain has one and gives run variables, the label of the run's paths
  # (`Apiary.Lingo.Domain.paths_label/1`), whose value is the run variables'
  # QORY_RUN_REPOSITORIES, the same list in the same order. None without a target.
  defp labels(_workspace, nil, _variables), do: %{}

  defp labels(workspace, target, variables) do
    labels = Map.new(Enum.zip(Domain.target_labels(workspace), [target.system, target.path]))

    case {Domain.paths_label(workspace), variables} do
      {nil, _variables} -> labels
      {_key, nil} -> labels
      {key, variables} -> Map.put(labels, key, RunVariables.repositories(variables))
    end
  end

  # The further paths the run's target's runs also read, in order
  # (`Apiary.Targets.further_repositories/1`), read without a lock: none where the
  # workspace has no target of that system and path yet, where the run has no target, or
  # where the workspace's domain has no label for them (`Apiary.Lingo.Domain.paths_label/1`).
  defp further_repositories(_workspace, nil), do: []

  defp further_repositories(
         %Workspace{id: workspace_id, organisation_id: organisation_id} = workspace,
         %{system: system, path: path}
       ) do
    found =
      Repo.one(
        from t in Target,
          where: t.organisation_id == ^organisation_id and t.workspace_id == ^workspace_id,
          where: t.system == ^system and t.path == ^path
      )

    if found && Domain.paths_label(workspace),
      do: Targets.further_repositories(found),
      else: []
  end

  # A prebuild's collection's target, while the collection is live, assigned to the run's
  # workspace and has a target: its assignment, its workspace, its end and its target,
  # read without a lock. Its Backlog switch and whether it has items are not read: neither
  # ends a prebuild.
  defp collection(%DispatchRun{source_collection_id: id, workspace_id: workspace_id}) do
    found =
      Repo.one(
        from c in Collection,
          where: c.id == ^id,
          select: %{
            ended_at: c.ended_at,
            workspace_id: c.workspace_id,
            system: c.target_system,
            path: c.target_path
          }
      )

    case found do
      %{ended_at: nil, workspace_id: ^workspace_id, system: system, path: path}
      when is_binary(system) and is_binary(path) ->
        {:ok, %{system: system, path: path}}

      _ended_moved_or_without_target ->
        :ended
    end
  end

  # The step, and for an explore run its work item by its public id: nothing of its
  # ticket's text.
  defp about(%DispatchRun{step: step}, nil), do: %{"kind" => step}

  defp about(%DispatchRun{step: step}, %WorkItem{public_id: public_id}),
    do: %{"kind" => step, "subjects" => [%{"type" => "work_item", "ref" => public_id}]}

  # end_claimed/3 ends the run of the queue, claimed, and its dispatch with `cause`; a
  # stale dispatch of it `run_ended`; the slot freed once. A run that is not a prebuild,
  # ended because the claim could not form it, gave an error, stored in the same
  # write (`Apiary.Dispatches.Settle`). The workspaces whose queue or slots changed.
  # Inside the transaction that holds the run of the queue.
  @doc false
  @spec end_claimed(DispatchRun.t(), atom, DateTime.t()) :: [Ecto.UUID.t()]
  def end_claimed(%DispatchRun{id: id, workspace_id: workspace_id} = run, cause, now) do
    {1, _rows} =
      Repo.update_all(from(r in DispatchRun, where: r.id == ^id),
        set: [state: :ended, end_cause: cause, updated_at: now] ++ gave(run, cause)
      )

    {_count, _rows} =
      Repo.update_all(
        from(d in Dispatch,
          where: d.dispatch_run_id == ^id,
          where: is_nil(d.ended_at) and is_nil(d.stale_at) and is_nil(d.handed_over_at)
        ),
        set: [ended_at: now, end_cause: cause, updated_at: now]
      )

    {_count, _rows} =
      Repo.update_all(
        from(d in Dispatch,
          where: d.dispatch_run_id == ^id,
          where: is_nil(d.ended_at) and not is_nil(d.stale_at)
        ),
        set: [ended_at: now, end_cause: :run_ended, updated_at: now]
      )

    [workspace_id | Slots.free({:runs, [id]}, now)]
  end

  defp gave(%DispatchRun{step: step}, cause)
       when step != @prebuild and cause in @unformed,
       do: [result_outcome: :error]

  defp gave(%DispatchRun{}, _cause), do: []

  # The registered run, pending, with its run code, and, for an explore run, the image the
  # claim read for it (`Apiary.Environments.claim_image/2`), nil for the pool's default.
  defp insert_run(%{key: key, run: dispatch_run, now: now, body: body} = locked, formed, through) do
    %Run{
      public_id: Run.new_public_id(),
      organisation_id: key.organisation_id,
      workspace_id: key.workspace_id,
      node_run_id: dispatch_run.run_id,
      access_key_id: key.id,
      state: "pending",
      registered_at: now,
      registration_labels: formed.labels,
      registration_about: formed.about,
      registration_digest: :crypto.hash(:sha256, body),
      registration_variables: formed.variables,
      run_settings: formed.settings && formed.settings.stored,
      projected_sequence: Run.projected_from(%{registered_at: now}),
      dispatch_run_id: dispatch_run.id,
      configured_image: Map.get(locked, :image),
      inserted_at: now,
      updated_at: now
    }
    |> struct!(Nodes.placement(key.node, dispatch_run.run_id))
    |> struct!(through)
    |> struct!((formed.settings && formed.settings.columns) || %{})
    |> PublicId.Insert.insert!()
  end

  defp unavailable(what, exception) do
    Logger.error("#{what}: #{inspect(exception.__struct__)}")
    {:error, :unavailable}
  end

  # Bookkeeping after the commit: it never fails the answer. A failure is logged by its
  # module, or its kind, alone.
  defp broadcast(workspace_ids) do
    Dispatches.broadcast(workspace_ids)
  rescue
    exception -> not_told(exception)
  catch
    kind, _reason -> not_told(kind)
  end

  # broadcast_run/1 broadcasts the run an answer carries as changed: bookkeeping after
  # the commit, which never fails the answer. A failure is logged by its module, or its
  # kind, alone. An answer with no run is given back as it is.
  @doc false
  @spec broadcast_run(term) :: term
  def broadcast_run({:ok, %{run: %Run{} = run}} = handed_over) do
    Runs.broadcast_changed(run)
    handed_over
  rescue
    exception ->
      not_told(exception)
      handed_over
  catch
    kind, _reason ->
      not_told(kind)
      handed_over
  end

  def broadcast_run(refused), do: refused

  defp not_told(%{__struct__: module}), do: not_told(module)
  defp not_told(what), do: Logger.error("a change could not be told: #{inspect(what)}")
end
