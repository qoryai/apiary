defmodule Apiary.Dispatches.Handover do
  @moduledoc false

  # A node pool's starter on a dispatch its pool claimed (the provisioner contract,
  # `contracts/provisioner/v1`): `dispatched/3`, the starter started the job for it
  # (`dispatched.schema.json`), and `handover/3`, the job asks for its run key and its
  # input (`handover.schema.json`). `Apiary.Dispatches` delegates both here.
  #
  # ## What both ask first
  #
  # A `dispatch_id` not of a dispatch's shape is `{:error, :forbidden}`, looked up nowhere.
  # Then, in one transaction:
  #
  #   1. the key read again as a request's verification reads it
  #      (`Apiary.Dispatches.current_key/1`): revoked, of a pool deleted, or of a place out
  #      of use since, `{:error, :unauthorized}`;
  #   2. the dispatch by its public id, read without a lock, and the action,
  #      `dispatch.dispatched` or `dispatch.handover`, asked of it (`Apiary.Access`): an
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
  # (`Apiary.Dispatches.Release`). So does a prebuilt, which holds a prebuild's
  # environment record (`Apiary.Dispatches.Prebuilt`).
  #
  # ## `dispatched/3`
  #
  # Then a dispatch that was not handed over and whose lease lapsed, `stale_at` set or the
  # clock at or past `lease_until`, is `{:error, :lease_expired}`. Else it is `:ok`: the
  # first `dispatched` sets `dispatched_at` and the job's `external_*`, when the body names
  # it; a later one changes nothing.
  #
  # ## `handover/3`
  #
  # After the five above, the first of these that applies:
  #
  #   6. the run was handed over before, through this dispatch or another: `{:error,
  #      :handed_over}`;
  #   7. the dispatch is stale, or the clock is at or past its `lease_until`:
  #      `{:error, :lease_expired}`;
  #   8. the starter has not said `dispatched`: `{:error, :not_dispatched}`;
  #   9. the pool's choice of gateway, as it resolves now (`Apiary.Gateways.resolve/1`),
  #      leads to no gateway: direct, no default gateway, a named gateway that may not
  #      serve the workspace, or a gateway with no active key; or the gateway, read
  #      `FOR SHARE` as its deletion holds it `FOR UPDATE`, may no longer serve the
  #      workspace: `{:error, :no_gateway}`. The dispatch stays claimed;
  #   10. what the run is formed from, which the handover cannot form: the run of the
  #       queue and its dispatch end, in the transaction, with a cause the run of the queue
  #       keeps, a stale dispatch of it `run_ended`, and the slot the dispatch took is freed
  #       once; `{:error, :gone}`, so the starter stops the job it started. A prebuild whose
  #       collection ended, is assigned to no workspace or another one, or has no target
  #       ends `collection_ended`: its assignment, its workspace, its end and its target are
  #       read, never its Backlog switch or whether it has items. Run variables of the
  #       target, and of the further paths its runs also read where the workspace's
  #       domain has a label for them (`Apiary.Targets.further_repositories/1`), that
  #       break the domain's rules (`Apiary.Lingo.Domain.run_variables/3`) end it
  #       `variables_invalid`; an explore run whose work item's ticket is no longer kept,
  #       `ticket_gone`; one whose input cannot be formed (`Apiary.Dispatches.Inputs`),
  #       or whose work item has no target in a domain that requires one
  #       (`Apiary.Lingo.Domain.target_required?/1`), `inputs_invalid`; an explore run
  #       whose model choice cannot be formed (`Apiary.Dispatches.RunSettings`):
  #       `provider_gone`, `runtime_unserved`, `key_gone` or `model_gone`; and, checked
  #       last, with the features `factory` and `secrets` on, an explore run whose model
  #       choice has a provider, while one of the gateway's active keys the run key lists
  #       was made without the stored-secrets flag (`allow_secrets`), or the provider's
  #       key may not be sealed for a gateway of the gateway's organisation
  #       (`Apiary.Runs.ProviderCredential.sealable_to?/3`): `secrets_not_allowed`, as
  #       such a gateway never receives the run's model key, and the run never starts on
  #       a model nobody chose;
  #   11. the run key cannot be made for the gateway's address
  #       (`Apiary.Runs.Registration.issue_through/5`), the run settings take more than 64
  #       KiB, the answer takes more than 1 MiB with every comment left out of its input,
  #       or anything else fails: `{:error, :unavailable}`, and the transaction rolls
  #       back: no run, no run key, the dispatch as it was.
  #
  # Else the run is registered, as a registration through the gateway by the pool:
  # `pending`, its `node_run_id` the run's `run_id`, on the pool, its instance the run's
  # `run_id` too, under the pool's key, its labels the target's
  # (`Apiary.Lingo.Domain.target_labels/1`) and, where the domain has one and gives the
  # run variables, the label of its paths (`Apiary.Lingo.Domain.paths_label/1`) with its
  # QORY_RUN_REPOSITORIES as the value, `about` the step and, for an explore run, its
  # work item, its run variables (`registration_variables`), none where the domain gives
  # none, its registration digest the
  # SHA-256 of the handover's body, with no heartbeat interval, no answer digest and no
  # contract version until its attach; with the gateway, its run key's payload and
  # signature, when the run key was made and the end of its attach window, 600 seconds
  # after (`Apiary.Runs.Registration.attach_window/1`). Its run key's instance id is the
  # run's id. The dispatch is handed over at the clock, before its `lease_until`, the run
  # of the queue `handed_over`, and the slot stays held: the run counts toward its pool's
  # limit by its dispatch, never as an instance (`Apiary.Nodes.instances_in_use/2`). The
  # action is recorded in the audit trail, about the registered run, with the dispatch's
  # public id and the step. The registration, the run key and the handover are one write:
  # of two handovers of one run, the second waits at the run of the queue, then finds it
  # handed over.
  #
  # The answer has the name of the workspace's domain (`Apiary.Lingo.Domain.name/1`) and
  # the run's target, or no target for an explore run whose work item has none. An explore
  # run's input has the same domain and the same target, from the same values.
  #
  # An explore run has `run_settings` with the features `factory` and `secrets` on
  # (`Apiary.Dispatches.RunSettings`), and keeps them on its registered run, with the
  # provider's row id, its keys' secret's row id, the chosen key's value id, the
  # provider's chain and the API of the provider the run uses; later reads take those,
  # never the choices. The answer, encoded, takes
  # at most 1 MiB: the input is given what the rest of the answer leaves, measured with a
  # run key of the longest length the contract allows, and leaves out its oldest comments
  # first (`comments_omitted`).
  #
  # A refusal commits what the lapse of step 3 wrote, and an end what it ended. Once the
  # transaction commits, the run is broadcast as changed and the workspaces whose queue or
  # slots changed are told. An exception in the transaction rolls it back, is logged by
  # its module alone, never the key, the body or the input, and is
  # `{:error, :unavailable}`. The broadcast and the telling, after the commit, never change
  # the answer: a failure of either is logged by its module, or its kind, alone.
  #
  # Locks, in the order `Apiary.Dispatches.Slots` gives, after those of an explore run's
  # model providers: the rows of the model providers its choices name `FOR SHARE`, then
  # the rows of their keys' secrets `FOR SHARE` (`Apiary.Dispatches.RunSettings`), taken
  # before anything else, then the environment records a lapse needs, the run of the
  # queue, the dispatch, the gateway's row `FOR SHARE`, then the registered run,
  # inserted. Nothing else is locked: not the pool, its connection, its collection, the
  # work item or the workspace.

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Apiary.{
    Access,
    AccessKeys,
    Audit,
    Dispatches,
    Gateways,
    Nodes,
    PublicId,
    Repo,
    Runs,
    Targets
  }

  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.Collection
  alias Apiary.Dispatches.{Dispatch, DispatchRun, Inputs, RunEnd, RunSettings, Slots}
  alias Apiary.Lingo.Domain
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Workspace
  alias Apiary.Runs.{About, ProviderCredential, Registration, Run, RunVariables, Target}
  alias Apiary.WorkItems.WorkItem
  alias ApiaryWeb.Contract.DispatchAnswer

  @prebuild DispatchRun.prebuild()
  # The causes a claimed run ends for when its handover cannot form what it is made from.
  @unformed [:variables_invalid, :ticket_gone, :inputs_invalid] ++
              RunSettings.causes() ++ [:secrets_not_allowed]
  # What the log says when an action's transaction fails.
  @failed %{
    "dispatch.dispatched": "a dispatched could not be recorded",
    "dispatch.handover": "a handover could not be made",
    "dispatch.release": "a release could not be made",
    "dispatch.prebuilt": "a prebuilt could not be recorded"
  }
  # The attach window of a run registered by its handover, in seconds.
  @attach_seconds 600
  # The most bytes the handover answer takes, encoded: 1 MiB, the provisioner contract's.
  @answer_bytes 1_048_576
  # The revision of the provisioner contract the answer is built for, and the longest run
  # key (`handover-answer.schema.json`), by which the answer is measured before the run
  # key is made.
  @revision 3
  @longest_run_key "qrk_" <> String.duplicate("A", 2044)

  @typedoc """
  A handover answered: the registered run, its run key, the run of the queue, the name of
  its workspace's domain, the run's target (nil for an explore run without one), its work
  item (nil for a prebuild), its run settings (nil for none,
  `Apiary.Dispatches.RunSettings`) and the step's input.
  """
  @type handed_over :: %{
          run: Run.t(),
          run_key: String.t(),
          dispatch_run: DispatchRun.t(),
          domain: String.t(),
          target: %{system: String.t(), path: String.t()} | nil,
          work_item: WorkItem.t() | nil,
          run_settings: Jason.OrderedObject.t() | nil,
          inputs: Jason.OrderedObject.t()
        }

  @type refusal ::
          :unauthorized
          | :forbidden
          | :gone
          | :handed_over
          | :lease_expired
          | :not_dispatched
          | :no_gateway
          | :unavailable

  # unformed/0 is every cause a claimed run ends for when its handover cannot form what
  # it is made from, each with the outcome `error` on a run that is not a prebuild.
  @doc false
  @spec unformed() :: [atom]
  def unformed, do: @unformed

  # dispatched/3 records that the starter started the job for the dispatch `dispatch_id`
  # of the pool of `access_key`, with the job's `external` (nil for none): the moduledoc.
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

  # handover/3 hands the run of the dispatch `dispatch_id` of the pool of `access_key`
  # over, for the handover's raw `body`: the moduledoc.
  @doc false
  @spec handover(AccessKey.t(), term, %{body: binary}) ::
          {:ok, handed_over} | {:error, refusal}
  def handover(%AccessKey{key_id: key_id}, dispatch_id, %{body: body}) when is_binary(body) do
    if Dispatch.public_id?(dispatch_id) do
      key_id
      |> transact(dispatch_id, :"dispatch.handover", &RunSettings.hold/1, fn locked ->
        with :ok <- not_ended(locked),
             :ok <- not_handed_over(locked),
             :ok <- lease_held(locked),
             :ok <- was_dispatched(locked),
             {:ok, gateway, keys} <- gateway(locked) do
          hand_over(locked, gateway, keys, body)
        end
      end)
      |> answered()
      |> broadcast_run()
    else
      {:error, :forbidden}
    end
  end

  ## What both ask first

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

  # A dispatch handed over keeps its lease no more: its `dispatched` changes nothing.
  defp record_dispatched(%{dispatch: %Dispatch{handed_over_at: %DateTime{}}}, _external),
    do: {:done, :ok, []}

  defp record_dispatched(locked, external) do
    with :ok <- lease_held(locked) do
      if is_nil(locked.dispatch.dispatched_at), do: set_dispatched(locked, external)
      {:done, :ok, []}
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

  ## Handover

  defp not_handed_over(%{run: %DispatchRun{state: :handed_over}}), do: {:refused, :handed_over}
  defp not_handed_over(_locked), do: :ok

  defp was_dispatched(%{dispatch: %Dispatch{dispatched_at: nil}}), do: {:refused, :not_dispatched}
  defp was_dispatched(_locked), do: :ok

  # The gateway the pool's choice resolves to now, read `FOR SHARE`, with its active keys,
  # at most two, oldest first.
  defp gateway(%{key: %AccessKey{node: %Node{} = pool}}) do
    workspace = Repo.get!(Workspace, pool.workspace_id)

    with {:gateway, %Node{id: id}} <- Gateways.resolve(%{pool | workspace: workspace}),
         %Node{} = gateway <- Repo.one(from n in Node, where: n.id == ^id, lock: "FOR SHARE"),
         true <- Gateways.may_serve?(gateway, workspace),
         [_ | _] = keys <- AccessKeys.active_keys(gateway) do
      {:ok, {gateway, workspace}, Enum.take(keys, 2)}
    else
      _direct_or_none -> {:refused, :no_gateway}
    end
  end

  defp hand_over(locked, {gateway, workspace}, keys, body) do
    case locked |> formed(workspace) |> sealable(gateway, workspace, keys) do
      {:end, cause} ->
        {:ended, end_claimed(locked.run, cause, locked.now)}

      :unavailable ->
        Logger.error("a handover could not be made: the answer does not fit its limit")
        {:error, :unavailable}

      :unstable ->
        Logger.error(
          "a handover could not be made: the run's model choices changed while the handover read them"
        )

        {:error, :unavailable}

      {:ok, formed} ->
        pool = locked.key.node

        grant = %{
          run_id: locked.run.run_id,
          workspace: workspace.public_id,
          node_id: pool.public_id,
          instance_id: locked.run.run_id
        }

        with {:ok, %{run_key: run_key, through: through}} <-
               Registration.issue_through(gateway, keys, grant, locked.now, @attach_seconds) do
          run = register(locked, formed, through, body)
          {:done, {:ok, Map.merge(formed.answer, %{run: run, run_key: run_key})}, []}
        end
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
        formed(dispatch_run, workspace, target, nil, nil, fn _domain ->
          {:ok, Inputs.prebuild(dispatch_run.environment_ref)}
        end)

      :ended ->
        {:end, :collection_ended}
    end
  end

  # An explore run has its work item's target, nil for none; a work item without one in
  # a domain that requires a target ends `inputs_invalid`. Its run settings come next
  # (`Apiary.Dispatches.RunSettings`), which can end it with one of the causes
  # `RunSettings.causes/0` lists, or refuse the handover. The answer and the input get the same target and the same domain, and the
  # input the bytes of the answer's limit that the rest of the answer leaves.
  defp formed(%{run: %DispatchRun{} = dispatch_run, held: held}, workspace) do
    work_item = Repo.get!(WorkItem, dispatch_run.work_item_id)
    target = target(work_item)

    with false <- is_nil(target) and Domain.target_required?(workspace),
         {:ok, settings} <- RunSettings.build(held) do
      formed(dispatch_run, workspace, target, work_item, settings, fn domain ->
        rest = %{
          dispatch_run: dispatch_run,
          domain: domain,
          target: target,
          work_item: work_item,
          run_settings: settings && settings.wire
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

  # The bytes of `answer_limit/0` that the answer leaves its input: the limit less the
  # answer encoded with an empty input and the longest run key, which the contract allows.
  defp budget(%{dispatch_run: dispatch_run} = rest) do
    empty =
      DispatchAnswer.handover_body(%{
        revision: @revision,
        run_id: dispatch_run.run_id,
        run_key: @longest_run_key,
        step: dispatch_run.step,
        domain: rest.domain,
        target: rest.target,
        work_item: rest.work_item,
        run_settings: rest.run_settings,
        inputs: Jason.OrderedObject.new([])
      })

    max(answer_limit() - (byte_size(empty) - 2), 1)
  end

  # answer_limit/0 is the most bytes the answer takes, encoded: 1 MiB. A test sets
  # `config :apiary, Apiary.Dispatches.Handover, answer_limit: bytes`
  # (`Application.put_env/3`, in a module that is not async), to see the input cut.
  defp answer_limit do
    :apiary
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:answer_limit, @answer_bytes)
  end

  # `target` is nil for a run without one: no run variables, labels or further paths.
  # `inputs` is given the name of the workspace's domain.
  defp formed(dispatch_run, workspace, target, work_item, settings, inputs) do
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
           domain: domain,
           target: target,
           work_item: work_item,
           run_settings: settings && settings.wire,
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
  # ended because its handover could not form it, gave an error, stored in the same
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

  # The registered run, the dispatch handed over and the audit entry: one write.
  defp register(
         %{key: key, dispatch: dispatch, run: dispatch_run, now: now},
         formed,
         through,
         body
       ) do
    run =
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
        inserted_at: now,
        updated_at: now
      }
      |> struct!(Nodes.placement(key.node, dispatch_run.run_id))
      |> struct!(through)
      |> struct!((formed.settings && formed.settings.columns) || %{})
      |> PublicId.Insert.insert!()

    {1, _rows} =
      Repo.update_all(from(d in Dispatch, where: d.id == ^dispatch.id),
        set: [handed_over_at: now, updated_at: now]
      )

    {1, _rows} =
      Repo.update_all(from(r in DispatchRun, where: r.id == ^dispatch_run.id),
        set: [state: :handed_over, updated_at: now]
      )

    {:ok, _entry} =
      Audit.record(Repo, Scope.for_access_key(key), :"dispatch.handover", run, %{
        details: %{"dispatch_id" => dispatch.public_id, "step" => dispatch_run.step}
      })

    run
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
