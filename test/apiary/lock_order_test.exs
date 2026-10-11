defmodule Apiary.LockOrderTest do
  @moduledoc """
  The order in which several organisations are locked
  (`Apiary.Organisations.lock_order/1`): those after which the edition holds another
  organisation first, then the rest, each in the order of their ids. The test checks out
  no database connection, so a read or a lock would fail it: the organisations here are
  structs alone.
  """
  use ExUnit.Case, async: true

  alias Apiary.Organisations
  alias Apiary.Organisations.Organisation

  defp organisations(n),
    do: for(_ <- 1..n, do: %Organisation{id: Ecto.UUID.generate()})

  defp ids(organisations), do: organisations |> Enum.map(& &1.id) |> Enum.sort()

  test "with the core's edition, the order of their ids" do
    given = organisations(5)

    assert Organisations.lock_order(Enum.shuffle(given)) == ids(given)
  end

  test "those the edition holds another organisation after come first, each part by id" do
    :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.HoldsOthers)
    given = organisations(5)
    # The two highest ids hold others, so they come before the three lower ones.
    [low, mid, other, high, top] = ids(given)
    Process.put(:places_held, %{top => [low], high => [mid, low]})

    assert Organisations.lock_order(Enum.shuffle(given)) == [high, top, low, mid, other]
  end

  test "one organisation, and none" do
    :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.HoldsOthers)
    [one] = given = organisations(1)
    Process.put(:places_held, %{one.id => [Ecto.UUID.generate()]})

    assert Organisations.lock_order(given) == [one.id]
    assert Organisations.lock_order([]) == []
  end
end
