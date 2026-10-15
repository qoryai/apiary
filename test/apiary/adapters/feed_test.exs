defmodule Apiary.Adapters.FeedTest do
  # An adapter's change feed (`Apiary.Adapters.Feed`): entries numbered from 1 per
  # adapter, of the contract's three kinds, written inside the change's transaction, and
  # the tables that hold them. The races of two entries at once are
  # `Apiary.Adapters.FeedRacesTest`'s.
  use Apiary.DataCase, async: true

  import Ecto.Query
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Adapters.Feed

  @moduletag needs: :factory

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope, adapter: adapter_fixture(scope)}
  end

  defp append(adapter, entry), do: Repo.transact(fn -> Feed.append(adapter, entry) end)

  defp feed(adapter) do
    Repo.all(
      from f in "adapter_feed",
        where: f.adapter_id == type(^adapter.id, :binary_id),
        order_by: f.seq,
        select: {f.seq, f.kind, f.data, type(f.organisation_id, :binary_id)}
    )
  end

  test "numbers each adapter's entries from 1, and stores each kind's members", ctx do
    other = adapter_fixture(ctx.scope)

    assert append(ctx.adapter, %{kind: "sync", interval: nil}) == {:ok, 1}

    assert append(ctx.adapter, %{kind: "collection", collection_ref: "TRK", status: "linked"}) ==
             {:ok, 2}

    assert append(other, %{kind: "sync", interval: 3600}) == {:ok, 1}

    assert append(ctx.adapter, %{
             kind: "work_item",
             work_item_id: "wi_0123456789abcdef",
             ref: "TRK-1",
             status: "taken_in",
             url: "https://control.example.com/work-items/wi_0123456789abcdef"
           }) == {:ok, 3}

    organisation_id = ctx.scope.organisation.id

    assert feed(ctx.adapter) == [
             {1, "sync", %{"interval" => nil}, organisation_id},
             {2, "collection", %{"collection_ref" => "TRK", "status" => "linked"},
              organisation_id},
             {3, "work_item",
              %{
                "work_item_id" => "wi_0123456789abcdef",
                "ref" => "TRK-1",
                "status" => "taken_in",
                "url" => "https://control.example.com/work-items/wi_0123456789abcdef"
              }, organisation_id}
           ]

    assert [{1, "sync", %{"interval" => 3600}, ^organisation_id}] = feed(other)
  end

  test "an entry rolled back gives its number back", ctx do
    assert {:error, :rolled_back} =
             Repo.transact(fn ->
               {:ok, 1} = Feed.append(ctx.adapter, %{kind: "sync", interval: nil})
               {:error, :rolled_back}
             end)

    assert append(ctx.adapter, %{kind: "sync", interval: 900}) == {:ok, 1}
  end

  test "refuses an entry of no shape the contract defines, and a node that is no adapter", ctx do
    for entry <- [
          %{kind: "sync", interval: 30},
          %{kind: "sync", interval: 86_401},
          %{kind: "sync"},
          %{kind: "sync", interval: nil, extra: 1},
          %{kind: "collection", collection_ref: "TRK", status: "taken_in"},
          %{kind: "work_item", work_item_id: "wi_1", ref: "TRK-1", status: "linked", url: "u"},
          %{kind: "work_item", ref: "TRK-1", status: "undone", url: "u"},
          %{kind: "dispatch"}
        ] do
      assert_raise ArgumentError, fn -> append(ctx.adapter, entry) end
    end

    node = node_fixture(ctx.scope)
    assert_raise ArgumentError, fn -> append(node, %{kind: "sync", interval: nil}) end
    assert feed(ctx.adapter) == []
  end

  describe "the tables" do
    test "hold an entry to its adapter's organisation, and to the kinds and size the feed has",
         ctx do
      %{scope: stranger} = sign_up_fixture()

      row = %{
        id: Ecto.UUID.bingenerate(),
        organisation_id: Ecto.UUID.dump!(stranger.organisation.id),
        adapter_id: Ecto.UUID.dump!(ctx.adapter.id),
        seq: 1,
        kind: "sync",
        data: %{"interval" => nil},
        inserted_at: DateTime.utc_now()
      }

      assert refused(fn -> Repo.insert_all("adapter_feed", [row]) end) ==
               "adapter_feed_adapter_id_fkey"

      row = %{row | organisation_id: Ecto.UUID.dump!(ctx.scope.organisation.id)}

      assert refused(fn -> Repo.insert_all("adapter_feed", [%{row | kind: "dispatch"}]) end) ==
               "adapter_feed_kind_check"

      assert refused(fn -> Repo.insert_all("adapter_feed", [%{row | seq: 0}]) end) ==
               "adapter_feed_seq_check"

      big = %{"interval" => String.duplicate("a", 4096)}

      assert refused(fn -> Repo.insert_all("adapter_feed", [%{row | data: big}]) end) ==
               "adapter_feed_data_check"

      assert {1, _} = Repo.insert_all("adapter_feed", [row])

      assert refused(fn ->
               Repo.insert_all("adapter_feed", [%{row | id: Ecto.UUID.bingenerate()}])
             end) == "adapter_feed_adapter_id_seq_index"
    end
  end

  defp refused(fun) do
    %Postgrex.Error{postgres: %{constraint: constraint}} = assert_raise(Postgrex.Error, fun)
    constraint
  end
end
