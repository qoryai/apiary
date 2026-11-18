defmodule ApiaryWeb.StagesLive.ModelPart do
  # The model part of a workflow's fold on the Workflows page (`ApiaryWeb.StagesLive.Index`,
  # drawn by `ApiaryWeb.StagesLive.Inspector`): the workflow's model choice, level 4 of
  # `Apiary.ModelChoices`, `{:workspace, workflow}`. A workflow uses the workspace default,
  # the workspace's choice (level 5), else the organisation's (level 6), or overrides it
  # with a whole set: one key and the three tiers of the key's provider, as
  # `ApiaryWeb.ModelTiers` draws them, and no fallbacks. A save of a key writes that set;
  # a save of the default removes the override.
  #
  # `load/1` reads what every row needs: the overrides by workflow, the default, the
  # default's runtime, and the providers that apply to the workspace. A row's Key offers
  # each key of a provider that serves a runtime of the catalogue
  # (`Apiary.Kinds.Providers.runtimes/1`) and is offered
  # (`Apiary.Kinds.Providers.offered?/1`), and the key of the row's override while its
  # provider is not offered, so a save does not change it unseen. With a key, Runtime
  # follows the tiers: the runtimes the key's provider serves. A row's state, by its row
  # (`Inspector.time_limit_key/2`), is the Key's value, the runtime, the tiers, the
  # refusals of the last save, and whether it was just saved.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  use Gettext, backend: ApiaryWeb.Gettext

  alias Apiary.{Connections, ModelChoices}
  alias Apiary.Accounts.Scope
  alias Apiary.Connections.Connection
  alias Apiary.Kinds.{Providers, Runtime, Runtimes}
  alias Apiary.ModelChoices.ModelChoice
  alias ApiaryWeb.ModelTiers

  @doc """
  What the rows read of the model choices: `overrides`, the workspace's choice of each
  workflow by its name; `default`, `{:workspace, label}`, `{:organisation, name, label}`
  or `:none`, with the label "<Provider> · <key>"; `runtime`, the default's runtime, else
  the catalogue's default; and `providers`, each a map of `provider`, `runtimes` (the
  runtimes it serves), `models_by` (its suggestions for each of them, by the runtime's
  name), `free` and `offered`. nil where the scope may not read the choices, or the
  features `factory` and `secrets` are not both shown to it.
  """
  @spec load(Scope.t()) :: map | nil
  def load(%Scope{workspace: %{id: workspace_id}} = scope) do
    with {:ok, choices} <- ModelChoices.list_choices(scope),
         {:ok, providers} <- Connections.list_providers(scope) do
      at_workspace = for %ModelChoice{workspace_id: ^workspace_id} = c <- choices, do: c

      overrides =
        for %ModelChoice{target_id: nil, workflow: workflow} = choice <- at_workspace,
            is_binary(workflow),
            into: %{},
            do: {workflow, choice}

      workspace = Enum.find(at_workspace, &(is_nil(&1.target_id) and is_nil(&1.workflow)))

      organisation =
        Enum.find(choices, &(is_nil(&1.workspace_id) and is_nil(&1.target_id)))

      runtime = runtime(workspace || organisation)

      %{
        overrides: overrides,
        default: default(workspace, organisation, scope),
        runtime: runtime,
        providers: entries(providers, workspace_id, overrides)
      }
    else
      _not_shown -> nil
    end
  end

  def load(%Scope{}), do: nil

  defp runtime(choice) do
    case ModelChoices.runtime(choice && choice.runtime) do
      {:ok, runtime} -> runtime
      :error -> ModelChoices.default_runtime()
    end
  end

  # The default a workflow without an override uses: the workspace's choice, else the
  # organisation's, each with its provider; `:none` without either.
  defp default(%ModelChoice{connection: %Connection{}} = choice, _organisation, _scope),
    do: {:workspace, label(choice)}

  defp default(_workspace, %ModelChoice{connection: %Connection{}} = choice, scope),
    do: {:organisation, scope.organisation.name, label(choice)}

  defp default(_workspace, _organisation, _scope), do: :none

  defp label(%ModelChoice{connection: provider, value_id: value_id}) do
    case value_id || provider.default_value_id do
      nil -> provider.name
      key -> gettext("%{provider} · %{key}", provider: provider.name, key: key)
    end
  end

  # The providers that apply to the workspace, with their descriptions: each that serves
  # a runtime and is offered, and the provider of an override, whichever it is.
  defp entries(providers, workspace_id, overrides) do
    stored = for {_workflow, choice} <- overrides, into: MapSet.new(), do: choice.connection_id

    for provider <- providers,
        applies?(provider, workspace_id),
        {:ok, description} <- [Connections.provider(provider)],
        runtimes = Providers.runtimes(description),
        offered <- [Providers.offered?(description) and runtimes != []],
        offered or MapSet.member?(stored, provider.id),
        do: %{
          provider: provider,
          runtimes: runtimes,
          models_by: Map.new(runtimes, &{&1.name, ModelChoices.suggestions(provider, &1)}),
          free: Connections.provider_models(description) == [],
          offered: offered
        }
  end

  defp applies?(%Connection{applies_to: "all"}, _workspace_id), do: true

  defp applies?(%Connection{workspaces: workspaces}, workspace_id),
    do: Enum.any?(workspaces, &(&1.workspace_id == workspace_id))

  @doc """
  The keys the row of `workflow` offers (`ApiaryWeb.ModelTiers.keys/2`): those of the
  offered providers, and the key of the workflow's override; each with its provider's
  models for the runtime named `name`, where the provider serves it, else for the first
  runtime it serves.
  """
  @spec keys(map, String.t(), String.t() | nil) :: [map]
  def keys(model, workflow, name) do
    providers =
      for entry <- model.providers do
        runtime = ModelTiers.runtime(entry.runtimes, name)
        Map.put(entry, :models, Map.get(entry.models_by, runtime && runtime.name, []))
      end

    ModelTiers.keys(providers, model.overrides[workflow])
  end

  @doc """
  The runtimes the provider of `key` serves, and the one of them a row shows for the
  runtime named `name` (`ApiaryWeb.ModelTiers.runtime/2`): `{[], nil}` for no key.
  """
  @spec runtimes(map, map | nil, String.t() | nil) :: {[Runtime.t()], Runtime.t() | nil}
  def runtimes(_model, nil, _name), do: {[], nil}

  def runtimes(model, key, name) do
    runtimes =
      case Enum.find(model.providers, &(&1.provider.id == key.provider.id)) do
        %{runtimes: runtimes} -> runtimes
        nil -> []
      end

    {runtimes, ModelTiers.runtime(runtimes, name)}
  end

  @doc "The state of the row `row` of `workflow`: its state in `rows`, else the saved one."
  @spec state(map, map, String.t(), String.t()) :: map
  def state(model, rows, row, workflow) do
    case rows[row] do
      %{workflow: ^workflow} = state -> state
      _other -> saved(model, workflow)
    end
  end

  @doc """
  The state of a row of `workflow` as its override, or none, has it. The runtime is the
  override's, or the default's where the override names none, while the key's provider
  serves it; else the first runtime that provider serves.
  """
  @spec saved(map, String.t()) :: map
  def saved(model, workflow) do
    stored = model.overrides[workflow]
    name = (stored && stored.runtime) || model.runtime.name
    key = ModelTiers.chosen(keys(model, workflow, name), stored)
    {_runtimes, runtime} = runtimes(model, key, name)

    %{
      workflow: workflow,
      value: (key && key.value) || "",
      runtime: runtime && runtime.name,
      tiers: ModelTiers.params(stored, key),
      errors: [],
      done: false,
      refused: false
    }
  end

  @doc """
  The state after a change the form sent: the Key's value, "" for the default; the
  runtime sent while the key's provider serves it, else the first it serves, so a change
  of Key keeps the runtime where it can; and the tiers, fitted to the key
  (`ApiaryWeb.ModelTiers.sent/5`). A change of the runtime keeps the models, and an
  effort the runtime does not accept goes back to Not set. A key the row does not offer
  keeps the Key as it was. Back from the default to the override's key, the tiers are
  the override's.
  """
  @spec change(map, map, map) :: map
  def change(model, state, params) do
    stored = model.overrides[state.workflow]
    keys = keys(model, state.workflow, state.runtime)
    before = ModelTiers.find(keys, state.value)

    value =
      case params["key"] do
        "" ->
          ""

        value when is_binary(value) ->
          if ModelTiers.find(keys, value), do: value, else: state.value

        _none ->
          state.value
      end

    name =
      if is_binary(params["runtime"]),
        do: params["runtime"],
        else: state.runtime || (stored && stored.runtime) || model.runtime.name

    {_runtimes, runtime} = runtimes(model, ModelTiers.find(keys, value), name)
    key = ModelTiers.find(keys(model, state.workflow, runtime && runtime.name), value)

    tiers =
      cond do
        key == nil ->
          ModelTiers.blank()

        before == nil and ModelTiers.chosen([key], stored) != nil ->
          ModelTiers.params(stored, key)

        true ->
          stored = ModelTiers.stored(stored)
          stored = if runtime, do: ModelTiers.accepted(stored, runtime), else: stored
          ModelTiers.sent(key, before, state.tiers, params["tiers"], stored)
      end

    runtime = runtime && runtime.name

    same =
      state.done and value == state.value and runtime == state.runtime and tiers == state.tiers

    %{
      state
      | value: value,
        runtime: runtime,
        tiers: tiers,
        errors: [],
        done: same,
        refused: false
    }
  end

  @doc """
  Whether the row's Key, runtime or tiers differ from what is saved for its workflow.
  """
  @spec changed?(map, map) :: boolean
  def changed?(model, state) do
    saved = saved(model, state.workflow)

    state.value != saved.value or
      (state.value != "" and (state.tiers != saved.tiers or state.runtime != saved.runtime))
  end

  @doc """
  Saves the row: `:ok` once the override is written, or removed for the default;
  `{:refused, state}` with the refusals placed on their fields
  (`ApiaryWeb.ModelTiers.field_errors/2`); else `{:error, reason}`. A key the row does
  not offer, sent all the same, is refused on Key, and nothing is written.
  """
  @spec save(Scope.t(), map, map, map) :: :ok | {:refused, map} | {:error, term}
  def save(scope, model, state, params) do
    sent = params["key"]
    keys = keys(model, state.workflow, state.runtime)

    if is_binary(sent) and sent != "" and ModelTiers.find(keys, sent) == nil do
      {:refused, refused(state, key: {"is invalid", []})}
    else
      state = change(model, state, params)

      write(
        scope,
        model,
        state,
        ModelTiers.find(keys(model, state.workflow, state.runtime), state.value)
      )
    end
  end

  defp write(scope, _model, state, nil) do
    case ModelChoices.delete_choice(scope, {:workspace, state.workflow}) do
      {:ok, _choice} -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp write(scope, _model, state, key) do
    attrs =
      key
      |> ModelTiers.attrs(state.tiers)
      |> Map.merge(%{
        fallbacks: [],
        runtime: if(length(Runtimes.list()) > 1, do: state.runtime)
      })

    case ModelChoices.put_choice(scope, {:workspace, state.workflow}, attrs) do
      {:ok, _choice} -> :ok
      {:error, %Ecto.Changeset{errors: errors}} -> {:refused, refused(state, errors)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp refused(state, errors),
    do: %{
      state
      | errors: ModelTiers.field_errors(errors, state.tiers),
        done: false,
        refused: true
    }
end
