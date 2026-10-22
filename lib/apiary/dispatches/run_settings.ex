defmodule Apiary.Dispatches.RunSettings do
  @moduledoc false

  # The `run_settings` of a run's documents and the values a run keeps of them
  # (`Apiary.Runs.Run`): what the model choices of the run's workspace and target come to
  # (`Apiary.ModelChoices.Resolution`), checked again at the claim. The choices and the
  # time limits are read for the workflow of the workspace's entry in the machines file
  # (`Apiary.Dispatches.MachinesFile.stack/2`); for an entry with no workflow, only the
  # choices without one apply.
  # The claim (`Apiary.Dispatches.claim/3`) locks the pool's row, the gateway's row, the
  # records a lapse needs (`Apiary.Dispatches.Slots`), the run of the queue it took and the
  # dispatch it inserted, in that order; then `Apiary.Dispatches.Handover.register/2` calls
  # `hold/1`, and `build/1` with what `hold/1` returned.
  #
  # Only an explore run has `run_settings`, and only with both features `factory` and
  # `secrets` on; without either, the documents have none. With them on and no choice at any
  # level, it has `runtime` alone, and the run uses the gateway's key.
  #
  # ## What it holds
  #
  # `hold/1` reads the choices of the run's chain without a lock, locks the rows of the
  # model providers they name `FOR SHARE`, by id, then the rows of those providers' keys'
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
  #   * `runtime_unserved`: no API of the provider serves the run's runtime
  #     (`Apiary.Kinds.Providers.api/2`);
  #   * `provider_gone`: the endpoint of that API is a setting whose address
  #     `Apiary.Kinds.Endpoint` refuses;
  #   * `key_gone`: the chosen key is no longer one of the provider's keys;
  #   * `model_gone`: the chosen model is no longer on the provider's list, or its effort
  #     value is no longer among both the model's and the runtime's effort values.
  #
  # A deny rule of the security policy is not asked: it never blocks a host of an
  # integration.
  #
  # ## What it writes
  #
  # `run_settings`, in the schema's order: `runtime`, `model`, `effort` when the choice has
  # one, `provider_models` (every model of the provider's list with the effort values that
  # both it and the runtime have) and `tiers`, a tier left out when no choice maps it to a
  # model the provider lists; then `time_limit_minutes`, the minutes the time limits of the
  # run's workspace and target come to for the workflow of the workspace's entry in the
  # machines file (`Apiary.TimeLimits.Resolution`, `Apiary.Dispatches.MachinesFile`), left
  # out when no limit resolves or the entry has no workflow. The limits are read without a
  # lock in `hold/1`. The documents have no key, no secret and no id of a key, and neither
  # has the stored copy. Beside it, the run keeps the provider's row id, its keys'
  # secret's row id, the chosen key's value id, the provider's chain and the API the run
  # uses (`provider_api`: its `format`, its `endpoint` with a setting resolved to its
  # address, its `auth` and, when the description lists them, its `key_prefixes`), for
  # the reads that follow the claim. The run settings take at most 64 KiB encoded; more
  # refuses the claim.
  #
  # Reads, and takes the locks above; writes nothing. It logs a provider that fails its
  # integrity code, by its public id.

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Apiary.{Connections, Edition, Features, ModelChoices, Repo, TimeLimits}
  alias Apiary.Connections.{Connection, ProviderModel}
  alias Apiary.Dispatches.{DispatchRun, MachinesFile}
  alias Apiary.Kinds.{Endpoint, Provider, Providers, Runtime, Runtimes}
  alias Apiary.ModelChoices.Resolution
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Runs.Target
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
  # locks anything: nil for a run that has no `run_settings`, else what `build/1` takes.
  @doc false
  @spec hold(DispatchRun.t()) :: map | :unstable | nil
  def hold(%DispatchRun{step: @step, workspace_id: workspace_id, work_item_id: id}) do
    if Features.on?(:factory) and Features.on?(:secrets) do
      workspace = Repo.get!(Workspace, workspace_id)
      organisation = Repo.get!(Organisation, workspace.organisation_id)
      target = target(workspace, id)
      workflow = workflow(organisation, workspace)

      case lock(workspace, target, workflow, [], @lock_rounds) do
        {:ok, input} ->
          %{
            organisation: organisation,
            workspace: workspace,
            target: target,
            input: input,
            time_limit: time_limit(workspace, target, workflow)
          }

        :unstable ->
          :unstable
      end
    end
  end

  def hold(%DispatchRun{}), do: nil

  # The workflow of the workspace's entry in the machines file, nil for none.
  defp workflow(%Organisation{slug: organisation_slug}, %Workspace{slug: workspace_slug}) do
    case MachinesFile.stack(organisation_slug, workspace_slug) do
      %{workflow: workflow} -> workflow
      _none -> nil
    end
  end

  # The minutes the time limits come to for `workflow`, nil for no limit or no workflow.
  defp time_limit(_workspace, _target, nil), do: nil

  defp time_limit(%Workspace{} = workspace, target, workflow) do
    case TimeLimits.Resolution.resolve(TimeLimits.limits_for(workspace, target, workflow)) do
      {:ok, %TimeLimits.Resolution{minutes: minutes}} -> minutes
      :none -> nil
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

  # The choices once every provider they name is held: read, lock what is new, read again.
  defp lock(workspace, target, workflow, locked, tries) do
    input = ModelChoices.choices_for(workspace, target, workflow)
    ids = for %{connection_id: id} <- input.choices, is_binary(id), uniq: true, do: id

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

  # build/1 is the run settings of what `hold/1` held: `{:ok, nil}` for a run with none,
  # `{:ok, built}`, `{:end, cause}`, `:unstable` where the choices changed while `hold/1`
  # read them, or `:unavailable` where the run settings take more than 64 KiB.
  @doc false
  @spec build(map | :unstable | nil) ::
          {:ok, built | nil} | {:end, cause} | :unstable | :unavailable
  def build(nil), do: {:ok, nil}
  def build(:unstable), do: :unstable

  def build(%{} = held) do
    providers = providers(held)

    resolved =
      Resolution.resolve(
        Map.put(
          held.input,
          :providers,
          Map.new(providers, fn {id, provider} ->
            {id, ModelChoices.resolution_provider(provider)}
          end)
        )
      )

    case resolved do
      :none ->
        sealed(with_time_limit(runtime_only(), held))

      {:error, :provider_removed} ->
        {:end, :provider_gone}

      {:ok, %Resolution{} = resolution} ->
        provider = Map.fetch!(providers, resolution.connection_id)
        {:ok, runtime} = Runtimes.fetch(ModelChoices.runtime_name())

        with :ok <- intact(provider),
             {:ok, built} <-
               form(
                 resolution,
                 provider,
                 Connections.provider(provider),
                 runtime,
                 held.workspace.id
               ),
             do: sealed(with_time_limit(built, held))
    end
  end

  # The providers the choices name, as they are now: with their models, the workspaces
  # they apply to and their keys' secret's value ids, by row id.
  defp providers(%{organisation: organisation, input: input}) do
    chain = Edition.model_choice_chain(organisation.id)
    ids = for %{connection_id: id} <- input.choices, is_binary(id), uniq: true, do: id

    from(c in Connection,
      where: c.id in ^ids and c.organisation_id == ^organisation.id,
      where: not is_nil(c.provider_kind) and c.chain == ^chain,
      preload: [
        models: ^from(m in ProviderModel, order_by: [asc: m.position]),
        workspaces: [],
        secret: [values: ^from(v in Value, select: struct(v, [:id, :value_id]))]
      ]
    )
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
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

  defp runtime_only do
    %{
      wire: Jason.OrderedObject.new([{"runtime", ModelChoices.runtime_name()}]),
      stored: %{"runtime" => ModelChoices.runtime_name()},
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
         {:ok, model} <- model(provider, resolution, runtime) do
      {:ok, built(resolution, provider, model, runtime, %{api | "endpoint" => endpoint})}
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

  # The chosen model on the provider's list, with an effort value that both the model's
  # and the runtime's lists have, or none.
  defp model(%Connection{models: models}, %Resolution{} = resolution, runtime) do
    case Enum.find(models, &(&1.model_id == resolution.model_id)) do
      %ProviderModel{} = model ->
        if is_nil(resolution.effort) or resolution.effort in offered(model, runtime),
          do: {:ok, model},
          else: {:end, :model_gone}

      nil ->
        {:end, :model_gone}
    end
  end

  # The effort values of `model` that the runtime's list has too, in the model's order.
  defp offered(%ProviderModel{effort: effort}, %Runtime{effort_values: values}),
    do: Enum.filter(effort || [], &(&1 in values))

  defp built(
         %Resolution{} = resolution,
         %Connection{} = provider,
         %ProviderModel{} = model,
         runtime,
         api
       ) do
    members =
      [{"runtime", ModelChoices.runtime_name()}, {"model", model.model_id}] ++
        if(resolution.effort, do: [{"effort", resolution.effort}], else: []) ++
        [{"provider_models", Enum.map(provider.models, &listed(&1, runtime))}] ++
        tiers(resolution.tiers)

    wire = Jason.OrderedObject.new(members)

    %{
      wire: wire,
      stored: wire |> Jason.encode!() |> Jason.decode!(),
      columns: %{
        provider_connection_id: provider.id,
        provider_secret_id: provider.secret_id,
        provider_value_id: resolution.value_id,
        provider_chain: provider.chain,
        provider_api: Map.take(api, ~w(format endpoint auth key_prefixes))
      }
    }
  end

  defp listed(%ProviderModel{model_id: id} = model, runtime) do
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
