defmodule Apiary.Stacks.Resolution do
  # What the stacks of a run's organisation come to for the run's workflow: the stack the
  # run uses, the level it came from, its owner, and whether the run hides the text of
  # the stack's harness. Pure: stacks in, a resolution out. `Apiary.Stacks` reads what it
  # takes.
  #
  # **The order.** The five stored levels, the most specific first
  # (`Apiary.Stacks.Stack.levels/0`): the target and the workflow, the target, the
  # workspace and the workflow, the workspace, the organisation's default. The first
  # level with a stack wins; a level without one passes to the next. A run with no target
  # has no target levels. No stack at any level resolves to `:none`.
  #
  # **The owner.** A name's owner is the instance, whoever saved it. A reference's owner is
  # the organisation of the person who saved it, when that person saved it as a member
  # acting in that organisation (`Apiary.Stacks.saved_by/1`). It is nil, unknown, for a
  # reference saved by any other reach, such as an instance admin or an operator's person
  # acting in a client, and once the saver's organisation is deleted; an unknown owner is
  # never the run's organisation, so the run hides the harness.
  #
  # **Hidden.** `harness_hidden` is true when the run's organisation is operated
  # (`c:Apiary.Edition.operated?/1`), or when the owner is not the run's organisation. The
  # instance counts as the run's organisation only when the instance has one
  # organisation (`c:Apiary.Edition.limits/0`).
  @moduledoc false

  alias Apiary.Contract
  alias Apiary.Stacks.Stack

  @typedoc """
  What a resolution reads: the stacks of the run's organisation (rows of other places and
  workflows are left out here), the run's organisation, workspace, target (nil for none)
  and workflow, whether the run's organisation is operated, and whether the instance has
  one organisation.
  """
  @type input :: %{
          required(:stacks) => [Stack.t()],
          required(:organisation_id) => Ecto.UUID.t(),
          required(:workspace_id) => Ecto.UUID.t(),
          required(:target_id) => Ecto.UUID.t() | nil,
          required(:workflow) => String.t(),
          required(:operated) => boolean,
          required(:single_organisation) => boolean
        }

  @typedoc "The level a resolved stack came from."
  @type level :: Stack.level()

  @typedoc "The owner of a stack: the instance, an organisation's id, or nil for one deleted."
  @type owner :: :instance | Ecto.UUID.t() | nil

  @typedoc """
  A resolution: the `stack`, the `workflow`, the `level` and the `owner`, and
  `harness_hidden`.
  """
  @type t :: %__MODULE__{
          stack: String.t(),
          workflow: String.t(),
          level: level,
          owner: owner,
          harness_hidden: boolean
        }

  @enforce_keys [:stack, :workflow, :level, :owner, :harness_hidden]
  defstruct [:stack, :workflow, :level, :owner, :harness_hidden]

  @doc false
  # resolve/1 is what `input` comes to: `{:ok, resolution}`, or `:none` where no level
  # has a stack.
  @spec resolve(input) :: {:ok, t} | :none
  def resolve(%{} = input) do
    stored =
      for stack <- input.stacks,
          level = place(stack, input),
          level != nil,
          do: {level, stack}

    found =
      Enum.find_value(Stack.levels(), fn level ->
        Enum.find_value(stored, fn
          {^level, stack} -> {level, stack.stack, owner(stack)}
          _other -> nil
        end)
      end)

    case found do
      {level, stack, owner} ->
        {:ok,
         %__MODULE__{
           stack: stack,
           workflow: input.workflow,
           level: level,
           owner: owner,
           harness_hidden: hidden?(owner, input)
         }}

      nil ->
        :none
    end
  end

  @doc false
  # owner/1 is the owner of a stored stack: the instance for a name, the organisation of
  # the person who saved it for a reference.
  @spec owner(Stack.t()) :: owner
  def owner(%Stack{stack: stack, saved_by_organisation_id: saved_by}) do
    if Contract.Stack.name?(stack), do: :instance, else: saved_by
  end

  # The level of `stack` for the run, or nil for a stack of another place or workflow.
  defp place(%Stack{} = stack, input) do
    level = Stack.level(stack)
    same_organisation = stack.organisation_id == input.organisation_id
    same_workspace = same_organisation and stack.workspace_id == input.workspace_id
    same_workflow = stack.workflow == input.workflow

    same_target =
      same_workspace and not is_nil(input.target_id) and stack.target_id == input.target_id

    cond do
      level == :organisation and same_organisation -> :organisation
      level == :workspace and same_workspace -> :workspace
      level == :workspace_workflow and same_workspace and same_workflow -> :workspace_workflow
      level == :target and same_target -> :target
      level == :target_workflow and same_target and same_workflow -> :target_workflow
      true -> nil
    end
  end

  defp hidden?(_owner, %{operated: true}), do: true
  defp hidden?(:instance, %{single_organisation: single}), do: not single
  defp hidden?(owner, %{organisation_id: organisation_id}), do: owner != organisation_id
end
