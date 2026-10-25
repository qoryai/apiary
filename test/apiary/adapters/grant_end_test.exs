defmodule Apiary.Adapters.GrantEndTest do
  # A grant's external account and the collections it covers, and the end of one grant
  # (`Apiary.Adapters.Grants`, `Apiary.Adapters.Collections`): a report keeps its
  # account, and a report that replaces the grant replaces it; a listing keeps each
  # collection's grant, and a part with a grant the connection has no live grant
  # with is refused after the connection's checks and stores nothing; a grant end answers
  # in the contract's order, ends the grant and the collections it covers with their feed
  # entries and one trail entry, leaves the connection and its other grants, goes on for
  # a connection whose organisation is out of use, and changes nothing the second time.
  use Apiary.DataCase, async: true

  import Ecto.Query
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.SourcesFixtures, only: [key_scope: 1]

  alias Apiary.{Adapters, Edition, EditionStubs, Repo}
  alias Apiary.Adapters.{Collection, Collections, Connection, Connections, Feed, Grant, Grants}
  alias Apiary.Audit.Entry
  alias Apiary.Contract.Ed25519

  @moduletag needs: :factory

  @started ~U[2026-10-15 11:00:00Z]

  setup do
    %{scope: scope} = sign_up_fixture()
    connectable = connectable_adapter_fixture(%{name: unique_adapter_name("Acme tracker")})
    {connection, _nonce} = connection_fixture(scope, connectable.adapter, :connected)

    %{
      scope: scope,
      adapter: connectable.adapter,
      pair: connectable.pair,
      key_scope: key_scope(connectable.access_key),
      connection: connection
    }
  end

  # A report of `ref` for `account` under the 16 bytes `nonce`.
  defp report(ctx, ref, nonce, account),
    do:
      Grants.report(ctx.key_scope, %{
        connection_id: ctx.connection.public_id,
        grant_ref: ref,
        account: account,
        pass_nonce: nonce
      })

  # A new pass of the connection, pressed by the scope's person, whose return came back
  # linked: the 16 bytes of its nonce.
  defp linked_pass(ctx) do
    :ok = pass_made_earlier(ctx.connection.public_id)
    {:ok, _url, {public_id, nonce}} = Adapters.connect(ctx.scope, ctx.adapter)
    token = return_token(ctx.pair.secret, public_id, nonce)
    {:ok, :linked} = Connections.complete_return(ctx.scope, public_id, token, nonce)
    elem(Ed25519.decode(nonce, 16), 1)
  end

  # One part of a listing of `connection`, each collection `{ref, grant_ref}`.
  defp part(connection, collections, opts \\ []) do
    %{
      time: DateTime.utc_now(:second),
      connection_id: connection.public_id,
      collections:
        for {ref, grant_ref} <- collections do
          %{
            ref: ref,
            url: "https://tracker.acme.example/" <> ref,
            title: "Title of " <> ref,
            grant_ref: grant_ref,
            target: nil
          }
        end,
      listing: %{
        id: Keyword.get(opts, :id, "listing-1"),
        part: 1,
        started_at: Keyword.get(opts, :started_at, @started),
        complete: Keyword.get(opts, :complete, false)
      }
    }
  end

  defp post(ctx, collections, opts \\ []),
    do: Collections.post_listing(ctx.key_scope, part(ctx.connection, collections, opts))

  defp end_grant(ctx, ref, connection_id \\ nil),
    do:
      Grants.end_grant(ctx.key_scope, %{
        connection_id: connection_id || ctx.connection.public_id,
        grant_ref: ref
      })

  defp grant(connection, ref),
    do:
      Repo.one!(from g in Grant, where: g.connection_id == ^connection.id and g.grant_ref == ^ref)

  # The live collections of `connection`, `{ref, grant ref}`, by ref.
  defp live(connection) do
    Repo.all(
      from c in Collection,
        left_join: g in Grant,
        on: g.id == c.grant_id,
        where: c.connection_id == ^connection.id and is_nil(c.ended_at),
        order_by: c.external_ref,
        select: {c.external_ref, g.grant_ref}
    )
  end

  defp collection(connection, ref),
    do: Repo.get_by!(Collection, connection_id: connection.id, external_ref: ref)

  defp entries(adapter), do: Enum.map(Feed.entries(adapter), &Map.put(&1.data, "kind", &1.kind))

  defp trail(action),
    do: Repo.all(from e in Entry, where: e.action == ^action, order_by: e.id)

  # Everything a refused request leaves as it was: the grants, the collections, the
  # connection, the feed and the trail.
  defp state(ctx) do
    {Repo.all(from g in Grant, order_by: g.id), Repo.all(from c in Collection, order_by: c.id),
     Repo.get!(Connection, ctx.connection.id), Feed.entries(ctx.adapter),
     Repo.all(from e in Entry, order_by: e.id)}
  end

  describe "a grant report with its account" do
    test "keeps the account; a report that replaces the grant replaces it", ctx do
      {:ok, first} = report(ctx, "G_1", ctx.connection.pass_nonce, %{ref: "1001", title: "acme"})
      assert {first.account_ref, first.account_title} == {"1001", "acme"}
      assert {grant(ctx.connection, "G_1").account_ref, first.account_title} == {"1001", "acme"}

      second_nonce = linked_pass(ctx)

      {:ok, second} =
        report(ctx, "G_1", second_nonce, %{ref: "1001", title: "Acme Corp"})

      assert second.id == first.id

      assert %Grant{account_ref: "1001", account_title: "Acme Corp", state: :live} =
               grant(ctx.connection, "G_1")
    end
  end

  describe "a listing with grant_ref" do
    test "keeps each collection's grant; a newer listing changes it, an older one does not",
         ctx do
      g1 = listing_grant(ctx.connection, "G_1")
      g2 = listing_grant(ctx.connection, "G_2")

      assert post(ctx, [{"TRK", g1}, {"OPS", g2}]) == {:ok, :accepted}
      assert live(ctx.connection) == [{"OPS", "G_2"}, {"TRK", "G_1"}]
      assert collection(ctx.connection, "TRK").grant_id == grant(ctx.connection, "G_1").id

      assert post(ctx, [{"TRK", g2}], id: "newer", started_at: DateTime.add(@started, 60)) ==
               {:ok, :accepted}

      assert post(ctx, [{"TRK", g1}], id: "older", started_at: DateTime.add(@started, -60)) ==
               {:ok, :accepted}

      assert live(ctx.connection) == [{"OPS", "G_2"}, {"TRK", "G_2"}]
    end

    test "an unknown, ended or other connection's grant_ref is refused and stores nothing",
         ctx do
      g1 = listing_grant(ctx.connection, "G_1")
      ended = listing_grant(ctx.connection, "G_ENDED")
      {:ok, _} = end_grant(ctx, ended)
      %{scope: other} = sign_up_fixture()
      {theirs, _nonce} = connection_fixture(other, ctx.adapter, :connected)
      their_ref = listing_grant(theirs)
      before = state(ctx)

      for wrong <- ["G_NEVER", ended, their_ref] do
        assert post(ctx, [{"TRK", g1}, {"OPS", wrong}]) == {:error, :invalid}, wrong
      end

      assert state(ctx) == before
      assert Repo.get!(Connection, ctx.connection.id).listed_at == nil
      assert Repo.aggregate("source_collection_listings", :count) == 0
    end

    test "the refusal order: unknown, ended and suspended come before a grant_ref it has not",
         ctx do
      %{scope: second} = sign_up_fixture()
      {pending, _nonce} = connection_fixture(second, ctx.adapter, :pending)

      assert Collections.post_listing(ctx.key_scope, part(pending, [{"A", "G_NEVER"}])) ==
               {:error, :unknown}

      Edition.put_test_stub(EditionStubs.OutOfUse)
      Process.put(:out_of_use, [ctx.scope.organisation.id])
      assert post(ctx, [{"A", "G_NEVER"}]) == {:error, :suspended}

      {:ok, _} = Connections.end_connection(ctx.key_scope, ctx.connection.public_id)
      assert post(ctx, [{"A", "G_NEVER"}]) == {:error, :ended}

      assert Collections.post_listing(ctx.scope, part(ctx.connection, [{"A", "G_NEVER"}])) ==
               {:error, :forbidden}

      assert Repo.aggregate(Collection, :count) == 0
    end
  end

  describe "a grant end" do
    test "ends that grant and its collections only; the connection and the other grant stay",
         ctx do
      {:ok, one} = report(ctx, "G_1", ctx.connection.pass_nonce, %{ref: "1001", title: "acme"})
      g2 = listing_grant(ctx.connection, "G_2")
      {:ok, :accepted} = post(ctx, [{"TRK", "G_1"}, {"OPS", "G_1"}, {"DOC", g2}], complete: true)
      # TRK and DOC linked, OPS assigned to no workspace.
      for ref <- ["TRK", "DOC"],
          do:
            {:ok, _} =
              set_collection_workspace(collection(ctx.connection, ref), ctx.scope.workspace)

      {:ok, _} = set_collection_workspace(collection(ctx.connection, "OPS"), nil)
      before_feed = length(Feed.entries(ctx.adapter))

      assert {:ok, %Grant{id: id, state: :ended, ended_reason: :adapter_reported}} =
               end_grant(ctx, "G_1")

      assert id == one.id
      assert %Grant{state: :live, ended_at: nil} = grant(ctx.connection, g2)
      assert live(ctx.connection) == [{"DOC", "G_2"}]

      for ref <- ["TRK", "OPS"] do
        assert %Collection{ended_reason: :disconnected, ended_at: %DateTime{}} =
                 collection(ctx.connection, ref)
      end

      assert %Connection{state: :connected, ended_at: nil} =
               Repo.get!(Connection, ctx.connection.id)

      # The collection that was linked, then the grant.
      assert Enum.drop(entries(ctx.adapter), before_feed) == [
               %{"kind" => "collection", "collection_ref" => "TRK", "status" => "unlinked"},
               %{
                 "kind" => "grant",
                 "connection_id" => ctx.connection.public_id,
                 "grant_ref" => "G_1",
                 "status" => "unlinked"
               }
             ]

      assert [%Entry{organisation_id: trail, actor_kind: :access_key} = entry] =
               trail("adapter.end_grant")

      assert {trail, entry.subject_kind, entry.subject_id} ==
               {Edition.instance_organisation_id(), "node", ctx.adapter.id}

      assert entry.details == %{
               "connection_id" => ctx.connection.public_id,
               "grant_id" => one.public_id,
               "collections" => 2
             }

      # Qory Apiary's copy no longer has the grant; a listing under it is refused.
      assert Grants.list_for_adapter(ctx.key_scope) == {:ok, [{ctx.connection.public_id, g2}]}
      assert post(ctx, [{"TRK", "G_1"}], id: "again") == {:error, :invalid}
    end

    test "a second grant end of the same grant is grant_unknown and changes nothing", ctx do
      ref = listing_grant(ctx.connection, "G_1")
      {:ok, :accepted} = post(ctx, [{"TRK", ref}])
      {:ok, _} = end_grant(ctx, ref)
      before = state(ctx)

      assert end_grant(ctx, ref) == {:error, :grant_unknown}
      assert end_grant(ctx, "G_NEVER") == {:error, :grant_unknown}
      assert state(ctx) == before
      assert length(trail("adapter.end_grant")) == 1
    end

    test "answers in the contract's order, and each refusal changes nothing", ctx do
      ref = listing_grant(ctx.connection, "G_1")
      {:ok, :accepted} = post(ctx, [{"TRK", ref}])
      %{scope: second} = sign_up_fixture()
      {pending, _nonce} = connection_fixture(second, ctx.adapter, :pending)
      other = connectable_adapter_fixture()
      {elsewhere, _nonce} = connection_fixture(second, other.adapter, :connected)
      their_ref = listing_grant(elsewhere)
      before = state(ctx)

      # Forbidden first: a scope of no adapter's key, whatever the connection.
      for scope <- [ctx.scope, nil],
          id <- [ctx.connection.public_id, pending.public_id, "ac_0000000000000000"] do
        assert Grants.end_grant(scope, %{connection_id: id, grant_ref: ref}) ==
                 {:error, :forbidden}
      end

      # Unknown: a pending connection, an id of no connection, a malformed id, another
      # adapter's connection in another organisation, and this connection to another
      # adapter's key.
      assert end_grant(ctx, ref, pending.public_id) == {:error, :unknown}
      assert end_grant(ctx, ref, "ac_0000000000000000") == {:error, :unknown}
      assert end_grant(ctx, ref, "not an id") == {:error, :unknown}
      assert end_grant(ctx, their_ref, elsewhere.public_id) == {:error, :unknown}

      assert Grants.end_grant(key_scope(other.access_key), %{
               connection_id: ctx.connection.public_id,
               grant_ref: ref
             }) == {:error, :unknown}

      # Grant unknown, for a ref the connection does not have.
      assert end_grant(ctx, their_ref) == {:error, :grant_unknown}
      assert state(ctx) == before

      # Ended, before grant_unknown.
      {:ok, _} = Connections.end_connection(ctx.key_scope, ctx.connection.public_id)
      assert end_grant(ctx, ref) == {:error, :ended}
      assert end_grant(ctx, "G_NEVER") == {:error, :ended}
      assert trail("adapter.end_grant") == []
    end

    test "a connection whose organisation is out of use: the grant ends all the same", ctx do
      ref = listing_grant(ctx.connection, "G_1")
      {:ok, :accepted} = post(ctx, [{"TRK", ref}])
      Edition.put_test_stub(EditionStubs.OutOfUse)
      Process.put(:out_of_use, [ctx.scope.organisation.id])

      assert {:ok, %Grant{state: :ended}} = end_grant(ctx, ref)
      assert live(ctx.connection) == []
      assert Repo.get!(Connection, ctx.connection.id).state == :connected
    end

    test "the collections ended are broadcast to the organisation", ctx do
      ref = listing_grant(ctx.connection, "G_1")
      {:ok, :accepted} = post(ctx, [{"TRK", ref}])
      id = collection(ctx.connection, "TRK").id
      :ok = Collections.subscribe(ctx.scope)

      {:ok, _} = end_grant(ctx, ref)

      assert_receive {:collections_changed,
                      %{connection_id: connection_id, collection_ids: [^id]}}

      assert connection_id == ctx.connection.id
    end

    test "a collection with no grant, from before the contract gave one, stays", ctx do
      ref = listing_grant(ctx.connection, "G_1")
      {:ok, :accepted} = post(ctx, [{"TRK", ref}, {"OLD", ref}])

      {1, _} =
        Repo.update_all(
          from(c in Collection, where: c.external_ref == "OLD"),
          set: [grant_id: nil]
        )

      {:ok, _} = end_grant(ctx, ref)
      assert live(ctx.connection) == [{"OLD", nil}]
    end
  end
end
