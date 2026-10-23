defmodule Apiary.ModelChoices do
  # The model choices of an organisation: which model provider, key, model, effort and tier
  # map its runs use (`Apiary.ModelChoices.ModelChoice`), set at levels 2 to 6 here and
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
  #   * `provider`: a model provider of the organisation's chain (`is invalid` otherwise),
  #     that applies to the workspace, and that serves the runtime of the runs
  #     (`Apiary.Kinds.Providers.serve/2`). A deny rule of the security policy is not
  #     asked: it never blocks a host of an integration;
  #   * `key`: a value id of the provider's keys;
  #   * `model` and `effort`: a model on the provider's list, and one of its offered effort
  #     values;
  #   * `tiers`: tiers among `light`, `fast` and `thinking`, each a model id, or a map of
  #     `model` and `effort`; with a provider, each model on the provider's list and each
  #     effort one of that model's offered effort values.
  #
  # A model's **offered effort values** are the values that both the model's list and the
  # runtime's (`Apiary.Kinds.Runtime`, `effort_values`) contain, in the model's order. A
  # resolution reads only these.
  #
  # The organisation's default has no workspace, so the workspace is not asked of it: a
  # run whose workspace the default's provider does not reach is ended at its claim.
  #
  # Only the organisation's chain is written here; an edition writes the operator's chain
  # (`c:Apiary.Edition.model_choice_chain/1`).
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
  alias Apiary.Connections.{Connection, ConnectionWorkspace, ProviderModel}
  alias Apiary.Kinds.{Provider, Providers, Runtimes}
  alias Apiary.ModelChoices.{ModelChoice, Resolution}
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Runs.Target
  alias Apiary.Secrets.Value
  alias ApiaryWeb.Format

  # A workflow's name.
  @workflow ~r/\A[a-z][a-z0-9-]{0,63}\z/

  # The runtime of every run of the queue.
  @runtime "claude"

  # How many places a refusal names before "and N more".
  @shown 5

  @model_id ~r/\A[A-Za-z0-9][!-~]{0,199}\z/
  @effort ~r/\A[a-z][a-z0-9-]{0,31}\z/

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
  # runtime_name/0 is the name of the runtime of every run of the queue.
  @spec runtime_name() :: String.t()
  def runtime_name, do: @runtime

  ## Reading

  @doc false
  # list_choices/1 is the choices of the organisation's chain at the organisation's default
  # and, where the scope has a workspace, at the workspace and its targets, each with its
  # provider and its target: `{:ok, choices}` for a reader who may `connection.read`; else
  # `{:error, reason}`.
  @spec list_choices(Scope.t()) :: {:ok, [ModelChoice.t()]} | {:error, Access.reason()}
  def list_choices(%Scope{} = scope) do
    with :ok <- shown(scope),
         {:ok, organisation} <- may_read(scope) do
      query =
        from c in ModelChoice,
          where: c.organisation_id == ^organisation.id and c.chain == "organisation",
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
  # none: the choices of the organisation's chain that may reach them, and the providers
  # those name. Read without a lock.
  defp input(%Workspace{} = workspace, target, workflow) do
    input = choices_for(workspace, target, workflow)
    ids = for %{connection_id: id} <- input.choices, is_binary(id), uniq: true, do: id

    providers =
      Repo.all(
        from c in Connection,
          where:
            c.id in ^ids and c.organisation_id == ^workspace.organisation_id and
              not is_nil(c.provider_kind),
          preload: [models: ^from(m in ProviderModel, order_by: [asc: m.position])]
      )
      |> Map.new(&{&1.id, resolution_provider(&1)})

    Map.put(input, :providers, providers)
  end

  @doc false
  # choices_for/3 is what a resolution reads of the choices for the runs of `workflow` of
  # `workspace` at `target`, nil for none, without the providers: the choices of the
  # organisation's chain that may reach them, read without a lock, as
  # `Apiary.ModelChoices.Resolution.resolve/1` takes them. A `workflow` of nil, for a run
  # with none, reaches no choice of levels 2 and 4. `Apiary.Dispatches.RunSettings` reads
  # the providers itself, once it holds their rows.
  @spec choices_for(Workspace.t(), Target.t() | nil, String.t() | nil) :: map
  def choices_for(%Workspace{} = workspace, target, workflow) do
    chain = Edition.model_choice_chain(workspace.organisation_id)
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
      Repo.all(
        from c in ModelChoice,
          where:
            ^dynamic(
              [c],
              c.organisation_id == ^workspace.organisation_id and c.chain == ^chain and
                (is_nil(c.workspace_id) or ^in_place)
            )
      )

    %{choices: choices, workspace_id: workspace.id, target_id: target_id, workflow: workflow}
  end

  @doc false
  # resolution_provider/1 is `provider`, a provider connection with its models loaded, as
  # `Apiary.ModelChoices.Resolution` reads a provider.
  @spec resolution_provider(Connection.t()) :: Resolution.provider()
  def resolution_provider(%Connection{} = provider) do
    %{
      default_value_id: provider.default_value_id,
      models:
        Enum.map(provider.models, fn model ->
          offered = offered(model)

          %{
            model_id: model.model_id,
            effort: if(offered == [], do: nil, else: offered),
            is_default: model.is_default
          }
        end)
    }
  end

  ## Writing

  @doc false
  # put_choice/3 sets the choice at `place` (`model_choice.write`; `provider.write` for
  # the organisation's default), replacing what the place had: `attrs` has `provider`, the
  # public id of a model provider of the organisation, `key`, the value id of one of its
  # keys, `model`, a model id of its list, `effort`, one of that model's effort values,
  # `tiers`, a map of tiers, and, at the workspace, `locked`. Each but `provider` and
  # `tiers` may be left out; one of those two is needed. `{:ok, choice}`, or
  # `{:error, refusal}`: a changeset with the reason on its field (the moduledoc).
  @spec put_choice(Scope.t(), place, map) ::
          {:ok, ModelChoice.t()} | {:error, Access.reason() | Ecto.Changeset.t()}
  def put_choice(%Scope{} = scope, place, attrs) when is_map(attrs) do
    write(scope, place, fn scope, at ->
      changeset = input(attrs, at)

      with {:ok, provider} <- hold_provider(changeset, at.organisation),
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
    write(scope, place, fn scope, at ->
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
  # `:not_found` for a place with no choice.
  @spec delete_choice(Scope.t(), place) :: {:ok, ModelChoice.t()} | {:error, Access.reason()}
  def delete_choice(%Scope{} = scope, place) do
    write(scope, place, fn scope, at ->
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
  # the scope, read again, and the place, `at`, once the scope may write there.
  defp write(scope, place, fun) do
    with :ok <- shown(scope),
         {:ok, holder, workflow} <- place(place) do
      Repo.transact(fn ->
        :ok = Access.lock_places(scope)

        with {:ok, scope, at} <- hold_place(scope, holder, workflow) do
          fun.(scope, at)
        end
      end)
    end
  end

  defp place({holder, workflow}) when holder != :organisation and is_binary(workflow) do
    if workflow?(workflow), do: {:ok, holder, workflow}, else: {:error, :not_found}
  end

  defp place({_holder, _workflow}), do: {:error, :not_found}
  defp place(holder), do: {:ok, holder, nil}

  defp workflow?(name), do: is_binary(name) and Regex.match?(@workflow, name)

  defp hold_place(
         %Scope{organisation: %Organisation{} = organisation} = scope,
         :organisation,
         nil
       ) do
    scope = Access.reload(scope, lock: :share)

    with :ok <- Access.check(scope, :"provider.write", organisation) do
      :ok = Connections.lock(organisation.id)

      {:ok, scope,
       %{
         level: 6,
         organisation: organisation,
         workspace: nil,
         target: nil,
         workflow: nil,
         action: :"provider.write"
       }}
    end
  end

  defp hold_place(%Scope{workspace: %Workspace{id: id}} = scope, holder, workflow)
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

  defp hold_place(_scope, _holder, _workflow), do: {:error, :not_found}

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
        where: c.organisation_id == ^at.organisation.id and c.chain == "organisation"

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
        chain: "organisation",
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
    |> needs(:provider, [:key, :model])
    |> needs(:model, [:effort])
    |> needs_one([:provider, :tiers])
    |> validate_tiers()
    |> Map.put(:action, :validate)
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

  # The provider `changeset` names, a model provider of the organisation's chain, read
  # with its models and its keys' value ids, its row locked `FOR SHARE`:
  # `{:ok, provider}`, `{:ok, nil}` for none named, or the changeset with the reason on
  # `provider`.
  defp hold_provider(%Ecto.Changeset{valid?: false} = changeset, _organisation),
    do: {:error, changeset}

  defp hold_provider(changeset, %Organisation{id: organisation_id}) do
    case get_field(changeset, :provider) do
      nil ->
        {:ok, nil}

      public_id ->
        query =
          from c in Connection,
            where:
              c.organisation_id == ^organisation_id and c.public_id == ^public_id and
                not is_nil(c.provider_kind) and c.chain == "organisation",
            lock: "FOR SHARE"

        case Repo.one(query) do
          %Connection{} = provider ->
            {:ok,
             Repo.preload(provider,
               models: from(m in ProviderModel, order_by: [asc: m.position]),
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
    changeset =
      changeset
      |> check_provider(provider, at)
      |> check_key(provider)
      |> check_model(provider)
      |> check_tiers(provider)

    if changeset.valid? do
      {:ok,
       %{
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

  defp check_provider(changeset, nil, _at), do: changeset

  defp check_provider(changeset, %Connection{} = provider, at) do
    with :ok <- applies(provider, at),
         {:ok, description} <- description(provider),
         :ok <- serves(description, runtime()) do
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
  defp description(%Connection{} = provider) do
    case Connections.provider(provider) do
      {:ok, description} -> {:ok, description}
      {:error, _changed} -> {:error, format_refusal(provider.name, runtime())}
    end
  end

  defp runtime do
    {:ok, runtime} = Runtimes.fetch(@runtime)
    runtime
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

  defp check_model(changeset, nil), do: changeset

  defp check_model(changeset, %Connection{} = provider) do
    case get_field(changeset, :model) do
      nil ->
        changeset

      model_id ->
        case listed(provider, model_id) do
          nil ->
            add_error(changeset, :model, not_listed(), provider: provider.name, model: model_id)

          model ->
            effort = get_field(changeset, :effort)

            if is_nil(effort) or effort in offered(model),
              do: changeset,
              else: add_error(changeset, :effort, effort_not_listed(), effort_bindings(model))
        end
    end
  end

  defp check_tiers(changeset, nil), do: changeset

  defp check_tiers(%Ecto.Changeset{valid?: false} = changeset, _provider), do: changeset

  defp check_tiers(changeset, %Connection{} = provider) do
    tiers = get_field(changeset, :tiers) || %{}

    Enum.reduce_while(tiers, changeset, fn {_tier, entry}, changeset ->
      %{"model" => model_id} = entry = tier_entry(entry)

      case listed(provider, model_id) do
        nil ->
          {:halt,
           add_error(changeset, :tiers, not_listed(), provider: provider.name, model: model_id)}

        model ->
          if is_nil(entry["effort"]) or entry["effort"] in offered(model),
            do: {:cont, changeset},
            else:
              {:halt, add_error(changeset, :tiers, effort_not_listed(), effort_bindings(model))}
      end
    end)
  end

  defp listed(%Connection{models: models}, model_id),
    do: Enum.find(models, &(&1.model_id == model_id))

  defp not_listed,
    do: dgettext_noop("errors", "Choose a model from %{provider}'s list: %{model} is not on it.")

  defp effort_not_listed,
    do: dgettext_noop("errors", "Choose one of %{model}'s effort values: %{values}.")

  defp effort_bindings(%ProviderModel{model_id: model_id} = model),
    do: [model: model_id, values: Enum.join(offered(model), ", ")]

  # The model's offered effort values: those of its list that the runtime's list contains
  # too, in the model's order.
  defp offered(%ProviderModel{effort: effort}),
    do: Enum.filter(effort || [], &(&1 in runtime().effort_values))

  ## What uses a provider

  @doc false
  # places_using/2 is the places of the choices, at levels 2 to 6, that use the model
  # provider `provider`, or, given `model_id`, that use that model of it, by their model
  # or a tier: each a `t:named_place/0`, the organisation's default first, then by
  # workspace, target and workflow. Read without a lock: the caller holds the provider's
  # row `FOR UPDATE`, so no save of a choice of it runs meanwhile.
  @spec places_using(Connection.t(), String.t() | nil) :: [named_place]
  def places_using(%Connection{id: id}, model_id \\ nil) do
    query = from c in ModelChoice, where: c.connection_id == ^id

    query =
      if model_id,
        do:
          where(
            query,
            [c],
            c.model_id == ^model_id or
              fragment(
                "EXISTS (SELECT 1 FROM jsonb_each(?) AS t(tier, entry) WHERE t.entry ->> 'model' = ?)",
                c.tiers,
                ^model_id
              )
          ),
        else: query

    named(query)
  end

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
  # in_use_words/2 is why the model provider, or the model, `name` was not removed: the
  # places of the choices that use it (`t:named_place/0`), the first five, then
  # "and N more". Nil for none.
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
