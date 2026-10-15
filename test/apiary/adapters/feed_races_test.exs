defmodule Apiary.Adapters.FeedRacesTest do
  # An adapter's feed entries written at the same time, the same request accepted at the
  # same time on two connections, as two nodes of a cluster would, and a declaration that
  # waits on the adapter's deletion. Each side runs on a
  # separate connection, outside the SQL sandbox, so each commits and each waits on the
  # other's locks as it would in production. Not async: what these tests commit is
  # visible to every other test while they run, and they delete it again before they end.
  #
  # The rules under test: the upsert that numbers an entry (`Apiary.Adapters.Feed.append/2`)
  # locks the adapter's counter until its transaction ends, so a second entry waits for
  # the first and takes the number after it, and entries commit in the order of their
  # numbers; a request's signature is accepted once (`Apiary.Adapters.SeenRequests`),
  # whichever connection asks first; and a declaration (`Apiary.Adapters.declare/2`) that
  # waits on the adapter's row while the adapter is deleted is refused as for a deleted
  # adapter, and stores nothing.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Apiary.Races

  alias Apiary.{AccessKeys, Adapters, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Feed, SeenRequests}
  alias Apiary.Nodes.Node

  @moduletag needs: :factory

  setup_all :clean_up_leftovers
  setup :setup_races

  defp adapter do
    %{scope: scope} = sign_up()
    {:ok, adapter} = Adapters.create_adapter(scope, %{name: "Acme tracker"})
    %{scope: scope, adapter: adapter}
  end

  defp append(adapter, interval),
    do: fn ->
      Repo.transact(fn -> Feed.append(adapter, %{kind: "sync", interval: interval}) end)
    end

  test "the second entry of an adapter waits for the first, and takes the next number" do
    %{adapter: adapter} = adapter()

    {first, first_pid} = hold(fn -> Feed.append(adapter, %{kind: "sync", interval: nil}) end)
    assert first.result == {:ok, 1}

    second = start(append(adapter, 900))
    await_blocked(second.backend, first_pid)
    commit(first)

    assert Task.await(second.task) == {:ok, 2}
  end

  # Twelve at most, and no more than the pool holds beside the test's connection: each
  # side keeps its connection until all are let go.
  test "of many entries appended at once, each number is taken once" do
    %{adapter: adapter} = adapter()
    count = sides(12)
    answers = together(for _ <- 1..count, do: append(adapter, 3600))
    assert Enum.sort(answers) == Enum.map(1..count, &{:ok, &1})
  end

  test "an entry is refused outside a transaction" do
    %{adapter: adapter} = adapter()

    assert_raise ArgumentError, ~r/inside the transaction/, fn ->
      Feed.append(adapter, %{kind: "sync", interval: nil})
    end
  end

  test "of the same request accepted at once on several connections, one is accepted" do
    %{scope: scope, adapter: adapter} = adapter()
    {:ok, _row, _code} = AccessKeys.create_enrolment_code(scope, adapter, %{})
    %{access_key: key} = Apiary.AccessKeysFixtures.enrolled_key_fixture(scope, adapter)
    signature = :crypto.strong_rand_bytes(64)
    now = System.os_time(:second)

    count = sides(8)

    answers =
      together(for _ <- 1..count, do: fn -> SeenRequests.record(key, signature, now, now) end)

    assert Enum.sort(answers) == [:ok | List.duplicate(:seen, count - 1)]
  end

  test "a declaration that waits on the adapter's deletion is refused as for a deleted adapter" do
    %{scope: scope, adapter: adapter} = adapter()
    {:ok, _row, _code} = AccessKeys.create_enrolment_code(scope, adapter, %{})
    %{access_key: key} = Apiary.AccessKeysFixtures.enrolled_key_fixture(scope, adapter)
    {:ok, key} = AccessKeys.fetch_for_verification(key.key_id)

    declaration = %{
      time: DateTime.utc_now(:second),
      connect_url: "https://tracker-adapter.acme.example/connect",
      default_interval: 900,
      minimum_interval: 300,
      sends_changes: false
    }

    {deleting, deleting_pid} = hold(fn -> Adapters.delete_adapter(scope, adapter) end)
    assert {:ok, _} = deleting.result

    declaring = start(fn -> Adapters.declare(Scope.for_access_key(key), declaration) end)
    await_blocked(declaring.backend, deleting_pid)
    commit(deleting)

    assert Task.await(declaring.task) == {:error, :not_found}
    assert %Node{connect_url: nil, deleted_at: %DateTime{}} = Repo.get!(Node, adapter.id)

    feed = from f in "adapter_feed", where: f.adapter_id == type(^adapter.id, :binary_id)
    assert Repo.aggregate(feed, :count) == 0
  end
end
