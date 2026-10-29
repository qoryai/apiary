defmodule Apiary.Adapters.CollectionsAssignTest do
  # The collections of a connection, for people: the page of them, its search, views and
  # workspace filter; the counts; assigning them to a workspace, or to none, with the
  # feed's entries and the trail's; the rule of a grant, which a choice in set-up's
  # chooser keeps, and which assigns each collection a listing makes for the grant; and
  # the broadcasts after each change, which carry ids only.
  use Apiary.DataCase, async: true

  import Ecto.Query
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{AccessKeys, Adapters, Deletion, Edition, EditionStubs, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Audit.Entry

  alias Apiary.Adapters.{
    Collection,
    Collections,
    ConnectPass,
    Connection,
    Connections,
    Feed,
    Grant,
    GrantRule,
    Grants
  }

  alias Apiary.Organisations.Workspace
  alias Apiary.Sources.Backlog

  @moduletag needs: :factory

  @started ~U[2026-10-15 11:00:00Z]

  # An organisation with two workspaces, so a collection is linked to none as it is made.
  setup do
    %{scope: scope} = sign_up_fixture()
    other_workspace = workspace_fixture(scope.organisation, "Second")
    connectable = connectable_adapter_fixture(%{name: unique_adapter_name("Acme tracker")})
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
          %{
            ref: ref,
            url: "https://tracker.acme.example/" <> ref,
            title: title,
            grant_ref: listing_grant(connection),
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

  # A disconnect of `ref` under this test's connection, as the wire reads one.
  defp disconnect(ctx, ref),
    do:
      Collections.disconnect(ctx.key_scope, %{
        connection_id: ctx.connection.public_id,
        collection_ref: ref
      })

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

  defp refs(from, to), do: for(n <- from..to, do: "R" <> String.pad_leading("#{n}", 3, "0"))

  # How many rows the pages of `opts` have, every page read from the first, a page after
  # the last row of the one before.
  defp walked(scope, connection, opts, after_id \\ nil, count \\ 0) do
    rows = Collections.list_collections(scope, connection, [after: after_id] ++ opts)
    count = count + length(rows)

    if length(rows) < Collections.page_size(),
      do: count,
      else: walked(scope, connection, opts, List.last(rows).public_id, count)
  end

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

    test "the page after a row that ended since its page was read starts past that row", ctx do
      refs = refs(1, 60)
      {:ok, :accepted} = post(ctx, titled(refs))

      first = Collections.list_collections(ctx.scope, ctx.connection)
      assert List.last(names(first)) == "Title of R050"
      {:ok, :disconnected} = disconnect(ctx, "R050")

      after_ended =
        Collections.list_collections(ctx.scope, ctx.connection, after: List.last(first).public_id)

      assert names(after_ended) == for(ref <- Enum.drop(refs, 50), do: "Title of " <> ref)
    end

    test "a cursor naming another connection's collection gives nothing", ctx do
      {:ok, :accepted} = post(ctx, titled(["A", "B"]))

      # Another organisation's connection to the adapter, with a collection whose title
      # sorts first.
      %{scope: other} = sign_up_fixture()
      workspace_fixture(other.organisation)
      {theirs, _nonce} = connection_fixture(other, ctx.adapter, :connected)

      {:ok, :accepted} =
        Collections.post_listing(ctx.key_scope, part(theirs, [{"THEIRS", "Aaa"}]))

      their_cursor = Repo.get_by!(Collection, connection_id: theirs.id).public_id
      assert Collections.list_collections(ctx.scope, ctx.connection, after: their_cursor) == []

      # The organisation's earlier connection, ended, whose collection ended with it.
      {:ok, _} = Connections.end_connection(ctx.key_scope, ctx.connection.public_id)
      {later, _nonce} = connection_fixture(ctx.scope, ctx.adapter, :connected)
      {:ok, :accepted} = Collections.post_listing(ctx.key_scope, part(later, titled(["C"])))
      earlier = Repo.get_by!(Collection, connection_id: ctx.connection.id, external_ref: "A")

      assert Collections.list_collections(ctx.scope, later, after: earlier.public_id) == []
      assert names(Collections.list_collections(ctx.scope, later)) == ["Title of C"]
    end

    test "a row: its ids, title, address, workspace, times and open tickets", ctx do
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
               open_tickets: 0
             } = row

      refute Map.has_key?(row, :ended_at)

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

    test "the views, the search and the workspace filter: live collections only", ctx do
      {:ok, :accepted} = post(ctx, titled(["A", "B", "C", "D", "E", "F"]))

      {:ok, 2} =
        Collections.assign_collections(
          ctx.scope,
          ctx.connection,
          ids(ctx, ["A", "D"]),
          ctx.workspace
        )

      {:ok, 1} =
        Collections.assign_collections(
          ctx.scope,
          ctx.connection,
          ids(ctx, ["B"]),
          ctx.other_workspace
        )

      # D, assigned, and F, unassigned, ended; E ended and is live again.
      {:ok, :disconnected} = disconnect(ctx, "D")
      {:ok, :disconnected} = disconnect(ctx, "E")
      {:ok, :disconnected} = disconnect(ctx, "F")
      {:ok, :accepted} = post(ctx, titled(["E"]), id: "again")

      list = &names(Collections.list_collections(ctx.scope, ctx.connection, &1))
      live_e = id(ctx, "E")

      assert list.([]) == for(ref <- ~w(A B C E), do: "Title of " <> ref)
      assert list.(view: :all) == list.([])

      assert [%{id: ^live_e}] =
               Collections.list_collections(ctx.scope, ctx.connection, search: "of e")

      assert list.(view: :unassigned) == ["Title of C", "Title of E"]
      assert list.(view: :assigned) == ["Title of A", "Title of B"]
      assert list.(workspace: ctx.workspace) == ["Title of A"]
      assert list.(workspace: ctx.other_workspace.id) == ["Title of B"]
      assert list.(view: :unassigned, workspace: ctx.workspace) == []
      assert list.(workspace: "not an id") == []
      assert list.(view: :assigned, search: "b") == ["Title of B"]

      for view <- [:all, :unassigned, :assigned] do
        assert list.(view: view, search: "of d") == [], inspect(view)
        assert list.(view: view, search: "of f") == [], inspect(view)
      end

      assert list.(view: :assigned, workspace: ctx.workspace, search: "of") == ["Title of A"]

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

      {:ok, :disconnected} = disconnect(ctx, "B")

      assert Collections.counts(ctx.scope, ctx.connection) == %{
               total: 4,
               unassigned: 2,
               by_workspace: %{ctx.workspace.id => 1, ctx.other_workspace.id => 1},
               ended: 1
             }

      assert Collections.count_unassigned(ctx.scope, ctx.connection) == 2
    end

    test "the ended count: each ref whose collections all ended, once; one live again counts not",
         ctx do
      {:ok, :accepted} = post(ctx, titled(["A", "B", "C", "D"]))

      # A ended; B ended and is live again; C ended twice; D is live.
      {:ok, :disconnected} = disconnect(ctx, "A")
      {:ok, :disconnected} = disconnect(ctx, "B")
      {:ok, :disconnected} = disconnect(ctx, "C")
      {:ok, :accepted} = post(ctx, titled(["B", "C"]), id: "again")
      {:ok, :disconnected} = disconnect(ctx, "C")

      assert %{total: 2, unassigned: 2, ended: 2} = Collections.counts(ctx.scope, ctx.connection)

      assert names(Collections.list_collections(ctx.scope, ctx.connection)) == [
               "Title of B",
               "Title of D"
             ]

      # Nothing to another organisation's people, nor of another organisation's connection.
      %{scope: other} = sign_up_fixture()
      workspace_fixture(other.organisation)
      {theirs, _nonce} = connection_fixture(other, ctx.adapter, :connected)
      {:ok, :accepted} = Collections.post_listing(ctx.key_scope, part(theirs, titled(["X"])))
      {:ok, :disconnected} = disconnect(%{ctx | connection: theirs}, "X")

      assert %{ended: 1} = Collections.counts(other, theirs)
      assert %{ended: 0, total: 0} = Collections.counts(other, ctx.connection)
      assert %{ended: 0, total: 0} = Collections.counts(ctx.scope, theirs)
    end

    test "the count of a search: the live rows of every page, for each view, search and workspace",
         ctx do
      {:ok, :accepted} = post(ctx, titled(Enum.shuffle(refs(1, 120))))

      # 60 in the workspace and 10 in the other; R111 to R120 ended, then R120 live again.
      {:ok, 60} =
        Collections.assign_collections(
          ctx.scope,
          ctx.connection,
          ids(ctx, refs(1, 60)),
          ctx.workspace
        )

      {:ok, 10} =
        Collections.assign_collections(
          ctx.scope,
          ctx.connection,
          ids(ctx, refs(61, 70)),
          ctx.other_workspace
        )

      for ref <- refs(111, 120),
          do: {:ok, :disconnected} = disconnect(ctx, ref)

      {:ok, :accepted} = post(ctx, titled(["R120"]), id: "again")

      for {opts, count} <- [
            {[], 111},
            {[view: :all], 111},
            {[view: :unassigned], 41},
            {[view: :assigned], 70},
            {[search: "r0"], 99},
            {[search: "  R11 "], 1},
            {[workspace: ctx.workspace], 60},
            {[workspace: ctx.other_workspace.id], 10},
            {[view: :assigned, search: "R06"], 10},
            {[view: :assigned, workspace: ctx.workspace, search: "R05"], 10},
            {[view: :unassigned, workspace: ctx.workspace], 0},
            {[workspace: "not an id"], 0},
            {[search: <<0xFF>>], 0}
          ] do
        assert Collections.count_collections(ctx.scope, ctx.connection, opts) == count,
               inspect(opts)

        assert walked(ctx.scope, ctx.connection, opts) == count, inspect(opts)
      end

      assert Collections.count_collections(ctx.scope, ctx.connection) == 111

      assert_raise ArgumentError, fn ->
        Collections.count_collections(ctx.scope, ctx.connection, view: :ended)
      end

      # 0 to another organisation's people, of another organisation's connection, and to a
      # person not shown the feature.
      %{scope: other} = sign_up_fixture()
      workspace_fixture(other.organisation)
      {theirs, _nonce} = connection_fixture(other, ctx.adapter, :connected)
      {:ok, :accepted} = Collections.post_listing(ctx.key_scope, part(theirs, titled(["X"])))

      assert Collections.count_collections(other, theirs) == 1
      assert Collections.count_collections(other, ctx.connection) == 0
      assert Collections.count_collections(ctx.scope, theirs) == 0

      :ok = Edition.put_test_stub(EditionStubs.HidesNamed)
      :ok = EditionStubs.HidesNamed.put([:factory])
      hidden = Apiary.Access.reload(ctx.scope)
      assert Collections.count_collections(hidden, ctx.connection) == 0
    end

    test "the order with those linked to no workspace first, paged across the two groups; the default unchanged",
         ctx do
      all = refs(1, 80)
      {:ok, :accepted} = post(ctx, titled(Enum.shuffle(all)))
      {odd, even} = all |> Enum.with_index() |> Enum.split_with(&(rem(elem(&1, 1), 2) == 0))
      unassigned = Enum.map(odd, &elem(&1, 0))
      assigned = Enum.map(even, &elem(&1, 0))

      {:ok, 40} =
        Collections.assign_collections(
          ctx.scope,
          ctx.connection,
          ids(ctx, assigned),
          ctx.workspace
        )

      title = &("Title of " <> &1)
      list = &Collections.list_collections(ctx.scope, ctx.connection, &1)
      public_id = &Repo.get!(Collection, id(ctx, &1)).public_id
      expected = Enum.map(unassigned ++ assigned, title)

      first = list.(order: :unassigned_first)
      assert names(first) == Enum.take(expected, 50)

      second = list.(order: :unassigned_first, after: List.last(first).public_id)
      assert names(second) == Enum.drop(expected, 50)

      # From the last of those linked to none to the first linked to one, whose title sorts
      # before it; and on from the middle of either group.
      assert List.last(unassigned) == "R079"

      assert names(list.(order: :unassigned_first, after: public_id.("R079"))) ==
               Enum.map(assigned, title)

      assert names(list.(order: :unassigned_first, after: public_id.("R039"))) ==
               expected |> Enum.drop(20) |> Enum.take(50)

      assert names(list.(order: :unassigned_first, after: public_id.("R080"))) == []

      assert names(list.(order: :unassigned_first, view: :assigned, after: public_id.("R040"))) ==
               Enum.map(Enum.drop(assigned, 20), title)

      # The default: by title, then id, as without the option.
      assert list.(order: :title) == list.([])
      assert names(list.([])) == Enum.map(Enum.take(all, 50), title)

      assert names(list.(after: public_id.("R079"))) == [title.("R080")]

      assert names(list.(order: :title, after: public_id.("R050"))) ==
               Enum.map(Enum.drop(all, 50), title)

      for order <- [:newest, nil, "unassigned_first"] do
        assert_raise ArgumentError, fn -> list.(order: order) end
      end
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

      nothing = %{total: 0, unassigned: 0, by_workspace: %{}, ended: 0}
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
      {:ok, :disconnected} = disconnect(ctx, "C")
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
      grant_rule_fixture(connection, gone.workspace)

      {:ok, :accepted} =
        Collections.post_listing(ctx.key_scope, part(connection, titled(["GONE"])))

      gone_id = Repo.get_by!(Collection, connection_id: connection.id).id
      {:ok, _} = Deletion.delete_organisation(gone, gone.organisation.slug)
      assert {:error, _refused} = assign.(gone, connection, [gone_id], nil)
      assert Repo.get!(Collection, gone_id).workspace_id == gone.workspace.id
      assert assign_entries() == []
    end
  end

  describe "the rule of a grant" do
    # The live grant of `connection`, made if missing (`listing_grant/2`).
    defp grant_of(connection) do
      ref = listing_grant(connection)
      Repo.get_by!(Grant, connection_id: connection.id, grant_ref: ref, state: :live)
    end

    defp choose(ctx, list, choice, workspace \\ nil, scope \\ nil),
      do:
        Collections.choose(
          scope || ctx.scope,
          grant_of(ctx.connection),
          workspace || ctx.workspace,
          list,
          choice
        )

    defp rule_of(connection), do: Repo.get_by(GrantRule, grant_id: grant_of(connection).id)

    defp backlog_of(ctx, ref), do: Repo.get!(Collection, id(ctx, ref)).backlog

    defp with_targets(ctx) do
      {1, _} =
        Repo.update_all(from(n in Apiary.Nodes.Node, where: n.id == ^ctx.adapter.id),
          set: [targets: true]
        )

      :ok
    end

    test "All in Work sources assigns each collection of the grant in no workspace, Backlog on, and each one a listing makes later",
         ctx do
      {:ok, :accepted} = post(ctx, titled(["A", "B"]))
      assert choose(ctx, :sources, :all) == {:ok, 2}

      assert %GrantRule{workspace_id: workspace_id, backlog: true} = rule_of(ctx.connection)
      assert workspace_id == ctx.workspace.id
      assert Enum.map(["A", "B"], &workspace_of(ctx, &1)) == [ctx.workspace.id, ctx.workspace.id]
      assert collection_entries(ctx.adapter) == [entry("A", "linked"), entry("B", "linked")]
      assert [%Entry{details: %{"count" => 2}}] = assign_entries()

      # A collection a person unassigns stays so as the next listing names it again; a new
      # one is assigned by the rule, with its linked entry and no trail entry.
      {:ok, 1} = Collections.assign_collections(ctx.scope, ctx.connection, ids(ctx, ["A"]), nil)
      {:ok, :accepted} = post(ctx, titled(["A", "B", "C"]), id: "again")
      assert workspace_of(ctx, "A") == nil
      assert workspace_of(ctx, "C") == ctx.workspace.id
      assert backlog_of(ctx, "C")

      assert collection_entries(ctx.adapter) == [
               entry("A", "linked"),
               entry("B", "linked"),
               entry("A", "unlinked"),
               entry("C", "linked")
             ]

      assert length(assign_entries()) == 2

      # Chosen again, nothing changes but A.
      assert choose(ctx, :sources, :all) == {:ok, 1}
      assert choose(ctx, :sources, :all) == {:ok, 0}
    end

    test "All in Destinations assigns with the Backlog off; All in Work sources then turns it on, and stays",
         ctx do
      :ok = with_targets(ctx)
      {:ok, :accepted} = post(ctx, titled(["A"]))
      assert choose(ctx, :destinations, :all) == {:ok, 1}
      assert %GrantRule{backlog: false} = rule_of(ctx.connection)
      assert {workspace_of(ctx, "A"), backlog_of(ctx, "A")} == {ctx.workspace.id, false}

      {:ok, :accepted} = post(ctx, titled(["A", "B"]), id: "again")
      assert {workspace_of(ctx, "B"), backlog_of(ctx, "B")} == {ctx.workspace.id, false}
      assert collection_entries(ctx.adapter) == []

      assert choose(ctx, :sources, :all) == {:ok, 2}
      assert %GrantRule{backlog: true} = rule_of(ctx.connection)
      assert Enum.map(["A", "B"], &backlog_of(ctx, &1)) == [true, true]

      # Destinations' All leaves the rule chosen in Work sources, and its Only selected is
      # refused while that rule stands.
      assert choose(ctx, :destinations, :all) == {:ok, 0}
      assert %GrantRule{backlog: true} = rule_of(ctx.connection)
      assert choose(ctx, :destinations, {:only, []}) == {:error, :locked}
      assert %GrantRule{backlog: true} = rule_of(ctx.connection)
    end

    test "one rule per grant: All for another workspace is refused; a collection another workspace has stays there",
         ctx do
      {:ok, :accepted} = post(ctx, titled(["A", "B"]))

      {:ok, 1} =
        Collections.assign_collections(
          ctx.scope,
          ctx.connection,
          ids(ctx, ["B"]),
          ctx.other_workspace
        )

      assert choose(ctx, :sources, :all) == {:ok, 1}
      assert workspace_of(ctx, "B") == ctx.other_workspace.id

      assert choose(ctx, :sources, :all, ctx.other_workspace) == {:error, :taken}
      assert choose(ctx, :destinations, :all, ctx.other_workspace) == {:error, :not_found}
      assert rule_of(ctx.connection).workspace_id == ctx.workspace.id
    end

    test "Only selected ends the rule, keeps what is still selected, and changes nothing for a forged id",
         ctx do
      {:ok, :accepted} = post(ctx, titled(["A", "B", "C"]))

      {:ok, 1} =
        Collections.assign_collections(
          ctx.scope,
          ctx.connection,
          ids(ctx, ["C"]),
          ctx.other_workspace
        )

      assert choose(ctx, :sources, :all) == {:ok, 2}

      # Another organisation's collection, an id of nothing, and a collection another
      # workspace has: none changes.
      %{scope: other} = sign_up_fixture()
      {theirs, _nonce} = connection_fixture(other, ctx.adapter, :connected)
      {:ok, :accepted} = Collections.post_listing(ctx.key_scope, part(theirs, titled(["THEIRS"])))
      their_id = Repo.get_by!(Collection, connection_id: theirs.id).id
      [a, c] = ids(ctx, ["A", "C"])

      assert choose(ctx, :sources, {:only, [a, c, their_id, Ecto.UUID.generate(), "not an id"]}) ==
               {:ok, 1}

      assert rule_of(ctx.connection) == nil
      assert workspace_of(ctx, "A") == ctx.workspace.id
      assert {workspace_of(ctx, "B"), backlog_of(ctx, "B")} == {nil, false}
      assert workspace_of(ctx, "C") == ctx.other_workspace.id
      assert Repo.get!(Collection, their_id).workspace_id == nil

      # A listing then assigns no new collection.
      {:ok, :accepted} = post(ctx, titled(["A", "B", "C", "D"]), id: "again")
      assert workspace_of(ctx, "D") == nil
    end

    test "the refusals, each changing nothing", ctx do
      {:ok, :accepted} = post(ctx, titled(["A"]))

      # A member, who may not; a choice of another shape; too many ids.
      %{scope: member} = member_fixture(ctx.scope, :member)
      assert {:error, _forbidden} = choose(ctx, :sources, :all, nil, member)
      assert choose(ctx, :sources, :some) == {:error, :invalid}
      assert choose(ctx, :sources, {:only, "A"}) == {:error, :invalid}
      many = for _ <- 1..10_001, do: Ecto.UUID.generate()
      assert choose(ctx, :sources, {:only, many}) == {:error, :invalid}

      # Another organisation's grant and workspace; a workspace marked for deletion; a
      # list whose role the adapter does not have.
      %{scope: other} = sign_up_fixture()
      {theirs, _nonce} = connection_fixture(other, ctx.adapter, :connected)

      assert Collections.choose(ctx.scope, grant_of(theirs), ctx.workspace, :sources, :all) ==
               {:error, :not_found}

      assert choose(ctx, :sources, :all, other.workspace) == {:error, :not_found}
      marked = workspace_fixture(ctx.scope.organisation, "Marked")
      {:ok, _} = Deletion.delete_workspace(ctx.scope, marked.id, marked.slug)
      assert choose(ctx, :sources, :all, marked) == {:error, :not_found}
      assert choose(ctx, :destinations, :all) == {:error, :not_found}

      assert Repo.aggregate(GrantRule, :count) == 0
      assert workspace_of(ctx, "A") == nil
      assert assign_entries() == []

      # A grant that ended; a connection that ended.
      grant = grant_of(ctx.connection)

      {:ok, _} =
        Grants.end_grant(ctx.key_scope, %{
          connection_id: ctx.connection.public_id,
          grant_ref: grant.grant_ref
        })

      assert Collections.choose(ctx.scope, grant, ctx.workspace, :sources, :all) ==
               {:error, :not_found}

      {:ok, _} = Connections.end_connection(ctx.key_scope, ctx.connection.public_id)

      assert Collections.choose(ctx.scope, grant, ctx.workspace, :sources, :all) ==
               {:error, :ended}

      assert Repo.aggregate(GrantRule, :count) == 0
    end

    test "a workspace marked for deletion gets no new collection; its purge deletes the rule",
         ctx do
      {:ok, :accepted} = post(ctx, titled(["A"]))
      assert choose(ctx, :sources, :all) == {:ok, 1}
      workspace = ctx.workspace
      {:ok, _} = Deletion.delete_workspace(ctx.scope, workspace.id, workspace.slug)

      {:ok, :accepted} = post(ctx, titled(["A", "B"]), id: "again")
      assert workspace_of(ctx, "B") == nil

      Repo.update_all(from(w in Workspace, where: w.id == ^workspace.id),
        set: [purge_after: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

      instance = Scope.for_instance(ctx.scope.organisation, Repo.get!(Workspace, workspace.id))
      assert {:ok, :purged} = Deletion.purge_workspace(instance)
      assert Repo.aggregate(GrantRule, :count) == 0
    end

    test "a grant's end and a connection's end delete its rule", ctx do
      {:ok, :accepted} = post(ctx, titled(["A"]))
      assert choose(ctx, :sources, :all) == {:ok, 1}
      grant = grant_of(ctx.connection)

      {:ok, _} =
        Grants.end_grant(ctx.key_scope, %{
          connection_id: ctx.connection.public_id,
          grant_ref: grant.grant_ref
        })

      assert Repo.get_by(GrantRule, grant_id: grant.id) == nil

      # A new grant of the connection, chosen, then the connection's end.
      assert choose(ctx, :sources, :all) == {:ok, 0}
      assert %GrantRule{} = rule_of(ctx.connection)
      {:ok, _} = Connections.end_connection(ctx.key_scope, ctx.connection.public_id)
      assert Repo.aggregate(GrantRule, :count) == 0
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

    test "a press of Install tells of the connection it gives a pass, and of one it replaced first",
         ctx do
      :ok = Collections.subscribe(ctx.scope)
      old_id = ctx.connection.id
      adapter_id = ctx.adapter.id
      past = DateTime.add(DateTime.utc_now(), -3600, :second)

      # Connected, its pass long expired: a press gives it a new pass and tells of it.
      {1, _} =
        Repo.update_all(from(c in Connection, where: c.id == ^old_id),
          set: [pass_expires_at: past]
        )

      {:ok, _url, {public_id, _nonce}} = Adapters.connect(ctx.scope, ctx.adapter)
      assert public_id == ctx.connection.public_id

      assert [{:connection_changed, %{connection_id: ^old_id, adapter_id: ^adapter_id}}] =
               messages()

      # Ended, then a press makes a pending one. A press when the next pass would expire too
      # far ahead replaces it: it tells of both, the one it ended first.
      {:ok, _} = Connections.end_connection(ctx.key_scope, ctx.connection.public_id)
      _ = messages()
      {:ok, _url, {pending_public_id, _nonce}} = Adapters.connect(ctx.scope, ctx.adapter)
      pending_id = Repo.get_by!(Connection, public_id: pending_public_id).id
      assert [{:connection_changed, %{connection_id: ^pending_id}}] = messages()
      ahead = DateTime.add(DateTime.utc_now(), 2 * ConnectPass.validity(), :second)

      {1, _} =
        Repo.update_all(from(c in Connection, where: c.id == ^pending_id),
          set: [pass_expires_at: ahead]
        )

      {:ok, _url, {new_public_id, _nonce}} = Adapters.connect(ctx.scope, ctx.adapter)
      new_id = Repo.get_by!(Connection, public_id: new_public_id).id
      assert Repo.get!(Connection, pending_id).ended_reason == :replaced

      assert [
               {:connection_changed, %{connection_id: ^pending_id, adapter_id: ^adapter_id}},
               {:connection_changed, %{connection_id: ^new_id, adapter_id: ^adapter_id}}
             ] = messages()
    end

    test "a part that changes no collection and no marker says nothing", ctx do
      {:ok, :accepted} = post(ctx, titled(["A"]))
      %{scope: other} = sign_up_fixture()
      {theirs, _nonce} = connection_fixture(other, ctx.adapter, :listed)
      :ok = Collections.subscribe(other)

      # The ref is live under this organisation's connection, and a listing newer than
      # their part named it there, so their part takes nothing.
      {:ok, :accepted} =
        Collections.post_listing(
          ctx.key_scope,
          part(theirs, titled(["A"]), started_at: DateTime.add(@started, -60))
        )

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

  describe "the domains the adapter serves" do
    # The adapter starts with its description listing `domains`, nil for none
    # (`Apiary.Adapters.declare/2`).
    defp start(ctx, domains) do
      document = Apiary.DescriptionFixtures.contract_description()

      document =
        if domains,
          do: Map.put(document, "domains", domains),
          else: Map.delete(document, "domains")

      {:ok, adapter} =
        Adapters.declare(ctx.key_scope, %{
          time: DateTime.utc_now(:second),
          connect_url: "https://tracker-adapter.acme.example/connect",
          default_interval: 900,
          minimum_interval: 300,
          sends_changes: false,
          description: Apiary.DescriptionFixtures.read_description(document)
        })

      adapter
    end

    test "a restart that leaves out the workspace's domain unassigns nothing, and its tickets still list; a new assignment there is refused",
         ctx do
      {:ok, :accepted} = post(ctx, titled(["SHOP", "API"]))
      assert %{domains: nil} = start(ctx, nil)

      assert {:ok, 1} =
               Collections.assign_collections(
                 ctx.scope,
                 ctx.connection,
                 ids(ctx, ["SHOP"]),
                 ctx.workspace
               )

      shop = Repo.get!(Collection, id(ctx, "SHOP"))

      ticket =
        Apiary.WorkItemsFixtures.source_item_fixture(%Scope{},
          collection: shop,
          external_ref: "SHOP-1"
        )

      assert [ticket.public_id] == Enum.map(Backlog.list_tickets(ctx.scope, %{}).rows, & &1.id)

      assert %{domains: ["example"]} = start(ctx, ["example"])
      assert workspace_of(ctx, "SHOP") == ctx.workspace.id

      # A listing after the restart leaves it assigned too.
      {:ok, :accepted} = post(ctx, titled(["SHOP", "API"]), id: "listing-2")
      assert workspace_of(ctx, "SHOP") == ctx.workspace.id
      assert [ticket.public_id] == Enum.map(Backlog.list_tickets(ctx.scope, %{}).rows, & &1.id)

      assert Collections.assign_collections(
               ctx.scope,
               ctx.connection,
               ids(ctx, ["API"]),
               ctx.workspace
             ) ==
               {:error, :other_domain}

      assert workspace_of(ctx, "API") == nil

      # Unassigning stays a person's step, whatever the domains.
      assert {:ok, 1} =
               Collections.assign_collections(ctx.scope, ctx.connection, ids(ctx, ["SHOP"]), nil)
    end

    test "an adapter that lists no domains serves every workspace; one that lists some, those",
         ctx do
      {:ok, :accepted} = post(ctx, titled(["SHOP", "API"]))
      example = %{ctx.other_workspace | domain: "example"}

      Repo.update_all(from(w in Workspace, where: w.id == ^example.id), set: [domain: "example"])

      start(ctx, ["software"])

      assert Collections.assign_collections(ctx.scope, ctx.connection, ids(ctx, ["API"]), example) ==
               {:error, :other_domain}

      assert {:ok, 1} =
               Collections.assign_collections(
                 ctx.scope,
                 ctx.connection,
                 ids(ctx, ["SHOP"]),
                 ctx.workspace
               )

      start(ctx, nil)

      assert {:ok, 1} =
               Collections.assign_collections(
                 ctx.scope,
                 ctx.connection,
                 ids(ctx, ["API"]),
                 example
               )

      start(ctx, ["example", "software"])

      assert {:ok, 1} =
               Collections.assign_collections(
                 ctx.scope,
                 ctx.connection,
                 ids(ctx, ["API"]),
                 ctx.workspace
               )
    end
  end
end
