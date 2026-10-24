defmodule Apiary.Stacks do
  # The stacks of an organisation (`Apiary.Stacks.Stack`): the stack a run uses, a stack
  # name or a stack reference (`Apiary.Contract.Stack`), set at five levels and resolved
  # for each run by `Apiary.Stacks.Resolution`.
  #
  # ## The run's stack
  #
  # `for_run/3` is the `stack`, `workflow` and `harness_hidden` of an explore run's
  # documents. The run's workflow is the workflow of the one row with a workflow at the
  # run's places, its workspace and its target (`workflow/2`). With no such row, or two
  # or more, the run has no workflow, so it has no stack, whatever the levels have.
  #
  # ## Writes
  #
  # `put_stack/3` and `delete_stack/1` set and remove the stack at one place. Only tests
  # call them, and the demo (`mix apiary.demo.console`) calls `put_stack/3`: no action,
  # route or page does, and they check no access. The access check comes with the
  # action. A write records the person who saved the value and, in
  # `saved_by_organisation_id`, the scope's organisation when the scope reaches it
  # through a membership there alone (`saved_by/1`). A scope that reaches it any other
  # way, such as an instance admin or an operator's person acting in a client, or the
  # instance acting by itself, records nil: the owner of a reference saved so is
  # unknown, and the run hides the harness.
  #
  # ## Refused on save
  #
  # `stack`: a stack name or a stack reference (`Apiary.Contract.Stack.valid?/1`).
  # `workflow`: a lower-case letter, then up to 63 lower-case letters, digits and hyphens.
  # Each refusal is a changeset error on its field.
  #
  # ## Locks
  #
  # A write takes the row of its place `FOR UPDATE`, when there is one; two first writes
  # at one place meet at the unique index, and the second is a changeset error on
  # `stack`. A read for a run takes no lock.
  @moduledoc false

  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias Apiary.{Contract, Edition, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Membership, Organisation, Workspace}
  alias Apiary.Runs.Target
  alias Apiary.Stacks.{Resolution, Stack}

  @workflow ~r/\A[a-z][a-z0-9-]{0,63}\z/

  @typedoc """
  A place a stack is set at: the organisation's default, the workspace, or a target,
  each of the last two with or without a workflow.
  """
  @type place ::
          {:organisation, Organisation.t()}
          | {:workspace, Workspace.t()}
          | {:workspace, Workspace.t(), String.t()}
          | {:target, Target.t()}
          | {:target, Target.t(), String.t()}

  @typedoc "The `stack`, `workflow` and `harness_hidden` of a run's documents."
  @type run_stack :: %{stack: String.t(), workflow: String.t(), harness_hidden: boolean}

  ## Reading

  @doc false
  # for_run/3 is the stack of an explore run of `workspace` in `organisation`, at
  # `target`, the work item's `%{system, path}`, nil for none: the resolution's `stack`,
  # the run's workflow (`workflow/2`) and `harness_hidden`, or nil for a run without a
  # workflow. The row the workflow is read from has a stack, so a run with a workflow has
  # a stack. A target no row of the workspace has counts as none.
  @spec for_run(Organisation.t(), Workspace.t(), %{system: String.t(), path: String.t()} | nil) ::
          run_stack | nil
  def for_run(%Organisation{} = organisation, %Workspace{} = workspace, target) do
    target = target_row(workspace, target)

    with workflow when is_binary(workflow) <- workflow(workspace, target),
         {:ok, %Resolution{} = resolution} <-
           organisation
           |> input_for(workspace, target, workflow)
           |> Resolution.resolve() do
      %{
        stack: resolution.stack,
        workflow: resolution.workflow,
        harness_hidden: resolution.harness_hidden
      }
    else
      _none -> nil
    end
  end

  @doc false
  # workflow/2 is the workflow of the runs of `workspace` at `target`, a target row of
  # the workspace or nil for none: the workflow of the one row with a workflow at the
  # workspace level and, for a run with a target, the target level. Nil for no such row,
  # and for two or more, whatever their workflows. Read without a lock.
  @spec workflow(Workspace.t(), Target.t() | nil) :: String.t() | nil
  def workflow(%Workspace{} = workspace, target) do
    in_place =
      case target do
        %Target{id: id} -> dynamic([s], is_nil(s.target_id) or s.target_id == ^id)
        nil -> dynamic([s], is_nil(s.target_id))
      end

    Repo.all(
      from s in Stack,
        where: s.organisation_id == ^workspace.organisation_id,
        where: s.workspace_id == ^workspace.id and not is_nil(s.workflow),
        where: ^in_place,
        select: s.workflow,
        limit: 2
    )
    |> case do
      [workflow] -> workflow
      _none_or_several -> nil
    end
  end

  @doc false
  # input_for/4 is what a resolution reads for the runs of `workflow` of `workspace` in
  # `organisation`, at `target`, nil for none: the organisation's stacks at the run's
  # places, read without a lock, whether the organisation is operated
  # (`c:Apiary.Edition.operated?/1`), and whether the instance has one organisation
  # (`c:Apiary.Edition.limits/0`).
  @spec input_for(Organisation.t(), Workspace.t(), Target.t() | nil, String.t()) ::
          Resolution.input()
  def input_for(%Organisation{} = organisation, %Workspace{} = workspace, target, workflow)
      when is_binary(workflow) do
    target_id = target && target.id

    in_place =
      if target_id,
        do: dynamic([s], is_nil(s.target_id) or s.target_id == ^target_id),
        else: dynamic([s], is_nil(s.target_id))

    in_workspace =
      dynamic(
        [s],
        s.workspace_id == ^workspace.id and ^in_place and
          (is_nil(s.workflow) or s.workflow == ^workflow)
      )

    stacks =
      Repo.all(
        from s in Stack,
          where: s.organisation_id == ^organisation.id,
          where: ^dynamic([s], is_nil(s.workspace_id) or ^in_workspace)
      )

    %{
      stacks: stacks,
      organisation_id: organisation.id,
      workspace_id: workspace.id,
      target_id: target_id,
      workflow: workflow,
      operated: Edition.operated?(organisation),
      single_organisation: Edition.limits().organisations == 1
    }
  end

  # The target row of the workspace at `system` and `path`, nil for none.
  defp target_row(_workspace, nil), do: nil

  defp target_row(%Workspace{} = workspace, %{system: system, path: path}) do
    Repo.one(
      from t in Target,
        where: t.organisation_id == ^workspace.organisation_id,
        where: t.workspace_id == ^workspace.id and t.system == ^system and t.path == ^path
    )
  end

  ## Writing

  @doc false
  # put_stack/3 sets the stack at `place` to `stack`, replacing what the place had, saved
  # by the scope's person in the scope's organisation. `{:ok, stack}`, or `{:error,
  # changeset}` with the reason on its field. Only tests and the demo call it: no action,
  # route or page does, and it checks no access (the moduledoc).
  @spec put_stack(Scope.t(), place, term) :: {:ok, Stack.t()} | {:error, Ecto.Changeset.t()}
  def put_stack(%Scope{organisation: %Organisation{}} = scope, place, stack) do
    columns = columns(place)
    user_id = scope.user && scope.user.id
    saved_by = saved_by(scope)

    Repo.transact(fn ->
      current = lock_row(columns)

      changes =
        Map.merge(columns, %{
          stack: stack,
          saved_by_organisation_id: saved_by,
          updated_by_id: user_id
        })

      changes = if current, do: changes, else: Map.put(changes, :created_by_id, user_id)

      (current || %Stack{})
      |> changeset(changes)
      |> Repo.insert_or_update()
    end)
  end

  @doc false
  # delete_stack/1 removes the stack at `place`, so the next level applies. `{:ok,
  # stack}`, as it was, or `{:error, :not_found}` for a place with none. Only tests call
  # it: no action, route or page does, and it checks no access (the moduledoc).
  @spec delete_stack(place) :: {:ok, Stack.t()} | {:error, :not_found}
  def delete_stack(place) do
    columns = columns(place)

    Repo.transact(fn ->
      case lock_row(columns) do
        %Stack{} = current -> Repo.delete(current)
        nil -> {:error, :not_found}
      end
    end)
  end

  @doc false
  # saved_by/1 is the organisation a write by `scope` records: the scope's organisation
  # when the scope's membership is in it and the scope reaches it through that
  # membership alone (`reach` nil or `:membership`), else nil.
  @spec saved_by(Scope.t()) :: Ecto.UUID.t() | nil
  def saved_by(%Scope{
        organisation: %Organisation{id: id},
        membership: %Membership{organisation_id: id},
        reach: reach
      })
      when reach in [nil, :membership],
      do: id

  def saved_by(%Scope{}), do: nil

  # The columns of a place: its organisation, workspace, target and workflow.
  defp columns({:organisation, %Organisation{id: id}}),
    do: %{organisation_id: id, workspace_id: nil, target_id: nil, workflow: nil}

  defp columns({:workspace, %Workspace{} = workspace}), do: columns(workspace, nil, nil)

  defp columns({:workspace, %Workspace{} = workspace, workflow}),
    do: columns(workspace, nil, workflow)

  defp columns({:target, %Target{} = target}), do: columns(target, target.id, nil)

  defp columns({:target, %Target{} = target, workflow}),
    do: columns(target, target.id, workflow)

  defp columns(%Workspace{id: id, organisation_id: organisation_id}, target_id, workflow),
    do: %{
      organisation_id: organisation_id,
      workspace_id: id,
      target_id: target_id,
      workflow: workflow
    }

  defp columns(%Target{} = target, target_id, workflow),
    do: %{
      organisation_id: target.organisation_id,
      workspace_id: target.workspace_id,
      target_id: target_id,
      workflow: workflow
    }

  # The stack at the place of `columns`, held `FOR UPDATE`, or nil.
  defp lock_row(columns) do
    query =
      from s in Stack, where: s.organisation_id == ^columns.organisation_id, lock: "FOR UPDATE"

    [:workspace_id, :target_id, :workflow]
    |> Enum.reduce(query, fn name, query ->
      case Map.fetch!(columns, name) do
        nil -> where(query, [s], is_nil(field(s, ^name)))
        value -> where(query, [s], field(s, ^name) == ^value)
      end
    end)
    |> Repo.one()
  end

  # The changes, checked against the rules of the moduledoc.
  defp changeset(%Stack{} = row, changes) do
    row
    |> change(Map.drop(changes, [:stack, :workflow]))
    |> cast(changes, [:stack, :workflow])
    |> validate_required([:stack])
    |> validate_change(:stack, fn :stack, value ->
      if Contract.Stack.valid?(value), do: [], else: [stack: "has invalid format"]
    end)
    |> validate_format(:workflow, @workflow)
    |> unique_constraint(:stack, name: :stacks_place_index)
  end
end
