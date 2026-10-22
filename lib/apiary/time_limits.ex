defmodule Apiary.TimeLimits do
  # The time limits of a workspace: the whole minutes, 15 to 1440, that a run of one
  # workflow may take (`Apiary.TimeLimits.TimeLimit`), set at the workspace or at a target
  # of it, and resolved for each run by `Apiary.TimeLimits.Resolution`. A workflow is
  # named as the machines file names it (`Apiary.Dispatches.MachinesFile`).
  #
  # ## Places
  #
  # A limit is set at a place, given to the functions here as a holder: `:workspace`, the
  # scope's workspace, or a target of it (`Apiary.Runs.Target`).
  #
  # ## Who
  #
  # No action of `Apiary.Access` covers time limits yet, so nothing here checks access:
  # the check comes with the action, and with the caller that asks it. A write takes the
  # action its caller checked, `action`, and leaves one entry of it in its transaction,
  # about the limit: `details.change` is `time_limit_set`, `time_limit_changed` or
  # `time_limit_removed`, with the `workflow`, the target's `target_id`, and `name`, the
  # place's name; `before` and `after` have the `minutes`.
  #
  # Everything here needs the feature `factory`, shown to the scope: with it off, every
  # function answers `{:error, :not_found}`.
  #
  # ## Refused on save
  #
  # `workflow`: a lower-case letter, then up to 63 lower-case letters, digits and hyphens,
  # as the machines file names a workflow. `minutes`: a whole number from 15 to 1440.
  # Each refusal is a changeset error on its field.
  #
  # ## Locks
  #
  # A write takes the organisation's rows `FOR SHARE` (`Apiary.Access.lock_places/1`), the
  # workspace's row `FOR NO KEY UPDATE`, then the limit's row `FOR UPDATE`. Two writes in
  # one workspace take turns at the workspace's row.
  @moduledoc false

  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias Apiary.{Access, Audit, Features, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.Workspace
  alias Apiary.Runs.Target
  alias Apiary.TimeLimits.{Resolution, TimeLimit}

  @workflow ~r/\A[a-z][a-z0-9-]{0,63}\z/
  @min_minutes 15
  @max_minutes 1440

  @typedoc "Whose limit: the scope's workspace, or a target of it."
  @type holder :: :workspace | Target.t()

  @doc false
  # minutes_range/0 is the minutes a limit may have.
  @spec minutes_range() :: Range.t()
  def minutes_range, do: @min_minutes..@max_minutes

  ## Reading

  @doc false
  # list_limits/1 is the limits of the scope's workspace and its targets, each with its
  # target: `{:ok, limits}`, or `{:error, :not_found}`. It checks no access: the check
  # comes with the action that covers time limits.
  @spec list_limits(Scope.t()) :: {:ok, [TimeLimit.t()]} | {:error, :not_found}
  def list_limits(%Scope{workspace: %Workspace{id: id}} = scope) do
    with :ok <- shown(scope) do
      {:ok,
       Repo.all(
         from l in TimeLimit,
           where: l.workspace_id == ^id and l.organisation_id == ^scope.organisation.id,
           order_by: [asc: l.target_id, asc: l.workflow, asc: l.id],
           preload: [:target]
       )}
    end
  end

  def list_limits(%Scope{}), do: {:error, :not_found}

  @doc false
  # resolve/3 is what the limits come to for the runs of `workflow` at `holder`, the
  # scope's workspace or a target of it, as `Apiary.TimeLimits.Resolution.resolve/1`
  # answers: `{:ok, {:ok, resolution}}` or `{:ok, :none}`; else `{:error, :not_found}`.
  # It checks no access: the check comes with the action that covers time limits.
  @spec resolve(Scope.t(), holder, String.t()) ::
          {:ok, {:ok, Resolution.t()} | :none} | {:error, :not_found}
  def resolve(%Scope{workspace: %Workspace{} = workspace} = scope, holder, workflow)
      when is_binary(workflow) do
    with :ok <- shown(scope),
         {:ok, target} <- target(scope, holder) do
      {:ok, Resolution.resolve(limits_for(workspace, target, workflow))}
    end
  end

  def resolve(%Scope{}, _holder, _workflow), do: {:error, :not_found}

  @doc false
  # limits_for/3 is what a resolution reads of the limits for the runs of `workflow` of
  # `workspace` at `target`, nil for none: the workspace's limits for the workflow, and
  # the target's, read without a lock, as `Apiary.TimeLimits.Resolution.resolve/1` takes
  # them. `Apiary.Dispatches.RunSettings` reads them for a handover.
  @spec limits_for(Workspace.t(), Target.t() | nil, String.t()) :: Resolution.input()
  def limits_for(%Workspace{} = workspace, target, workflow) when is_binary(workflow) do
    target_id = target && target.id

    in_place =
      if target_id,
        do: dynamic([l], is_nil(l.target_id) or l.target_id == ^target_id),
        else: dynamic([l], is_nil(l.target_id))

    limits =
      Repo.all(
        from l in TimeLimit,
          where:
            ^dynamic(
              [l],
              l.workspace_id == ^workspace.id and
                l.organisation_id == ^workspace.organisation_id and l.workflow == ^workflow and
                ^in_place
            )
      )

    %{limits: limits, workspace_id: workspace.id, target_id: target_id, workflow: workflow}
  end

  ## Writing

  @doc false
  # put_limit/5 sets the limit for the runs of `workflow` at `holder` to `minutes`,
  # replacing what the place had, and leaves an entry of `action`, an action of
  # `Apiary.Access`, in the trail (the moduledoc). It checks no access: the check comes
  # with the action that covers time limits, which the caller asks before it calls here.
  # `{:ok, limit}`, or `{:error, refusal}`: a changeset with the reason on its field, or
  # `:not_found`. No caller exists yet: only the tests call it, and they pass
  # `model_choice.write` as a stand-in for the action.
  @spec put_limit(Scope.t(), Access.action(), holder, String.t(), term) ::
          {:ok, TimeLimit.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def put_limit(%Scope{} = scope, action, holder, workflow, minutes) do
    with :ok <- shown(scope),
         {:ok, values} <- checked(workflow, minutes) do
      write(scope, holder, fn at ->
        save(scope, action, at, lock_row(at, values.workflow), values)
      end)
    end
  end

  @doc false
  # delete_limit/4 removes the limit for the runs of `workflow` at `holder`, so the next
  # place in the order applies, and leaves an entry of `action` in the trail. It checks no
  # access, as `put_limit/5`. `{:ok, limit}`, as it was, or `{:error, :not_found}` for a
  # place with no limit for the workflow. No caller exists yet: only the tests call it,
  # and they pass `model_choice.write` as a stand-in for the action.
  @spec delete_limit(Scope.t(), Access.action(), holder, String.t()) ::
          {:ok, TimeLimit.t()} | {:error, :not_found}
  def delete_limit(%Scope{} = scope, action, holder, workflow) when is_binary(workflow) do
    write(scope, holder, fn at ->
      case lock_row(at, workflow) do
        %TimeLimit{} = current ->
          with {:ok, deleted} <- Repo.delete(current),
               {:ok, _entry} <-
                 record(scope, action, at, deleted, "time_limit_removed", %{
                   before: %{minutes: current.minutes}
                 }),
               do: {:ok, deleted}

        nil ->
          {:error, :not_found}
      end
    end)
  end

  # A write at one place, in one transaction under the locks of the moduledoc: `fun` of
  # the place, `at`, once its workspace's row is held.
  defp write(scope, holder, fun) do
    with :ok <- shown(scope) do
      Repo.transact(fn ->
        :ok = Access.lock_places(scope)

        with {:ok, at} <- hold_place(scope, holder), do: fun.(at)
      end)
    end
  end

  defp hold_place(%Scope{workspace: %Workspace{id: id}} = scope, holder) do
    case Repo.one(
           from w in Workspace,
             where: w.id == ^id and w.organisation_id == ^scope.organisation.id,
             lock: "FOR NO KEY UPDATE"
         ) do
      %Workspace{} = workspace ->
        with {:ok, target} <- target(scope, holder),
             do: {:ok, %{workspace: workspace, target: target}}

      nil ->
        {:error, :not_found}
    end
  end

  defp hold_place(_scope, _holder), do: {:error, :not_found}

  # The limit at the place for `workflow`, held `FOR UPDATE`, or nil.
  defp lock_row(at, workflow) do
    query =
      from l in TimeLimit,
        where: l.workspace_id == ^at.workspace.id and l.workflow == ^workflow,
        lock: "FOR UPDATE"

    query =
      case at.target do
        nil -> where(query, [l], is_nil(l.target_id))
        %Target{id: id} -> where(query, [l], l.target_id == ^id)
      end

    Repo.one(query)
  end

  defp save(_scope, _action, _at, %TimeLimit{minutes: minutes} = current, %{minutes: minutes}),
    do: {:ok, current}

  defp save(scope, action, at, current, values) do
    user_id = scope.user && scope.user.id

    changes =
      %{
        organisation_id: at.workspace.organisation_id,
        workspace_id: at.workspace.id,
        target_id: at.target && at.target.id,
        workflow: values.workflow,
        minutes: values.minutes,
        updated_by_id: user_id
      }
      |> then(&if(current, do: &1, else: Map.put(&1, :created_by_id, user_id)))

    {change, before} =
      if current,
        do: {"time_limit_changed", %{minutes: current.minutes}},
        else: {"time_limit_set", nil}

    with {:ok, saved} <- Repo.insert_or_update(change(current || %TimeLimit{}, changes)),
         {:ok, _entry} <-
           record(scope, action, at, saved, change, %{
             before: before,
             after: %{minutes: saved.minutes}
           }),
         do: {:ok, saved}
  end

  defp record(scope, action, at, limit, change, data) do
    details =
      %{change: change, workflow: limit.workflow, name: place_name(at)}
      |> then(&if(at.target, do: Map.put(&1, :target_id, at.target.id), else: &1))

    Audit.record(Repo, scope, action, limit, Map.put(data, :details, details))
  end

  defp place_name(%{target: %Target{system: system, path: path}}), do: "#{system}/#{path}"
  defp place_name(%{workspace: %Workspace{name: name}}), do: name

  ## The checks

  # The workflow and the minutes, checked against the rules of the moduledoc:
  # `{:ok, values}`, or the changeset with each reason.
  defp checked(workflow, minutes) do
    changeset =
      {%{}, %{workflow: :string, minutes: :integer}}
      |> cast(%{"workflow" => workflow, "minutes" => minutes}, [:workflow, :minutes])
      |> validate_required([:workflow, :minutes])
      |> validate_format(:workflow, @workflow)
      |> validate_number(:minutes,
        greater_than_or_equal_to: @min_minutes,
        less_than_or_equal_to: @max_minutes
      )
      |> Map.put(:action, :validate)

    if changeset.valid?,
      do:
        {:ok,
         %{workflow: get_field(changeset, :workflow), minutes: get_field(changeset, :minutes)}},
      else: {:error, changeset}
  end

  ## Helpers

  # Time limits need `factory` shown to the scope.
  defp shown(scope) do
    if Features.visible?(scope, :factory), do: :ok, else: {:error, :not_found}
  end

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
