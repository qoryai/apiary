defmodule Apiary.Dispatches.RunSettings do
  @moduledoc false

  # The `run_settings` of a handover answer (`handover-answer.schema.json`) and the values
  # a run keeps of them (`Apiary.Runs.Run`): what the model choices of the run's workspace
  # and target come to (`Apiary.ModelChoices.Resolution`), checked again at the handover.
  # `Apiary.Dispatches.Handover` calls `hold/1` before it locks anything else, and
  # `build/1` once its run of the queue and its dispatch are locked.
  #
  # Only an explore run has `run_settings`, and only with both features `factory` and
  # `secrets` on; without either, the answer has none. With them on and no choice at any
  # level, it has `runtime` alone, and the run uses the gateway's key.
  #
  # ## What it holds
  #
  # `hold/1` reads the choices of the run's chain without a lock, locks the rows of the
  # model providers they name `FOR SHARE`, by id, then the rows of those providers' keys'
  # secrets `FOR SHARE`, by id, and reads the choices again: should the second read name a
  # provider the first did not, it locks that one too, up to three times, else the handover
  # is refused (`:unavailable`) with nothing written. A change to a provider takes its row
  # `FOR UPDATE`, and a change to its keys the keys' secret's row, in the same order, so a
  # change and a handover of its run take turns: a handover that holds the row finishes
  # first, and the change then sees the run it registered; a change that came first is
  # seen by the handover, which reads the provider after the lock.
  #
  # ## What it checks
  #
  # `build/1` resolves the choices against the providers as they are once the rows are
  # held, and ends the run with the first cause that applies, in this order:
  #
  #   * `provider_gone`: the provider is not there, does not apply to the workspace
  #     any more, is no longer in the catalogue as it was added, or has no address that
  #     passes `Apiary.Kinds.Endpoint`;
  #   * `runtime_unserved`: the provider no longer serves the run's runtime
  #     (`Apiary.ModelChoices.serves/3`);
  #   * `key_gone`: the chosen key is no longer one of the provider's keys;
  #   * `model_gone`: the chosen model, or its effort value, is no longer on the
  #     provider's list;
  #   * `host_denied`: a deny rule in force for the run's workspace and target covers a host
  #     the provider's runs reach.
  #
  # ## What it writes
  #
  # `run_settings`, in the schema's order: `runtime`, `model`, `effort` when the choice has
  # one, `endpoint`, `provider_models` (every model of the provider's list with its effort
  # values) and `tiers`, a tier left out when no choice maps it to a model the provider
  # lists. The answer has no key, no secret and no id of a key, and neither has the
  # stored copy: the run keeps the provider's row id, its keys' secret's row id, the
  # chosen key's value id and the provider's chain beside it, for the reads that follow
  # the handover. At most 64 KiB encoded; more refuses the handover.
  #
  # Reads, and takes the locks above; writes nothing, and logs nothing.

  import Ecto.Query, only: [from: 2]

  alias Apiary.{Connections, Edition, Features, ModelChoices, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Connections.{Connection, ProviderModel}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Kinds.{Endpoint, Provider, Runtime, Runtimes}
  alias Apiary.ModelChoices.Resolution
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Runs.Target
  alias Apiary.Secrets.{Secret, Value}
  alias Apiary.WorkItems.WorkItem

  @run_kind "explore"
  # The most bytes the run settings take, encoded: the column's check.
  @max_bytes 65_536
  # How often `hold/1` locks the providers a second read named.
  @tries 3

  @typedoc "The causes the handover ends a run for here."
  @type cause :: :provider_gone | :runtime_unserved | :key_gone | :model_gone | :host_denied

  @typedoc """
  What a handover writes: `wire`, the answer's `run_settings`; `stored`, the same as a
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
  def causes, do: [:provider_gone, :runtime_unserved, :key_gone, :model_gone, :host_denied]

  # hold/1 is what the handover of the run of the queue `dispatch_run` holds before it
  # locks anything: nil for a run that has no `run_settings`, else what `build/1` takes.
  @doc false
  @spec hold(DispatchRun.t()) :: map | :unstable | nil
  def hold(%DispatchRun{step: @run_kind, workspace_id: workspace_id, work_item_id: id}) do
    if Features.on?(:factory) and Features.on?(:secrets) do
      workspace = Repo.get!(Workspace, workspace_id)
      organisation = Repo.get!(Organisation, workspace.organisation_id)
      target = target(workspace, id)

      case lock(workspace, target, [], @tries) do
        {:ok, input} ->
          %{organisation: organisation, workspace: workspace, target: target, input: input}

        :unstable ->
          :unstable
      end
    end
  end

  def hold(%DispatchRun{}), do: nil

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
  defp lock(workspace, target, locked, tries) do
    input = ModelChoices.choices_for(workspace, target, @run_kind)
    ids = for %{connection_id: id} <- input.choices, is_binary(id), uniq: true, do: id

    case ids -- locked do
      [] ->
        {:ok, input}

      _new when tries == 0 ->
        :unstable

      new ->
        lock_rows(Enum.sort(new))
        lock(workspace, target, locked ++ new, tries - 1)
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
  # `{:ok, built}`, `{:end, cause}`, or `:unavailable` where the handover cannot be made.
  @doc false
  @spec build(map | :unstable | nil) :: {:ok, built | nil} | {:end, cause} | :unavailable
  def build(nil), do: {:ok, nil}
  def build(:unstable), do: :unavailable

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
        sealed(runtime_only())

      {:error, :provider_removed} ->
        {:end, :provider_gone}

      {:ok, %Resolution{} = resolution} ->
        provider = Map.fetch!(providers, resolution.connection_id)
        {:ok, runtime} = Runtimes.fetch(ModelChoices.runtime_name())

        scope = %Scope{organisation: held.organisation, workspace: held.workspace}

        denied = fn description ->
          ModelChoices.denied?(provider, description, scope, held.workspace, held.target)
        end

        case form(
               resolution,
               provider,
               Connections.provider(provider),
               runtime,
               held.workspace.id,
               denied
             ) do
          {:ok, built} -> sealed(built)
          {:end, _cause} = ended -> ended
        end
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

  defp runtime_only do
    %{
      wire: Jason.OrderedObject.new([{"runtime", ModelChoices.runtime_name()}]),
      stored: %{"runtime" => ModelChoices.runtime_name()},
      columns: %{}
    }
  end

  # The settings within the column's bound, or the handover is refused.
  defp sealed(%{wire: wire} = built) do
    if byte_size(Jason.encode!(wire)) <= @max_bytes, do: {:ok, built}, else: :unavailable
  end

  # form/6 is the settings of `resolution` for `provider`, the connection as `hold/1` read
  # it, whose description in the catalogue is `description` (`Connections.provider/1`),
  # for the runs of `runtime` in the workspace `workspace_id`; `denied` is given the
  # description and says whether a deny rule covers a host. The first cause of the
  # moduledoc that applies, else `{:ok, built}`. A function of its arguments, which a test
  # calls with a description or a runtime the catalogue does not have.
  @doc false
  @spec form(
          Resolution.t(),
          Connection.t(),
          {:ok, Provider.t()} | {:error, atom},
          Runtime.t(),
          Ecto.UUID.t(),
          (Provider.t() -> boolean)
        ) :: {:ok, built} | {:end, cause}
  def form(resolution, provider, description, runtime, workspace_id, denied) do
    with {:ok, description} <- described(description),
         :ok <- applies(provider, workspace_id),
         {:ok, endpoint} <- endpoint(description, provider),
         :ok <- served(description, runtime),
         :ok <- key(provider, resolution.value_id),
         {:ok, model} <- model(provider, resolution),
         :ok <- not_denied(denied.(description)) do
      {:ok, built(resolution, provider, model, endpoint)}
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

  # The address of the provider's API: its description's, or the one its address setting has.
  defp endpoint(%Provider{endpoint: address}, _provider) when is_binary(address),
    do: checked(address)

  defp endpoint(%Provider{endpoint: %{"setting" => name}}, %Connection{} = provider),
    do: checked(Map.get(Connection.settings_map(provider), name))

  defp checked(address) do
    case Endpoint.check(address) do
      :ok -> {:ok, address}
      {:error, _refusal} -> {:end, :provider_gone}
    end
  end

  defp served(description, runtime) do
    case ModelChoices.serves(description, runtime) do
      :ok -> :ok
      {:error, _refusal} -> {:end, :runtime_unserved}
    end
  end

  defp key(%Connection{secret: %Secret{values: values}}, value_id) when is_binary(value_id) do
    if Enum.any?(values, &(&1.value_id == value_id)), do: :ok, else: {:end, :key_gone}
  end

  defp key(%Connection{}, _value_id), do: {:end, :key_gone}

  defp model(%Connection{models: models}, %Resolution{model_id: model_id, effort: effort}) do
    case Enum.find(models, &(&1.model_id == model_id)) do
      %ProviderModel{} = model ->
        if is_nil(effort) or effort in (model.effort || []),
          do: {:ok, model},
          else: {:end, :model_gone}

      nil ->
        {:end, :model_gone}
    end
  end

  defp not_denied(false), do: :ok
  defp not_denied(true), do: {:end, :host_denied}

  defp built(
         %Resolution{} = resolution,
         %Connection{} = provider,
         %ProviderModel{} = model,
         endpoint
       ) do
    members =
      [{"runtime", ModelChoices.runtime_name()}, {"model", model.model_id}] ++
        if(resolution.effort, do: [{"effort", resolution.effort}], else: []) ++
        [
          {"endpoint", endpoint},
          {"provider_models", Enum.map(provider.models, &listed/1)}
        ] ++ tiers(resolution.tiers)

    wire = Jason.OrderedObject.new(members)

    %{
      wire: wire,
      stored: wire |> Jason.encode!() |> Jason.decode!(),
      columns: %{
        provider_connection_id: provider.id,
        provider_secret_id: provider.secret_id,
        provider_value_id: resolution.value_id,
        provider_chain: provider.chain
      }
    }
  end

  defp listed(%ProviderModel{model_id: id, effort: effort}) when effort in [nil, []],
    do: Jason.OrderedObject.new([{"id", id}])

  defp listed(%ProviderModel{model_id: id, effort: effort}),
    do: Jason.OrderedObject.new([{"id", id}, {"effort", effort}])

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
