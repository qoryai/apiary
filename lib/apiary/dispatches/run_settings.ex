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
  # key on the run, and leaves no run waiting for a key; the run uses the gateway's key.
  # `time_limit_minutes` needs `factory`, whose pages set the time limits.
  #
  # ## What it holds
  #
  # `hold/1` reads the choices of the run's chain and their fallbacks without a lock, locks
  # the rows of the model providers they name, as a provider or a fallback, `FOR SHARE`,
  # by id, then the rows of those providers' keys'
  # secrets `FOR SHARE`, by id, and reads the choices again. Each read that names a
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
  #   * `key_gone`: the chosen key is no longer one of the provider's keys;
  #   * `model_gone`: no model resolves, for a choice with no model of a provider whose
  #     description lists none; or the chosen effort value is no longer among both the
  #     model's effort values in the description and the runtime's, which a model the
  #     description no longer lists has none of. A model the description does not list
  #     ends no run by itself.
  #
  # Then the keys, at the claim's clock (`build/2`). The run takes the provider's keys
  # where one of them is not in cooldown (`Apiary.ModelKeys`). Else it takes the first of
  # the choice's fallbacks, in their order, that forms as the choice's provider does
  # above, with the fallback's model and effort and the tiers that go with its provider
  # (`Apiary.ModelChoices.Resolution.fallback/3`), and that has a key not in cooldown; a
  # fallback that does not form is passed over and ends nothing. A run takes the keys of
  # one provider alone. With none, `build/2` returns `{:cooling, built, ids}`: the claim
  # checks what can end the run first, then leaves it waiting with `ids` as the providers
  # it waits for (`Apiary.Dispatches.Handover`): the choice's provider, each fallback
  # that formed, and each fallback whose settings check ran out of time or crashed.
  #
  # The run gets at most 6 keys, picked in the order of `Apiary.ModelKeys.Order`, the key
  # the choice names first while it is not in cooldown; the first of that order is the
  # start key, never one in cooldown. They are kept in the order the run configuration
  # sends them (`Apiary.ModelKeys.Order.sent/2`), the start key marked.
  #
  # A deny rule of the security policy is not asked: it never blocks a host of an
  # integration.
  #
  # ## What it writes
  #
  # `run_settings`, in the schema's order: `runtime`, `model`, `effort` when the choice has
  # one, `provider_models` and `tiers`, a tier left out when no choice maps it to a model
  # that goes with the provider (`Apiary.ModelChoices.Resolution`). The documents have no
  # key, no secret and no id of a key, and neither has the stored copy.
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
  # keeps on the run (`Apiary.Stages.claim_sessions!/2`). The process document has no
  # time limit. The workflows and the limits are read without a lock. Beside it, the run keeps the provider's row
  # id, its keys' secret's row id, its keys (`runs.model_keys`: each key's row id, its
  # credential name `<provider's public id>-<place from 1>`, `start` on the start key, and
  # what its run configuration entry has of it), the provider's chain and the API the run
  # uses (`provider_api`: its `format`, its `endpoint` with a setting resolved to its
  # address, its `auth`, and, when the description lists them, its `key_prefixes` and its
  # limit windows as `use_up_to_windows`), for the reads that follow the claim. The run
  # settings take at most 64 KiB encoded; a claim with more fails.
  #
  # `provider_models` is the description's models (`Apiary.Connections.provider_models/1`),
  # in its order, each with the effort values that both it and the runtime have, then the
  # chosen model and each tier's model that the description does not list, each once,
  # with no effort, in the order `model`, `light`, `fast`, `thinking`. A description has
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
  @type cause :: :provider_gone | :runtime_unserved | :key_gone | :model_gone

  @typedoc """
  What a claim writes: `wire`, the documents' `run_settings`; `stored`, the same as a
  map, for the run's column; and `columns`, the run's provider columns, empty where no
  provider was chosen.
  """
  @type built :: %{
          wire: Jason.OrderedObject.t(),
          stored: map,
          columns: %{optional(atom) => term}
        }

  # max_bytes/0 is the most bytes the run settings take, encoded.
  @doc false
  @spec max_bytes() :: pos_integer
  def max_bytes, do: @max_bytes

  # causes/0 is every cause `build/1` ends a run for.
  @doc false
  @spec causes() :: [cause]
  def causes, do: [:provider_gone, :runtime_unserved, :key_gone, :model_gone]

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

    case lock(workspace, target, workflow, [], @lock_rounds) do
      {:ok, input} ->
        time_limits = time_limits(dispatch_run, workspace, target, workflow)

        %{
          organisation: organisation,
          workspace: workspace,
          target: target,
          input: input,
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

  # time_limit_minutes/2 is the minutes the time limits of the workspace and the target of
  # the run of the queue `dispatch_run` come to for `workflow`, the default for no limit,
  # read without a lock, as `hold/1` reads them.
  @doc false
  @spec time_limit_minutes(DispatchRun.t(), String.t()) :: pos_integer
  def time_limit_minutes(
        %DispatchRun{workspace_id: workspace_id, work_item_id: id},
        workflow
      )
      when is_binary(workflow) do
    workspace = Repo.get!(Workspace, workspace_id)
    time_limit(workspace, target(workspace, id), workflow)
  end

  # The run's workflow: with the workflow model, the one its stage entry names
  # (`Apiary.Stages.run_workflow/1`); else the one the Harness page saved.
  defp workflow(dispatch_run, workspace, target),
    do: Apiary.Stages.run_workflow(dispatch_run) || Stacks.workflow(workspace, target)

  # The minutes of the run's workflow and of each workflow of its shared stage, by name;
  # none with `factory` off, whose pages set the time limits.
  defp time_limits(dispatch_run, workspace, target, workflow) do
    if Features.on?(:factory) do
      Map.new(
        Enum.uniq(List.wrap(workflow) ++ Apiary.Stages.shared_workflows(dispatch_run)),
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

  # The choices once every provider they name is held, their fallbacks' among them: read,
  # lock what is new, read again.
  defp lock(workspace, target, workflow, locked, tries) do
    input = ModelChoices.choices_for(workspace, target, workflow)
    input = %{input | choices: Repo.preload(input.choices, :fallbacks)}
    ids = provider_ids(input)

    case ids -- locked do
      [] ->
        {:ok, input}

      _new when tries == 0 ->
        :unstable

      new ->
        lock_rows(Enum.sort(new))
        lock(workspace, target, workflow, locked ++ new, tries - 1)
    end
  end

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
  # every key of the choice's provider and of each usable fallback is in cooldown, with
  # the choice's settings without keys and those providers' row ids, the choice's first,
  # and those of the fallbacks whose settings check ran out of time or crashed,
  # `:unstable` where the choices changed while `hold/1` read them, `{:unchecked,
  # provider}` where the check of the settings of `provider`, the chosen one, ran out of
  # time or crashed (`Apiary.Connections.provider/1`), or `:unavailable` where the run
  # settings take more than 64 KiB. Each provider's description is read once, for the
  # resolution and the settings alike.
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

    input =
      Map.put(
        held.input,
        :providers,
        Map.new(providers, fn {id, provider} ->
          {id, ModelChoices.resolution_provider(provider, described[id])}
        end)
      )

    case Resolution.resolve(input) do
      :none ->
        sealed(runtime_only(ModelChoices.default_runtime()))

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
             {:ok, built} <-
               keys(
                 built,
                 provider,
                 {input, resolution, providers, described, runtime},
                 held,
                 now
               ),
             do: sealed(built)
    end
  end

  # Without the features under which a run is given its provider's key
  # (`Apiary.Runs.ProviderCredential.applies?/0`), the run gets the choice's runtime and
  # models and no key: it keeps no provider column and waits for no key.
  defp keys(built, _provider, _resolved, %{keyed: false}, _now),
    do: {:ok, %{built | columns: %{}}}

  # The settings `built` of the choice's provider with its keys, else those of the first
  # fallback with a key not in cooldown, else `{:cooling, built, provider_ids}`: the
  # choice's settings without keys, and the choice's provider first, then the fallbacks
  # of `fallback/6`'s `{:cooling, ids}`.
  defp keys(built, provider, {input, resolution, providers, described, runtime}, held, now) do
    with nil <- keyed(built, provider, named_value_id(input), now) do
      case fallback(input, resolution, {providers, described}, runtime, held.workspace.id, now) do
        {:ok, _built} = fallen ->
          fallen

        {:cooling, ids} ->
          {:cooling, built, Enum.uniq([provider.id | ids])}
      end
    end
  end

  # The key the choice in effect names, nil for none: the key that goes first.
  defp named_value_id(input) do
    case Resolution.in_effect(input) do
      {_level, %{value_id: value_id}} -> value_id
      nil -> nil
    end
  end

  # The settings `built` with the run's keys of `provider` at `now`, or nil where every
  # key is in cooldown: the keys a run gets and its start key by their order
  # (`Apiary.ModelKeys.Order.order/2`), kept in the order the run configuration sends
  # them (`Apiary.ModelKeys.Order.sent/2`). Each key is a credential named by the
  # provider's public id and the key's place in that order, from 1: `<public id>-1`,
  # `<public id>-2` and on; the start key is marked `start`.
  defp keyed(built, %Connection{} = provider, named, now) do
    keys = provider |> ModelKeys.claim_keys(named, now) |> Order.order(now)

    if start = Order.start(keys, now) do
      stored =
        keys
        |> Order.sent(now)
        |> Enum.with_index(1)
        |> Enum.map(fn {key, place} ->
          stored_key(key, "#{provider.public_id}-#{place}", key.id == start.id, now)
        end)

      {:ok, %{built | columns: Map.put(built.columns, :model_keys, stored)}}
    end
  end

  # A key as the run keeps it and its run configuration writes it: its row id, its name,
  # `start` on the start key, its Pause for, and, where it has them, its known reset from
  # the providers' responses, the next reset of its schedule, whether the choice is set to
  # it, the end of its cooldown while it is in cooldown at `now`, a window at its Use up
  # to percentage included, and that percentage. The limit windows are not on the key:
  # the run keeps them once, in `provider_api` (`with_windows/2`). Times are in whole
  # seconds, rounded up.
  defp stored_key(key, name, start?, now) do
    [
      {"id", key.id},
      {"name", name},
      {"start", if(start?, do: true)},
      {"pause_for_s", key.pause_seconds},
      {"resets_at", time(key.resets_at)},
      {"schedule_resets_at", time(key.schedule_resets_at)},
      {"chosen", if(key.named, do: true)},
      {"cooldown_until", if(Order.cooling?(key, now), do: time(key.cooldown_until))},
      {"use_up_to_percent", key.use_up_to_percent}
    ]
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp time(nil), do: nil

  defp time(%DateTime{} = time) do
    whole = DateTime.truncate(time, :second)
    whole = if DateTime.compare(whole, time) == :lt, do: DateTime.add(whole, 1), else: whole
    DateTime.to_iso8601(whole)
  end

  # The first of the choice's fallbacks, in their order, that forms and has a key not in
  # cooldown at `now`, with its model and effort: `{:ok, built}`, or `{:cooling, ids}`
  # for none. `ids` are the fallbacks that formed, each with every key in cooldown, and
  # those whose settings check ran out of time or crashed, which a later claim checks
  # again. A fallback that does not form for a cause that ends a run on the choice's
  # provider is passed over and left out of `ids`.
  defp fallback(
         input,
         %Resolution{fallbacks: fallbacks} = resolution,
         {providers, described},
         runtime,
         ws,
         now
       ) do
    Enum.reduce_while(fallbacks, {:cooling, []}, fn %{connection_id: id} = fallback,
                                                    {:cooling, ids} ->
      provider = Map.fetch!(providers, id)
      fallen = Resolution.fallback(input, resolution, fallback)

      with true <- Connections.intact?(provider),
           {:ok, built} <- form(fallen, provider, described[id], runtime, ws) do
        case keyed(built, provider, nil, now) do
          {:ok, _built} = keyed -> {:halt, keyed}
          nil -> {:cont, {:cooling, ids ++ [provider.id]}}
        end
      else
        {:unchecked, _provider} -> {:cont, {:cooling, ids ++ [provider.id]}}
        _not_formed -> {:cont, {:cooling, ids}}
      end
    end)
  end

  # The providers the choices name, and their fallbacks', each once.
  defp provider_ids(input) do
    for choice <- input.choices,
        id <- [choice.connection_id | Enum.map(choice.fallbacks, & &1.connection_id)],
        is_binary(id),
        uniq: true,
        do: id
  end

  # The providers the choices and their fallbacks name, as they are now: with the
  # workspaces they apply to and their keys' secret's value ids, by row id.
  defp providers(%{organisation: organisation, input: input}) do
    ids = provider_ids(input)

    # The providers of the run's chain are the rows of the run's organisation.
    if ids == [] do
      %{}
    else
      from(c in Connection,
        where: c.id in ^ids and c.organisation_id == ^organisation.id,
        where: not is_nil(c.provider_kind) and c.chain == "organisation",
        preload: [
          workspaces: [],
          secret: [values: ^from(v in Value, select: struct(v, [:id, :value_id]))]
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

  # form/5 is the settings of `resolution` for `provider`, the connection as `hold/1` read
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
         :ok <- key(provider, resolution.value_id, keyed),
         models = Connections.provider_models(description),
         :ok <- model(models, resolution, runtime) do
      api = with_windows(%{api | "endpoint" => endpoint}, description)
      {:ok, built(resolution, provider, models, runtime, api)}
    end
  end

  # The API with the description's limit windows as `use_up_to_windows`, which the run
  # keeps in `provider_api` for each key's Use up to percentage
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

  # The chosen key, checked only for a run given its provider's key.
  defp key(_provider, _value_id, false), do: :ok

  defp key(%Connection{secret: %Secret{values: values}}, value_id, true)
       when is_binary(value_id) do
    if Enum.any?(values, &(&1.value_id == value_id)), do: :ok, else: {:end, :key_gone}
  end

  defp key(%Connection{}, _value_id, true), do: {:end, :key_gone}

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
