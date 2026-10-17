defmodule Apiary.WorkItems.StateTest do
  use ExUnit.Case, async: true

  alias Apiary.WorkItems.State

  # Every move the table has; every other pair of a state and an event is refused.
  @moves %{
    {nil, :take_in} => :exploring,
    {:exploring, :undo} => :undone,
    {:exploring, :decline} => :declined,
    {:exploring, :close} => :closed,
    {:declined, :take_in_again} => :exploring,
    {:closed, :take_in_again} => :exploring,
    {:undone, :take_in_again} => :exploring
  }

  test "every state and event: the moves of the table, and no other" do
    for state <- [nil | State.states()], event <- State.events() do
      expected =
        case Map.fetch(@moves, {state, event}) do
          {:ok, next} -> {:ok, next}
          :error -> :error
        end

      assert State.next(state, event) == expected, inspect({state, event})
    end
  end

  test "the states are exploring, the one live state, and the three a work item ends in" do
    assert State.states() == [:exploring, :declined, :closed, :undone]
    assert State.ended_states() == [:declined, :closed, :undone]
    assert State.live?(:exploring)
    for state <- [nil | State.ended_states()], do: refute(State.live?(state))
  end

  test "a work item is taken in once, and is exploring after it" do
    assert State.next(nil, :take_in) == {:ok, :exploring}

    for state <- State.states(), do: assert(State.next(state, :take_in) == :error)
  end

  test "a work item that ended is taken in again, the same work item, and a live one is not" do
    for state <- State.ended_states(),
        do: assert(State.next(state, :take_in_again) == {:ok, :exploring})

    assert State.next(:exploring, :take_in_again) == :error
    assert State.next(nil, :take_in_again) == :error
  end

  test "an ended work item moves only by a take in again" do
    for state <- State.ended_states(), event <- State.events() -- [:take_in_again] do
      assert State.next(state, event) == :error, inspect({state, event})
    end
  end

  test "an undo goes back to where the take in found the work item" do
    # Its first take in: undone.
    assert State.next(:exploring, :undo, nil) == {:ok, :undone}

    # A take in again: the state it had ended in.
    for before <- State.ended_states(),
        do: assert(State.next(:exploring, :undo, before) == {:ok, before})

    # Only an exploring work item is undone, and only to a state it may have ended in.
    for state <- [nil | State.ended_states()], before <- [nil | State.ended_states()] do
      assert State.next(state, :undo, before) == :error, inspect({state, before})
    end

    assert State.next(:exploring, :undo, :exploring) == :error
    assert State.next(:exploring, :close, nil) == :error
  end

  test "a work item not taken in is neither undone, declined nor closed" do
    assert State.next(nil, :undo) == :error
    assert State.next(nil, :decline) == :error
    assert State.next(nil, :close) == :error
  end

  test "an event or a state the table does not know is refused" do
    assert State.next(:exploring, :ship) == :error
    assert State.next(:shipped, :close) == :error
  end
end
