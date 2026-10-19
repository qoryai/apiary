defmodule Apiary.ModelChoices do
  # The model choices of an organisation: which model provider, key, model, effort and tier
  # map its runs use (`Apiary.ModelChoices.ModelChoice`, `Apiary.ModelChoices.TakeInChoice`),
  # set at six levels and resolved for each run by `Apiary.ModelChoices.Resolution`.
  #
  # ## Places
  #
  # A choice is set at a place, given to the functions here as a holder and a run kind:
  #
  #   * `:organisation`, the organisation's default (level 6), with no run kind;
  #   * `:workspace`, the scope's workspace (level 5), or `{:workspace, run_kind}` (level 4);
  #   * a target of the scope's workspace (`Apiary.Runs.Target`, level 3), or
  #     `{target, run_kind}` (level 2).
  #
  # Level 1 is the choice a person sends with a take in (`Apiary.WorkItems.take_in/3`,
  # `model_choice`). A run kind is a step of the queue that runs a model: `run_kinds/0`.
  #
  # ## Who
  #
  # Levels 2 to 5 are written under `model_choice.write`, asked of the workspace or the
  # target; level 6 under `connection.write`, asked of the organisation; level 1 by the
  # person who takes the work item in (`work_item.take_in`). Reading is `connection.read`.
  # Every write leaves one entry in its transaction, about the choice, of the action it was
  # asked under: `details.change` is `choice_set`, `choice_changed`, `choice_locked`,
  # `choice_unlocked` or `choice_removed`, with the `level`, the `run_kind`, the target's
  # `target_id`, and `name`, the place's name.
  #
  # Everything here needs the features `factory` and `secrets`, shown to the scope: with
  # either off, every function answers `{:error, :not_found}`, and a take in stores no
  # choice.
  #
  # ## Refused on save
  #
  # A save is checked, each refusal a changeset error on its field:
  #
  #   * `provider`: a model provider of the organisation's chain (`is invalid` otherwise),
  #     that applies to the workspace, that serves the runtime of the runs
  #     (`Apiary.Kinds.Providers.serve/2`), and none of whose hosts a deny rule of the
  #     security policy in force covers;
  #   * `key`: a value id of the provider's keys;
  #   * `model` and `effort`: a model on the provider's list, and one of its effort values;
  #   * `tiers`: tiers among `light`, `fast` and `thinking`, each a model id, or a map of
  #     `model` and `effort`; with a provider, each on the provider's list.
  #
  # The organisation's default has no workspace, so neither the workspace nor the security
  # policy is asked of it: a run whose workspace the default's provider does not reach is
  # ended at its handover.
  #
  # A take in's choice is also refused while a choice of the workspace is locked, with the
  # workspace's name; and, where the organisation runs on an operator's chain
  # (`c:Apiary.Edition.model_choice_chain/1`), any choice at all, `:forbidden`. Only the
  # organisation's chain is written here; an edition writes the operator's chain.
  #
  # ## Locks
  #
  # A write of levels 2 to 5 takes the organisation's rows `FOR SHARE`
  # (`Apiary.Access.lock_places/1`), the workspace's row `FOR NO KEY UPDATE`, the membership
  # `FOR SHARE`, then the provider's row `FOR SHARE`, then the choice's row `FOR UPDATE`.
  # A write of level 6 takes the organisation's rows and the membership, then the
  # organisation's integrations lock (`Apiary.Connections.lock/1`), then the provider's
  # row and the choice's row. A take in takes the provider's row `FOR KEY SHARE`, then the
  # row of its keys' secret `FOR SHARE`, after the work item's counter. A provider's change
  # takes the provider's row `FOR UPDATE`, so a save and a change of the same provider take
  # turns, and each sees what the other wrote.
  @moduledoc false

  use Gettext, backend: ApiaryWeb.Gettext

  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias Apiary.{Access, Audit, Connections, Edition, Features, Policy, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Connections.{Connection, ConnectionWorkspace, ProviderModel}
  alias Apiary.Kinds.{Endpoint, Provider, Providers, Runtimes}
  alias Apiary.ModelChoices.{ModelChoice, Resolution, TakeInChoice}
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Policy.{Entry, Grammar}
  alias Apiary.Runs.Target
  alias Apiary.Secrets.{Secret, Value}
  alias Apiary.WorkItems.WorkItem
  alias ApiaryWeb.Format

  # The steps of the queue whose runs use a model.
  @run_kinds ["explore"]

  # The runtime of every run of the queue.
  @runtime "claude"

  # How many places a refusal names before "and N more".
  @shown 5

  @model_id ~r/\A[A-Za-z0-9][!-~]{0,199}\z/
  @effort ~r/\A[a-z][a-z0-9-]{0,31}\z/

  @typedoc "Whose choice: the organisation's default, the scope's workspace, or a target of it."
  @type holder :: :organisation | :workspace | Target.t()

  @typedoc "A place of a choice: a holder, alone or with a run kind."
  @type place :: holder | {:workspace | Target.t(), String.t()}

  @typedoc """
  A place as a refusal names it: its `level`, the `workspace`'s name, the `target`'s name,
  the `run_kind`, and the `value_id` of the key it chose.
  """
  @type named_place :: %{
          level: ModelChoice.level(),
          workspace: String.t() | nil,
          target: String.t() | nil,
          run_kind: String.t() | nil,
          value_id: String.t() | nil
        }

  @doc false
  # run_kinds/0 is the run kinds a choice may be set for.
  @spec run_kinds() :: [String.t()]
  def run_kinds, do: @run_kinds

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
          order_by: [asc: c.workspace_id, asc: c.target_id, asc: c.run_kind, asc: c.id],
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
  # resolve/4 is what the choices come to for the runs of `run_kind` at `holder`, the
  # scope's workspace or a target of it, as `Apiary.ModelChoices.Resolution.resolve/1`
  # answers: `{:ok, {:ok, resolution}}`, `{:ok, :none}` or `{:ok, {:error, :provider_removed}}`,
  # for a reader who may `connection.read`; else `{:error, reason}`. `take_in` is the
  # choice of the take in the runs belong to (`take_in_choice/2`), level 1, or nil.
  @spec resolve(Scope.t(), :workspace | Target.t(), String.t(), TakeInChoice.t() | nil) ::
          {:ok, {:ok, Resolution.t()} | :none | {:error, :provider_removed}}
          | {:error, Access.reason()}
  def resolve(scope, holder, run_kind, take_in \\ nil)

  def resolve(%Scope{workspace: %Workspace{} = workspace} = scope, holder, run_kind, take_in) do
    with :ok <- shown(scope),
         {:ok, _organisation} <- may_read(scope),
         true <- run_kind in @run_kinds,
         {:ok, target} <- target(scope, holder) do
      {:ok, Resolution.resolve(input(workspace, target, run_kind, take_in))}
    else
      false -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def resolve(%Scope{}, _holder, _run_kind, _take_in), do: {:error, :not_found}

  @doc false
  # take_in_choice/2 is the choice sent with the take in `take_in` of the work item
  # `work_item_id`, level 1: the row, or nil for a take in that sent none. Read without a
  # lock.
  @spec take_in_choice(Ecto.UUID.t(), pos_integer) :: TakeInChoice.t() | nil
  def take_in_choice(work_item_id, take_in),
    do: Repo.get_by(TakeInChoice, work_item_id: work_item_id, take_in: take_in)

  # What a resolution reads for the runs of `run_kind` of `workspace` at `target`, nil for
  # none, with the take in's choice `take_in`: the choices of the organisation's chain
  # that may reach them, and the providers those name. Read without a lock.
  defp input(%Workspace{} = workspace, target, run_kind, take_in) do
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

    take_in = if chain == "organisation", do: take_in

    ids =
      for %{connection_id: id} <- [take_in | choices], is_binary(id), uniq: true, do: id

    providers =
      Repo.all(
        from c in Connection,
          where:
            c.id in ^ids and c.organisation_id == ^workspace.organisation_id and
              not is_nil(c.provider_kind),
          preload: [models: ^from(m in ProviderModel, order_by: [asc: m.position])]
      )
      |> Map.new(fn provider ->
        {provider.id,
         %{
           default_value_id: provider.default_value_id,
           models: Enum.map(provider.models, &Map.take(&1, [:model_id, :effort, :is_default]))
         }}
      end)

    %{
      take_in: take_in,
      choices: choices,
      workspace_id: workspace.id,
      target_id: target_id,
      run_kind: run_kind,
      providers: providers
    }
  end

  ## Writing

  @doc false
  # put_choice/3 sets the choice at `place` (`model_choice.write`; `connection.write` for
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

      with {:ok, provider} <- hold_provider(changeset, at.organisation, "FOR SHARE"),
           {:ok, values} <- checked(changeset, provider, Map.put(at, :scope, scope)) do
        current = lock_choice_row(at)
        save(scope, at, current, provider, values)
      end
    end)
  end

  @doc false
  # lock_choice/2 locks the workspace's choice at `place`, `:workspace` or
  # `{:workspace, run_kind}`, against the levels below it (`model_choice.write`):
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
  # delete_choice/2 removes the choice at `place` (`model_choice.write`; `connection.write`
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
         {:ok, holder, run_kind} <- place(place) do
      Repo.transact(fn ->
        :ok = Access.lock_places(scope)

        with {:ok, scope, at} <- hold_place(scope, holder, run_kind) do
          fun.(scope, at)
        end
      end)
    end
  end

  defp place({holder, run_kind}) when holder != :organisation and run_kind in @run_kinds,
    do: {:ok, holder, run_kind}

  defp place({_holder, _run_kind}), do: {:error, :not_found}
  defp place(holder), do: {:ok, holder, nil}

  defp hold_place(
         %Scope{organisation: %Organisation{} = organisation} = scope,
         :organisation,
         nil
       ) do
    scope = Access.reload(scope, lock: :share)

    with :ok <- Access.check(scope, :"connection.write", organisation) do
      :ok = Connections.lock(organisation.id)

      {:ok, scope,
       %{
         level: 6,
         organisation: organisation,
         workspace: nil,
         target: nil,
         run_kind: nil,
         action: :"connection.write"
       }}
    end
  end

  defp hold_place(%Scope{workspace: %Workspace{id: id}} = scope, holder, run_kind)
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
             level: level(target, run_kind),
             organisation: scope.organisation,
             workspace: workspace,
             target: target,
             run_kind: run_kind,
             action: :"model_choice.write"
           }}
        end

      nil ->
        {:error, :not_found}
    end
  end

  defp hold_place(_scope, _holder, _run_kind), do: {:error, :not_found}

  defp level(nil, nil), do: 5
  defp level(nil, _run_kind), do: 4
  defp level(%Target{}, nil), do: 3
  defp level(%Target{}, _run_kind), do: 2

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

    case at.run_kind do
      nil -> where(query, [c], is_nil(c.run_kind))
      kind -> where(query, [c], c.run_kind == ^kind)
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
        run_kind: at.run_kind,
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
      |> put_present(:run_kind, at.run_kind)
      |> put_present(:target_id, at.target && at.target.id)

    Audit.record(Repo, scope, at.action, choice, Map.put(data, :details, details))
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp place_name(%{target: %Target{} = target}), do: target_name(target)
  defp place_name(%{workspace: %Workspace{name: name}}), do: name
  defp place_name(%{organisation: %Organisation{name: name}}), do: name

  defp target_name(%Target{system: system, path: path}), do: "#{system}/#{path}"

  ## A take in's choice

  @doc false
  # take_in_input/2 is the choice `params` sends with a take in of the scope's workspace,
  # checked as far as a check without a lock and without the work item's target goes:
  # `{:ok, nil}` for none, or where the features are not shown to the scope;
  # `{:ok, changeset}`; or `{:error, {:model_choice, refusal}}`. The take in's
  # transaction stores it with `store_take_in/4`, which checks it again.
  @spec take_in_input(Scope.t(), term) ::
          {:ok, Ecto.Changeset.t() | nil}
          | {:error, {:model_choice, :forbidden | Ecto.Changeset.t()}}
  def take_in_input(%Scope{workspace: %Workspace{} = workspace} = scope, params) do
    if shown(scope) == :ok and not blank?(params) do
      at = take_in_place(scope, workspace)
      changeset = input(params, at)

      with :ok <- organisation_chain(workspace),
           {:ok, provider} <- hold_provider(changeset, scope.organisation, nil),
           {:ok, _values} <- checked(changeset, provider, %{at | deny: false}) do
        {:ok, changeset}
      else
        {:error, refusal} -> {:error, {:model_choice, refusal}}
      end
    else
      {:ok, nil}
    end
  end

  def take_in_input(%Scope{}, _params), do: {:ok, nil}

  @doc false
  # store_take_in/4 stores `input`, a choice `take_in_input/2` gave, as the choice of the
  # take in `take_in` of `work_item`, inside the take in's transaction and after the work
  # item's counter: the provider's row `FOR KEY SHARE`, then its keys' secret
  # `FOR SHARE`, every check again, the deny rules of the work item's target included,
  # then the row. `:ok`, or `{:error, {:model_choice, refusal}}`.
  @spec store_take_in(Scope.t(), WorkItem.t(), pos_integer, Ecto.Changeset.t() | nil) ::
          :ok | {:error, {:model_choice, :forbidden | Ecto.Changeset.t()}}
  def store_take_in(_scope, _work_item, _take_in, nil), do: :ok

  def store_take_in(%Scope{} = scope, %WorkItem{} = work_item, take_in, changeset) do
    workspace = scope.workspace
    at = %{take_in_place(scope, workspace) | target: work_item_target(work_item)}

    with :ok <- organisation_chain(workspace),
         {:ok, provider} <- hold_provider(changeset, scope.organisation, "FOR KEY SHARE"),
         :ok <- hold_keys(provider),
         {:ok, values} <- checked(changeset, provider, at),
         {:ok, _row} <-
           Repo.insert(%TakeInChoice{
             organisation_id: work_item.organisation_id,
             workspace_id: work_item.workspace_id,
             work_item_id: work_item.id,
             take_in: take_in,
             provider_chosen: not is_nil(provider),
             connection_id: provider && provider.id,
             value_id: values.value_id,
             model_id: values.model_id,
             effort: values.effort,
             tiers: values.tiers,
             created_by_id: scope.user && scope.user.id
           }) do
      :ok
    else
      {:error, %Ecto.Changeset{} = refused} -> {:error, {:model_choice, refused}}
      {:error, refusal} -> {:error, {:model_choice, refusal}}
    end
  end

  defp take_in_place(scope, workspace),
    do: %{
      level: 1,
      organisation: scope.organisation,
      workspace: workspace,
      target: nil,
      run_kind: nil,
      deny: true,
      scope: scope
    }

  # The target of the work item's workspace that the work item's target labels name; nil
  # for none, as a work item with no target, or one whose target no run has named yet,
  # has.
  defp work_item_target(%WorkItem{target_system: system, target_path: path} = work_item)
       when is_binary(system) and is_binary(path) do
    Repo.one(
      from t in Target,
        where:
          t.workspace_id == ^work_item.workspace_id and t.system == ^system and t.path == ^path
    )
  end

  defp work_item_target(%WorkItem{}), do: nil

  # A take in that sends no choice: no map, or one whose every value is empty.
  defp blank?(%{} = params),
    do: Enum.all?(params, fn {_key, value} -> value in [nil, "", %{}] end)

  defp blank?(_params), do: true

  # A take in's choice holds only in the organisation's chain: an operator's chain is
  # the whole chain of its client.
  defp organisation_chain(%Workspace{organisation_id: id}) do
    if Edition.model_choice_chain(id) == "organisation",
      do: :ok,
      else: {:error, :forbidden}
  end

  # The row of the keys' secret of `provider`, `FOR SHARE`, so no key goes meanwhile.
  defp hold_keys(nil), do: :ok

  defp hold_keys(%Connection{secret_id: secret_id}) do
    Repo.one(from s in Secret, where: s.id == ^secret_id, lock: "FOR SHARE", select: s.id)
    :ok
  end

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
  # with its models and its keys' value ids, its row locked in `lock` (nil for none):
  # `{:ok, provider}`, `{:ok, nil}` for none named, or the changeset with the reason on
  # `provider`.
  defp hold_provider(%Ecto.Changeset{valid?: false} = changeset, _organisation, _lock),
    do: {:error, changeset}

  defp hold_provider(changeset, %Organisation{id: organisation_id}, lock) do
    case get_field(changeset, :provider) do
      nil ->
        {:ok, nil}

      public_id ->
        query =
          from c in Connection,
            where:
              c.organisation_id == ^organisation_id and c.public_id == ^public_id and
                not is_nil(c.provider_kind) and c.chain == "organisation"

        query =
          case lock do
            nil -> query
            "FOR SHARE" -> lock(query, "FOR SHARE")
            "FOR KEY SHARE" -> lock(query, "FOR KEY SHARE")
          end

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

    changeset =
      if changeset.valid? and at.level == 1, do: check_unlocked(changeset, at), else: changeset

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
         :ok <- serves(description, runtime()),
         :ok <- not_denied(provider, description, at) do
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

  # Whether a deny rule in force at the place, its workspace's or its target's, covers a
  # host the provider's runs reach. The organisation's default has no workspace to ask;
  # a take in's first check, before its transaction, has no target yet.
  defp not_denied(_provider, _description, %{workspace: nil}), do: :ok
  defp not_denied(_provider, _description, %{deny: false}), do: :ok

  defp not_denied(%Connection{} = provider, %Provider{} = description, at) do
    effective = Policy.effective(%{at.scope | workspace: at.workspace}, at.target)

    denies =
      for %Entry{kind: :host, action: :deny, in_force: true} = entry <- effective.entries,
          do: entry

    found =
      Enum.find_value(hosts(provider, description), fn host ->
        Enum.find_value(denies, fn entry ->
          if Grammar.covers?(entry.host, host), do: {entry, host}
        end)
      end)

    case found do
      nil ->
        :ok

      {entry, host} ->
        {:error,
         {dgettext_noop(
            "errors",
            "Choose another provider, or change the deny rule %{rule} in %{place}. The rule covers %{host}, which runs of %{provider} reach."
          ),
          rule: entry.host,
          place: rule_place(entry, at.target, effective),
          host: host,
          provider: provider.name}}
    end
  end

  # Where the deny rule is: the workspace, locked or not, the target by its name, or the
  # level an edition keeps above the workspace, by its name.
  defp rule_place(%Entry{source: :workspace, locked: true}, _target, _effective),
    do: gettext("the workspace (locked)")

  defp rule_place(%Entry{source: :workspace}, _target, _effective), do: gettext("the workspace")

  defp rule_place(%Entry{source: :target}, %Target{} = target, _effective),
    do: target_name(target)

  defp rule_place(%Entry{source: :organisation}, _target, %{above: above}), do: above.name

  # The hosts a run of the provider reaches: its description's `egress_hosts`, a setting's
  # entry as the host of the address the provider has for it.
  defp hosts(%Connection{} = provider, %Provider{egress_hosts: entries}) do
    settings = Connection.settings_map(provider)

    for entry <- entries,
        host <- [host(entry, settings)],
        is_binary(host),
        uniq: true,
        do: host
  end

  defp host(host, _settings) when is_binary(host), do: host

  defp host(%{"setting" => name}, settings) do
    case Endpoint.host(settings[name]) do
      {:ok, host} -> host
      _none -> nil
    end
  end

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

            if is_nil(effort) or effort in (model.effort || []),
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
          if is_nil(entry["effort"]) or entry["effort"] in (model.effort || []),
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

  defp effort_bindings(%ProviderModel{model_id: model_id, effort: effort}),
    do: [model: model_id, values: Enum.join(effort || [], ", ")]

  # A take in's choice while a choice of the workspace is locked.
  defp check_unlocked(changeset, %{workspace: %Workspace{} = workspace}) do
    locked =
      Repo.exists?(
        from c in ModelChoice,
          where:
            c.organisation_id == ^workspace.organisation_id and c.chain == "organisation" and
              c.workspace_id == ^workspace.id and is_nil(c.target_id) and c.locked
      )

    if locked,
      do:
        add_error(
          changeset,
          :provider,
          dgettext_noop(
            "errors",
            "Leave the model choice empty. %{workspace}'s model choice is locked, and every run in the workspace uses it."
          ),
          workspace: workspace.name
        ),
      else: changeset
  end

  ## What uses a provider

  @doc false
  # places_using/2 is the places of the choices, at levels 2 to 6, that use the model
  # provider `provider`, or, given `model_id`, that use that model of it, by their model
  # or a tier: each a `t:named_place/0`, the organisation's default first, then by
  # workspace, target and run kind. Read without a lock: the caller holds the provider's
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
        run_kind: choice.run_kind,
        value_id: choice.value_id
      }
    end)
    |> Enum.sort_by(&{&1.level != 6, &1.workspace || "", &1.target || "", &1.run_kind || ""})
  end

  @doc false
  # place_words/1 is how a refusal names a place (`t:named_place/0`): the organisation's
  # default, a workspace or a target by its name, and a run kind beside it.
  @spec place_words(named_place) :: String.t()
  def place_words(%{level: 6}), do: gettext("the organisation's default")

  def place_words(%{level: level} = place) when level in [2, 4],
    do: gettext("%{name}, %{kind} runs", name: place_name_of(place), kind: place.run_kind)

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
