defmodule Apiary.ModelChoices do
  # The model choices of an organisation: which runtime, model provider, key, model, effort
  # and tier map its runs use (`Apiary.ModelChoices.ModelChoice`), set at levels 2 to 6 here and
  # resolved for each run by `Apiary.ModelChoices.Resolution`.
  #
  # ## Places
  #
  # A choice is set at a place, given to the functions here as a holder and a workflow:
  #
  #   * `:organisation`, the organisation's default (level 6), with no workflow;
  #   * `:workspace`, the scope's workspace (level 5), or `{:workspace, workflow}` (level 4);
  #   * a target of the scope's workspace (`Apiary.Runs.Target`, level 3), or
  #     `{target, workflow}` (level 2).
  #
  # A workflow name is a lower-case letter, then up to 63 lower-case letters, digits and
  # hyphens. A place with a workflow of another form is not found. A run reads the
  # choices of its workflow (`Apiary.Stacks.workflow/2`), the same key as its time limit
  # (`Apiary.TimeLimits`).
  #
  # ## Who
  #
  # Levels 2 to 5 are written under `model_choice.write`, asked of the workspace or the
  # target; level 6 under `provider.write`, asked of the organisation. Reading is
  # `connection.read`.
  # Every write leaves one entry in its transaction, about the choice, of the action it was
  # asked under: `details.change` is `choice_set`, `choice_changed`, `choice_locked`,
  # `choice_unlocked` or `choice_removed`, with the `level`, the `workflow`, the target's
  # `target_id`, and `name`, the place's name.
  #
  # Everything here needs the features `factory` and `secrets`, shown to the scope: with
  # either off, every function answers `{:error, :not_found}`.
  #
  # ## Refused on save
  #
  # A save is checked, each refusal a changeset error on its field:
  #
  #   * `runtime`: a runtime of the catalogue (`Apiary.Kinds.Runtimes`), or none for the
  #     default (`default_runtime/0`); a choice that names one names a provider too;
  #   * `provider`: a model provider of the chain the choice is set on (`is invalid`
  #     otherwise), that applies to the workspace, and that serves the choice's runtime
  #     (`Apiary.Kinds.Providers.serve/2`). A deny rule of the security policy is not
  #     asked: it never blocks a host of an integration;
  #   * `key`: a value id of the provider's keys;
  #   * `model` and `effort`: a model id of the form `@model_id` takes, one of the
  #     description's models (`Connections.provider_models/1`) or any other id. With a
  #     model of the description, the effort is one of its offered effort values; with any
  #     other id, the choice sets no effort;
  #   * `tiers`: tiers among `light`, `fast` and `thinking`, each a model id, or a map of
  #     `model` and `effort`; with a provider, each tier as `model` and `effort` are.
  #
  # A model's **offered effort values** are the values that both the model's list in the
  # description and the runtime's (`Apiary.Kinds.Runtime`, `effort_values`) contain, in the
  # model's order; a model the description does not list has none. A resolution reads only
  # these.
  #
  # The organisation's default has no workspace, so the workspace is not asked of it: a
  # run whose workspace the default's provider does not reach is ended at its claim.
  #
  # The organisation's chain is written by anyone who may. The operator's chain
  # (`c:Apiary.Edition.model_choice_chain/1`) is written only at the organisation's
  # default, and only by a scope that the edition says writes it
  # (`c:Apiary.Edition.operator_chain_writer?/1`), with the same access check. The rows of
  # the operator's chain are read from the operator's organisation by the runs of its
  # clients, at that level alone (`choices_for/3`).
  #
  # ## Locks
  #
  # A write of levels 2 to 5 takes the organisation's rows `FOR SHARE`
  # (`Apiary.Access.lock_places/1`), the workspace's row `FOR NO KEY UPDATE`, the membership
  # `FOR SHARE`, then the provider's row `FOR SHARE`, then the choice's row `FOR UPDATE`.
  # A write of level 6 takes the organisation's rows and the membership, then the
  # organisation's integrations lock (`Apiary.Connections.lock/1`), then the provider's
  # row and the choice's row. A provider's change takes the provider's row `FOR UPDATE`, so
  # a save and a change of the same provider take turns, and each sees what the other
  # wrote.
  @moduledoc false

  use Gettext, backend: ApiaryWeb.Gettext

  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias Apiary.{Access, Audit, Connections, Edition, Features, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Connections.{Connection, ConnectionWorkspace}
  alias Apiary.Kinds.{Provider, Providers, Runtime, Runtimes}
  alias Apiary.ModelChoices.{ModelChoice, Resolution}
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Runs.Target
  alias Apiary.Secrets.Value
  alias ApiaryWeb.Format

  # A workflow's name.
  @workflow ~r/\A[a-z][a-z0-9-]{0,63}\z/

  # How many places a refusal names before "and N more".
  @shown 5

  @model_id ~r/\A[A-Za-z0-9][!-~]{0,199}\z/
  @effort ~r/\A[a-z][a-z0-9-]{0,31}\z/

  # The model ids and titles of models.dev for each provider of the catalogue, by the name
  # of its description, as `mix apiary.models.update` wrote them; read when the module is
  # compiled, so a release has the file's models and nothing reads it while it runs.
  @suggestions_path Path.expand("../../priv/models/suggestions.json", __DIR__)
  @external_resource @suggestions_path
  @suggestions (for {kind, models} <- @suggestions_path |> File.read!() |> Jason.decode!(),
                    into: %{} do
                  {kind,
                   for(%{"id" => id, "title" => title} <- models, do: %{id: id, title: title})}
                end)

  @typedoc "Whose choice: the organisation's default, the scope's workspace, or a target of it."
  @type holder :: :organisation | :workspace | Target.t()

  @typedoc "A place of a choice: a holder, alone or with a workflow."
  @type place :: holder | {:workspace | Target.t(), String.t()}

  @typedoc """
  A place as a refusal names it: its `level`, the `workspace`'s name, the `target`'s name,
  the `workflow`, and the `value_id` of the key it chose.
  """
  @type named_place :: %{
          level: ModelChoice.level(),
          workspace: String.t() | nil,
          target: String.t() | nil,
          workflow: String.t() | nil,
          value_id: String.t() | nil
        }

  @doc false
  # default_runtime/0 is the runtime of a choice that names none, and of a run whose
  # choices name no provider: the catalogue's only runtime (`Apiary.Kinds.Runtimes`).
  # With more than one in the catalogue, its first, in the catalogue's order.
  @spec default_runtime() :: Runtime.t()
  def default_runtime, do: hd(Runtimes.list())

  @doc false
  # runtime/1 is the runtime named `name`, the default for nil: `{:ok, runtime}`, or
  # `:error` for a name the catalogue does not have (any more).
  @spec runtime(String.t() | nil) :: {:ok, Runtime.t()} | :error
  def runtime(nil), do: {:ok, default_runtime()}
  def runtime(name), do: Runtimes.fetch(name)

  ## Reading

  @doc false
  # list_choices/2 is the choices of the organisation's chain at the organisation's default
  # and, where the scope has a workspace, at the workspace and its targets, each with its
  # provider and its target: `{:ok, choices}` for a reader who may `connection.read`; else
  # `{:error, reason}`. Given `chain` "operator", the choices of the operator's chain, for a
  # scope that writes it; else `{:error, :not_found}`.
  @spec list_choices(Scope.t(), String.t()) ::
          {:ok, [ModelChoice.t()]} | {:error, Access.reason()}
  def list_choices(%Scope{} = scope, chain \\ "organisation") do
    with :ok <- shown(scope),
         :ok <- chain_readable(scope, chain),
         {:ok, organisation} <- may_read(scope) do
      query =
        from c in ModelChoice,
          where: c.organisation_id == ^organisation.id and c.chain == ^chain,
          order_by: [asc: c.workspace_id, asc: c.target_id, asc: c.workflow, asc: c.id],
          preload: [:connection, :target]

      query =
        case scope.workspace do
          %Workspace{id: id} -> where(query, [c], is_nil(c.workspace_id) or c.workspace_id == ^id)
          nil -> where(query, [c], is_nil(c.workspace_id))
        end

      {:ok, Repo.all(query)}
    end
  end

  @doc false
  # resolve/3 is what the choices come to for the runs of `workflow` at `holder`, the
  # scope's workspace or a target of it, as `Apiary.ModelChoices.Resolution.resolve/1`
  # answers: `{:ok, {:ok, resolution}}`, `{:ok, :none}` or
  # `{:ok, {:error, :provider_removed}}`, for a reader who may `connection.read`; else
  # `{:error, reason}`.
  @spec resolve(Scope.t(), :workspace | Target.t(), String.t()) ::
          {:ok, {:ok, Resolution.t()} | :none | {:error, :provider_removed}}
          | {:error, Access.reason()}
  def resolve(%Scope{workspace: %Workspace{} = workspace} = scope, holder, workflow) do
    with :ok <- shown(scope),
         {:ok, _organisation} <- may_read(scope),
         true <- workflow?(workflow),
         {:ok, target} <- target(scope, holder) do
      {:ok, Resolution.resolve(input(workspace, target, workflow))}
    else
      false -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def resolve(%Scope{}, _holder, _workflow), do: {:error, :not_found}

  # What a resolution reads for the runs of `workflow` of `workspace` at `target`, nil for
  # none: the choices of the run's chain that may reach them, read from the organisation
  # that `chain_owner/1` names, and the providers those name. Read without a lock.
  defp input(%Workspace{} = workspace, target, workflow) do
    input = choices_for(workspace, target, workflow)
    ids = for %{connection_id: id} <- input.choices, is_binary(id), uniq: true, do: id
    {chain, owner} = chain_owner(workspace.organisation_id)

    providers =
      if ids == [] do
        %{}
      else
        Repo.all(
          from c in Connection,
            where:
              c.id in ^ids and c.organisation_id == ^owner and not is_nil(c.provider_kind) and
                c.chain == ^chain
        )
        |> Map.new(&{&1.id, resolution_provider(&1)})
      end

    Map.put(input, :providers, providers)
  end

  @doc false
  # chain_owner/1 is `{chain, organisation_id}`: the chain of model choices that the runs of
  # the organisation `organisation_id` use (`c:Apiary.Edition.model_choice_chain/1`), and the
  # organisation whose rows it is made of: the organisation itself for the chain
  # "organisation", and for the chain "operator" the operator's organisation
  # (`c:Apiary.Edition.operator_chain_organisation/1`), nil where the edition names none.
  # Read without a lock.
  @spec chain_owner(Ecto.UUID.t()) :: {String.t(), Ecto.UUID.t() | nil}
  def chain_owner(organisation_id) do
    case Edition.model_choice_chain(organisation_id) do
      "operator" -> {"operator", Edition.operator_chain_organisation(organisation_id)}
      chain -> {chain, organisation_id}
    end
  end

  @doc false
  # choices_for/3 is what a resolution reads of the choices for the runs of `workflow` of
  # `workspace` at `target`, nil for none, without the providers: the choices of the run's
  # chain that may reach them, read without a lock, as
  # `Apiary.ModelChoices.Resolution.resolve/1` takes them (`chain_owner/1`). The
  # organisation's chain is read at all five levels. The operator's is read from the
  # operator's organisation at its default alone, since a workspace or a target belongs to
  # the organisation of its row: the choices of the run's workspace and target are not
  # read, and an operator the edition does not name leaves no choice. A `workflow` of nil,
  # for a run with none, reaches no choice of levels 2 and 4. `Apiary.Dispatches.RunSettings`
  # reads the providers itself, once it holds their rows.
  @spec choices_for(Workspace.t(), Target.t() | nil, String.t() | nil) :: map
  def choices_for(%Workspace{} = workspace, target, workflow) do
    {chain, owner} = chain_owner(workspace.organisation_id)
    target_id = target && target.id

    # The rows of the workspace, and of its target where the run has one.
    in_place =
      if target_id,
        do:
          dynamic(
            [c],
            c.workspace_id == ^workspace.id and
              (is_nil(c.target_id) or c.target_id == ^target_id)
          ),
        else: dynamic([c], c.workspace_id == ^workspace.id and is_nil(c.target_id))

    choices =
      case {chain, owner} do
        {_chain, nil} ->
          []

        {"operator", operator_id} ->
          Repo.all(
            from c in ModelChoice,
              where:
                c.organisation_id == ^operator_id and c.chain == "operator" and
                  is_nil(c.workspace_id)
          )

        {chain, organisation_id} ->
          Repo.all(
            from c in ModelChoice,
              where:
                ^dynamic(
                  [c],
                  c.organisation_id == ^organisation_id and c.chain == ^chain and
                    (is_nil(c.workspace_id) or ^in_place)
                )
          )
      end

    %{
      choices: choices,
      workspace_id: workspace.id,
      target_id: target_id,
      workflow: workflow,
      default_runtime: default_runtime().name,
      effort_values: Map.new(Runtimes.list(), &{&1.name, &1.effort_values})
    }
  end

  @doc false
  # resolution_provider/1 is `provider`, a provider connection, as
  # `Apiary.ModelChoices.Resolution` reads a provider: its default key, its default model
  # and its description's models (`Connections.provider_models/1`), each with the effort
  # values its description lists. The resolution keeps those its runtime offers too.
  @spec resolution_provider(Connection.t()) :: Resolution.provider()
  def resolution_provider(%Connection{} = provider) do
    %{
      default_value_id: provider.default_value_id,
      default_model_id: Connections.default_model(provider),
      models:
        Enum.map(Connections.provider_models(provider), fn model ->
          effort = model["effort"] || []
          %{model_id: model["id"], effort: if(effort == [], do: nil, else: effort)}
        end)
    }
  end

  @doc false
  # suggestions/2 is the models that Workspace settings › Model offers for the model
  # provider `provider` and the runs of `runtime`, each a map of `id`, `title` and
  # `effort`: the models of `@suggestions` for the provider's description, in the order
  # of their id, with its default model (`Connections.default_model/1`) first. A model's
  # effort is its offered effort values, `[]` for a model the description does not list.
  # A default model the file lacks comes first all the same, with the description's title,
  # as a choice that names no model runs it. The page reads its list here alone, and a
  # choice may name any other model id too.
  @spec suggestions(Connection.t(), Runtime.t()) :: [
          %{id: String.t(), title: String.t(), effort: [String.t()]}
        ]
  def suggestions(%Connection{provider_kind: kind} = provider, %Runtime{} = runtime) do
    described = Map.new(Connections.provider_models(provider), &{&1["id"], &1})
    default = Connections.default_model(provider)

    models =
      for %{id: id} = model <- Map.get(@suggestions, kind, []),
          do: Map.put(model, :effort, effort_of(described[id], runtime))

    case Enum.split_with(models, &(&1.id == default)) do
      {[], rest} when is_binary(default) ->
        entry = described[default]
        [%{id: default, title: entry["title"], effort: offered(entry, runtime)} | rest]

      {first, rest} ->
        first ++ rest
    end
  end

  defp effort_of(nil, _runtime), do: []
  defp effort_of(%{} = model, runtime), do: offered(model, runtime)

  ## Writing

  @doc false
  # put_choice/3 sets the choice at `place` (`model_choice.write`; `provider.write` for
  # the organisation's default), replacing what the place had: `attrs` has `runtime`, the
  # name of a runtime of the catalogue, `provider`, the
  # public id of a model provider of the organisation, `key`, the value id of one of its
  # keys, `model`, a model id, `effort`, one of that model's offered effort values,
  # `tiers`, a map of tiers, and, at the workspace, `locked`. Each but `provider` and
  # `tiers` may be left out; one of those two is needed. `{:ok, choice}`, or
  # `{:error, refusal}`: a changeset with the reason on its field (the moduledoc). `chain`
  # is "organisation" by default; "operator" sets the operator's choice at `:organisation`
  # alone, for a scope that writes that chain, with a provider of that chain; any other
  # place or scope is `{:error, :not_found}`.
  @spec put_choice(Scope.t(), place, map, String.t()) ::
          {:ok, ModelChoice.t()} | {:error, Access.reason() | Ecto.Changeset.t()}
  def put_choice(%Scope{} = scope, place, attrs, chain \\ "organisation") when is_map(attrs) do
    write(scope, place, chain, fn scope, at ->
      changeset = input(attrs, at)

      with {:ok, provider} <- hold_provider(changeset, at.organisation, at.chain),
           {:ok, values} <- checked(changeset, provider, Map.put(at, :scope, scope)) do
        current = lock_choice_row(at)
        save(scope, at, current, provider, values)
      end
    end)
  end

  @doc false
  # lock_choice/2 locks the workspace's choice at `place`, `:workspace` or
  # `{:workspace, workflow}`, against the levels below it (`model_choice.write`):
  # `{:ok, choice}`, or `{:error, reason}`, `:not_found` for a place with no choice.
  @spec lock_choice(Scope.t(), place) :: {:ok, ModelChoice.t()} | {:error, Access.reason()}
  def lock_choice(%Scope{} = scope, place), do: set_locked(scope, place, true)

  @doc false
  # unlock_choice/2 unlocks the workspace's choice at `place` (`model_choice.write`).
  @spec unlock_choice(Scope.t(), place) :: {:ok, ModelChoice.t()} | {:error, Access.reason()}
  def unlock_choice(%Scope{} = scope, place), do: set_locked(scope, place, false)

  defp set_locked(scope, place, locked) do
    write(scope, place, "organisation", fn scope, at ->
      case {at.level in [4, 5], lock_choice_row(at)} do
        {true, %ModelChoice{locked: ^locked} = current} ->
          {:ok, current}

        {true, %ModelChoice{} = current} ->
          change = if locked, do: "choice_locked", else: "choice_unlocked"

          with {:ok, updated} <-
                 current
                 |> change(locked: locked, updated_by_id: scope.user && scope.user.id)
                 |> Repo.update(),
               {:ok, _entry} <-
                 record(scope, at, updated, change, %{
                   before: %{locked: current.locked},
                   after: %{locked: locked}
                 }),
               do: {:ok, updated}

        _none ->
          {:error, :not_found}
      end
    end)
  end

  @doc false
  # delete_choice/2 removes the choice at `place` (`model_choice.write`; `provider.write`
  # for the organisation's default): `{:ok, choice}`, as it was, or `{:error, reason}`,
  # `:not_found` for a place with no choice. `chain` is as `put_choice/4` takes it.
  @spec delete_choice(Scope.t(), place, String.t()) ::
          {:ok, ModelChoice.t()} | {:error, Access.reason()}
  def delete_choice(%Scope{} = scope, place, chain \\ "organisation") do
    write(scope, place, chain, fn scope, at ->
      case lock_choice_row(at) do
        %ModelChoice{} = current ->
          with {:ok, deleted} <- Repo.delete(current),
               {:ok, _entry} <-
                 record(scope, at, deleted, "choice_removed", %{before: audited(current)}),
               do: {:ok, deleted}

        nil ->
          {:error, :not_found}
      end
    end)
  end

  # A write at one place, in one transaction under the locks of the moduledoc: `fun` of
  # the scope, read again, and the place, `at`, once the scope may write there. The
  # operator's chain has the organisation's default alone.
  defp write(scope, place, chain, fun) do
    with :ok <- shown(scope),
         {:ok, holder, workflow} <- place(place),
         :ok <- chain_place(chain, holder) do
      Repo.transact(fn ->
        :ok = Access.lock_places(scope)

        with {:ok, scope, at} <- hold_place(scope, holder, workflow, chain) do
          fun.(scope, at)
        end
      end)
    end
  end

  defp chain_place("organisation", _holder), do: :ok
  defp chain_place("operator", :organisation), do: :ok
  defp chain_place(_chain, _holder), do: {:error, :not_found}

  # The operator's chain is read only by a scope that the edition says writes it.
  defp chain_readable(_scope, "organisation"), do: :ok

  defp chain_readable(scope, "operator"),
    do: if(Edition.operator_chain_writer?(scope), do: :ok, else: {:error, :not_found})

  defp chain_readable(_scope, _other), do: {:error, :not_found}

  defp place({holder, workflow}) when holder != :organisation and is_binary(workflow) do
    if workflow?(workflow), do: {:ok, holder, workflow}, else: {:error, :not_found}
  end

  defp place({_holder, _workflow}), do: {:error, :not_found}
  defp place(holder), do: {:ok, holder, nil}

  defp workflow?(name), do: is_binary(name) and Regex.match?(@workflow, name)

  defp hold_place(
         %Scope{organisation: %Organisation{} = organisation} = scope,
         :organisation,
         nil,
         chain
       ) do
    scope = Access.reload(scope, lock: :share)

    with :ok <- Access.check(scope, :"provider.write", organisation),
         :ok <- chain_writable(scope, chain) do
      :ok = Connections.lock(organisation.id)

      {:ok, scope,
       %{
         level: 6,
         chain: chain,
         organisation: organisation,
         workspace: nil,
         target: nil,
         workflow: nil,
         action: :"provider.write"
       }}
    end
  end

  defp hold_place(%Scope{workspace: %Workspace{id: id}} = scope, holder, workflow, "organisation")
       when holder != :organisation do
    case Repo.one(
           from w in Workspace,
             where: w.id == ^id and w.organisation_id == ^scope.organisation.id,
             lock: "FOR NO KEY UPDATE"
         ) do
      %Workspace{} = workspace ->
        scope = Access.reload(scope, lock: :share)

        with {:ok, target} <- target(scope, holder),
             :ok <- Access.check(scope, :"model_choice.write", target || workspace) do
          {:ok, scope,
           %{
             level: level(target, workflow),
             chain: "organisation",
             organisation: scope.organisation,
             workspace: workspace,
             target: target,
             workflow: workflow,
             action: :"model_choice.write"
           }}
        end

      nil ->
        {:error, :not_found}
    end
  end

  defp hold_place(_scope, _holder, _workflow, _chain), do: {:error, :not_found}

  # The scope, read again under the locks, writes the chain.
  defp chain_writable(_scope, "organisation"), do: :ok

  defp chain_writable(scope, "operator"),
    do: if(Edition.operator_chain_writer?(scope), do: :ok, else: {:error, :not_found})

  defp level(nil, nil), do: 5
  defp level(nil, _workflow), do: 4
  defp level(%Target{}, nil), do: 3
  defp level(%Target{}, _workflow), do: 2

  # The choice at the place, held `FOR UPDATE`, or nil.
  defp lock_choice_row(at) do
    Repo.one(from c in at_place(at), lock: "FOR UPDATE")
  end

  defp at_place(at) do
    query =
      from c in ModelChoice,
        where: c.organisation_id == ^at.organisation.id and c.chain == ^at.chain

    query =
      case at.workspace do
        nil -> where(query, [c], is_nil(c.workspace_id))
        %Workspace{id: id} -> where(query, [c], c.workspace_id == ^id)
      end

    query =
      case at.target do
        nil -> where(query, [c], is_nil(c.target_id))
        %Target{id: id} -> where(query, [c], c.target_id == ^id)
      end

    case at.workflow do
      nil -> where(query, [c], is_nil(c.workflow))
      workflow -> where(query, [c], c.workflow == ^workflow)
    end
  end

  defp save(scope, at, current, provider, values) do
    row = current || %ModelChoice{}
    before = current && audited(current)

    # A save that does not send `locked` keeps the lock the place has.
    values =
      if is_nil(values.locked),
        do: %{values | locked: row.locked},
        else: values

    changes =
      Map.merge(values, %{
        organisation_id: at.organisation.id,
        workspace_id: at.workspace && at.workspace.id,
        target_id: at.target && at.target.id,
        workflow: at.workflow,
        chain: at.chain,
        connection_id: provider && provider.id,
        updated_by_id: scope.user && scope.user.id
      })

    changes =
      if current, do: changes, else: Map.put(changes, :created_by_id, scope.user && scope.user.id)

    after_ = audited(struct(row, changes), provider)

    cond do
      current && before == after_ ->
        {:ok, current}

      true ->
        changeset = change(row, changes)

        with {:ok, saved} <- Repo.insert_or_update(changeset),
             {:ok, _entry} <-
               record(
                 scope,
                 at,
                 saved,
                 if(current, do: "choice_changed", else: "choice_set"),
                 %{before: before, after: after_}
               ) do
          {:ok, saved}
        end
    end
  end

  # What the trail keeps of a choice: no value of a key, only its value id.
  defp audited(%ModelChoice{} = choice, provider \\ :loaded) do
    provider =
      case provider do
        :loaded -> choice.connection_id && Repo.get(Connection, choice.connection_id)
        provider -> provider
      end

    %{
      runtime: choice.runtime,
      provider: provider && provider.public_id,
      key: choice.value_id,
      model: choice.model_id,
      effort: choice.effort,
      tiers: choice.tiers,
      locked: choice.locked
    }
  end

  defp record(scope, at, choice, change, data) do
    details =
      %{change: change, level: at.level, name: place_name(at)}
      |> put_present(:workflow, at.workflow)
      |> put_present(:target_id, at.target && at.target.id)

    Audit.record(Repo, scope, at.action, choice, Map.put(data, :details, details))
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp place_name(%{target: %Target{} = target}), do: target_name(target)
  defp place_name(%{workspace: %Workspace{name: name}}), do: name
  defp place_name(%{organisation: %Organisation{name: name}}), do: name

  defp target_name(%Target{system: system, path: path}), do: "#{system}/#{path}"

  ## The checks

  # The changeset of what `attrs` sends for a choice at `at`: the formats, and what goes
  # with what. The rest asks the provider (`checked/3`).
  defp input(attrs, at) do
    types = %{
      runtime: :string,
      provider: :string,
      key: :string,
      model: :string,
      effort: :string,
      tiers: :map,
      locked: :boolean
    }

    fields = if at.level in [4, 5], do: Map.keys(types), else: Map.keys(types) -- [:locked]

    {%{}, types}
    |> cast(stringify(attrs), fields)
    |> update_change(:tiers, &empty_to_nil/1)
    |> validate_format(:model, @model_id, message: model_rule())
    |> validate_format(:effort, @effort, message: effort_rule())
    |> validate_runtime()
    |> needs(:provider, [:runtime, :key, :model])
    |> needs(:model, [:effort])
    |> needs_one([:provider, :tiers])
    |> validate_tiers()
    |> Map.put(:action, :validate)
  end

  # A runtime the catalogue has.
  defp validate_runtime(changeset) do
    validate_change(changeset, :runtime, fn :runtime, name ->
      case Runtimes.fetch(name) do
        {:ok, _runtime} ->
          []

        :error ->
          [
            runtime:
              {dgettext_noop(
                 "errors",
                 "Choose one of the offered runtimes: %{runtime} is not one of them."
               ), runtime: name}
          ]
      end
    end)
  end

  # The runtime of the choice `changeset` sends: the one it names, else the default.
  defp runtime_of(changeset) do
    case runtime(get_field(changeset, :runtime)) do
      {:ok, runtime} -> runtime
      :error -> default_runtime()
    end
  end

  defp stringify(attrs) when is_map(attrs),
    do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

  defp stringify(_attrs), do: %{}

  defp empty_to_nil(tiers) when tiers == %{}, do: nil
  defp empty_to_nil(tiers), do: tiers

  # `field` is required once any of `with` is given.
  defp needs(changeset, field, with) do
    if Enum.any?(with, &get_field(changeset, &1)),
      do: validate_required(changeset, [field]),
      else: changeset
  end

  defp needs_one(changeset, [first | _rest] = fields) do
    if Enum.all?(fields, &is_nil(get_field(changeset, &1))) and
         not Keyword.has_key?(changeset.errors, first),
       do: add_error(changeset, first, "can't be blank", validation: :required),
       else: changeset
  end

  defp validate_tiers(changeset) do
    validate_change(changeset, :tiers, fn :tiers, tiers ->
      Enum.find_value(tiers, [], fn {tier, entry} -> tier_error(tier, entry) end)
    end)
  end

  defp tier_error(tier, entry) do
    cond do
      tier not in Resolution.tiers() ->
        [
          tiers:
            {dgettext_noop("errors", "Use light, fast or thinking: %{tier} is not a tier."),
             tier: to_string(tier)}
        ]

      not match?(%{"model" => _}, tier_entry(entry)) ->
        [tiers: model_rule()]

      not Regex.match?(@model_id, tier_entry(entry)["model"]) ->
        [tiers: model_rule()]

      not (is_nil(tier_entry(entry)["effort"]) or
               Regex.match?(@effort, tier_entry(entry)["effort"])) ->
        [tiers: effort_rule()]

      true ->
        nil
    end
  end

  # A tier's entry as a map of `model` and `effort`: a model id alone is its model; an
  # entry of any other shape, or with other keys, is nil.
  defp tier_entry(model) when is_binary(model), do: %{"model" => model}

  defp tier_entry(%{} = entry) do
    entry = stringify(entry)

    with true <- Map.keys(entry) -- ["model", "effort"] == [],
         model when is_binary(model) <- entry["model"],
         effort when is_nil(effort) or is_binary(effort) <- entry["effort"] do
      if effort, do: %{"model" => model, "effort" => effort}, else: %{"model" => model}
    else
      _other -> nil
    end
  end

  defp tier_entry(_entry), do: nil

  defp model_rule,
    do:
      dgettext_noop(
        "errors",
        "Use 1 to 200 ASCII letters, digits and punctuation with no space, starting with a letter or a digit."
      )

  defp effort_rule,
    do:
      dgettext_noop(
        "errors",
        "Use 1 to 32 lower-case letters, digits and hyphens, starting with a letter, such as high."
      )

  # The provider `changeset` names, a model provider of the chain `chain`, read
  # with its keys' value ids, its row locked `FOR SHARE`:
  # `{:ok, provider}`, `{:ok, nil}` for none named, or the changeset with the reason on
  # `provider`.
  defp hold_provider(%Ecto.Changeset{valid?: false} = changeset, _organisation, _chain),
    do: {:error, changeset}

  defp hold_provider(changeset, %Organisation{id: organisation_id}, chain) do
    case get_field(changeset, :provider) do
      nil ->
        {:ok, nil}

      public_id ->
        query =
          from c in Connection,
            where:
              c.organisation_id == ^organisation_id and c.public_id == ^public_id and
                not is_nil(c.provider_kind) and c.chain == ^chain,
            lock: "FOR SHARE"

        case Repo.one(query) do
          %Connection{} = provider ->
            {:ok,
             Repo.preload(provider,
               workspaces: [],
               secret: [values: from(v in Value, select: struct(v, [:id, :value_id]))]
             )}

          nil ->
            {:error, add_error(changeset, :provider, "is invalid")}
        end
    end
  end

  # Every check of the moduledoc that asks the provider, on a changeset `input/2` gave:
  # `{:ok, values}`, the columns to store, or the changeset with each reason.
  defp checked(changeset, provider, at) do
    runtime = runtime_of(changeset)

    changeset =
      changeset
      |> check_provider(provider, at, runtime)
      |> check_key(provider)
      |> check_model(provider, runtime)
      |> check_tiers(provider, runtime)

    if changeset.valid? do
      {:ok,
       %{
         runtime: get_field(changeset, :runtime),
         value_id: get_field(changeset, :key),
         model_id: get_field(changeset, :model),
         effort: get_field(changeset, :effort),
         tiers: tiers_of(get_field(changeset, :tiers)),
         locked: get_field(changeset, :locked)
       }}
    else
      {:error, changeset}
    end
  end

  defp tiers_of(nil), do: nil
  defp tiers_of(tiers), do: Map.new(tiers, fn {tier, entry} -> {tier, tier_entry(entry)} end)

  defp check_provider(changeset, nil, _at, _runtime), do: changeset

  defp check_provider(changeset, %Connection{} = provider, at, runtime) do
    with :ok <- applies(provider, at),
         {:ok, description} <- description(provider, runtime),
         :ok <- serves(description, runtime) do
      changeset
    else
      {:error, {message, bindings}} -> add_error(changeset, :provider, message, bindings)
    end
  end

  defp applies(_provider, %{workspace: nil}), do: :ok
  defp applies(%Connection{applies_to: "all"}, _at), do: :ok

  defp applies(%Connection{} = provider, %{workspace: %Workspace{id: id}}) do
    if Enum.any?(provider.workspaces, &match?(%ConnectionWorkspace{workspace_id: ^id}, &1)),
      do: :ok,
      else:
        {:error,
         {dgettext_noop(
            "errors",
            "Choose another provider: %{provider} is not used in this workspace."
          ), provider: provider.name}}
  end

  # The description the provider was added from; one a later pin changed or removed
  # serves nothing, and is refused as a provider that serves no format.
  defp description(%Connection{} = provider, runtime) do
    case Connections.provider(provider) do
      {:ok, description} -> {:ok, description}
      {:error, _changed} -> {:error, format_refusal(provider.name, runtime)}
    end
  end

  @doc false
  # serves/2 is whether `provider` of the catalogue, under the name `name`, serves
  # `runtime` (`Apiary.Kinds.Providers.serve/2`): `:ok`, or the refusal on `provider`.
  @spec serves(Provider.t(), Apiary.Kinds.Runtime.t(), String.t() | nil) ::
          :ok | {:error, {String.t(), keyword}}
  def serves(%Provider{} = provider, runtime, name \\ nil) do
    name = name || provider.title

    case Providers.serve(provider, runtime) do
      :ok ->
        :ok

      {:error, :format} ->
        {:error, format_refusal(name, runtime)}

      {:error, :key_variable} ->
        {:error,
         {dgettext_noop(
            "errors",
            "Choose another provider for %{runtime}. %{runtime} has no environment variable for %{provider}'s key with the same authentication."
          ), runtime: runtime.title, provider: name}}
    end
  end

  defp format_refusal(name, runtime),
    do:
      {dgettext_noop(
         "errors",
         "Choose another provider for %{runtime}. %{provider} serves no request format that %{runtime} sends."
       ), runtime: runtime.title, provider: name}

  defp check_key(changeset, nil), do: changeset

  defp check_key(changeset, %Connection{} = provider) do
    case get_field(changeset, :key) do
      nil ->
        changeset

      value_id ->
        if Enum.any?(provider.secret.values, &(&1.value_id == value_id)),
          do: changeset,
          else:
            add_error(
              changeset,
              :key,
              dgettext_noop(
                "errors",
                "Choose one of %{provider}'s keys: %{value} is not one of them."
              ),
              provider: provider.name,
              value: value_id
            )
    end
  end

  defp check_model(changeset, nil, _runtime), do: changeset

  defp check_model(changeset, %Connection{} = provider, runtime) do
    case get_field(changeset, :model) do
      nil ->
        changeset

      model_id ->
        case effort_error(provider, model_id, get_field(changeset, :effort), runtime) do
          nil -> changeset
          {message, bindings} -> add_error(changeset, :effort, message, bindings)
        end
    end
  end

  defp check_tiers(changeset, nil, _runtime), do: changeset

  defp check_tiers(%Ecto.Changeset{valid?: false} = changeset, _provider, _runtime),
    do: changeset

  defp check_tiers(changeset, %Connection{} = provider, runtime) do
    tiers = get_field(changeset, :tiers) || %{}

    Enum.reduce_while(tiers, changeset, fn {_tier, entry}, changeset ->
      %{"model" => model_id} = entry = tier_entry(entry)

      case effort_error(provider, model_id, entry["effort"], runtime) do
        nil -> {:cont, changeset}
        {message, bindings} -> {:halt, add_error(changeset, :tiers, message, bindings)}
      end
    end)
  end

  # Why `effort` does not go with the model `model_id` of `provider` for the runs of
  # `runtime`, or nil: no effort always does; else one of the model's offered effort
  # values, of which a model the description does not list has none.
  defp effort_error(_provider, _model_id, nil, _runtime), do: nil

  defp effort_error(%Connection{} = provider, model_id, effort, runtime) do
    offered =
      case Enum.find(Connections.provider_models(provider), &(&1["id"] == model_id)) do
        nil -> []
        model -> offered(model, runtime)
      end

    cond do
      effort in offered ->
        nil

      offered == [] ->
        {dgettext_noop(
           "errors",
           "Leave the effort empty: %{model} has no effort values to choose from."
         ), model: model_id}

      true ->
        {dgettext_noop("errors", "Choose one of %{model}'s effort values: %{values}."),
         model: model_id, values: Enum.join(offered, ", ")}
    end
  end

  # The model's offered effort values: those of its list in the description that the
  # runtime's list contains too, in the model's order.
  defp offered(%{} = model, %Runtime{effort_values: values}),
    do: Enum.filter(model["effort"] || [], &(&1 in values))

  ## What uses a provider

  @doc false
  # places_using/1 is the places of the choices, at levels 2 to 6, that use the model
  # provider `provider`: each a `t:named_place/0`, the organisation's default first, then
  # by workspace, target and workflow. Read without a lock: the caller holds the
  # provider's row `FOR UPDATE`, so no save of a choice of it runs meanwhile.
  @spec places_using(Connection.t()) :: [named_place]
  def places_using(%Connection{id: id}),
    do: named(from c in ModelChoice, where: c.connection_id == ^id)

  @doc false
  # key_places/1 is the places of the choices, at levels 2 to 6, that use a key of the
  # secret with the row id `secret_id`, by its value id, each a `t:named_place/0`, for
  # `Apiary.Secrets.Usage`.
  @spec key_places(Ecto.UUID.t()) :: [named_place]
  def key_places(secret_id) do
    named(
      from c in ModelChoice,
        join: p in Connection,
        on: p.id == c.connection_id,
        where: p.secret_id == ^secret_id and not is_nil(c.value_id)
    )
  end

  defp named(query) do
    Repo.all(
      from c in query,
        left_join: w in Workspace,
        on: w.id == c.workspace_id,
        left_join: t in Target,
        on: t.id == c.target_id,
        select: %{
          choice: c,
          workspace: w.name,
          target: fragment("? || '/' || ?", t.system, t.path)
        }
    )
    |> Enum.map(fn %{choice: choice} = row ->
      %{
        level: ModelChoice.level(choice),
        workspace: row.workspace,
        target: row.target,
        workflow: choice.workflow,
        value_id: choice.value_id
      }
    end)
    |> Enum.sort_by(&{&1.level != 6, &1.workspace || "", &1.target || "", &1.workflow || ""})
  end

  @doc false
  # place_words/1 is how a refusal names a place (`t:named_place/0`): the organisation's
  # default, a workspace or a target by its name, and a workflow beside it.
  @spec place_words(named_place) :: String.t()
  def place_words(%{level: 6}), do: gettext("the organisation's default")

  def place_words(%{level: level} = place) when level in [2, 4],
    do: gettext("%{name}, %{kind} runs", name: place_name_of(place), kind: place.workflow)

  def place_words(place), do: place_name_of(place)

  defp place_name_of(%{level: level, target: target}) when level in [2, 3], do: target
  defp place_name_of(%{workspace: workspace}), do: workspace

  @doc false
  # in_use_words/2 is why the model provider `name` was not removed: the places of the
  # choices that use it (`t:named_place/0`), the first five, then "and N more". Nil for
  # none.
  @spec in_use_words(String.t(), [named_place]) :: String.t() | nil
  def in_use_words(_name, []), do: nil

  def in_use_words(name, places) do
    gettext("Change the model choices that use %{provider} first: %{places}.",
      provider: name,
      places: listed_words(Enum.map(places, &place_words/1))
    )
  end

  @doc false
  # listed_words/1 is `names` joined with commas, the first five, then "and N more";
  # nil for none.
  @spec listed_words([String.t()]) :: String.t() | nil
  def listed_words([]), do: nil

  def listed_words(names) do
    {shown, rest} = Enum.split(names, @shown)

    case length(rest) do
      0 ->
        Enum.join(shown, ", ")

      more ->
        Enum.join(shown, ", ") <>
          " " <>
          ngettext("and %{number} more", "and %{number} more", more, number: Format.number(more))
    end
  end

  ## Helpers

  # Model choices need `factory` and `secrets` shown to the scope.
  defp shown(scope) do
    if Features.visible?(scope, :factory) and Features.visible?(scope, :secrets),
      do: :ok,
      else: {:error, :not_found}
  end

  defp may_read(%Scope{organisation: %Organisation{} = organisation} = scope) do
    with :ok <- Access.authorize(scope, :"connection.read", organisation),
         do: {:ok, organisation}
  end

  defp may_read(_scope), do: {:error, :not_found}

  # The holder's target, read in the scope's workspace: nil for the workspace.
  defp target(_scope, :workspace), do: {:ok, nil}

  defp target(%Scope{workspace: %Workspace{id: workspace_id}} = scope, %Target{id: id})
       when is_binary(id) do
    case Repo.one(
           from t in Target,
             where:
               t.id == ^id and t.workspace_id == ^workspace_id and
                 t.organisation_id == ^scope.organisation.id
         ) do
      %Target{} = target -> {:ok, target}
      nil -> {:error, :not_found}
    end
  end

  defp target(_scope, _holder), do: {:error, :not_found}
end
