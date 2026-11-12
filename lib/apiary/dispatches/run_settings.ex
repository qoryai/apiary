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
  # Only an explore run has `run_settings`, and only with both features `factory` and
  # `secrets` on; without either, the documents have none. With them on and no choice at any
  # level, it has `runtime` alone, the catalogue's default
  # (`Apiary.ModelChoices.default_runtime/0`), and the run uses the gateway's key. With a
  # choice, `runtime` is the runtime the choice resolves to.
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
  #     (`Apiary.Connections.intact?/1`), does not apply to the workspace any more, or is
  #     no longer in the catalogue as it was added;
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
  # checks what can end the run first, then leaves it waiting with `ids`, the providers
  # it checked, as the ones it waits for (`Apiary.Dispatches.Handover`).
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
  # that goes with the provider (`Apiary.ModelChoices.Resolution`); then
  # `time_limit_minutes`, the minutes the time limits of the run's workspace and target
  # come to for the run's workflow
  # (`Apiary.TimeLimits.Resolution`, `Apiary.Stacks.workflow/2`), left out when no limit
  # resolves or the run has no workflow; with the workflow model, the lower of those
  # minutes and the run's stage entry's time limit (`Apiary.Stages.limits/1`), which only
  # lowers a limit that resolved and is left out with none. The
  # workflow and the limits are read without a lock in `hold/1`. The documents have no key, no secret and no id of a key, and neither
  # has the stored copy. Beside it, the run keeps the provider's row id, its keys'
  # secret's row id, its keys (`runs.model_keys`: each key's row id, its credential name
  # `<provider's public id>-<place from 1>`, `start` on the start key, and what its run
  # configuration entry has of it), the provider's chain and the API the run uses
  # (`provider_api`: its `format`, its `endpoint` with a setting resolved to its address,
  # its `auth` and, when the description lists them, its `key_prefixes`), for the reads
  # that follow the claim. The run settings take at most 64 KiB encoded; more refuses
  # the claim.
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
  alias Apiary.Runs.Target
  alias Apiary.Secrets.{Secret, Value}
  alias Apiary.WorkItems.WorkItem

  # The step of the queue whose runs have `run_settings`.
  @step "explore"
  # The fewest minutes of a run's time limit (the contract's `time_limit_minutes`).
  @least_minutes 15
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
  # locks anything: nil for a run that has no `run_settings`, else what `build/1` takes.
  @doc false
  @spec hold(DispatchRun.t()) :: map | :unstable | nil
  def hold(%DispatchRun{step: @step, workspace_id: workspace_id, work_item_id: id} = dispatch_run) do
    if Features.on?(:factory) and Features.on?(:secrets) do
      workspace = Repo.get!(Workspace, workspace_id)
      organisation = Repo.get!(Organisation, workspace.organisation_id)
      target = target(workspace, id)
      workflow = workflow(dispatch_run, workspace, target)

      case lock(workspace, target, workflow, [], @lock_rounds) do
        {:ok, input} ->
          %{
            organisation: organisation,
            workspace: workspace,
            target: target,
            input: input,
            time_limit: lowered(time_limit(workspace, target, workflow), dispatch_run)
          }

        :unstable ->
          :unstable
      end
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

  # The run's workflow: with the workflow model, the one its stage entry names
  # (`Apiary.Stages.run_workflow/1`); else the one the Harness page saved.
  defp workflow(dispatch_run, workspace, target),
    do: Apiary.Stages.run_workflow(dispatch_run) || Stacks.workflow(workspace, target)

  # The minutes the time limits come to for `workflow`, nil for no limit or no workflow.
  defp time_limit(_workspace, _target, nil), do: nil

  defp time_limit(%Workspace{} = workspace, target, workflow) do
    case TimeLimits.Resolution.resolve(TimeLimits.limits_for(workspace, target, workflow)) do
      {:ok, %TimeLimits.Resolution{minutes: minutes}} -> minutes
      :none -> nil
    end
  end

  # Hand-over: with the workflow model, a run the stage runner queued takes the lower of
  # the minutes resolved here and its stage entry's time limit (`Apiary.Stages.limits/1`),
  # in whole minutes rounded up, and at least 15, the contract's least. The entry only
  # lowers: with no limit resolved here, the run has none, and the stack's default
  # applies, which Qory Apiary does not know.
  defp lowered(nil, _dispatch_run), do: nil

  defp lowered(minutes, dispatch_run) do
    case Apiary.Stages.limits(dispatch_run) do
      %{time_limit: seconds} when is_integer(seconds) ->
        min(minutes, max(div(seconds + 59, 60), @least_minutes))

      _none ->
        minutes
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
  # `:unstable` where the choices changed while `hold/1` read them, or `:unavailable`
  # where the run settings take more than 64 KiB.
  @doc false
  @spec build(map | :unstable | nil, DateTime.t()) ::
          {:ok, built | nil}
          | {:end, cause}
          | {:cooling, built, [Ecto.UUID.t()]}
          | :unstable
          | :unavailable
  def build(held, now \\ DateTime.utc_now())
  def build(nil, _now), do: {:ok, nil}
  def build(:unstable, _now), do: :unstable

  def build(%{} = held, %DateTime{} = now) do
    providers = providers(held)

    input =
      Map.put(
        held.input,
        :providers,
        Map.new(providers, fn {id, provider} ->
          {id, ModelChoices.resolution_provider(provider)}
        end)
      )

    case Resolution.resolve(input) do
      :none ->
        sealed(with_time_limit(runtime_only(ModelChoices.default_runtime()), held))

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
                 Connections.provider(provider),
                 runtime,
                 held.workspace.id
               ),
             {:ok, built} <-
               keys(built, provider, {input, resolution, providers, runtime}, held, now),
             do: sealed(with_time_limit(built, held))
    end
  end

  # The settings `built` of the choice's provider with its keys, else those of the first
  # fallback with a key not in cooldown, else `{:cooling, built, provider_ids}`: the
  # choice's settings without keys, and the providers whose keys were checked, the
  # choice's and each fallback that forms, every one with each key in cooldown.
  defp keys(built, provider, {input, resolution, providers, runtime}, held, now) do
    with nil <- keyed(built, provider, named_value_id(input), now) do
      case fallback(input, resolution, providers, runtime, held.workspace.id, now) do
        {:ok, _built} = fallen ->
          fallen

        {:cooling, ids} ->
          {:cooling, with_time_limit(built, held), Enum.uniq([provider.id | ids])}
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
  # the providers' responses, the next reset of its schedule, whether the choice names it,
  # and the end of its cooldown while it is in cooldown at `now`. Times are in whole
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
      {"cooldown_until", if(Order.cooling?(key, now), do: time(key.cooldown_until))}
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
  # for none, with the fallbacks that formed, each with every key in cooldown. A
  # fallback that does not form, for any of the causes that end a run on the choice's
  # provider, is passed over.
  defp fallback(
         input,
         %Resolution{fallbacks: fallbacks} = resolution,
         providers,
         runtime,
         ws,
         now
       ) do
    Enum.reduce_while(fallbacks, {:cooling, []}, fn %{connection_id: id} = fallback,
                                                    {:cooling, ids} ->
      provider = Map.fetch!(providers, id)
      fallen = Resolution.fallback(input, resolution, fallback)

      with true <- Connections.intact?(provider),
           {:ok, built} <- form(fallen, provider, Connections.provider(provider), runtime, ws) do
        case keyed(built, provider, nil, now) do
          {:ok, _built} = keyed -> {:halt, keyed}
          nil -> {:cont, {:cooling, ids ++ [provider.id]}}
        end
      else
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
    {chain, owner} = ModelChoices.chain_owner(organisation.id)
    ids = provider_ids(input)

    # The providers of the run's chain are the rows of the organisation that chain is made
    # of: the run's organisation, or, on the operator's chain, the operator's.
    if ids == [] or is_nil(owner) do
      %{}
    else
      from(c in Connection,
        where: c.id in ^ids and c.organisation_id == ^owner,
        where: not is_nil(c.provider_kind) and c.chain == ^chain,
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

  # `time_limit_minutes` after the other members, when a limit resolved.
  defp with_time_limit(built, %{time_limit: minutes}) when is_integer(minutes) do
    wire = Jason.OrderedObject.new(built.wire.values ++ [{"time_limit_minutes", minutes}])
    %{built | wire: wire, stored: Map.put(built.stored, "time_limit_minutes", minutes)}
  end

  defp with_time_limit(built, _held), do: built

  # The settings within the column's bound, or the claim is refused.
  defp sealed(%{wire: wire} = built) do
    if byte_size(Jason.encode!(wire)) <= @max_bytes, do: {:ok, built}, else: :unavailable
  end

  # form/5 is the settings of `resolution` for `provider`, the connection as `hold/1` read
  # it, whose description in the catalogue is `description` (`Connections.provider/1`),
  # for the runs of `runtime` in the workspace `workspace_id`. The first cause of the
  # moduledoc that applies, else `{:ok, built}`. A function of its arguments, which a test
  # calls with a description or a runtime the catalogue does not have.
  @doc false
  @spec form(
          Resolution.t(),
          Connection.t(),
          {:ok, Provider.t()} | {:error, atom},
          Runtime.t(),
          Ecto.UUID.t()
        ) :: {:ok, built} | {:end, cause}
  def form(resolution, provider, description, runtime, workspace_id) do
    with {:ok, description} <- described(description),
         :ok <- applies(provider, workspace_id),
         {:ok, api} <- api(description, runtime),
         {:ok, endpoint} <- endpoint(api, provider),
         :ok <- key(provider, resolution.value_id),
         models = Connections.provider_models(description),
         :ok <- model(models, resolution, runtime) do
      {:ok, built(resolution, provider, models, runtime, %{api | "endpoint" => endpoint})}
    end
  end

  defp described({:ok, %Provider{} = description}), do: {:ok, description}
  defp described(_changed_or_unknown), do: {:end, :provider_gone}

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
  defp endpoint(%{"endpoint" => address}, _provider) when is_binary(address), do: {:ok, address}

  defp endpoint(%{"endpoint" => %{"setting" => name}}, %Connection{} = provider) do
    address = Map.get(Connection.settings_map(provider), name)

    case Endpoint.check(address) do
      :ok -> {:ok, address}
      {:error, _refusal} -> {:end, :provider_gone}
    end
  end

  defp key(%Connection{secret: %Secret{values: values}}, value_id) when is_binary(value_id) do
    if Enum.any?(values, &(&1.value_id == value_id)), do: :ok, else: {:end, :key_gone}
  end

  defp key(%Connection{}, _value_id), do: {:end, :key_gone}

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
        provider_api: Map.take(api, ~w(format endpoint auth key_prefixes))
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
