defmodule Apiary.Dispatches.RunSettings do
  @moduledoc false

  # The `run_settings` of a run's documents and the values a run keeps of them
  # (`Apiary.Runs.Run`): what the model choices of the run's workspace and target come to
  # (`Apiary.ModelChoices.Resolution`), checked again at the claim. The choices and the
  # time limits are read for the run's workflow (`Apiary.Stacks.workflow/2`, or, with the
  # workflow model, the workflow of the run's stage entry, `Apiary.Stages.run_workflow/1`);
  # for a run with no workflow, only the choices without one apply.
  # The claim (`Apiary.Dispatches.claim/4`) locks the pool's row, the gateway's row, the
  # records a lapse needs (`Apiary.Dispatches.Slots`), the run of the queue it took and the
  # dispatch it inserted, in that order; then `Apiary.Dispatches.Handover.register/2` calls
  # `hold/1`, and `build/1` with what `hold/1` returned.
  #
  # Every run of the step `explore`, the runs of the stage runner among them, has
  # `run_settings`, whatever the features; a prebuild has none. The choice in effect is the
  # first in the order of `Apiary.ModelChoices.Resolution`: a locked choice of the
  # workspace, then the workflow's at the target (level 2), the target's (3), the
  # workflow's at the workspace (4), the workspace's (5) and the organisation's default
  # (6). With no choice at any level, the run has `runtime` alone, the catalogue's default
  # (`Apiary.ModelChoices.default_runtime/0`), and the run uses the gateway's key. With a
  # choice, `runtime` is the runtime the choice resolves to, with its model.
  #
  # The run is given its provider's key only with both features `factory` and `secrets`
  # on (`Apiary.Runs.ProviderCredential.applies?/0`). With either off, the run still gets
  # the choice's runtime, model, effort, `provider_models` and `tiers`, and no key: the
  # claim checks no key and no endpoint (no `key_gone`), keeps no provider column and no
  # key on the run, and waits for no key; the run uses the gateway's key.
  # `time_limit_minutes` needs `factory`, whose pages set the time limits.
  #
  # ## What it holds
  #
  # `hold/1` reads the choices of the run's chain and their fallbacks without a lock, and
  # for a run of a stage with `shared_run: true` the choices for each workflow of the
  # stage (`Apiary.Stages.shared_workflows/1`), the models of its later sessions. It locks
  # the rows of the model providers they name, as a provider or a fallback, `FOR SHARE`,
  # by id, then the rows of those providers' keys' secrets `FOR SHARE`, by id, and reads
  # the choices again. Each read that names a
  # provider not yet locked locks it the same way. It reads the choices at most four times
  # and locks at most three times: when the fourth read still names a provider not yet
  # locked, the choices changed while the claim read them (`:unstable`), and the claim is
  # refused with nothing written. A change to a provider takes its row `FOR UPDATE`, and
  # a change to its keys the keys' secret's row, in the same order, so a change and a
  # claim of its run take turns: a change waits for a claim that holds the row, and the
  # run keeps the provider as it was before the change; a change that came first is seen
  # by the claim, which reads the provider after the lock.
  #
  # ## What it checks
  #
  # `build/1` resolves the choices against the providers as they are once the rows are
  # held, and ends the run with the first cause that applies, in this order:
  #
  #   * `provider_gone`: the provider is not there, fails its integrity code
  #     (`Apiary.Connections.intact?/1`), does not apply to the workspace any more, or
  #     `Apiary.Connections.provider/1` returns an error for it: its kind is no longer
  #     in the catalogue, or its settings no longer fit the catalogue's entry. A check of
  #     its settings that ran out of time or crashed ends no run: the claim leaves the
  #     run waiting and takes the next run, and a later claim tries the run again;
  #   * `runtime_unserved`: the runtime the choice names is no longer in the catalogue
  #     (`Apiary.Kinds.Runtimes`), or no API of the provider serves the run's runtime
  #     (`Apiary.Kinds.Providers.api/2`);
  #   * `provider_gone`: the endpoint of that API is a setting whose address
  #     `Apiary.Kinds.Endpoint` refuses;
  #   * `key_gone`: the provider has no key;
  #   * `model_gone`: no model resolves: the choice maps a `thinking` tier whose entry
  #     does not go with its provider (`Apiary.ModelChoices.Resolution`), or it maps
  #     none and has no model and a provider whose description lists none; or the run's
  #     effort value is no longer among both the model's effort values in the
  #     description and the runtime's, which a model the description no longer lists has
  #     none of. A choice's `model` that the description does not list ends no run by
  #     itself.
  #
  # Then the keys, at the claim's clock (`build/2`). The run takes the provider's keys
  # where one of them is not in cooldown (`Apiary.ModelKeys`). Else it walks the later
  # steps in order and takes the first that forms as the choice's provider does above
  # and has a key not in cooldown:
  #
  #   1. under a workflow's override, the default step, with its runtime and its tiers
  #      (`Apiary.ModelChoices.Resolution`);
  #   2. the fallbacks, in their order: the default step's under an override, else the
  #      choice's; each with the fallback's runtime and tiers
  #      (`Apiary.ModelChoices.Resolution.fallback/3`). A fallback's runtime is the run's
  #      `runtime`, and its provider's API for that runtime the API of its key rows.
  #
  # A step whose provider's keys were already found in cooldown is passed over: its keys
  # are the same, so the skip only saves work and changes no result. A step that does not
  # form is passed over and ends nothing. That step's provider's keys are the group of
  # the run's default model provider credential. With none, `build/2` returns `{:cooling,
  # built, ids}`: the claim checks what can end the run first, then leaves it waiting
  # with `ids` as the providers it waits for (`Apiary.Dispatches.Handover`): the choice's
  # provider, each later step's provider that formed, and each whose settings check ran
  # out of time or crashed. The queue keeps the same providers in the same order for the
  # claim's filter (`model_providers/1`).
  #
  # A run of a stage with `shared_run: true` also takes the keys of each provider its
  # later sessions run on, one provider per session (`with_sessions/3`). The run gets at
  # most 6 keys across its providers (`merge/3`): the keys of the provider of the default
  # model provider credential, picked in the order of `Apiary.ModelKeys.Order`, the first
  # of that order being the default model provider credential, never one in cooldown; at
  # least one key of each other provider; then the rest. Each provider's keys are kept in
  # the order the run configuration sends them (`Apiary.ModelKeys.Order.sent/2`), the
  # default model provider credential marked.
  #
  # A deny rule of the security policy is not asked: it never blocks a host of an
  # integration.
  #
  # ## What it writes
  #
  # `run_settings`, in the schema's order: `runtime`, `model` and `effort`, the `thinking`
  # tier's where the choice has one, `effort` left out where there is none,
  # `provider_models` and `tiers`, a tier left out when the choice does not map it to a
  # model that goes with the provider (`Apiary.ModelChoices.Resolution`). The documents
  # have no key, no secret and no id of a key, and neither has the stored copy.
  #
  # `hold/1` also reads the time limits: `time_limit`, the minutes the time limits of the
  # run's workspace and target come to for the run's workflow
  # (`Apiary.TimeLimits.Resolution`, `Apiary.Stacks.workflow/2`), with the workflow model
  # the workflow of its stage entry (`Apiary.Stages.run_workflow/1`); 180 minutes for a
  # workflow with no limit (`Apiary.TimeLimits.default_minutes/0`), and nil when the run
  # has no workflow. The documents have it as their top-level `time_limit_minutes`, the
  # limit of the run's first session (`Apiary.Dispatches.Handover`). `time_limits` has
  # the minutes of the run's workflow and, for a run of a stage with `shared_run: true`,
  # of each workflow of that stage (`Apiary.Stages.shared_workflows/1`), which the claim
  # keeps on the run (`Apiary.Stages.claim_sessions!/3`). The process document has no
  # time limit. The workflows and the limits are read without a lock. Beside it, the run
  # keeps the row id of the provider of the default model provider credential
  # (`provider_connection_id`) and its keys (`run_model_keys`, `Apiary.Runs.ModelKey`:
  # each key's place, its row id, its credential name `<provider's public id>-<place from
  # 1>`, the place counted per provider, `start` on the default model provider
  # credential, its provider's row id, keys' secret's row id and chain, the API its
  # sessions use, with its `format`, its `endpoint` with a setting resolved to its
  # address, its `auth`, and, when the description lists them, its `key_prefixes` and its
  # limit windows as `use_up_to_windows`, and what its run configuration entry has of
  # it), for the reads that follow the claim. The run settings take at most 64 KiB
  # encoded; a claim with more fails.
  #
  # `provider_models` is the description's models (`Apiary.Connections.provider_models/1`),
  # in its order, each with the effort values that both it and the runtime have, then the
  # chosen model and each tier's model that the description does not list, each once,
  # with no effort, `model` first and then the tiers in the order of
  # `Apiary.ModelChoices.Resolution.tiers/0`. A description has
  # at most 200 models (`Apiary.Kinds.Provider.load!/1`), so the list stays within the
  # schema's 256.
  #
  # Reads, and takes the locks above; writes nothing. It logs a provider that fails its
  # integrity code, by its public id.

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Apiary.{Connections, Features, ModelChoices, ModelKeys, Repo, Stacks, TimeLimits}
  alias Apiary.Connections.Connection
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Kinds.{Endpoint, Provider, Providers, Runtime}
  alias Apiary.ModelChoices.Resolution
  alias Apiary.ModelKeys.Order
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Runs.{ProviderCredential, Target}
  alias Apiary.Secrets.{Secret, Value}
  alias Apiary.WorkItems.WorkItem

  # The step of the queue whose runs have `run_settings`.
  @step "explore"
  # The most bytes the run settings take, encoded: the column's check.
  @max_bytes 65_536
  # The most times `hold/1` locks providers: after each of the first three reads of the
  # choices. A fourth read that names a provider not yet locked is `:unstable`.
  @lock_rounds 3

  @typedoc "The causes the claim ends a run for here."
  @type cause ::
          :provider_gone
          | :runtime_unserved
          | :key_gone
          | :model_gone
          | :model_choice_missing
          | :too_many_providers
          | :session_key_missing

  @typedoc """
  What a claim writes: `wire`, the documents' `run_settings`; `stored`, the same as a
  map, for the run's column; `columns`, the run's provider column, empty where the run
  has no key; `keys`, the run's key rows (`merge/3`); and `sessions`, each later
  session's entry by its workflow (`with_sessions/3`).
  """
  @type built :: %{
          required(:wire) => Jason.OrderedObject.t(),
          required(:stored) => map,
          required(:columns) => %{optional(atom) => term},
          optional(:keys) => [map],
          optional(:sessions) => map
        }

  # max_bytes/0 is the most bytes the run settings take, encoded.
  @doc false
  @spec max_bytes() :: pos_integer
  def max_bytes, do: @max_bytes

  # causes/0 is every cause `build/1` ends a run for, and those of the claim's check of a
  # shared stage's model choices (`Apiary.Stages.shared_models/1`), which the claim runs
  # before it stores keys: `model_choice_missing`, `too_many_providers` and
  # `session_key_missing`, which `build/1` also ends a run for (`with_sessions/3`).
  @doc false
  @spec causes() :: [cause]
  def causes,
    do: [
      :provider_gone,
      :runtime_unserved,
      :key_gone,
      :model_gone,
      :model_choice_missing,
      :too_many_providers,
      :session_key_missing
    ]

  # hold/1 is what the claim of the run of the queue `dispatch_run` holds before it
  # locks anything: nil for a prebuild, which has no `run_settings`, else what `build/1`
  # takes.
  @doc false
  @spec hold(DispatchRun.t()) :: map | :unstable | nil
  def hold(%DispatchRun{step: @step, workspace_id: workspace_id, work_item_id: id} = dispatch_run) do
    workspace = Repo.get!(Workspace, workspace_id)
    organisation = Repo.get!(Organisation, workspace.organisation_id)
    target = target(workspace, id)
    workflow = workflow(dispatch_run, workspace, target)

    shared = Apiary.Stages.shared_workflows(dispatch_run)

    case lock(workspace, target, {workflow, shared}, [], @lock_rounds) do
      {:ok, input, sessions} ->
        time_limits = time_limits(workspace, target, workflow, shared)

        %{
          organisation: organisation,
          workspace: workspace,
          target: target,
          input: input,
          sessions: sessions,
          shared: shared,
          keyed: ProviderCredential.applies?(),
          time_limit: workflow && Map.get(time_limits, workflow),
          time_limits: time_limits
        }

      :unstable ->
        :unstable
    end
  end

  def hold(%DispatchRun{}), do: nil

  # choice_in_effect/1 is the model choice that a claim of the run of the queue
  # `dispatch_run` would take its provider from if it ran now
  # (`Apiary.ModelChoices.Resolution.in_effect/1`), read without a lock: `{level, choice}`,
  # or nil for none or for a run of another step.
  @doc false
  @spec choice_in_effect(DispatchRun.t()) ::
          {ModelChoices.ModelChoice.level(), ModelChoices.ModelChoice.t()} | nil
  def choice_in_effect(
        %DispatchRun{step: @step, workspace_id: workspace_id, work_item_id: id} = dispatch_run
      ) do
    workspace = Repo.get!(Workspace, workspace_id)
    target = target(workspace, id)

    Resolution.in_effect(
      ModelChoices.choices_for(workspace, target, workflow(dispatch_run, workspace, target))
    )
  end

  def choice_in_effect(%DispatchRun{}), do: nil

  # model_providers/1 is the row ids of the model providers a claim of the run of the
  # queue `dispatch_run` would try if it ran now, read without a lock, each once, in the
  # order the claim tries them: the provider of the choice in effect, the default step's
  # under a workflow's override, then the fallbacks of the choice they follow
  # (`Apiary.ModelChoices.Resolution.walk/1`); none for a run of another step. As in the
  # resolution, a default step whose provider is gone is left out with its fallbacks, and
  # so is a fallback whose provider is gone (`providers/1`).
  @doc false
  @spec model_providers(DispatchRun.t()) :: [Ecto.UUID.t()]
  def model_providers(
        %DispatchRun{step: @step, workspace_id: workspace_id, work_item_id: id} = dispatch_run
      ) do
    workspace = Repo.get!(Workspace, workspace_id)
    target = target(workspace, id)
    input = ModelChoices.choices_for(workspace, target, workflow(dispatch_run, workspace, target))
    {choices, with_fallbacks} = Resolution.walk(input)

    fallbacks =
      case with_fallbacks do
        nil ->
          []

        choice ->
          choice
          |> Repo.preload(:fallbacks)
          |> Map.fetch!(:fallbacks)
          |> Enum.sort_by(& &1.position)
      end

    present =
      present_providers(
        workspace.organisation_id,
        Enum.map(Enum.drop(choices, 1), & &1.connection_id) ++
          Enum.map(fallbacks, & &1.connection_id)
      )

    {choices, fallbacks} =
      case choices do
        [in_effect, %{connection_id: id}] when not is_map_key(present, id) -> {[in_effect], []}
        _present -> {choices, Enum.filter(fallbacks, &is_map_key(present, &1.connection_id))}
      end

    (Enum.map(choices, & &1.connection_id) ++ Enum.map(fallbacks, & &1.connection_id))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def model_providers(%DispatchRun{}), do: []

  # time_limit_minutes/2 is the minutes the time limits of the workspace and the target of
  # the run of the queue `dispatch_run` come to for `workflow`, the default for no limit,
  # read without a lock, as `hold/1` reads them; nil with `factory` off, as `hold/1`
  # reads none then.
  @doc false
  @spec time_limit_minutes(DispatchRun.t(), String.t()) :: pos_integer | nil
  def time_limit_minutes(
        %DispatchRun{workspace_id: workspace_id, work_item_id: id},
        workflow
      )
      when is_binary(workflow) do
    if Features.on?(:factory) do
      workspace = Repo.get!(Workspace, workspace_id)
      time_limit(workspace, target(workspace, id), workflow)
    end
  end

  # target_of/1 is the target row of the work item of the run of the queue `dispatch_run`
  # in its workspace, as the claim reads it; nil for none.
  @doc false
  @spec target_of(DispatchRun.t()) :: Target.t() | nil
  def target_of(%DispatchRun{workspace_id: workspace_id, work_item_id: id}),
    do: target(Repo.get!(Workspace, workspace_id), id)

  # The run's workflow: with the workflow model, the one its stage entry names
  # (`Apiary.Stages.run_workflow/1`); else the one the Harness page saved.
  defp workflow(dispatch_run, workspace, target),
    do: Apiary.Stages.run_workflow(dispatch_run) || Stacks.workflow(workspace, target)

  # The minutes of the run's workflow and of each workflow of its shared stage, by name;
  # none with `factory` off, whose pages set the time limits.
  defp time_limits(workspace, target, workflow, shared) do
    if Features.on?(:factory) do
      Map.new(
        Enum.uniq(List.wrap(workflow) ++ shared),
        &{&1, time_limit(workspace, target, &1)}
      )
    else
      %{}
    end
  end

  # The minutes the time limits come to for `workflow`, the default for no limit; nil for
  # no workflow.
  defp time_limit(_workspace, _target, nil), do: nil

  defp time_limit(%Workspace{} = workspace, target, workflow) do
    case TimeLimits.Resolution.resolve(TimeLimits.limits_for(workspace, target, workflow)) do
      {:ok, %TimeLimits.Resolution{minutes: minutes}} -> minutes
      :none -> TimeLimits.default_minutes()
    end
  end

  # The target row of the run's work item in the run's workspace, nil for a work item
  # with none or whose target no row of the workspace has.
  defp target(%Workspace{id: workspace_id, organisation_id: organisation_id}, work_item_id) do
    case Repo.one(
           from w in WorkItem,
             where: w.id == ^work_item_id,
             select: {w.target_system, w.target_path}
         ) do
      {system, path} when is_binary(system) and is_binary(path) ->
        Repo.one(
          from t in Target,
            where: t.organisation_id == ^organisation_id and t.workspace_id == ^workspace_id,
            where: t.system == ^system and t.path == ^path
        )

      _no_target ->
        nil
    end
  end

  # The choices once every provider they name is held, their fallbacks' among them, and
  # the choices for each workflow of `shared`, a later session's, with the providers they
  # name: read, lock what is new, read again. `{:ok, input, sessions}`, `sessions` the
  # input of each workflow of `shared` by its name.
  defp lock(workspace, target, {workflow, shared} = workflows, locked, tries) do
    input = with_fallbacks(ModelChoices.choices_for(workspace, target, workflow))

    sessions =
      Map.new(shared, &{&1, with_fallbacks(ModelChoices.choices_for(workspace, target, &1))})

    ids = all_provider_ids(input, sessions)

    case ids -- locked do
      [] ->
        {:ok, input, sessions}

      _new when tries == 0 ->
        :unstable

      new ->
        lock_rows(Enum.sort(new))
        lock(workspace, target, workflows, locked ++ new, tries - 1)
    end
  end

  defp with_fallbacks(input), do: %{input | choices: Repo.preload(input.choices, :fallbacks)}

  # The providers' rows `FOR SHARE`, by id, then their keys' secrets' rows. A row that is
  # gone is not locked: `build/1` reads it as gone.
  defp lock_rows(ids) do
    secret_ids =
      Repo.all(
        from c in Connection,
          where: c.id in ^ids and not is_nil(c.provider_kind),
          order_by: [asc: c.id],
          select: c.secret_id,
          lock: "FOR SHARE"
      )
      |> Enum.reject(&is_nil/1)

    Repo.all(
      from s in Secret,
        where: s.id in ^secret_ids,
        order_by: [asc: s.id],
        select: s.id,
        lock: "FOR SHARE"
    )

    :ok
  end

  # build/2 is the run settings of what `hold/1` held, for a claim at `now`: `{:ok, nil}`
  # for a run with none, `{:ok, built}`, `{:end, cause}`, `{:cooling, built, ids}` where
  # every key of the choice's provider and of each usable later step (the default step
  # and the fallbacks) is in cooldown, with the choice's settings without keys and those
  # providers' row ids, the choice's first, and those of the later steps whose settings
  # check ran out of time or crashed; `{:cooling, built, ids}` too where a later
  # session's provider has no key and the keys of each of its later steps are all in
  # cooldown, with the run's settings and those steps' providers' row ids, so the run
  # waits for them (`cooling_steps/4`); `:unstable` where the choices changed while
  # `hold/1` read them, `{:unchecked, provider}` where the check of the settings of
  # `provider`, the chosen one, ran out of time or crashed
  # (`Apiary.Connections.provider/1`), or `:unavailable` where the run settings take more
  # than 64 KiB. Each provider's description is read once, for the resolution and the
  # settings alike.
  @doc false
  @spec build(map | :unstable | nil, DateTime.t()) ::
          {:ok, built | nil}
          | {:end, cause}
          | {:cooling, built, [Ecto.UUID.t()]}
          | :unstable
          | {:unchecked, Connection.t()}
          | :unavailable
  def build(held, now \\ DateTime.utc_now())
  def build(nil, _now), do: {:ok, nil}
  def build(:unstable, _now), do: :unstable

  def build(%{} = held, %DateTime{} = now) do
    providers = providers(held)
    described = Map.new(providers, fn {id, provider} -> {id, Connections.provider(provider)} end)

    resolved_providers =
      Map.new(providers, fn {id, provider} ->
        {id, ModelChoices.resolution_provider(provider, described[id])}
      end)

    input = Map.put(held.input, :providers, resolved_providers)

    context = %{
      resolved: resolved_providers,
      providers: providers,
      described: described,
      held: held,
      now: now
    }

    case Resolution.resolve(input) do
      :none ->
        ModelChoices.default_runtime()
        |> runtime_only()
        |> sealed()
        |> with_sessions(nil, context)

      {:error, :provider_removed} ->
        {:end, :provider_gone}

      {:ok, %Resolution{} = resolution} ->
        provider = Map.fetch!(providers, resolution.connection_id)

        with {:ok, runtime} <- runtime(resolution),
             :ok <- intact(provider),
             {:ok, built} <-
               form(
                 resolution,
                 provider,
                 described[provider.id],
                 runtime,
                 held.workspace.id,
                 held.keyed
               ),
             {:ok, built, default_group} <-
               keys(
                 built,
                 provider,
                 {input, resolution, providers, described},
                 held,
                 now
               ),
             do:
               built
               |> sealed()
               |> with_sessions(default_group, context)
    end
  end

  # The model and the key of each later session of a shared run, by its workflow, as
  # `sessions` beside `built`, which the claim keeps on the run
  # (`Apiary.Stages.claim_sessions!/3`), and the run's keys, as `keys`, with the default
  # model provider credential's provider as `columns` (`merged/4`). `default_group` is the
  # group of the run's default model provider credential (`keys/5`): its provider, the API
  # its sessions use, and its keys in their order; nil for a run with no key. The workflows
  # are walked in session order (`Apiary.Stages.shared_workflows/1`). Each entry has
  # `model_choice`, which always has `runtime`, the runtime the session runs on, and, for
  # a session on a provider other than the default model provider credential's,
  # `model_provider_credential_name`, the name of that provider's first free key
  # (`Apiary.ModelKeys.Order.first_free/2`), else its first key: the session starts on that
  # key's group. A session with no `model_provider_credential_name` joins the group of the
  # run's default model provider credential.
  #
  # `model_choice` is, for the choices of the workflow (`session_choice/4`):
  #   * the `runtime`, `model`, `effort`, `provider_models` and `tiers` of the choice on
  #     its provider, where that provider has a free key; else on its first fallback
  #     that forms and has a free key (`Apiary.ModelChoices.Resolution.fallback/3`); else
  #     on its provider, whose keys are all in cooldown. A choice on the default model
  #     provider credential's provider whose runtime uses the default model provider
  #     credential's API (`format`, `endpoint` and `auth`) joins the default model
  #     provider credential's group;
  #   * the run's `run_settings`, where that choice's runtime or model is no longer valid
  #     (`form/6`), or its runtime is no longer in the catalogue;
  #   * `runtime` alone, the runtime of the choice, where the run gets no key (`keyed`
  #     false); or the catalogue's default runtime
  #     (`Apiary.ModelChoices.default_runtime/0`), where the choices resolve to no choice
  #     at any level: the session joins the group of the run's default model provider
  #     credential, or, in a run whose first session starts on the machine's local model
  #     provider credential (so the run has no default model provider credential), runs
  #     on that credential. The session then uses the default model of that runtime.
  #
  # A session whose choice's provider is gone ends the claim `provider_gone`, as the run's
  # does: the choice is set to a provider that was removed, or its provider is not there,
  # fails its integrity code, or `form/6` ends `provider_gone` for it. A session that
  # would have no key in the run ends the claim `session_key_missing`: its runtime uses
  # another API of a provider that an earlier session uses (`same_api/3`,
  # `on_default_group/2`); its provider has no key (`key_gone`) and no later step has a
  # key; or the run's first session runs on the machine's local model provider credential
  # (`session_on/6`).
  # A settings check of the session's provider that ran out of time or crashed is
  # `{:unchecked, provider}`, which leaves the run waiting as for the run's provider. A
  # session whose provider has no key, and whose later steps' keys are all in cooldown,
  # leaves the run waiting for those steps' providers (`cooling_steps/4`): `{:cooling,
  # built, ids}`, once every session is checked.
  defp with_sessions({:ok, built}, default_group, context) do
    sessions = context.held.sessions
    context = Map.put(context, :claim_keys, session_keys(sessions, context))

    context.held
    |> Map.get(:shared, Map.keys(sessions))
    |> Enum.filter(&Map.has_key?(sessions, &1))
    |> Enum.reduce_while({:ok, [], [], []}, fn workflow, {:ok, chosen, groups, cooling} ->
      with {:ok, choice, group, ids} <-
             session_choice(Map.fetch!(sessions, workflow), built, default_group, context)
             |> waiting(),
           {:ok, choice, group} <- same_api(choice, group, groups) do
        groups = if is_map(group) and group not in groups, do: groups ++ [group], else: groups
        {:cont, {:ok, chosen ++ [{workflow, choice, group}], groups, cooling ++ ids}}
      else
        {:end, cause} = ended when cause in [:provider_gone, :session_key_missing] ->
          {:halt, ended}

        {:unchecked, _provider} = unchecked ->
          {:halt, unchecked}
      end
    end)
    |> case do
      {:ok, chosen, groups, cooling} ->
        cond do
          not fits?(default_group, groups) ->
            {:end, :too_many_providers}

          cooling == [] ->
            {:ok, merged(built, default_group, {chosen, groups}, context.now)}

          true ->
            {:cooling, merged(built, default_group, {chosen, groups}, context.now),
             Enum.uniq(cooling)}
        end

      other ->
        other
    end
  end

  defp with_sessions(other, _start, _context), do: other

  # A session's result with the providers the run waits for: none for a session with a
  # key; for a session that waits (`cooling_steps/4`), its choice with no group, and
  # those providers. Every other session is checked before the run waits, so a cause that
  # ends the run ends it first.
  defp waiting({:ok, choice, group}), do: {:ok, choice, group, []}
  defp waiting({:cooling, choice, ids}), do: {:ok, choice, nil, ids}
  defp waiting(other), do: other

  # Whether the run's providers, the default model provider credential's and those of its
  # later sessions' groups, are at most `Apiary.ModelKeys.Order.max_keys/0`, so each gets
  # a key (`merge/3`). The claim's guard checks the stage's choices before `hold/1` reads
  # them (`Apiary.Stages.shared_models/1`); a choice saved in between can add a provider,
  # and the claim then ends the run `too_many_providers`, as the guard would.
  defp fits?(default_group, groups) do
    default_group_ids = if default_group, do: [default_group.provider.id], else: []
    ids = Enum.uniq(default_group_ids ++ Enum.map(groups, & &1.provider.id))
    length(ids) <= Order.max_keys()
  end

  # A session's group, where an earlier session's group of the same provider uses the
  # same API, is that group; where it uses another API, the claim ends
  # `session_key_missing`: a provider's keys are kept with one API per run.
  defp same_api(choice, %{provider: %{id: id}, api: api} = group, groups) do
    case Enum.find(groups, &(&1.provider.id == id)) do
      nil ->
        {:ok, choice, group}

      earlier ->
        if same_api?(earlier.api, api),
          do: {:ok, choice, earlier},
          else: {:end, :session_key_missing}
    end
  end

  defp same_api(choice, group, _groups), do: {:ok, choice, group}

  defp same_api?(api, other),
    do: Map.take(api, ~w(format endpoint auth)) == Map.take(other, ~w(format endpoint auth))

  # The run's keys, at most `Apiary.ModelKeys.Order.max_keys/0`, as `keys` (`merge/3`),
  # `columns` with the default model provider credential's provider, and each session's
  # entry with the name of its group's default model provider credential as
  # `model_provider_credential_name`. A run whose first session starts on the machine's
  # local model provider credential (so the run has no default model provider credential)
  # keeps no key.
  defp merged(built, nil, {chosen, _groups}, _now) do
    sessions = Map.new(chosen, fn {workflow, choice, _group} -> {workflow, entry(choice)} end)
    built |> Map.put(:keys, []) |> Map.put(:sessions, sessions)
  end

  defp merged(built, default_group, {chosen, groups}, now) do
    {keys, credentials} = merge(default_group, groups, now)

    sessions =
      Map.new(chosen, fn {workflow, choice, group} ->
        {workflow, entry(choice, group && Map.fetch!(credentials, group.provider.id))}
      end)

    built
    |> Map.put(:columns, %{provider_connection_id: default_group.provider.id})
    |> Map.put(:keys, keys)
    |> Map.put(:sessions, sessions)
  end

  defp entry(choice, credential \\ nil)
  defp entry(choice, nil), do: %{"model_choice" => choice}

  defp entry(choice, name),
    do: %{"model_choice" => choice, "model_provider_credential_name" => name}

  # merge/3 is the keys a run gets from the group of its default model provider
  # credential, `default_group`, and the groups of its later sessions' other providers,
  # `groups`, in session order, at `now`, each group's keys in their order
  # (`Apiary.ModelKeys.Order.order/2`): the default model provider credential's
  # provider's keys, at most 6 less the number of other providers, so at least 1; then
  # the first key of each other provider; then the other providers' remaining keys,
  # provider by provider in session order, until the run has 6. `{keys, credentials}`:
  # each key as the run keeps it (`stored_key/5`), the default model provider
  # credential's provider's first, then each other provider's, each provider's keys in
  # the order the run configuration sends them (`Apiary.ModelKeys.Order.sent/2`) and
  # named `<provider's public id>-<place>`, the place counted per provider from 1; and
  # the name of each other provider's first free key (`Apiary.ModelKeys.Order.first_free/2`),
  # else its first, by provider id. The claim's guard keeps the providers of a run's
  # stage at 6 or fewer (`Apiary.Stages.shared_models/1`), so every provider gets a key.
  @doc false
  @spec merge(map, [map], DateTime.t()) :: {[map], %{Ecto.UUID.t() => String.t()}}
  def merge(default_group, groups, %DateTime{} = now) do
    max = Order.max_keys()
    others = Enum.take(groups, max - 1)
    first = Enum.take(default_group.keys, max - length(others))
    heads = Enum.map(others, &Enum.take(&1.keys, 1))
    left = max - length(first) - Enum.sum(Enum.map(heads, &length/1))

    {tails, _left} =
      Enum.map_reduce(others, left, fn group, left ->
        taken = group.keys |> Enum.drop(1) |> Enum.take(left)
        {taken, left - length(taken)}
      end)

    taken = [{default_group, first} | Enum.zip([others, heads, tails]) |> Enum.map(&taken/1)]
    default_credential = Order.first_free(first, now)

    named =
      Enum.map(taken, fn {group, keys} ->
        {group,
         keys
         |> Order.sent(now)
         |> Enum.with_index(1)
         |> Enum.map(fn {key, place} -> {key, "#{group.provider.public_id}-#{place}"} end)}
      end)

    keys =
      named
      |> Enum.flat_map(fn {group, keys} -> Enum.map(keys, &{group, &1}) end)
      |> Enum.with_index(1)
      |> Enum.map(fn {{group, {key, name}}, position} ->
        default? =
          group == default_group and default_credential != nil and key.id == default_credential.id

        stored_key(group, key, {position, name}, default?, now)
      end)

    credentials =
      for {group, keys} <- tl(named), into: %{} do
        {first_key, first_name} = hd(keys)
        free = Order.first_free(Enum.map(keys, &elem(&1, 0)), now) || first_key
        {_key, name} = Enum.find(keys, {first_key, first_name}, &(elem(&1, 0).id == free.id))
        {group.provider.id, name}
      end

    {keys, credentials}
  end

  defp taken({group, head, tail}), do: {group, head ++ tail}

  # What the choices `input` of a later session's workflow come to (`with_sessions/3`):
  # `{:ok, model_choice, group}`, `group` the session's provider's group where it is not
  # the default model provider credential's, else nil; `{:end, :provider_gone}`; `{:end,
  # :session_key_missing}`; or `{:unchecked, provider}`.
  defp session_choice(input, built, default_group, context) do
    input = Map.put(input, :providers, context.resolved)

    case Resolution.resolve(input) do
      {:ok, %Resolution{} = resolution} ->
        case runtime(resolution) do
          {:ok, runtime} -> session_on(input, resolution, runtime, built, default_group, context)
          {:end, :runtime_unserved} -> {:ok, built.stored, nil}
        end

      {:error, :provider_removed} ->
        {:end, :provider_gone}

      :none ->
        {:ok, %{"runtime" => ModelChoices.default_runtime().name}, nil}
    end
  end

  # A run whose first session starts on the machine's local model provider credential (so
  # the run has no default model provider credential) keeps no key, once the session's
  # provider is checked for `provider_gone`. Without the features under which a run is
  # given keys (`keyed` false), the session gets `runtime` alone. Else the run's first
  # session runs on the machine's local model provider credential, so a later session on
  # a model provider would have no key in the run, whether its provider has keys or not:
  # the claim ends the run `session_key_missing`.
  defp session_on(_input, resolution, runtime, built, nil, context) do
    provider = Map.fetch!(context.providers, resolution.connection_id)

    with :ok <- intact(provider) do
      case session_form(resolution, provider, runtime, built, context) do
        {:ok, _formed} when context.held.keyed -> {:end, :session_key_missing}
        {:ok, _formed} -> {:ok, %{"runtime" => runtime.name}, nil}
        {:end, :key_gone} when context.held.keyed -> {:end, :session_key_missing}
        other -> other
      end
    end
    |> session_result(built)
  end

  defp session_on(input, resolution, runtime, built, default_group, context) do
    provider = Map.fetch!(context.providers, resolution.connection_id)

    with :ok <- intact(provider) do
      case session_form(resolution, provider, runtime, built, context) do
        {:ok, formed} ->
          cond do
            provider.id == default_group.provider.id ->
              on_default_group(formed, default_group)

            group = free_group(provider, formed, context) ->
              {:ok, formed.stored, group}

            fallen = on_fallback(input, resolution, default_group, context) ->
              fallen

            true ->
              {:ok, formed.stored, session_group(provider, formed, context)}
          end

        # A provider with no key (`key_gone`): the session takes its first later step
        # with a free key; else the run waits for the later steps whose keys are all in
        # cooldown; else the session would have no key in the run.
        {:end, :key_gone} when context.held.keyed ->
          on_fallback(input, resolution, default_group, context) ||
            cooling_steps(input, resolution, default_group, context) ||
            {:end, :session_key_missing}

        other ->
          other
      end
    end
    |> session_result(built)
  end

  # The session's choice formed on `provider`, as `form/6` forms the run's, with or
  # without a key as the run has one.
  defp session_form(resolution, provider, runtime, _built, context) do
    form(
      resolution,
      provider,
      context.described[provider.id],
      runtime,
      context.held.workspace.id,
      context.held.keyed
    )
  end

  # A session whose provider is gone, or that would have no key in the run, ends the
  # claim; one whose choice no longer forms for another cause gets the run's
  # `run_settings`.
  defp session_result({:end, cause} = ended, _built)
       when cause in [:provider_gone, :session_key_missing],
       do: ended

  defp session_result({:end, _cause}, built), do: {:ok, built.stored, nil}
  defp session_result(other, _built), do: other

  # A choice on the default model provider credential's provider joins the default model
  # provider credential's group where its runtime uses the same API; else the claim ends
  # `session_key_missing`.
  defp on_default_group(formed, default_group) do
    if same_api?(formed.columns.provider_api, default_group.api),
      do: {:ok, formed.stored, nil},
      else: {:end, :session_key_missing}
  end

  # The first later step of `resolution` (`later_steps/2`), in order, that forms and has a
  # free key at the claim, or that is the default model provider credential's provider
  # with the same API: `{:ok, choice, group}`, or nil for none. Each step forms on its
  # runtime and tiers. A step that does not form, or whose settings check ran out of time
  # or crashed, is passed over.
  defp on_fallback(input, %Resolution{} = resolution, default_group, ctx) do
    input
    |> later_steps(resolution)
    |> Enum.find_value(fn %Resolution{connection_id: id} = fallen ->
      provider = Map.fetch!(ctx.providers, id)

      with true <- Connections.intact?(provider),
           {:ok, runtime} <- runtime(fallen),
           {:ok, formed} <- session_form(fallen, provider, runtime, nil, ctx) do
        cond do
          id == default_group.provider.id ->
            if same_api?(formed.columns.provider_api, default_group.api),
              do: {:ok, formed.stored, nil}

          group = free_group(provider, formed, ctx) ->
            {:ok, formed.stored, group}

          true ->
            nil
        end
      else
        _not_formed -> nil
      end
    end)
  end

  # The later steps of `resolution` (`later_steps/2`) that form, on a provider other than
  # the default model provider credential's, with keys that are all in cooldown at the
  # claim, as `on_fallback/4` found no free one: `{:cooling, choice, ids}`, the first
  # such step's choice and those steps' providers in order, each once; nil for none.
  defp cooling_steps(input, %Resolution{} = resolution, default_group, ctx) do
    input
    |> later_steps(resolution)
    |> Enum.flat_map(fn %Resolution{connection_id: id} = fallen ->
      provider = Map.fetch!(ctx.providers, id)

      with false <- id == default_group.provider.id,
           true <- Connections.intact?(provider),
           {:ok, runtime} <- runtime(fallen),
           {:ok, formed} <- session_form(fallen, provider, runtime, nil, ctx),
           %{keys: [_ | _]} <- session_group(provider, formed, ctx) do
        [{formed.stored, id}]
      else
        _no_keys_or_not_formed -> []
      end
    end)
    |> case do
      [] ->
        nil

      [{choice, _id} | _rest] = cooling ->
        {:cooling, choice, cooling |> Enum.map(&elem(&1, 1)) |> Enum.uniq()}
    end
  end

  # The group of `provider`'s keys for the API `formed` uses, at the claim's clock, where
  # one of them is free; else nil.
  defp free_group(provider, formed, context) do
    group = session_group(provider, formed, context)
    if Order.first_free(group.keys, context.now), do: group
  end

  # The group of a later session on `provider` (`group/3`), from the keys
  # `session_keys/2` read once for the claim.
  defp session_group(provider, formed, context) do
    keys = Map.get_lazy(context.claim_keys, provider.id, fn -> claim_keys(provider, context) end)
    %{provider: provider, api: formed.columns.provider_api, keys: keys}
  end

  # The keys at the claim of each provider that the later sessions' choices and their
  # fallbacks name, in their order (`Apiary.ModelKeys.Order.order/2`), by provider id:
  # each provider's keys read once, however many sessions use it. A run given no key
  # (`keyed` false) reads none.
  defp session_keys(_sessions, %{held: %{keyed: false}}), do: %{}

  defp session_keys(sessions, context) do
    for {_workflow, session} <- sessions,
        id <- provider_ids(session),
        provider = Map.get(context.providers, id),
        uniq: true,
        into: %{},
        do: {id, claim_keys(provider, context)}
  end

  defp claim_keys(provider, context),
    do: provider |> ModelKeys.claim_keys(context.now) |> Order.order(context.now)

  # The keys of `provider` a run gets at `now` (`Apiary.ModelKeys.Order.order/2`), with
  # the provider and the API of `formed`.
  defp group(provider, formed, now) do
    %{
      provider: provider,
      api: formed.columns.provider_api,
      keys: provider |> ModelKeys.claim_keys(now) |> Order.order(now)
    }
  end

  # Without the features under which a run is given its provider's key
  # (`Apiary.Runs.ProviderCredential.applies?/0`), the run gets the choice's runtime and
  # models and no key: it keeps no provider column and waits for no key.
  defp keys(built, _provider, _resolved, %{keyed: false}, _now),
    do: {:ok, %{built | columns: %{}}, nil}

  # The settings `built` of the choice's provider with the group of its keys, else those
  # of the first later step with a key not in cooldown (`fall_back/6`), else `{:cooling,
  # built, provider_ids}`: the choice's settings without keys, and the choice's provider
  # first, then the providers of `fall_back/6`'s `{:cooling, ids}`.
  defp keys(built, provider, {input, resolution, providers, described}, held, now) do
    with nil <- keyed(built, provider, now) do
      case fall_back(input, resolution, {providers, described}, provider, held.workspace.id, now) do
        {:ok, _built, _start} = fallen ->
          fallen

        {:cooling, ids} ->
          {:cooling, built, Enum.uniq([provider.id | ids])}
      end
    end
  end

  # The settings `built` with the group of the run's default model provider credential,
  # `provider`'s keys at `now` in their order (`Apiary.ModelKeys.Order.order/2`); or nil
  # where every key is in cooldown. `merge/3` takes the run's keys from the group.
  defp keyed(built, %Connection{} = provider, now) do
    group = group(provider, built, now)
    if Order.first_free(group.keys, now), do: {:ok, built, group}
  end

  # A key as the run keeps it (`Apiary.Runs.ModelKey`) and its run configuration writes
  # it: its place, its name, its row id, its provider, its keys' secret, its chain and the
  # API its group uses; `start` on the default model provider credential, its Pause for,
  # and, where it has them, its known reset from the providers' responses, the next reset
  # of its schedule, the end of its cooldown while it is in cooldown at `now`, a window
  # at its Use up to percentage included, and that percentage. Times are in whole
  # seconds, rounded up.
  defp stored_key(group, key, {position, name}, default?, now) do
    %{
      position: position,
      name: name,
      start: default?,
      secret_value_id: key.id,
      connection_id: group.provider.id,
      secret_id: group.provider.secret_id,
      chain: group.provider.chain,
      api: group.api,
      pause_for_s: key.pause_seconds,
      resets_at: time(key.resets_at),
      schedule_resets_at: time(key.schedule_resets_at),
      cooldown_until: if(Order.cooling?(key, now), do: time(key.cooldown_until)),
      use_up_to_percent: key.use_up_to_percent
    }
  end

  defp time(nil), do: nil

  defp time(%DateTime{} = time) do
    whole = DateTime.truncate(time, :second)
    if DateTime.compare(whole, time) == :lt, do: DateTime.add(whole, 1), else: whole
  end

  # The first later step, in order, that forms and has a key not in cooldown at `now`:
  # the default step under a workflow's override, then the fallbacks, each with its
  # runtime and tiers (`Apiary.ModelChoices.Resolution.fallback/3`).
  # `{:ok, built, group}`, or `{:cooling, ids}` for none. A step whose provider's keys
  # were already found in cooldown, `provider`'s first, is passed over. `ids` are the
  # providers of the steps that formed, each with every key in cooldown, and of those
  # whose settings check ran out of time or crashed, which a later claim checks again. A
  # step that does not form for a cause that ends a run on the choice's provider is
  # passed over and left out of `ids`.
  defp fall_back(input, %Resolution{} = resolution, {providers, described}, provider, ws, now) do
    steps = later_steps(input, resolution)

    steps
    |> Enum.reduce_while({:cooling, [], [provider.id]}, fn step, acc ->
      step(step, {providers, described}, ws, now, acc)
    end)
    |> case do
      {:ok, _built, _group} = keyed -> keyed
      {:cooling, ids, _cooled} -> {:cooling, ids}
    end
  end

  # The later steps of `resolution`, in order: under a workflow's override, the default
  # step, then its fallbacks; else the choice's fallbacks. Each is a resolution with its
  # runtime and tiers (`Apiary.ModelChoices.Resolution.fallback/3`).
  defp later_steps(input, %Resolution{default: nil} = resolution),
    do:
      for(fallback <- resolution.fallbacks, do: Resolution.fallback(input, resolution, fallback))

  defp later_steps(input, %Resolution{default: %Resolution{} = default}),
    do: [
      default
      | for(fallback <- default.fallbacks, do: Resolution.fallback(input, default, fallback))
    ]

  # One step of `fall_back/6`: `{:halt, {:ok, built, group}}` for a step with a free key,
  # else the providers waited for and those whose keys are all in cooldown (`cooled`).
  defp step(%Resolution{connection_id: id} = step, {providers, described}, ws, now, acc) do
    {:cooling, ids, cooled} = acc
    provider = Map.fetch!(providers, id)

    with false <- id in cooled,
         true <- Connections.intact?(provider),
         {:ok, runtime} <- runtime(step),
         {:ok, built} <- form(step, provider, described[id], runtime, ws) do
      case keyed(built, provider, now) do
        {:ok, _built, _group} = keyed -> {:halt, keyed}
        nil -> {:cont, {:cooling, ids ++ [id], cooled ++ [id]}}
      end
    else
      true -> {:cont, acc}
      {:unchecked, _provider} -> {:cont, {:cooling, ids ++ [id], cooled}}
      _not_formed -> {:cont, acc}
    end
  end

  # The providers of the run's choices and their fallbacks, and those of the choices of
  # its later sessions and their fallbacks, each once: a later session takes its first
  # fallback with a free key where its choice's provider has none.
  defp all_provider_ids(input, sessions) do
    session_ids = for {_workflow, session} <- sessions, id <- provider_ids(session), do: id
    Enum.uniq(provider_ids(input) ++ session_ids)
  end

  # The providers the choices name, and their fallbacks', each once.
  defp provider_ids(input) do
    for choice <- input.choices,
        id <- [choice.connection_id | Enum.map(choice.fallbacks, & &1.connection_id)],
        is_binary(id),
        uniq: true,
        do: id
  end

  # The row ids among `ids` of the organisation's model providers that are there, the
  # rows `providers/1` reads, as a map of each to true.
  defp present_providers(_organisation_id, []), do: %{}

  defp present_providers(organisation_id, ids) do
    from(c in Connection,
      where: c.id in ^Enum.reject(ids, &is_nil/1) and c.organisation_id == ^organisation_id,
      where: not is_nil(c.provider_kind) and c.chain == "organisation",
      select: {c.id, true}
    )
    |> Repo.all()
    |> Map.new()
  end

  # The providers the choices and their fallbacks name, as they are now: with the
  # workspaces they apply to and their keys' secret's value ids, by row id.
  defp providers(%{organisation: organisation, input: input} = held) do
    ids = all_provider_ids(input, Map.get(held, :sessions, %{}))

    # The providers of the run's chain are the rows of the run's organisation.
    if ids == [] do
      %{}
    else
      from(c in Connection,
        where: c.id in ^ids and c.organisation_id == ^organisation.id,
        where: not is_nil(c.provider_kind) and c.chain == "organisation",
        preload: [
          workspaces: [],
          secret: [values: ^from(v in Value, select: struct(v, [:id]))]
        ]
      )
      |> Repo.all()
      |> Map.new(&{&1.id, &1})
    end
  end

  # The provider's row as it was written, or the run ends `provider_gone`: the row's
  # endpoint setting and keys' secret id are read only from a row whose code verifies.
  defp intact(%Connection{} = provider) do
    if Connections.intact?(provider) do
      :ok
    else
      Logger.error(
        "a claim ends its run: the model provider #{provider.public_id} fails its integrity code"
      )

      {:end, :provider_gone}
    end
  end

  # The runtime the choice resolved to, or the run ends `runtime_unserved` for one the
  # catalogue no longer has: no provider serves it.
  defp runtime(%Resolution{runtime: name}) do
    case ModelChoices.runtime(name) do
      {:ok, runtime} -> {:ok, runtime}
      :error -> {:end, :runtime_unserved}
    end
  end

  defp runtime_only(%Runtime{name: name}) do
    %{
      wire: Jason.OrderedObject.new([{"runtime", name}]),
      stored: %{"runtime" => name},
      columns: %{}
    }
  end

  # The settings within the column's bound, or the claim is refused.
  defp sealed(%{wire: wire} = built) do
    if byte_size(Jason.encode!(wire)) <= @max_bytes, do: {:ok, built}, else: :unavailable
  end

  # form/6 is the settings of `resolution` for `provider`, the connection as `hold/1` read
  # it, whose description in the catalogue is `description` (`Connections.provider/1`),
  # for the runs of `runtime` in the workspace `workspace_id`. The first cause of the
  # moduledoc that applies, else `{:ok, built}`; `{:unchecked, provider}` where the check
  # of the provider's settings ran out of time or crashed, which ends no run. A function
  # of its arguments, which a test calls with a description or a runtime the catalogue
  # does not have. With `keyed` false, for a run given no key, the endpoint and the key
  # are not checked.
  @doc false
  @spec form(
          Resolution.t(),
          Connection.t(),
          {:ok, Provider.t()} | {:error, atom},
          Runtime.t(),
          Ecto.UUID.t(),
          boolean
        ) :: {:ok, built} | {:end, cause} | {:unchecked, Connection.t()}
  def form(resolution, provider, description, runtime, workspace_id, keyed \\ true) do
    with {:ok, description} <- described(description, provider),
         :ok <- applies(provider, workspace_id),
         {:ok, api} <- api(description, runtime),
         {:ok, endpoint} <- endpoint(api, provider, keyed),
         :ok <- key(provider, keyed),
         models = Connections.provider_models(description),
         :ok <- model(models, resolution, runtime) do
      api = with_windows(%{api | "endpoint" => endpoint}, description)
      {:ok, built(resolution, provider, models, runtime, api)}
    end
  end

  # The API with the description's limit windows as `use_up_to_windows`, which each key
  # row of the run keeps in its `api` for the key's Use up to percentage
  # (`Apiary.Runs.ProviderCredential`); none for a provider without them.
  defp with_windows(api, %Provider{limit_windows: [_ | _] = windows}),
    do: Map.put(api, "use_up_to_windows", windows)

  defp with_windows(api, %Provider{}), do: api

  defp described({:ok, %Provider{} = description}, _provider), do: {:ok, description}
  defp described({:error, :provider_unchecked}, provider), do: {:unchecked, provider}
  defp described(_changed_or_unknown, _provider), do: {:end, :provider_gone}

  defp applies(%Connection{applies_to: "all"}, _workspace_id), do: :ok

  defp applies(%Connection{workspaces: workspaces}, workspace_id) do
    if Enum.any?(workspaces, &(&1.workspace_id == workspace_id)),
      do: :ok,
      else: {:end, :provider_gone}
  end

  # The API of the provider that the runtime's runs use.
  defp api(description, runtime) do
    case Providers.api(description, runtime) do
      {:ok, api} -> {:ok, api}
      {:error, _refusal} -> {:end, :runtime_unserved}
    end
  end

  # The address of the API: the description's, or the one the provider has for the
  # setting the description names, which passes the endpoint rule again here.
  # A run given no key does not reach the provider's API, so its endpoint is not checked.
  defp endpoint(_api, _provider, false), do: {:ok, nil}

  defp endpoint(%{"endpoint" => address}, _provider, true) when is_binary(address),
    do: {:ok, address}

  defp endpoint(%{"endpoint" => %{"setting" => name}}, %Connection{} = provider, true) do
    address = Map.get(Connection.settings_map(provider), name)

    case Endpoint.check(address) do
      :ok -> {:ok, address}
      {:error, _refusal} -> {:end, :provider_gone}
    end
  end

  # A provider with a key, checked only for a run given its provider's key: a run takes
  # its keys.
  defp key(_provider, false), do: :ok
  defp key(%Connection{secret: %Secret{values: [_ | _]}}, true), do: :ok
  defp key(%Connection{}, true), do: {:end, :key_gone}

  # A chosen model, with no effort or one of its offered effort values.
  defp model(_models, %Resolution{model_id: nil}, _runtime), do: {:end, :model_gone}
  defp model(_models, %Resolution{effort: nil}, _runtime), do: :ok

  defp model(models, %Resolution{model_id: id, effort: effort}, runtime) do
    case Enum.find(models, &(&1["id"] == id)) do
      %{} = model -> if effort in offered(model, runtime), do: :ok, else: {:end, :model_gone}
      nil -> {:end, :model_gone}
    end
  end

  # The effort values of `model` that the runtime's list has too, in the model's order.
  defp offered(%{} = model, %Runtime{effort_values: values}),
    do: Enum.filter(model["effort"] || [], &(&1 in values))

  defp built(%Resolution{} = resolution, %Connection{} = provider, models, runtime, api) do
    members =
      [{"runtime", runtime.name}, {"model", resolution.model_id}] ++
        if(resolution.effort, do: [{"effort", resolution.effort}], else: []) ++
        [{"provider_models", provider_models(models, resolution, runtime)}] ++
        tiers(resolution.tiers)

    wire = Jason.OrderedObject.new(members)

    %{
      wire: wire,
      stored: wire |> Jason.encode!() |> Jason.decode!(),
      # The provider and the API the choice uses, until `with_sessions/3` replaces them
      # with the run's column and keys (`merged/4`).
      columns: %{
        provider_connection_id: provider.id,
        provider_secret_id: provider.secret_id,
        provider_chain: provider.chain,
        provider_api: Map.take(api, ~w(format endpoint auth key_prefixes use_up_to_windows))
      }
    }
  end

  # The description's models, then each chosen model it does not list (the moduledoc).
  defp provider_models(models, %Resolution{} = resolution, runtime) do
    listed = Enum.map(models, & &1["id"])

    chosen =
      for tier <- Resolution.tiers(),
          entry = resolution.tiers[tier],
          entry != nil,
          do: entry["model"]

    others = Enum.uniq([resolution.model_id | chosen]) -- listed

    Enum.map(models, &listed(&1, runtime)) ++
      Enum.map(others, &Jason.OrderedObject.new([{"id", &1}]))
  end

  defp listed(%{"id" => id} = model, runtime) do
    case offered(model, runtime) do
      [] -> Jason.OrderedObject.new([{"id", id}])
      effort -> Jason.OrderedObject.new([{"id", id}, {"effort", effort}])
    end
  end

  defp tiers(tiers) when tiers == %{}, do: []

  defp tiers(tiers) do
    entries =
      for tier <- Resolution.tiers(), entry = tiers[tier], entry != nil do
        {tier, tier_entry(entry)}
      end

    [{"tiers", Jason.OrderedObject.new(entries)}]
  end

  defp tier_entry(%{"model" => model, "effort" => effort}),
    do: Jason.OrderedObject.new([{"model", model}, {"effort", effort}])

  defp tier_entry(%{"model" => model}), do: model
end
