defmodule Apiary.Stacks do
  # The stacks of an organisation (`Apiary.Stacks.Stack`): harness documents, the
  # contents of the `harness` section of qory's format written in YAML
  # (`Apiary.Stacks.Document`), set at five levels, a run's workflow, and the harness
  # choices a run's walk follows (`Apiary.Harnesses.Walk`). A row may set only the
  # workflow.
  #
  # ## A run's workflow
  #
  # An explore run's workflow is the workflow of the one row with a workflow at the run's
  # places, its workspace and its target (`workflow_for/2`). With no such row, or two or
  # more, the run has no workflow and no harness, whatever the levels have. The walk
  # reads no document of a row with a workflow.
  #
  # ## The harness choices
  #
  # A `choice` is on a row with no workflow, at one of three places, each with its
  # document: a target's row, the stack chosen for that target (`target_choice/2`); the
  # workspace's row, the workspace's choice (`choice/1`); the organisation's row, the
  # harness it shares with every workspace (`shared/1`). The choice `:qory` is the Qory
  # harness, with the document that extends the harness of the workspace's type
  # (`Apiary.Lingo.Domain.definition/1`) at its pinned commit; `:repository` a harness
  # repository or a stack of one, with the document that extends it at the `ref` the save
  # wrote. `chosen_for/4` reads the choices for a run in the walk's order, and
  # `Apiary.Stacks.Sources.choose/3` and `Apiary.Stacks.Sources.choose_target/3` save one.
  #
  # ## Writes
  #
  # `put_stack/3` and `delete_stack/1` set and remove the stack at one place. They check no
  # access and write no audit entry. Tests call them, the demo (`mix apiary.demo.console`)
  # calls `put_stack/3`, and Workspace settings › Workflow calls both through
  # `Apiary.Stacks.Sources.save/3`, which asks `harness.save`, the access action for a
  # save, first. A write records the person who saved the value and, in
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
  # a workflow, nil at any place. `choice`: `:qory` or `:repository` at a place with no
  # workflow and with a document, nil at any place. Each refusal is a changeset error on
  # its field.
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
  # choice/1 is the row of `workspace`'s harness choice (the moduledoc), nil for none.
  # Read without a lock.
  @spec choice(Workspace.t()) :: Stack.t() | nil
  def choice(%Workspace{id: id, organisation_id: organisation_id}) do
    Repo.one(
      from s in Stack,
        where: s.organisation_id == ^organisation_id and s.workspace_id == ^id,
        where: is_nil(s.target_id) and is_nil(s.workflow) and not is_nil(s.choice)
    )
  end

  @doc false
  # shared/1 is the row of the harness `organisation` shares with every workspace (the
  # moduledoc), nil for none. Read without a lock.
  @spec shared(Organisation.t()) :: Stack.t() | nil
  def shared(%Organisation{id: organisation_id}) do
    Repo.one(
      from s in Stack,
        where: s.organisation_id == ^organisation_id and is_nil(s.workspace_id),
        where: is_nil(s.target_id) and is_nil(s.workflow) and not is_nil(s.choice)
    )
  end

  @doc false
  # target_choice/2 is the row of the stack chosen for `target` of `workspace`, a
  # `%{system, path}` or a target row, nil for none. Read without a lock.
  @spec target_choice(Workspace.t(), Target.t() | %{system: String.t(), path: String.t()}) ::
          Stack.t() | nil
  def target_choice(%Workspace{} = workspace, %Target{id: target_id}) do
    Repo.one(
      from s in Stack,
        where: s.organisation_id == ^workspace.organisation_id,
        where: s.workspace_id == ^workspace.id and s.target_id == ^target_id,
        where: is_nil(s.workflow) and not is_nil(s.choice)
    )
  end

  def target_choice(%Workspace{} = workspace, %{system: _system, path: _path} = target) do
    case target_row(workspace, target) do
      %Target{} = row -> target_choice(workspace, row)
      nil -> nil
    end
  end

  @doc false
  # chosen_for/4 is the harness choice an explore run of `workflow` of `workspace` of
  # `organisation` at `target`, a `%{system, path}` or nil for none, takes, in this order:
  #
  #   * the stack chosen for the target, `:qory` or `:repository`: `{:chosen, resolution}`;
  #   * the workspace's choice, else the organisation's shared one: `{:chosen,
  #     resolution}` for `:repository`, `{:qory, resolution}` for `:qory`;
  #   * `:none`.
  #
  # The resolution is the one row's document at its level, its owner and whether the run
  # hides it, as `Apiary.Stacks.Resolution` reads a row. The walk reads the target's
  # harness file before the document of `{:qory, resolution}`, and before the Qory
  # harness for `:none`. Read without a lock.
  @spec chosen_for(
          Organisation.t(),
          Workspace.t(),
          %{system: String.t(), path: String.t()} | nil,
          String.t()
        ) :: {:chosen, Resolution.t()} | {:qory, Resolution.t()} | :none
  def chosen_for(%Organisation{} = organisation, %Workspace{} = workspace, target, workflow)
      when is_binary(workflow) do
    target_row = target_row(workspace, target)
    by_target = target_row && target_choice(workspace, target_row)

    cond do
      by_target ->
        {:chosen, resolved(organisation, workspace, target_row.id, workflow, by_target)}

      row = choice(workspace) || shared(organisation) ->
        kind = if row.choice == :qory, do: :qory, else: :chosen
        {kind, resolved(organisation, workspace, nil, workflow, row)}

      true ->
        :none
    end
  end

  # The resolution of the one choice row `row` for a run (`Apiary.Stacks.Resolution`).
  defp resolved(organisation, workspace, target_id, workflow, %Stack{} = row) do
    {:ok, resolution} =
      Resolution.resolve(%{
        stacks: [row],
        organisation_id: organisation.id,
        workspace_id: workspace.id,
        target_id: target_id,
        workflow: workflow,
        operated: Edition.operated?(organisation)
      })

    resolution
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
  # the runs of the place's workflow, `:read` or `:write`, nil for none (the default); and
  # `choice`, the harness choice at a place with no workflow (the moduledoc), nil for
  # none (the default), so a write there without one removes the choice. `{:ok, stack}`;
  # `{:error, :forbidden}` when the edition gives none; or `{:error, changeset}` with the
  # reason on its field. It checks no access (the moduledoc).
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
              choice: Keyword.get(opts, :choice),
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
  # stack}`, as it was, or `{:error, :not_found}` for a place with none. It checks no
  # access (the moduledoc).
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
    |> change(Map.drop(changes, [:harness, :workflow, :access, :choice]))
    |> cast(changes, [:harness, :workflow, :access, :choice])
    |> validate_harness_or_workflow()
    |> validate_access()
    |> validate_choice()
    |> validate_change(:harness, fn :harness, value ->
      for error <- Document.errors(value), do: {:harness, error}
    end)
    |> validate_format(:workflow, @workflow)
    |> check_constraint(:harness, name: :stacks_harness_or_workflow, message: "can't be blank")
    |> check_constraint(:harness, name: :stacks_harness_size, message: "is too long")
    |> check_constraint(:access, name: :stacks_access_check, message: @access_without_workflow)
    |> check_constraint(:choice, name: :stacks_choice_check, message: "is invalid")
    |> unique_constraint(:harness, name: :stacks_place_index)
  end

  # A row sets a harness document, a workflow or a choice, or more than one. A value that
  # did not cast has the error "is invalid" already.
  defp validate_harness_or_workflow(changeset) do
    if is_nil(get_field(changeset, :harness)) and is_nil(get_field(changeset, :workflow)) and
         is_nil(get_field(changeset, :choice)) and
         not Keyword.has_key?(changeset.errors, :harness),
       do: add_error(changeset, :harness, "can't be blank", validation: :required),
       else: changeset
  end

  # A choice only at a place with no workflow, and only with its document.
  defp validate_choice(changeset) do
    cond do
      is_nil(get_field(changeset, :choice)) ->
        changeset

      get_field(changeset, :workflow) != nil ->
        add_error(changeset, :choice, "is invalid")

      is_nil(get_field(changeset, :harness)) and not Keyword.has_key?(changeset.errors, :harness) ->
        add_error(changeset, :harness, "can't be blank", validation: :required)

      true ->
        changeset
    end
  end

  # An access level only at a place with a workflow.
  defp validate_access(changeset) do
    if get_field(changeset, :access) && is_nil(get_field(changeset, :workflow)),
      do: add_error(changeset, :access, @access_without_workflow),
      else: changeset
  end
end
