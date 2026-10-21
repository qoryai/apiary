defmodule Apiary.WorkItems.State do
  # State holds where a work item stands and what moves it on, with no database: a pure
  # table of moves.
  #
  # A work item is `:exploring` once it is taken in (`:take_in`, from no state), and
  # `:exploring` is its one live state. From there it is declined (`:decline`), closed
  # (`:close`) or undone (`:undo`). `:declined`, `:closed` and `:undone` are how a work
  # item ended: from each, its ticket may be taken in again (`:take_in_again`), which
  # makes the same work item `:exploring` again. An undo puts the work item back where
  # the take in found it: undone after its first take in, and after a take in again, the
  # state it had ended in, which the caller keeps and names (`next/3`). Every other move
  # is refused.
  #
  # | State | Event | Next |
  # |---|---|---|
  # | none | `:take_in` | `:exploring` |
  # | `:exploring` | `:undo` | `:undone`, or the state before the take in again |
  # | `:exploring` | `:decline` | `:declined` |
  # | `:exploring` | `:close` | `:closed` |
  # | `:declined`, `:closed`, `:undone` | `:take_in_again` | `:exploring` |
  @moduledoc false

  @typedoc "Where a work item stands."
  @type state :: :exploring | :declined | :closed | :undone

  @typedoc "How a work item ended: a state it may be taken in again from."
  @type ended :: :declined | :closed | :undone

  @typedoc "What moves a work item on."
  @type event :: :take_in | :undo | :decline | :close | :take_in_again

  @states [:exploring, :declined, :closed, :undone]
  @ended [:declined, :closed, :undone]
  @events [:take_in, :undo, :decline, :close, :take_in_again]

  # states/0 is every state a work item may be in, as the database holds them.
  @doc false
  @spec states() :: [state]
  def states, do: @states

  # ended_states/0 is every state a work item ended in, from which its ticket may be
  # taken in again.
  @doc false
  @spec ended_states() :: [ended]
  def ended_states, do: @ended

  # live?/1 says whether a work item in `state` is live: exploring.
  @doc false
  @spec live?(state | nil) :: boolean
  def live?(state), do: state == :exploring

  # events/0 is every event that moves a work item on.
  @doc false
  @spec events() :: [event]
  def events, do: @events

  # next/2 is the state `event` moves a work item in `state` to: `{:ok, state}`, or
  # `:error` for a move the table does not have. A work item not yet taken in has the
  # state nil. An undo here is the undo of a first take in, to `:undone`; `next/3` names
  # the state before a take in again.
  @doc false
  @spec next(state | nil, event) :: {:ok, state} | :error
  def next(nil, :take_in), do: {:ok, :exploring}
  def next(:exploring, :undo), do: {:ok, :undone}
  def next(:exploring, :decline), do: {:ok, :declined}
  def next(:exploring, :close), do: {:ok, :closed}
  def next(state, :take_in_again) when state in @ended, do: {:ok, :exploring}
  def next(_state, _event), do: :error

  # next/3 is the state an undo moves an exploring work item to, given `before`, the
  # state the latest take in found it in: nil for its first take in, which leads to
  # `:undone`, or the state it had ended in for a take in again, which it goes back to.
  # `:error` for any other state, event or `before`.
  @doc false
  @spec next(state | nil, event, ended | nil) :: {:ok, state} | :error
  def next(:exploring, :undo, nil), do: {:ok, :undone}
  def next(:exploring, :undo, before) when before in @ended, do: {:ok, before}
  def next(_state, _event, _before), do: :error
end
