defmodule Apiary.Stages.Approvers do
  # The approvers of a stage's gate, as the stage's `gate.approvers` lists them: every
  # member (`"members"`, or no list), or the members whose account ids the list has
  # (`%{"members" => ids}`). `Apiary.Access` asks `allows?/2` for the actions only a
  # stage's approvers take on a work item at that stage; `Apiary.Stages` asks `listed/1`
  # and `listed?/2` for the gate it shows. This module reads the process version and
  # nothing else, and calls neither `Apiary.Access` nor `Apiary.Stages`, so both may call
  # it.
  @moduledoc false

  alias Apiary.Accounts.Scope
  alias Apiary.{Features, Processes}
  alias Apiary.Processes.Version
  alias Apiary.WorkItems.WorkItem

  # allows?/2 is whether the scope's person is among the approvers of the stage the work
  # item `work_item` is in: true with the workflow model off, for a work item the runner
  # did not place, and for a stage that lists no approvers. It reads the work item's
  # process version, unless the work item has it loaded.
  @doc false
  @spec allows?(Scope.t() | nil, WorkItem.t()) :: boolean
  def allows?(scope, %WorkItem{} = work_item) do
    case Features.on?(:workflow_model) && stage(work_item) do
      stage when is_map(stage) -> listed?(scope, stage)
      _off_or_not_placed -> true
    end
  end

  # listed/1 is the approvers of `stage`'s gate: `:members` for every member, else the
  # account ids it lists.
  @doc false
  @spec listed(map) :: :members | [String.t()]
  def listed(stage) do
    case get_in(stage, ["gate", "approvers"]) do
      %{"members" => members} when is_list(members) -> members
      _members -> :members
    end
  end

  # listed?/2 is whether the scope's person is among the approvers of `stage`'s gate:
  # any scope for a gate of every member; for a list, a scope whose person's account id
  # it has. False for no scope.
  @doc false
  @spec listed?(Scope.t() | nil, map) :: boolean
  def listed?(%Scope{user: user}, stage) do
    case listed(stage) do
      :members -> true
      members -> match?(%{id: id} when is_binary(id), user) and user.id in members
    end
  end

  def listed?(nil, _stage), do: false

  # The stage the work item is in, from its process version; nil for a work item the
  # runner did not place, or whose version has no such stage.
  defp stage(%WorkItem{stage_id: stage_id} = work_item) when is_binary(stage_id),
    do: Processes.stage(version(work_item), stage_id)

  defp stage(%WorkItem{}), do: nil

  defp version(%WorkItem{process_version: %Version{} = version}), do: version
  defp version(%WorkItem{} = work_item), do: Processes.version_for(work_item)
end
