defmodule Apiary.TimeLimits.Resolution do
  # What the time limits of a run's workspace come to for its workflow: the minutes a run
  # may take, and the place they came from. Pure: limits in, a resolution out.
  # `Apiary.TimeLimits` reads what it takes.
  #
  # **The order.** The target's limit for the workflow, then the workspace's. A run with
  # no target has the workspace's alone. No limit at either place resolves to `:none`: the
  # run takes the default of the workflow's stack, which the machine applies.
  @moduledoc false

  alias Apiary.TimeLimits.TimeLimit

  @typedoc """
  What a resolution reads: the time limits of the run's workspace (rows of other places
  and workflows are left out here), the run's workspace, its target (nil for none) and its
  workflow.
  """
  @type input :: %{
          required(:limits) => [TimeLimit.t()],
          required(:workspace_id) => Ecto.UUID.t(),
          required(:target_id) => Ecto.UUID.t() | nil,
          required(:workflow) => String.t()
        }

  @typedoc "A resolution: the `minutes`, and the `level` they came from."
  @type t :: %__MODULE__{minutes: pos_integer, level: TimeLimit.level()}

  @enforce_keys [:minutes, :level]
  defstruct [:minutes, :level]

  @doc false
  # resolve/1 is what `input` comes to: `{:ok, resolution}`, or `:none` where no place has
  # a limit for the workflow.
  @spec resolve(input) :: {:ok, t} | :none
  def resolve(%{} = input) do
    placed =
      for limit <- input.limits,
          limit.workflow == input.workflow,
          level = place(limit, input),
          level != nil,
          do: {level, limit}

    case Enum.find(placed, &match?({:target, _}, &1)) ||
           Enum.find(placed, &match?({:workspace, _}, &1)) do
      {level, limit} -> {:ok, %__MODULE__{minutes: limit.minutes, level: level}}
      nil -> :none
    end
  end

  # The level of `limit` for the run, or nil for a limit of another place.
  defp place(%TimeLimit{} = limit, input) do
    same_workspace = limit.workspace_id == input.workspace_id

    cond do
      not same_workspace -> nil
      is_nil(limit.target_id) -> :workspace
      not is_nil(input.target_id) and limit.target_id == input.target_id -> :target
      true -> nil
    end
  end
end
