defmodule Apiary.Stacks do
  # The stacks of an organisation (`Apiary.Stacks.Stack`): the harness document a run
  # uses, the contents of the `harness` section of qory's format written in YAML
  # (`Apiary.Stacks.Document`), set at five levels and resolved for each run by
  # `Apiary.Stacks.Resolution`. A row may set only the workflow.
  #
  # ## A run's harness
  #
  # An explore run's workflow is the workflow of the one row with a workflow at the run's
  # places, its workspace and its target (`workflow_for/2`). With no such row, or two or
  # more, the run has no workflow and no harness, whatever the levels have. A run with a
  # workflow takes the document that resolves for it (`resolve_for/4`) where its
  # target's harness file does not apply (`Apiary.Harnesses.Walk`).
  #
  # ## Writes
  #
  # `put_stack/3` and `delete_stack/1` set and remove the stack at one place. Only tests
  # call them, and the demo (`mix apiary.demo.console`) calls `put_stack/3`: no route or
  # page does, and they check no access and write no audit entry. `harness.save` is the
  # access action for a save. A write records the person who saved the value and, in
  # `owner_organisation_id`, the organisation the edition gives for the scope
  # (`Apiary.Edition.harness_owner/1`). The core gives the scope's organisation when the
  # scope reaches it through a membership there alone (`saved_by/1`), and the instance's
  # organisation for an instance admin who reaches it any other way. A scope the edition
  # gives no organisation for, such as the instance acting by itself, saves nothing
  # (`{:error, :forbidden}`).
  #
  # ## Refused on save
  #
  # `harness`: a harness document under the save rules of `Apiary.Stacks.Document`, or
  # nil at a place with a workflow. `workflow`: a lower-case letter, then up to 63
  # lower-case letters, digits and hyphens. `access`: `:read` or `:write` at a place with
  # a workflow, nil at any place. Each refusal is a changeset error on its field.
  #
  # ## Locks
  #
  # A write takes the row of its place `FOR UPDATE`, when there is one; two first writes
  # at one place meet at the unique index, and the second is a changeset error on
  # `harness`. A read for a run takes no lock.
  @moduledoc false

  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias Apiary.{Edition, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Membership, Organisation, Workspace}
  alias Apiary.Runs.Target
  alias Apiary.Stacks.{Document, Resolution, Stack}

  @workflow ~r/\A[a-z][a-z0-9-]{0,63}\z/
  @access_without_workflow "is recorded only at a place with a workflow"

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

  ## Reading

  @doc false
  # workflow_for/2 is the workflow of an explore run of `workspace` at `target`, the work
  # item's `%{system, path}`, nil for none (`workflow/2`). A target no row of the
  # workspace has counts as none.
  @spec workflow_for(Workspace.t(), %{system: String.t(), path: String.t()} | nil) ::
          String.t() | nil
  def workflow_for(%Workspace{} = workspace, target),
    do: workflow(workspace, target_row(workspace, target))

  @doc false
  # resolve_for/4 is what the stacks of `organisation` come to for an explore run of
  # `workflow` of `workspace` at `target`, the work item's `%{system, path}`, nil for
  # none (`Apiary.Stacks.Resolution.resolve/1`): `{:ok, resolution}`, or `:none` where no
  # level has a harness document. Read without a lock.
  @spec resolve_for(
          Organisation.t(),
          Workspace.t(),
          %{system: String.t(), path: String.t()} | nil,
          String.t()
        ) :: {:ok, Resolution.t()} | :none
  def resolve_for(%Organisation{} = organisation, %Workspace{} = workspace, target, workflow)
      when is_binary(workflow) do
    organisation
    |> input_for(workspace, target_row(workspace, target), workflow)
    |> Resolution.resolve()
  end

  @doc false
  # workflow/2 is the workflow of the runs of `workspace` at `target`, a target row of
  # the workspace or nil for none: the workflow of the one row with a workflow at the
  # workspace level and, for a run with a target, the target level. Nil for no such row,
  # and for two or more, whatever their workflows. Read without a lock.
  @spec workflow(Workspace.t(), Target.t() | nil) :: String.t() | nil
  def workflow(%Workspace{} = workspace, target) do
    case workflow_row(workspace, target) do
      %{workflow: workflow} -> workflow
      nil -> nil
    end
  end

  @doc false
  # recorded_access/3 is the access level recorded for an explore run of `workflow` of
  # `workspace` at `target`, the work item's `%{system, path}`, nil for none: the
  # `access` of the row `workflow/2` reads, nil where that row records none. `:read`
  # where that row's workflow is no longer `workflow`, or where no such row is left, so
  # a row of another workflow, or none, never gives this run's level. Read without a
  # lock, when the walk runs.
  @spec recorded_access(
          Workspace.t(),
          %{system: String.t(), path: String.t()} | nil,
          String.t()
        ) :: :read | :write | nil
  def recorded_access(%Workspace{} = workspace, target, workflow) when is_binary(workflow) do
    case workflow_row(workspace, target_row(workspace, target)) do
      %{workflow: ^workflow, access: access} -> access
      _changed_or_gone -> :read
    end
  end

  # The workflow and the access level of the one row with a workflow at the run's
  # places (`workflow/2`), nil for none or for two or more.
  defp workflow_row(%Workspace{} = workspace, target) do
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
        select: %{workflow: s.workflow, access: s.access},
        limit: 2
    )
    |> case do
      [row] -> row
      _none_or_several -> nil
    end
  end

  @doc false
  # input_for/4 is what a resolution reads for the runs of `workflow` of `workspace` in
  # `organisation`, at `target`, nil for none: the organisation's stacks at the run's
  # places, read without a lock, and whether the organisation is operated
  # (`c:Apiary.Edition.operated?/1`).
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
      operated: Edition.operated?(organisation)
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
  # put_stack/4 sets the harness document at `place` to `harness`, nil for none at a
  # place with a workflow, replacing what the place had, saved by the scope's person and
  # owned by the organisation the edition gives for the scope
  # (`Apiary.Edition.harness_owner/1`). `opts`: `access`, the access level recorded for
  # the runs of the place's workflow, `:read` or `:write`, nil for none (the default).
  # `{:ok, stack}`; `{:error, :forbidden}` when the edition gives none; or `{:error,
  # changeset}` with the reason on its field. Only tests and the demo call it: no route
  # or page does, and it checks no access (the moduledoc).
  @spec put_stack(Scope.t(), place, term, keyword) ::
          {:ok, Stack.t()} | {:error, Ecto.Changeset.t() | :forbidden}
  def put_stack(%Scope{organisation: %Organisation{}} = scope, place, harness, opts \\ []) do
    columns = columns(place)
    user_id = scope.user && scope.user.id

    case Edition.harness_owner(scope) do
      owner when is_binary(owner) ->
        Repo.transact(fn ->
          current = lock_row(columns)

          changes =
            Map.merge(columns, %{
              harness: harness,
              access: Keyword.get(opts, :access),
              owner_organisation_id: owner,
              updated_by_id: user_id
            })

          changes = if current, do: changes, else: Map.put(changes, :created_by_id, user_id)

          (current || %Stack{})
          |> changeset(changes)
          |> Repo.insert_or_update()
        end)

      nil ->
        {:error, :forbidden}
    end
  end

  @doc false
  # delete_stack/1 removes the stack at `place`, so the next level applies. `{:ok,
  # stack}`, as it was, or `{:error, :not_found}` for a place with none. Only tests call
  # it: no route or page does, and it checks no access (the moduledoc).
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
  # saved_by/1 is the scope's organisation when the scope's membership is in it and the
  # scope reaches it through that membership alone (`reach` nil or `:membership`), else
  # nil: the core's first answer to `Apiary.Edition.harness_owner/1`.
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
    |> change(Map.drop(changes, [:harness, :workflow, :access]))
    |> cast(changes, [:harness, :workflow, :access])
    |> validate_harness_or_workflow()
    |> validate_access()
    |> validate_change(:harness, fn :harness, value ->
      for error <- Document.errors(value), do: {:harness, error}
    end)
    |> validate_format(:workflow, @workflow)
    |> check_constraint(:harness, name: :stacks_harness_or_workflow, message: "can't be blank")
    |> check_constraint(:harness, name: :stacks_harness_size, message: "is too long")
    |> check_constraint(:access, name: :stacks_access_check, message: @access_without_workflow)
    |> unique_constraint(:harness, name: :stacks_place_index)
  end

  # A row sets a harness document, a workflow, or both. A value that did not cast has the
  # error "is invalid" already.
  defp validate_harness_or_workflow(changeset) do
    if is_nil(get_field(changeset, :harness)) and is_nil(get_field(changeset, :workflow)) and
         not Keyword.has_key?(changeset.errors, :harness),
       do: add_error(changeset, :harness, "can't be blank", validation: :required),
       else: changeset
  end

  # An access level only at a place with a workflow.
  defp validate_access(changeset) do
    if get_field(changeset, :access) && is_nil(get_field(changeset, :workflow)),
      do: add_error(changeset, :access, @access_without_workflow),
      else: changeset
  end
end
