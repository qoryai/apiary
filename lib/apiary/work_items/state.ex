defmodule Apiary.WorkItems.State do
  @moduledoc """
  State holds where a work item stands and what moves it on, with no database: a pure
  table of moves.

  A work item is `:exploring` once it is taken in (`:take_in`, from no state). From
  there it is undone (`:undo`), as if it had never been taken in, or closed (`:close`).
  `:undone` and `:closed` are final. Every other move is refused.

  | State | Event | Next |
  |---|---|---|
  | none | `:take_in` | `:exploring` |
  | `:exploring` | `:undo` | `:undone` |
  | `:exploring` | `:close` | `:closed` |
  """

  @typedoc "Where a work item stands."
  @type state :: :exploring | :closed | :undone

  @typedoc "What moves a work item on."
  @type event :: :take_in | :undo | :close

  @states [:exploring, :closed, :undone]
  @events [:take_in, :undo, :close]

  @doc "states/0 is every state a work item may be in, as the database holds them."
  @spec states() :: [state]
  def states, do: @states

  @doc "events/0 is every event that moves a work item on."
  @spec events() :: [event]
  def events, do: @events

  @doc """
  next/2 is the state `event` moves a work item in `state` to: `{:ok, state}`, or `:error`
  for a move the table does not have. A work item not yet taken in has the state nil.
  """
  @spec next(state | nil, event) :: {:ok, state} | :error
  def next(nil, :take_in), do: {:ok, :exploring}
  def next(:exploring, :undo), do: {:ok, :undone}
  def next(:exploring, :close), do: {:ok, :closed}
  def next(_state, _event), do: :error
end
