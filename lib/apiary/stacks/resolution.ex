defmodule Apiary.Stacks.Resolution do
  # What the stacks of a run's organisation come to for the run's workflow: the harness
  # document the run uses, the level it came from, its owner, and whether the run hides
  # the text of the harness. Pure: stacks in, a resolution out. `Apiary.Stacks` reads
  # what it takes: for a run's walk, `Apiary.Stacks.chosen_for/4` passes the one row of
  # a chosen stack or choice.
  #
  # **The order.** The five stored levels, the most specific first
  # (`Apiary.Stacks.Stack.levels/0`): the target and the workflow, the target, the
  # workspace and the workflow, the workspace, the organisation's default. The first
  # level with a harness document wins; a level without one, a row that sets only the
  # workflow included, passes to the next. A run with no target has no target levels. No
  # document at any level resolves to `:none`.
  #
  # **The owner.** A document's owner is its row's owner organisation, which the edition
  # gives for the person who saved it last (`Apiary.Edition.harness_owner/1`). In the
  # core, that is the organisation of a member who saved it there through that membership
  # (`Apiary.Stacks.saved_by/1`). For an instance admin who saved it with no such
  # membership, it is the instance's organisation. It is nil once that organisation is
  # deleted.
  #
  # **Hidden.** `harness_hidden` is true when the run's organisation is operated
  # (`c:Apiary.Edition.operated?/1`), or when the owner is not the run's organisation. A
  # document the instance's organisation owns is the run's organisation's only for a run
  # of the instance's organisation: a run of any other organisation hides it, whether the
  # instance has one organisation or several. A nil owner is never the run's
  # organisation.
  @moduledoc false

  alias Apiary.Stacks.Stack

  @typedoc """
  What a resolution reads: the stacks of the run's organisation (rows of other places and
  workflows are left out here), the run's organisation, workspace, target (nil for none)
  and workflow, and whether the run's organisation is operated.
  """
  @type input :: %{
          required(:stacks) => [Stack.t()],
          required(:organisation_id) => Ecto.UUID.t(),
          required(:workspace_id) => Ecto.UUID.t(),
          required(:target_id) => Ecto.UUID.t() | nil,
          required(:workflow) => String.t(),
          required(:operated) => boolean
        }

  @typedoc "The level a resolved document came from."
  @type level :: Stack.level()

  @typedoc "The owner of a document: an organisation's id, or nil for one deleted."
  @type owner :: Ecto.UUID.t() | nil

  @typedoc """
  A resolution: the `harness` document, the id of its row (`stack_id`), the `workflow`,
  the `level` and the `owner`, and `harness_hidden`. `ref` is the version a run reads the
  document's base at, which `Apiary.Stacks.chosen_for/4` sets from the row's version
  (`Apiary.Stacks.version_ref/3`); nil for the document's `ref` as written, which
  `resolve/1` gives.
  """
  @type t :: %__MODULE__{
          harness: String.t(),
          stack_id: Ecto.UUID.t(),
          workflow: String.t(),
          level: level,
          owner: owner,
          harness_hidden: boolean,
          ref: String.t() | {:missing, String.t()} | nil
        }

  @enforce_keys [:harness, :stack_id, :workflow, :level, :owner, :harness_hidden]
  defstruct [:harness, :stack_id, :workflow, :level, :owner, :harness_hidden, ref: nil]

  @doc false
  # resolve/1 is what `input` comes to: `{:ok, resolution}`, or `:none` where no level
  # has a harness document.
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
          {^level, %Stack{harness: harness} = stack} when is_binary(harness) ->
            {level, stack, owner(stack)}

          _other ->
            nil
        end)
      end)

    case found do
      {level, stack, owner} ->
        {:ok,
         %__MODULE__{
           harness: stack.harness,
           stack_id: stack.id,
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
  # owner/1 is the owner of a stored document: its row's owner organisation.
  @spec owner(Stack.t()) :: owner
  def owner(%Stack{owner_organisation_id: owner}), do: owner

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
  defp hidden?(owner, %{organisation_id: organisation_id}), do: owner != organisation_id
end
