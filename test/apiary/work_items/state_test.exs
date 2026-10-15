defmodule Apiary.WorkItems.StateTest do
  use ExUnit.Case, async: true

  alias Apiary.WorkItems.State

  # Every move the table has; every other pair of a state and an event is refused.
  @moves %{
    {nil, :take_in} => :exploring,
    {:exploring, :undo} => :undone,
    {:exploring, :close} => :closed
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

  test "a work item is taken in once, and is exploring after it" do
    assert State.next(nil, :take_in) == {:ok, :exploring}

    for state <- State.states(), do: assert(State.next(state, :take_in) == :error)
  end

  test "undone and closed are final" do
    for state <- [:undone, :closed], event <- State.events() do
      assert State.next(state, event) == :error, inspect({state, event})
    end
  end

  test "a work item not taken in is neither undone nor closed" do
    assert State.next(nil, :undo) == :error
    assert State.next(nil, :close) == :error
  end

  test "an event or a state the table does not know is refused" do
    assert State.next(:exploring, :ship) == :error
    assert State.next(:shipped, :close) == :error
  end
end
