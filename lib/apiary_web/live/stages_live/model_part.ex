defmodule ApiaryWeb.StagesLive.ModelPart do
  # The model part of a workflow's fold on the Workflows page (`ApiaryWeb.StagesLive.Index`,
  # drawn by `ApiaryWeb.StagesLive.Inspector`): the workflow's model choice, level 4 of
  # `Apiary.ModelChoices`, `{:workspace, workflow}`. A workflow uses the workspace default,
  # the workspace's choice (level 5), else the organisation's (level 6), or overrides it
  # with a whole set: one model provider and the three tiers of that provider, as
  # `ApiaryWeb.ModelTiers` draws them, and no fallbacks. A save of a provider writes that
  # set; a save of the default removes the override.
  #
  # `load/1` reads what every row needs: the overrides by workflow, the default, the
  # default's runtime, and the providers that apply to the workspace. A row's Provider
  # offers each provider that is offered (`Apiary.Kinds.Providers.offered?/1`), also one
  # that serves no runtime of the catalogue (`Apiary.Kinds.Providers.runtimes/1`), and the
  # provider of the row's override while it is not offered, so a save does not change it
  # unseen. A provider that serves no runtime has a line under Provider, and a save of it
  # writes nothing (`no_runtime/2`). With a provider, Runtime follows the tiers: the
  # runtimes the provider serves. A row's state, by its row
  # (`Inspector.time_limit_key/2`), is the Provider's value, the runtime, the tiers, the
  # refusals of the last save, and whether it was just saved.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  alias Apiary.{Connections, ModelChoices, Organisations, Processes}
  alias Apiary.Accounts.Scope
  alias Apiary.Connections.Connection
  alias Apiary.Kinds.{Providers, Runtime, Runtimes}
  alias Apiary.ModelChoices.ModelChoice
  alias ApiaryWeb.ModelTiers

  @doc """
  What the rows read of the model choices: `overrides`, the workspace's choice of each
  workflow by its name; `default`, `{:workspace, label}`, `{:organisation, name, label}`
  or `:none`, with the label the provider's name; `runtime`, the default's runtime, else
  the catalogue's default; and `providers`, each a map of `provider`, `title`, `runtimes`
  (the runtimes it serves), `models_by` (its suggestions for each of them, by the
  runtime's name), `free`, `offered`, and `no_runtime`, true for a provider whose
  description serves no runtime. nil where the scope may not read the choices, or the
  features `factory` and `secrets` are not both shown to it.
  """
  @spec load(Scope.t()) :: map | nil
  def load(%Scope{workspace: %{id: workspace_id}} = scope) do
    with {:ok, choices} <- ModelChoices.list_choices(scope),
         {:ok, providers} <- Connections.list_providers(scope) do
      at_workspace = for %ModelChoice{workspace_id: ^workspace_id} = c <- choices, do: c

      # Only the overrides the workspace keeps (`Apiary.Processes.kept_workflows/1`): a
      # workflow that comes back after its override was left over starts from the default.
      kept = Processes.kept_workflows(scope.workspace)

      overrides =
        for %ModelChoice{target_id: nil, workflow: workflow} = choice <- at_workspace,
            is_binary(workflow),
            MapSet.member?(kept, workflow),
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
        providers: provider_entries(providers, workspace_id, overrides)
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

  defp label(%ModelChoice{connection: provider}), do: provider.name

  # The providers that apply to the workspace, with their descriptions: each that is
  # offered, and the provider of an override, whichever it is. The provider of an override
  # whose description cannot be read stays, not offered and with no runtimes and no
  # models, so its row shows the override's provider and can remove it.
  defp provider_entries(providers, workspace_id, overrides) do
    stored = for {_workflow, choice} <- overrides, into: MapSet.new(), do: choice.connection_id

    for provider <- providers,
        applies?(provider, workspace_id),
        entry <- entry(provider, MapSet.member?(stored, provider.id)),
        do: entry
  end

  defp entry(provider, stored?) do
    case Connections.provider(provider) do
      {:ok, description} ->
        runtimes = Providers.runtimes(description)
        offered = Providers.offered?(description)

        if offered or stored?,
          do: [
            %{
              provider: provider,
              title: description.title,
              runtimes: runtimes,
              models_by: Map.new(runtimes, &{&1.name, ModelChoices.suggestions(provider, &1)}),
              free: Connections.provider_models(description) == [],
              offered: offered,
              no_runtime: runtimes == []
            }
          ],
          else: []

      {:error, _reason} when stored? ->
        [
          %{
            provider: provider,
            title: provider.name,
            runtimes: [],
            models_by: %{},
            free: false,
            offered: false,
            no_runtime: false
          }
        ]

      {:error, _reason} ->
        []
    end
  end

  defp applies?(%Connection{applies_to: "all"}, _workspace_id), do: true

  defp applies?(%Connection{workspaces: workspaces}, workspace_id),
    do: Enum.any?(workspaces, &(&1.workspace_id == workspace_id))

  @doc """
  The providers the row of `workflow` offers (`ApiaryWeb.ModelTiers.entries/2`): the
  offered providers, and the provider of the workflow's override; each with its models
  for the runtime named `name`, where the provider serves it, else for the first runtime
  it serves.
  """
  @spec entries(map, String.t(), String.t() | nil) :: [map]
  def entries(model, workflow, name) do
    providers =
      for entry <- model.providers do
        runtime = ModelTiers.runtime(entry.runtimes, name)
        Map.put(entry, :models, Map.get(entry.models_by, runtime && runtime.name, []))
      end

    ModelTiers.entries(providers, model.overrides[workflow])
  end

  @doc """
  The runtimes the provider of `entry` serves, and the one of them a row shows for the
  runtime named `name` (`ApiaryWeb.ModelTiers.runtime/2`): `{[], nil}` for no provider.
  """
  @spec runtimes(map, map | nil, String.t() | nil) :: {[Runtime.t()], Runtime.t() | nil}
  def runtimes(_model, nil, _name), do: {[], nil}

  def runtimes(model, entry, name) do
    runtimes =
      case entry_of(model, entry) do
        %{runtimes: runtimes} -> runtimes
        nil -> []
      end

    {runtimes, ModelTiers.runtime(runtimes, name)}
  end

  @doc """
  The title of the provider of `entry` as its catalogue entry has it, such as
  "OpenRouter", which the Runtime line uses; the provider's name where its description
  cannot be read.
  """
  @spec provider_title(map, map) :: String.t()
  def provider_title(model, entry) do
    case entry_of(model, entry) do
      %{title: title} -> title
      nil -> entry.provider.name
    end
  end

  @doc """
  The line under Provider while the provider of `entry` serves no runtime of the
  catalogue (`ApiaryWeb.ModelTiers.no_runtime_line/1`); nil for any other provider, and
  for none.
  """
  @spec no_runtime(map, map | nil) :: String.t() | nil
  def no_runtime(_model, nil), do: nil

  def no_runtime(model, entry) do
    case entry_of(model, entry) do
      %{no_runtime: true, title: title} -> ModelTiers.no_runtime_line(title)
      _fits -> nil
    end
  end

  defp entry_of(model, entry),
    do: Enum.find(model.providers, &(&1.provider.id == entry.provider.id))

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
  override's, or the catalogue's default where the override names none, as a run takes it;
  with no override, the default's. Either while the provider serves it; else the first
  runtime that provider serves.
  """
  @spec saved(map, String.t()) :: map
  def saved(model, workflow) do
    stored = model.overrides[workflow]
    name = runtime_name(model, stored)
    entry = ModelTiers.chosen(entries(model, workflow, name), stored)
    {_runtimes, runtime} = runtimes(model, entry, name)

    %{
      workflow: workflow,
      value: (entry && entry.value) || "",
      runtime: runtime && runtime.name,
      tiers: ModelTiers.params(stored, entry),
      errors: [],
      done: false,
      refused: false
    }
  end

  @doc """
  The state after a change the form sent: the Provider's value, "" for the default; the
  runtime sent while the provider serves it, else the first it serves, so a change of
  Provider keeps the runtime where it can; and the tiers, fitted to the provider
  (`ApiaryWeb.ModelTiers.sent/5`). A change of the runtime keeps the models, and an
  effort the runtime does not accept goes back to Not set. A provider the row does not
  offer keeps the Provider as it was. Back from the default to the override's provider,
  the tiers are the override's.
  """
  @spec change(map, map, map) :: map
  def change(model, state, params) do
    stored = model.overrides[state.workflow]
    entries = entries(model, state.workflow, state.runtime)
    before = ModelTiers.find(entries, state.value)

    value =
      case params["provider"] do
        "" ->
          ""

        value when is_binary(value) ->
          if ModelTiers.find(entries, value), do: value, else: state.value

        _none ->
          state.value
      end

    name =
      if is_binary(params["runtime"]),
        do: params["runtime"],
        else: state.runtime || runtime_name(model, stored)

    {_runtimes, runtime} = runtimes(model, ModelTiers.find(entries, value), name)
    entry = ModelTiers.find(entries(model, state.workflow, runtime && runtime.name), value)

    tiers =
      cond do
        entry == nil ->
          ModelTiers.blank()

        before == nil and ModelTiers.chosen([entry], stored) != nil ->
          ModelTiers.params(stored, entry)

        true ->
          stored = ModelTiers.stored(stored)
          stored = if runtime, do: ModelTiers.accepted(stored, runtime), else: stored
          ModelTiers.sent(entry, before, state.tiers, params["tiers"], stored)
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
  Whether the row's Provider, runtime or tiers differ from what is saved for its workflow. A
  stored runtime other than the one the row shows, such as one the catalogue no longer
  has, is a change, so a save can write the one the row shows.
  """
  @spec changed?(map, map) :: boolean
  def changed?(model, state) do
    saved = saved(model, state.workflow)
    stored = model.overrides[state.workflow]

    state.value != saved.value or
      (state.value != "" and
         (state.tiers != saved.tiers or state.runtime != saved.runtime or
            (stored != nil and state.runtime != nil and
               runtime_name(model, stored) != state.runtime)))
  end

  # The runtime of the override `stored`: its own name, or the catalogue's default where
  # it names none, as a run takes it (`Apiary.ModelChoices.default_runtime/0`); with no
  # override, the workspace default's, so a new override starts from it.
  defp runtime_name(model, nil), do: model.runtime.name

  defp runtime_name(_model, %ModelChoice{runtime: runtime}),
    do: runtime || ModelChoices.default_runtime().name

  @doc """
  Saves the row: `:ok` once the override is written, or removed for the default;
  `{:refused, state}` with the refusals placed on their fields
  (`ApiaryWeb.ModelTiers.field_errors/2`); else `{:error, reason}`. A provider the row
  does not offer, sent all the same, is refused on Provider, and nothing is written. A
  provider that serves no runtime writes nothing: its line under Provider says why
  (`no_runtime/2`).
  """
  @spec save(Scope.t(), map, map, map) :: :ok | {:refused, map} | {:error, term}
  def save(scope, model, state, params) do
    sent = params["provider"]
    entries = entries(model, state.workflow, state.runtime)

    if is_binary(sent) and sent != "" and ModelTiers.find(entries, sent) == nil do
      {:refused, refused(state, provider: {"is invalid", []})}
    else
      state = change(model, state, params)
      entry = ModelTiers.find(entries(model, state.workflow, state.runtime), state.value)

      if no_runtime(model, entry),
        do: {:refused, refused(state, [])},
        else: write(scope, model, state, entry)
    end
  end

  # No override to remove is what the save asked for, while the workspace is still in use;
  # a workspace gone, or marked for deletion, is `{:error, :not_found}`.
  defp write(scope, _model, state, nil) do
    case ModelChoices.delete_choice(scope, {:workspace, state.workflow}) do
      {:ok, _choice} -> :ok
      {:error, :not_found} -> if workspace_in_use?(scope), do: :ok, else: {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write(scope, _model, state, entry) do
    attrs =
      entry
      |> ModelTiers.attrs(state.tiers)
      |> Map.merge(%{
        fallbacks: [],
        runtime: if(Runtimes.several?(), do: state.runtime)
      })

    case ModelChoices.put_choice(scope, {:workspace, state.workflow}, attrs) do
      {:ok, _choice} -> :ok
      {:error, %Ecto.Changeset{errors: errors}} -> {:refused, refused(state, errors)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp workspace_in_use?(%Scope{workspace: %{id: id}} = scope),
    do: Enum.any?(Organisations.list_workspaces(scope), &(&1.id == id))

  defp refused(state, errors),
    do: %{
      state
      | errors: ModelTiers.field_errors(errors, state.tiers),
        done: false,
        refused: true
    }
end
