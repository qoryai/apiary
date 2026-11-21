defmodule Apiary.ModelKeys.OrderTest do
  # The order of one provider's keys at a run's claim, and the keys the run gets
  # (`Apiary.ModelKeys.Order`).
  use ExUnit.Case, async: true

  alias Apiary.ModelKeys.Order

  @now ~U[2026-11-10 12:00:00.000000Z]

  # A key added `added` seconds after a fixed time, with `opts` of the order's fields.
  defp key(id, added, opts \\ []) do
    %{
      id: id,
      default: Keyword.get(opts, :default, false),
      inserted_at: DateTime.add(~U[2026-11-01 09:00:00.000000Z], added),
      known_reset: Keyword.get(opts, :reset),
      cooldown_until: Keyword.get(opts, :until)
    }
  end

  defp at(seconds), do: DateTime.add(@now, seconds)
  defp ids(keys), do: Enum.map(keys, & &1.id)

  test "the keys are sent in tie order: the free, then the cooling" do
    keys = [
      key("late", 1, reset: at(7200)),
      key("cooling-default", 2, default: true, until: at(600)),
      key("cooling", 0, until: at(60)),
      key("free", 3),
      key("soon", 4, reset: at(3600))
    ]

    picked = Order.order(keys, @now)
    assert ids(picked) == ~w(free soon late cooling cooling-default)
    assert Order.first_free(picked, @now).id == "free"
    assert ids(Order.sent(picked, @now)) == ~w(late free soon cooling-default cooling)
  end

  test "a key with no known reset, or one at or before now, goes before a known reset" do
    keys = [
      key("soon", 1, reset: at(60)),
      key("past", 2, reset: at(-60)),
      key("at-now", 3, reset: @now),
      key("none", 4)
    ]

    assert ids(Order.order(keys, @now)) == ~w(past at-now none soon)
  end

  test "keys with no known reset go in tie order: the default key, then the order they were added" do
    keys = [key("b", 2), key("c", 1), key("default", 3, default: true), key("a", 2)]

    # "a" and "b" were added at the same moment: their row ids break the tie.
    assert ids(Order.order(keys, @now)) == ~w(default c a b)
  end

  test "known resets go closest first, and resets in the same minute in tie order" do
    keys = [
      key("late", 1, reset: at(7200)),
      key("minute-b", 2, reset: at(605)),
      key("minute-default", 3, default: true, reset: at(610)),
      key("minute-a", 1, reset: at(601)),
      key("next-minute", 0, reset: at(660))
    ]

    assert ids(Order.order(keys, @now)) ==
             ~w(minute-default minute-a minute-b next-minute late)
  end

  test "keys in cooldown follow the free keys, the earliest end first, ties in tie order" do
    keys = [
      key("cool-late", 1, until: at(7200)),
      key("free", 9, reset: at(9000)),
      key("cool-early-b", 3, until: at(600)),
      key("cool-early-default", 4, default: true, until: at(600)),
      key("ended", 5, until: @now)
    ]

    assert ids(Order.order(keys, @now)) ==
             ~w(ended free cool-early-default cool-early-b cool-late)
  end

  test "a run gets at most 6 keys, the free ones first; the rest serve later runs" do
    free = for n <- 1..4, do: key("free-#{n}", n)
    cooling = for n <- 1..4, do: key("cool-#{n}", n, until: at(n * 60))

    ordered = Order.order(cooling ++ free, @now)

    assert Order.max_keys() == 6
    assert ids(ordered) == ~w(free-1 free-2 free-3 free-4 cool-1 cool-2)

    many_free = for n <- 1..8, do: key("free-#{n}", n)
    assert ids(Order.order(many_free ++ cooling, @now)) == for(n <- 1..6, do: "free-#{n}")
  end

  test "the default model provider credential is the first free key, never a key in cooldown" do
    keys = [key("cool", 1, default: true, until: at(60)), key("free", 2)]
    assert Order.first_free(Order.order(keys, @now), @now).id == "free"

    all_cooling = [key("a", 1, until: at(60)), key("b", 2, until: at(120))]
    ordered = Order.order(all_cooling, @now)
    assert ids(ordered) == ~w(a b)
    assert Order.first_free(ordered, @now) == nil
  end

  test "a key whose cooldown ended is free, and orders by its known reset" do
    keys = [
      key("ended", 1, until: at(-1), reset: at(3600)),
      key("open", 2, reset: at(1800))
    ]

    assert ids(Order.order(keys, @now)) == ~w(open ended)
    assert Order.cooling?(hd(keys), @now) == false
  end
end
