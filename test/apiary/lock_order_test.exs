defmodule Apiary.LockOrderTest do
  @moduledoc """
  The order in which several organisations are locked
  (`Apiary.Organisations.lock_order/1`): those after which the edition holds another
  organisation first, then the rest, each in the order of their ids. The edition may read
  in `c:Apiary.Edition.places_to_lock/1`, so the test has a connection of its own in the
  SQL sandbox; each test says which edition answers, so it holds under every edition.
  """
  use Apiary.DataCase, async: true

  alias Apiary.Organisations
  alias Apiary.Organisations.Organisation

  defp organisations(n),
    do: for(_ <- 1..n, do: %Organisation{id: Ecto.UUID.generate()})

  defp ids(organisations), do: organisations |> Enum.map(& &1.id) |> Enum.sort()

  test "with the core's edition (Apiary.Edition.Core), the order of their ids" do
    :ok = Apiary.Edition.put_test_stub(Apiary.Edition.Core)
    given = organisations(5)

    assert Organisations.lock_order(Enum.shuffle(given)) == ids(given)
  end

  test "with an edition that reads in places_to_lock/1, the order it answers" do
    :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ReadsPlaces)
    given = organisations(3)

    assert Organisations.lock_order(Enum.shuffle(given)) == ids(given)
    for id <- ids(given), do: assert_received({:places_read, ^id})
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

  test "lock_organisations/2 takes each mode, and an empty set" do
    :ok = Apiary.Edition.put_test_stub(Apiary.Edition.Core)
    %{organisation: %Organisation{id: id}} = Apiary.OrganisationsFixtures.sign_up_fixture()

    for mode <- [:key_share, :share, :no_key_update, :update] do
      assert {:ok, {:ok, [^id]}} =
               Repo.transaction(fn -> Organisations.lock_organisations([id], mode) end)
    end

    assert {:ok, {:ok, []}} =
             Repo.transaction(fn -> Organisations.lock_organisations([], :share) end)
  end
end
