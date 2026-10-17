defmodule Apiary.Adapters.CollectionsAssignTest do
  # The collections of a connection, for people: the page of them, its search, views and
  # workspace filter; the counts; assigning them to a workspace, or to none, with the
  # feed's entries and the trail's; the auto-assign while the organisation has one
  # workspace; and the broadcasts after each change, which carry ids only.
  use Apiary.DataCase, async: true

  import Ecto.Query
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{AccessKeys, Adapters, Deletion, Edition, EditionStubs, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Audit.Entry
  alias Apiary.Adapters.{Collection, Collections, Connection, Connections, Feed}
  alias Apiary.Organisations.Workspace

  @moduletag needs: :factory

  @started ~U[2026-10-15 11:00:00Z]

  # An organisation with two workspaces, so a collection is linked to none as it is made.
  setup do
    %{scope: scope} = sign_up_fixture()
    other_workspace = workspace_fixture(scope.organisation, "Second")
    connectable = connectable_adapter_fixture(%{name: "Acme tracker"})
    {connection, _nonce} = connection_fixture(scope, connectable.adapter, :connected)

    %{
      scope: scope,
      workspace: scope.workspace,
      other_workspace: other_workspace,
      adapter: connectable.adapter,
      key_scope: key_scope(connectable.access_key),
      connection: connection
    }
  end

  defp key_scope(key) do
    {:ok, verified} = AccessKeys.fetch_for_verification(key.key_id)
    Scope.for_access_key(verified)
  end

  # One part of a listing naming `collections`, `{ref, title}` each.
  defp part(connection, collections, opts \\ []) do
    %{
      time: DateTime.utc_now(:second),
      connection_id: connection.public_id,
      collections:
        for {ref, title} <- collections do
          %{ref: ref, url: "https://tracker.acme.example/" <> ref, title: title, target: nil}
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

  defp titled(refs), do: for(ref <- refs, do: {ref, "Title of " <> ref})

  defp id(ctx, ref) do
    Repo.one!(
      from c in Collection,
        where: c.connection_id == ^ctx.connection.id and c.external_ref == ^ref,
        where: is_nil(c.ended_at),
        select: c.id
    )
  end

  defp ids(ctx, refs), do: Enum.map(refs, &id(ctx, &1))

  defp names(rows), do: Enum.map(rows, & &1.name)

  defp workspace_of(ctx, ref), do: Repo.get!(Collection, id(ctx, ref)).workspace_id

  defp collection_entries(adapter),
    do: for(%{kind: "collection", data: data} <- Feed.entries(adapter), do: data)

  defp entry(ref, status), do: %{"collection_ref" => ref, "status" => status}

  defp assign_entries do
    Repo.all(
      from e in Entry,
        where: e.action == "collection.assign",
        order_by: [asc: e.inserted_at, asc: e.id]
    )
  end

  describe "the page" do
    test "50 rows by title, then the next after the last row's public id, and a short last page",
         ctx do
      refs = for n <- 1..120, do: "R" <> String.pad_leading(Integer.to_string(n), 3, "0")
      {:ok, :accepted} = post(ctx, titled(Enum.shuffle(refs)))
      assert Collections.page_size() == 50

      first = Collections.list_collections(ctx.scope, ctx.connection)
      assert names(first) == for(ref <- Enum.slice(refs, 0, 50), do: "Title of " <> ref)

      second =
        Collections.list_collections(ctx.scope, ctx.connection, after: List.last(first).public_id)

      assert names(second) == for(ref <- Enum.slice(refs, 50, 50), do: "Title of " <> ref)

      last =
        Collections.list_collections(ctx.scope, ctx.connection,
          after: List.last(second).public_id
        )

      assert length(last) == 20
      assert List.last(names(last)) == "Title of R120"

      # A cursor that names no collection of the connection gives nothing.
      for cursor <- ["sc_0000000000000000", "not a cursor", 7] do
        assert Collections.list_collections(ctx.scope, ctx.connection, after: cursor) == []
      end
    end

    test "a row: its ids, title, address, workspace, times, end and open tickets", ctx do
      {:ok, :accepted} = post(ctx, [{"TRK", "Tracker"}])

      {:ok, 1} =
        Collections.assign_collections(
          ctx.scope,
          ctx.connection,
          ids(ctx, ["TRK"]),
          ctx.workspace
        )

      assert [row] = Collections.list_collections(ctx.scope, ctx.connection)
      collection = Repo.get!(Collection, row.id)

      assert %{
               public_id: public_id,
               name: "Tracker",
               url: "https://tracker.acme.example/TRK",
               workspace: %Workspace{id: workspace_id},
               last_listed_at: @started,
               ended_at: nil,
               ended_reason: nil,
               open_tickets: 0
             } = row

      assert {public_id, workspace_id} == {collection.public_id, ctx.workspace.id}
      assert row.added_at == collection.inserted_at
    end

    test "the search: any case, with %, _ and \\ as they are", ctx do
      {:ok, :accepted} =
        post(ctx, [
          {"A", "Shop 100%"},
          {"B", "shop_api"},
          {"C", "shopXapi"},
          {"D", "Docs"},
          {"E", "back\\slash"}
        ])

      search = &names(Collections.list_collections(ctx.scope, ctx.connection, search: &1))

      assert search.("%") == ["Shop 100%"]
      assert search.("_") == ["shop_api"]
      assert search.("SHOP_") == ["shop_api"]
      assert search.("\\") == ["back\\slash"]
      assert search.("shop") == ["Shop 100%", "shop_api", "shopXapi"]
      assert search.("  docs ") == ["Docs"]
      assert search.("  ") == names(Collections.list_collections(ctx.scope, ctx.connection))

      # Text no title can hold, or longer than a title, matches nothing.
      assert search.("shop" <> <<0>>) == []
      assert search.(<<0xFF>>) == []
      assert search.(String.duplicate("s", 1025)) == []
      assert search.(String.duplicate("s", 100_000)) == []
    end

    test "the views and the workspace filter; an ended ref shows once, as it ended last", ctx do
      {:ok, :accepted} = post(ctx, titled(["A", "B", "C", "D", "E"]))

      {:ok, 1} =
        Collections.assign_collections(ctx.scope, ctx.connection, ids(ctx, ["A"]), ctx.workspace)

      {:ok, 1} =
        Collections.assign_collections(
          ctx.scope,
          ctx.connection,
          ids(ctx, ["B"]),
          ctx.other_workspace
        )

      {:ok, :disconnected} = Collections.disconnect(ctx.key_scope, %{collection_ref: "D"})
      {:ok, :disconnected} = Collections.disconnect(ctx.key_scope, %{collection_ref: "E"})
      {:ok, :accepted} = post(ctx, titled(["E"]), id: "again")

      list = &names(Collections.list_collections(ctx.scope, ctx.connection, &1))
      rows = Collections.list_collections(ctx.scope, ctx.connection, view: :all)

      assert names(rows) == for(ref <- ~w(A B C D E), do: "Title of " <> ref)
      assert [%{ended_reason: :disconnected}] = Enum.filter(rows, & &1.ended_at)
      assert Enum.find(rows, &(&1.name == "Title of E")).ended_at == nil

      assert list.(view: :unassigned) == ["Title of C", "Title of E"]
      assert list.(view: :assigned) == ["Title of A", "Title of B"]
      assert list.(workspace: ctx.workspace) == ["Title of A"]
      assert list.(workspace: ctx.other_workspace.id) == ["Title of B"]
      assert list.(view: :unassigned, workspace: ctx.workspace) == []
      assert list.(workspace: "not an id") == []
      assert list.(view: :assigned, search: "b") == ["Title of B"]

      assert_raise ArgumentError, fn ->
        Collections.list_collections(ctx.scope, ctx.connection, view: :ended)
      end
    end

    test "the counts: all live, unassigned, per workspace; an ended one counts nowhere", ctx do
      {:ok, :accepted} = post(ctx, titled(["A", "B", "C", "D", "E"]))

      {:ok, 2} =
        Collections.assign_collections(
          ctx.scope,
          ctx.connection,
          ids(ctx, ["A", "B"]),
          ctx.workspace
        )

      {:ok, 1} =
        Collections.assign_collections(
          ctx.scope,
          ctx.connection,
          ids(ctx, ["C"]),
          ctx.other_workspace
        )

      {:ok, :disconnected} = Collections.disconnect(ctx.key_scope, %{collection_ref: "B"})

      assert Collections.counts(ctx.scope, ctx.connection) == %{
               total: 4,
               unassigned: 2,
               by_workspace: %{ctx.workspace.id => 1, ctx.other_workspace.id => 1}
             }

      assert Collections.count_unassigned(ctx.scope, ctx.connection) == 2
    end

    test "the listing-complete marker: kept from the first listing that completes", ctx do
      refute Collections.listing_complete?(Repo.get!(Connection, ctx.connection.id))
      {:ok, :accepted} = post(ctx, titled(["A"]))
      refute Collections.listing_complete?(Repo.get!(Connection, ctx.connection.id))
      {:ok, :accepted} = post(ctx, titled(["A"]), id: "whole", complete: true)

      assert %Connection{listing_completed_at: %DateTime{}} =
               done = Repo.get!(Connection, ctx.connection.id)

      assert Collections.listing_complete?(done)
    end

    test "another organisation's people read nothing of it, nor does a person not shown the feature; a member reads it",
         ctx do
      {:ok, :accepted} = post(ctx, titled(["A"]))
      %{scope: other} = sign_up_fixture()
      workspace_fixture(other.organisation)
      {theirs, _nonce} = connection_fixture(other, ctx.adapter, :connected)
      {:ok, :accepted} = Collections.post_listing(ctx.key_scope, part(theirs, titled(["THEIRS"])))

      nothing = %{total: 0, unassigned: 0, by_workspace: %{}}
      assert Collections.list_collections(other, ctx.connection) == []
      assert Collections.counts(other, ctx.connection) == nothing
      assert Collections.count_unassigned(other, ctx.connection) == 0
      assert names(Collections.list_collections(ctx.scope, ctx.connection)) == ["Title of A"]
      assert Collections.list_collections(ctx.scope, theirs) == []

      %{scope: member} = member_fixture(ctx.scope, :member)
      assert names(Collections.list_collections(member, ctx.connection)) == ["Title of A"]

      :ok = Edition.put_test_stub(EditionStubs.HidesNamed)
      :ok = EditionStubs.HidesNamed.put([:factory])
      hidden = Apiary.Access.reload(ctx.scope)
      assert Collections.list_collections(hidden, ctx.connection) == []
      assert Collections.counts(hidden, ctx.connection) == nothing
    end
  end

  describe "assigning" do
    setup ctx do
      {:ok, :accepted} = post(ctx, titled(["A", "B", "C"]))
      :ok
    end

    test "many to a workspace: a linked entry each, one trail entry with the count; again, nothing",
         ctx do
      assert Collections.assign_collections(
               ctx.scope,
               ctx.connection,
               ids(ctx, ["B", "A"]),
               ctx.workspace
             ) == {:ok, 2}

      assert workspace_of(ctx, "A") == ctx.workspace.id
      assert workspace_of(ctx, "B") == ctx.workspace.id
      assert workspace_of(ctx, "C") == nil
      assert collection_entries(ctx.adapter) == [entry("A", "linked"), entry("B", "linked")]

      assert [%Entry{} = recorded] = assign_entries()
      assert {recorded.subject_kind, recorded.subject_id} == {"workspace", ctx.workspace.id}
      assert recorded.organisation_id == ctx.scope.organisation.id
      assert recorded.workspace_id == nil

      assert recorded.details == %{
               "count" => 2,
               "connection_id" => ctx.connection.public_id,
               "workspace_id" => ctx.workspace.id
             }

      # As asked already: nothing changes, no entry of either.
      assert Collections.assign_collections(
               ctx.scope,
               ctx.connection,
               ids(ctx, ["A"]),
               ctx.workspace
             ) ==
               {:ok, 0}

      assert Collections.assign_collections(ctx.scope, ctx.connection, [], ctx.workspace) ==
               {:ok, 0}

      assert length(collection_entries(ctx.adapter)) == 2
      assert length(assign_entries()) == 1
    end

    test "a move to another workspace writes no feed entry; unassigning writes unlinked ones",
         ctx do
      {:ok, 2} =
        Collections.assign_collections(
          ctx.scope,
          ctx.connection,
          ids(ctx, ["A", "B"]),
          ctx.workspace
        )

      assert Collections.assign_collections(
               ctx.scope,
               ctx.connection,
               ids(ctx, ["A"]),
               ctx.other_workspace
             ) == {:ok, 1}

      assert workspace_of(ctx, "A") == ctx.other_workspace.id
      assert collection_entries(ctx.adapter) == [entry("A", "linked"), entry("B", "linked")]

      assert Collections.assign_collections(
               ctx.scope,
               ctx.connection,
               ids(ctx, ["A", "B", "C"]),
               nil
             ) ==
               {:ok, 2}

      assert Enum.map(["A", "B", "C"], &workspace_of(ctx, &1)) == [nil, nil, nil]

      assert collection_entries(ctx.adapter) == [
               entry("A", "linked"),
               entry("B", "linked"),
               entry("A", "unlinked"),
               entry("B", "unlinked")
             ]

      assert [_first, _move, %Entry{} = unassigned] = assign_entries()

      assert {unassigned.subject_kind, unassigned.subject_id} ==
               {"organisation", ctx.scope.organisation.id}

      assert unassigned.details["count"] == 2
      assert unassigned.details["workspace_id"] == nil
    end

    test "the refusals, each changing nothing", ctx do
      a = id(ctx, "A")
      assign = &Collections.assign_collections(&1, &2, &3, &4)

      # A member, who may not.
      %{scope: member} = member_fixture(ctx.scope, :member)
      assert {:error, _forbidden} = assign.(member, ctx.connection, [a], ctx.workspace)

      # Too many ids.
      many = for _ <- 1..10_001, do: Ecto.UUID.generate()
      assert assign.(ctx.scope, ctx.connection, many, ctx.workspace) == {:error, :invalid}

      # Another organisation's workspace, connection and collection.
      %{scope: other} = sign_up_fixture()
      workspace_fixture(other.organisation)
      {theirs, _nonce} = connection_fixture(other, ctx.adapter, :connected)
      {:ok, :accepted} = Collections.post_listing(ctx.key_scope, part(theirs, titled(["THEIRS"])))
      their_id = Repo.get_by!(Collection, connection_id: theirs.id).id

      assert assign.(ctx.scope, ctx.connection, [a], other.workspace) == {:error, :not_found}
      assert assign.(ctx.scope, theirs, [their_id], ctx.workspace) == {:error, :not_found}

      assert assign.(ctx.scope, ctx.connection, [a, their_id], ctx.workspace) ==
               {:error, :not_found}

      # An id that names no live collection of the connection: none, not an id, ended.
      {:ok, :disconnected} = Collections.disconnect(ctx.key_scope, %{collection_ref: "C"})
      ended = Repo.one!(from c in Collection, where: c.external_ref == "C", select: c.id)

      for bad <- [Ecto.UUID.generate(), "not an id", 7, ended] do
        assert assign.(ctx.scope, ctx.connection, [a, bad], ctx.workspace) == {:error, :not_found}
      end

      # A workspace marked for deletion (a purge claims only a marked one).
      marked = workspace_fixture(ctx.scope.organisation, "Marked")
      {:ok, _} = Deletion.delete_workspace(ctx.scope, marked.id, marked.slug)
      assert assign.(ctx.scope, ctx.connection, [a], marked) == {:error, :not_found}

      assert workspace_of(ctx, "A") == nil
      assert collection_entries(ctx.adapter) == []
      assert assign_entries() == []

      # A connection that ended.
      {:ok, _} = Connections.end_connection(ctx.key_scope, ctx.connection.public_id)
      assert assign.(ctx.scope, ctx.connection, [a], ctx.workspace) == {:error, :ended}

      # An organisation marked for deletion, which nothing is asked of.
      %{scope: gone} = sign_up_fixture()
      {connection, _nonce} = connection_fixture(gone, ctx.adapter, :connected)

      {:ok, :accepted} =
        Collections.post_listing(ctx.key_scope, part(connection, titled(["GONE"])))

      gone_id = Repo.get_by!(Collection, connection_id: connection.id).id
      {:ok, _} = Deletion.delete_organisation(gone, gone.organisation.slug)
      assert {:error, _refused} = assign.(gone, connection, [gone_id], nil)
      assert Repo.get!(Collection, gone_id).workspace_id == gone.workspace.id
      assert assign_entries() == []
    end
  end

  describe "auto-assign" do
    test "with one workspace, a new collection is linked to it as it is listed, with its linked entry",
         _ctx do
      %{scope: scope} = sign_up_fixture()
      %{adapter: adapter, access_key: key} = connectable_adapter_fixture()
      {connection, _nonce} = connection_fixture(scope, adapter, :connected)
      ctx = %{key_scope: key_scope(key), connection: connection, scope: scope}

      {:ok, :accepted} = post(ctx, titled(["B", "A"]))
      assert workspace_of(ctx, "A") == scope.workspace.id
      assert workspace_of(ctx, "B") == scope.workspace.id
      assert collection_entries(adapter) == [entry("A", "linked"), entry("B", "linked")]
      assert assign_entries() == []

      # One a person unlinked keeps its link as the next listing names it again; one new
      # is linked.
      {:ok, 1} = Collections.assign_collections(scope, connection, ids(ctx, ["A"]), nil)
      {:ok, :accepted} = post(ctx, titled(["A", "B", "C"]), id: "again")
      assert workspace_of(ctx, "A") == nil
      assert workspace_of(ctx, "C") == scope.workspace.id

      assert collection_entries(adapter) == [
               entry("A", "linked"),
               entry("B", "linked"),
               entry("A", "unlinked"),
               entry("C", "linked")
             ]
    end

    test "with two workspaces, none is linked; a workspace marked for deletion is not counted",
         ctx do
      {:ok, :accepted} = post(ctx, titled(["A"]))
      assert workspace_of(ctx, "A") == nil
      assert collection_entries(ctx.adapter) == []

      {:ok, _} =
        Deletion.delete_workspace(ctx.scope, ctx.other_workspace.id, ctx.other_workspace.slug)

      {:ok, :accepted} = post(ctx, titled(["A", "B"]), id: "again")
      assert workspace_of(ctx, "A") == nil
      assert workspace_of(ctx, "B") == ctx.workspace.id
      assert collection_entries(ctx.adapter) == [entry("B", "linked")]
    end
  end

  describe "the broadcasts" do
    # Every message the caller holds now, in order, each checked to carry ids only.
    defp messages(acc \\ []) do
      receive do
        {kind, _payload} = message when kind in [:collections_changed, :connection_changed] ->
          messages([message | acc])
      after
        0 -> acc |> Enum.reverse() |> Enum.map(&ids_only!/1)
      end
    end

    defp ids_only!({kind, %{} = payload} = message)
         when kind in [:collections_changed, :connection_changed] do
      for {_key, value} <- payload, value <- List.wrap(value) do
        assert is_binary(value) and match?({:ok, ^value}, Ecto.UUID.cast(value))
      end

      message
    end

    test "after each change, the organisation's topic carries ids only", ctx do
      assert Collections.subscribe(ctx.scope, ctx.connection) == :ok
      connection_id = ctx.connection.id
      adapter_id = ctx.adapter.id
      changed = {:connection_changed, %{connection_id: connection_id, adapter_id: adapter_id}}

      # The first part, which marks the connection listed.
      {:ok, :accepted} = post(ctx, titled(["A", "B"]))

      assert [
               {:collections_changed, %{connection_id: ^connection_id, collection_ids: listed}},
               ^changed
             ] = messages()

      assert Enum.sort(listed) == Enum.sort(ids(ctx, ["A", "B"]))

      # A part that completes the listing: what it ended, and the marker.
      {:ok, :accepted} =
        post(ctx, titled(["A"]),
          id: "whole",
          started_at: DateTime.add(@started, 60),
          complete: true
        )

      b = Repo.one!(from c in Collection, where: c.external_ref == "B", select: c.id)

      assert [{:collections_changed, %{collection_ids: completed}}, ^changed] = messages()
      assert Enum.sort(completed) == Enum.sort([id(ctx, "A"), b])

      # An assign: the collections it changed, none for one that changes nothing.
      {:ok, 1} =
        Collections.assign_collections(ctx.scope, ctx.connection, ids(ctx, ["A"]), ctx.workspace)

      a = id(ctx, "A")

      assert [{:collections_changed, %{connection_id: ^connection_id, collection_ids: [^a]}}] =
               messages()

      {:ok, 0} = Collections.assign_collections(ctx.scope, ctx.connection, [a], ctx.workspace)
      assert messages() == []

      # The connection's end.
      {:ok, _} = Connections.end_connection(ctx.key_scope, ctx.connection.public_id)
      assert [^changed] = messages()

      # A press of Install, which makes a new pending connection.
      {:ok, _url, {public_id, _nonce}} = Adapters.connect(ctx.scope, ctx.adapter)
      new_id = Repo.get_by!(Connection, public_id: public_id).id

      assert [{:connection_changed, %{connection_id: ^new_id, adapter_id: ^adapter_id}}] =
               messages()
    end

    test "a part that changes no collection and no marker says nothing", ctx do
      {:ok, :accepted} = post(ctx, titled(["A"]))
      %{scope: other} = sign_up_fixture()
      {theirs, _nonce} = connection_fixture(other, ctx.adapter, :listed)
      :ok = Collections.subscribe(other)

      # The ref is live under this organisation's connection, so their part takes nothing.
      {:ok, :accepted} = Collections.post_listing(ctx.key_scope, part(theirs, titled(["A"])))
      assert messages() == []
    end

    test "subscribing asks to read the organisation's adapters", ctx do
      %{scope: other} = sign_up_fixture()
      %{scope: member} = member_fixture(ctx.scope, :member)

      assert Collections.subscribe(member, ctx.connection) == :ok
      assert Collections.subscribe(other, ctx.connection) == {:error, :not_found}

      :ok = Edition.put_test_stub(EditionStubs.HidesNamed)
      :ok = EditionStubs.HidesNamed.put([:factory])
      assert {:error, _refused} = Collections.subscribe(ctx.scope)
      assert {:error, _refused} = Collections.subscribe(ctx.scope, ctx.connection)
    end
  end
end
