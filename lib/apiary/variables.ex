defmodule Apiary.Variables do
  @moduledoc """
  A workspace's variables: names and values a run's process is given, set for the
  workspace or for one of its repositories (a target), resolved for each holder by
  `Apiary.Variables.Resolution`.

  ## Levels and locks

  A variable is at a level (`Apiary.Variables.Variable`): the workspace's, which every
  repository of it takes, or a repository's, which overrides the workspace's for that
  repository. Above the workspace an edition may keep a level of its own
  (`Apiary.Policy.Above`, its `variables`), which the core resolves first and never
  stores. A level **locks** a name against the levels below it: a locked name is set by
  no level below. Only the workspace's variables are locked here; the level above locks
  its own.

  ## Refused on save

    * a name that breaks the rule, `^[A-Za-z_][A-Za-z0-9_]{0,127}$`, or a value over 4096
      bytes, or with a NUL, a carriage return or a line feed;
    * a name beginning `QORY_`, whatever its case, at every level: "names beginning QORY_
      are the runner's own" (`Apiary.Variables.Denied.refused?/1`); any other name on the
      runner's deny list is saved, and the page warns (`Apiary.Variables.Denied.denied?/1`);
    * a name the level already sets, compared without case;
    * a name a level above locks;
    * a name that differs only in case from one set elsewhere in a chain it is in: for a
      workspace's, at the level above and in any repository of the workspace; for a
      repository's, at the level above and in the workspace;
    * a change that would take any holder it reaches over the contract's limits, 128
      names or 64 KiB of names and values (`Apiary.Variables.Resolution.check_limits/1`).

  A lock set on a name that repositories already set is saved: the lock wins, and their
  own values are set aside (`ignored` in the resolution), as they are for a lock the
  level above sets after them.

  ## Who, and the trail

  Reading is `variable.read`, every member; every change is `variable.edit`, owners and
  admins, asked of the workspace or the repository for a new variable and of the variable
  for a change to it. Every change leaves one `variable.edit` entry in its transaction,
  the variable its subject, by name, never by value: `details.change` is `created`,
  `updated`, `locked`, `unlocked` or `deleted`, with the name, the level and, for a
  repository's, its target id; a change of the value says only that it changed.

  A write locks the scope's organisation `FOR SHARE`, then the workspace's row
  `FOR NO KEY UPDATE`, then reads the membership again, so two writes to one workspace's
  variables take turns, and the checks across levels see every write before them.
  """

  use Gettext, backend: ApiaryWeb.Gettext

  import Ecto.Query, warn: false

  alias Apiary.{Access, Audit, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Policy.Above
  alias Apiary.Runs.Target
  alias Apiary.Variables.{Denied, Resolution, Variable}

  @typedoc "Whose variables: the workspace's, or a repository's (a target)."
  @type holder :: :workspace | Target.t()

  @typedoc "Why a change is refused: the reasons of `Apiary.Access`, or what is wrong with it."
  @type refusal :: Access.reason() | Ecto.Changeset.t()

  ## Reading

  @doc """
  list_variables/2 is the variables `holder` sets itself, by name without case: the
  workspace's, or the repository's own.
  """
  @spec list_variables(Scope.t(), holder) :: [Variable.t()]
  def list_variables(%Scope{} = scope, holder) do
    Repo.all(
      from v in level(variables(scope), holder),
        order_by: [asc: fragment("lower(?)", v.name), asc: v.id]
    )
  end

  @doc """
  get_variable/2 is the scope's workspace's variable with the row id `id`, of the
  workspace or of a repository: `{:ok, variable}`, or `{:error, :not_found}`.
  """
  @spec get_variable(Scope.t(), term) :: {:ok, Variable.t()} | {:error, :not_found}
  def get_variable(%Scope{} = scope, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Variable{} = variable <- Repo.one(from v in variables(scope), where: v.id == ^id) do
      {:ok, variable}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  resolve/2 is `holder`'s resolution (`Apiary.Variables.Resolution`): the values its runs
  are given, with which level set and which locked each, for the pages; its `values/1`
  for the run configuration.
  """
  @spec resolve(Scope.t(), holder) :: Resolution.t()
  def resolve(%Scope{workspace: %Workspace{} = workspace} = scope, holder) do
    Resolution.resolve(chain(scope, workspace, holder))
  end

  @doc "change_variable/2 is the changeset of a variable, for a form."
  @spec change_variable(Variable.t(), map) :: Ecto.Changeset.t()
  def change_variable(%Variable{} = variable, attrs \\ %{}),
    do: Variable.changeset(variable, attrs)

  defp variables(%Scope{
         organisation: %Organisation{id: organisation_id},
         workspace: %Workspace{id: workspace_id}
       }) do
    from v in Variable,
      where: v.organisation_id == ^organisation_id and v.workspace_id == ^workspace_id
  end

  defp level(query, holder) when holder in [:workspace, nil],
    do: where(query, [v], is_nil(v.target_id))

  defp level(query, %Target{id: target_id}), do: where(query, [v], v.target_id == ^target_id)

  # The levels of `holder`'s chain, from the top down, as `Resolution.resolve/1` takes them.
  defp chain(scope, workspace, holder) do
    above =
      case Above.for_workspace(workspace) do
        %Above{variables: variables} when is_list(variables) -> [{:above, variables}]
        _none -> []
      end

    own =
      case holder do
        %Target{} = target -> [{:target, list_variables(scope, target)}]
        _workspace -> []
      end

    above ++ [{:workspace, list_variables(scope, :workspace)}] ++ own
  end

  ## Writing

  @doc """
  create_variable/3 sets a new variable at `holder`'s level (`variable.edit`): `attrs` has
  `name`, `value`, and, for the workspace's, `locked`. `{:ok, variable}`, or
  `{:error, refusal}`, a changeset with the reason on `name`, `value` or `locked`.
  """
  @spec create_variable(Scope.t(), holder, map) :: {:ok, Variable.t()} | {:error, refusal}
  def create_variable(%Scope{} = scope, holder, attrs) do
    write(scope, fn scope, workspace ->
      with {:ok, target} <- target(scope, holder),
           :ok <- Access.check(scope, :"variable.edit", target || workspace) do
        changeset =
          %Variable{
            organisation_id: workspace.organisation_id,
            workspace_id: workspace.id,
            target_id: target && target.id,
            created_by_id: scope.user.id,
            updated_by_id: scope.user.id
          }
          |> Variable.changeset(attrs)

        with {:ok, changeset} <- check(scope, workspace, changeset),
             {:ok, variable} <- Repo.insert(changeset),
             :ok <- within_limits(scope, workspace, variable, changeset),
             {:ok, _entry} <-
               Audit.record(Repo, scope, :"variable.edit", variable, %{
                 after: %{name: variable.name, locked: variable.locked},
                 details: details(variable, "created")
               }) do
          {:ok, variable}
        end
      end
    end)
  end

  @doc """
  update_variable/3 changes a variable's name or value (`variable.edit`); the lock is
  `lock_variable/2`'s and `unlock_variable/2`'s. `{:ok, variable}`, or `{:error, refusal}`.
  A change that changes nothing leaves no entry.
  """
  @spec update_variable(Scope.t(), Variable.t(), map) :: {:ok, Variable.t()} | {:error, refusal}
  def update_variable(%Scope{} = scope, %Variable{} = variable, attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
    change(scope, variable, Map.take(attrs, ["name", "value"]), "updated")
  end

  @doc "lock_variable/2 locks a workspace's variable against the repositories (`variable.edit`)."
  @spec lock_variable(Scope.t(), Variable.t()) :: {:ok, Variable.t()} | {:error, refusal}
  def lock_variable(%Scope{} = scope, %Variable{} = variable),
    do: change(scope, variable, %{"locked" => true}, "locked")

  @doc "unlock_variable/2 unlocks a workspace's variable (`variable.edit`)."
  @spec unlock_variable(Scope.t(), Variable.t()) :: {:ok, Variable.t()} | {:error, refusal}
  def unlock_variable(%Scope{} = scope, %Variable{} = variable),
    do: change(scope, variable, %{"locked" => false}, "unlocked")

  defp change(scope, %Variable{id: id}, attrs, change) do
    write(scope, fn scope, workspace ->
      with {:ok, current} <- lock_row(scope, id),
           :ok <- Access.check(scope, :"variable.edit", current) do
        changeset =
          current
          |> Variable.changeset(attrs)
          |> lock_is_the_workspaces(current, attrs)
          |> Ecto.Changeset.put_change(:updated_by_id, scope.user.id)

        case Audit.changed(current, Ecto.Changeset.apply_changes(changeset), [
               :name,
               :value,
               :locked
             ]) do
          nil ->
            if changeset.valid?, do: {:ok, current}, else: {:error, changeset}

          changed ->
            with {:ok, changeset} <- check(scope, workspace, changeset),
                 {:ok, updated} <- Repo.update(changeset),
                 :ok <- within_limits(scope, workspace, updated, changeset),
                 {:ok, _entry} <-
                   Audit.record(Repo, scope, :"variable.edit", updated, %{
                     before: Map.take(changed.before, [:name, :locked]),
                     after: Map.take(changed.after, [:name, :locked]),
                     details:
                       updated
                       |> details(change)
                       |> Map.put(:value_changed, Map.has_key?(changed.after, :value))
                   }) do
              {:ok, updated}
            end
        end
      end
    end)
  end

  # A repository's variable is never locked: the changeset casts no lock for it, so a
  # lock asked of one is said, not dropped.
  defp lock_is_the_workspaces(changeset, %Variable{target_id: nil}, _attrs), do: changeset

  defp lock_is_the_workspaces(changeset, %Variable{}, %{"locked" => true}) do
    Ecto.Changeset.add_error(
      changeset,
      :locked,
      dgettext_noop(
        "errors",
        "only a workspace's variable can be locked: a lock holds it against the repositories"
      )
    )
  end

  defp lock_is_the_workspaces(changeset, %Variable{}, _attrs), do: changeset

  @doc "delete_variable/2 removes a variable (`variable.edit`): `{:ok, variable}`, as it was."
  @spec delete_variable(Scope.t(), Variable.t()) :: {:ok, Variable.t()} | {:error, refusal}
  def delete_variable(%Scope{} = scope, %Variable{id: id}) do
    write(scope, fn scope, _workspace ->
      with {:ok, current} <- lock_row(scope, id),
           :ok <- Access.check(scope, :"variable.edit", current),
           {:ok, deleted} <- Repo.delete(current),
           {:ok, _entry} <-
             Audit.record(Repo, scope, :"variable.edit", deleted, %{
               before: %{name: deleted.name, locked: deleted.locked},
               details: details(deleted, "deleted")
             }) do
        {:ok, deleted}
      end
    end)
  end

  defp details(%Variable{} = variable, change) do
    %{
      change: change,
      name: variable.name,
      level: if(variable.target_id, do: "target", else: "workspace")
    }
    |> then(fn details ->
      if variable.target_id, do: Map.put(details, :target_id, variable.target_id), else: details
    end)
  end

  ## The checks

  # What the changeset alone cannot see: the runner's names, the other levels' names and
  # locks, compared without case. Run only on a valid changeset.
  defp check(_scope, _workspace, %Ecto.Changeset{valid?: false} = changeset),
    do: {:error, changeset}

  defp check(scope, workspace, changeset) do
    name = Ecto.Changeset.get_field(changeset, :name)
    target_id = Ecto.Changeset.get_field(changeset, :target_id)
    id = Ecto.Changeset.get_field(changeset, :id)
    above = above_variables(workspace)

    cond do
      Denied.refused?(name) ->
        refuse(
          changeset,
          :name,
          dgettext_noop("errors", "names beginning QORY_ are the runner's own")
        )

      locked_above?(above, scope, target_id, name) ->
        refuse(
          changeset,
          :name,
          dgettext_noop("errors", "is locked above, so it cannot be set here")
        )

      other = spelled_otherwise(above, scope, target_id, id, name) ->
        refuse(
          changeset,
          :name,
          dgettext_noop(
            "errors",
            "is %{name} elsewhere in this workspace: use the same spelling"
          ),
          name: other
        )

      true ->
        {:ok, changeset}
    end
  end

  defp refuse(changeset, field, message, keys \\ []),
    do: {:error, Ecto.Changeset.add_error(changeset, field, message, keys)}

  defp above_variables(workspace) do
    case Above.for_workspace(workspace) do
      %Above{variables: variables} when is_list(variables) -> variables
      _none -> []
    end
  end

  # A name the level above locks, or, for a repository's, one the workspace locks.
  defp locked_above?(above, scope, target_id, name) do
    key = String.downcase(name)

    Enum.any?(above, &(&1.locked == true and String.downcase(&1.name) == key)) or
      (not is_nil(target_id) and
         Repo.exists?(
           from v in variables(scope),
             where: is_nil(v.target_id) and v.locked and fragment("lower(?)", v.name) == ^key
         ))
  end

  # The other spelling of `name` set in a chain the variable is in, or nil: at the level
  # above, and in the workspace and every repository for a workspace's variable, or in the
  # workspace for a repository's. The variable's own row is left out, so a variable may
  # change the case of its own name.
  defp spelled_otherwise(above, scope, target_id, id, name) do
    key = String.downcase(name)

    case Enum.find(above, &(String.downcase(&1.name) == key and &1.name != name)) do
      %{name: other} ->
        other

      nil ->
        query =
          from v in variables(scope),
            where: fragment("lower(?)", v.name) == ^key and v.name != ^name,
            select: v.name,
            limit: 1

        query = if id, do: where(query, [v], v.id != ^id), else: query

        query =
          if target_id,
            do: where(query, [v], is_nil(v.target_id)),
            else: query

        Repo.one(query)
    end
  end

  # After the write, in its transaction: every holder the variable reaches is within the
  # limits, or the write rolls back. A workspace's variable reaches the workspace and every
  # repository with variables of its own; a repository's, that repository.
  defp within_limits(scope, workspace, %Variable{target_id: target_id}, changeset) do
    holders =
      case target_id do
        nil ->
          [
            :workspace
            | Repo.all(from t in Target, where: t.id in subquery(targets_with_variables(scope)))
          ]

        id ->
          [Repo.get!(Target, id)]
      end

    Enum.reduce_while(holders, :ok, fn holder, :ok ->
      case Resolution.check_limits(Resolution.resolve(chain(scope, workspace, holder))) do
        :ok ->
          {:cont, :ok}

        {:error, :too_many_names} ->
          {:halt,
           refuse(
             changeset,
             :name,
             dgettext_noop("errors", "would give a run more than %{count} variables"),
             count: Resolution.max_names()
           )}

        {:error, :too_large} ->
          {:halt,
           refuse(
             changeset,
             :value,
             dgettext_noop("errors", "would give a run more than 64 KiB of variables")
           )}
      end
    end)
  end

  defp targets_with_variables(scope) do
    from v in variables(scope),
      where: not is_nil(v.target_id),
      distinct: true,
      select: v.target_id
  end

  ## The write

  # A write to the scope's workspace's variables: in one transaction, the organisation
  # `FOR SHARE`, the workspace `FOR NO KEY UPDATE`, the membership read again under its
  # lock (the security policy's lock order, docs/access.md), then `fun`, which asks first.
  defp write(%Scope{workspace: %Workspace{id: workspace_id}} = scope, fun) do
    Repo.transact(fn ->
      :ok = Access.lock_places(scope)

      case Repo.one(
             from w in Workspace,
               where: w.id == ^workspace_id and w.organisation_id == ^scope.organisation.id,
               lock: "FOR NO KEY UPDATE"
           ) do
        %Workspace{} = workspace -> fun.(Access.reload(scope, lock: :share), workspace)
        nil -> {:error, :not_found}
      end
    end)
  end

  defp write(_scope, _fun), do: {:error, :not_found}

  defp lock_row(scope, id) do
    case Repo.one(from v in variables(scope), where: v.id == ^id, lock: "FOR UPDATE") do
      %Variable{} = variable -> {:ok, variable}
      nil -> {:error, :not_found}
    end
  end

  # The holder's target, read in the scope's workspace: nil for the workspace.
  defp target(_scope, holder) when holder in [:workspace, nil], do: {:ok, nil}

  defp target(%Scope{workspace: %Workspace{id: workspace_id}} = scope, %Target{id: id}) do
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
end
