defmodule Apiary.Sources.BacklogTest do
  # The Backlog of a workspace, read for people: its views and their counts, the search
  # with `%` and `_`, the filters, the pages, the values the filters offer, one ticket and
  # its comments, the facts of an empty Backlog, the open tickets of a collection, and
  # what is never read: another workspace's or organisation's tickets, the tickets of an
  # ended connection or collection, a disconnected ticket, and anything at all for a
  # person who may not read the workspace's work items. A row's work item is found by the
  # ticket's organisation, adapter and ref.
  use Apiary.DataCase, async: true

  import Ecto.Query
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Edition, EditionStubs, Repo}
  alias Apiary.Adapters.{Collection, Collections, Connection}
  alias Apiary.Sources.{Backlog, Comment, Item, Topic}
  alias Apiary.WorkItems.WorkItem
  alias ApiaryWeb.People

  @moduletag needs: :factory

  @at ~U[2026-10-01 12:00:00Z]

  setup do
    %{scope: scope} = sign_up_fixture()
    connection = ticket_connection_fixture(scope)
    collection = source_collection_fixture(scope, connection, %{title: "acme/shop"})
    %{scope: scope, connection: connection, collection: collection}
  end

  # A ticket of `collection`, with a ref no other has, changed at the source `minutes`
  # after `@at` (`:minutes`), and any other field `attrs` names.
  defp ticket(collection, attrs \\ %{}) do
    unique = System.unique_integer([:positive])
    attrs = Map.new(attrs)
    {minutes, attrs} = Map.pop(attrs, :minutes, 0)
    at = DateTime.add(@at, minutes, :minute)
    scope = %Apiary.Accounts.Scope{}

    source_item_fixture(
      scope,
      Enum.into(attrs, %{
        collection: collection,
        external_ref: "ref-#{unique}",
        key: "##{unique}",
        source_created_at: at,
        source_updated_at: at
      })
    )
  end

  # The work item of `item`, in the scope's workspace, in `state`.
  defp work_item(scope, %Item{} = item, state \\ :exploring) do
    connection =
      Repo.one!(
        from c in Collection,
          where: c.id == ^item.collection_id,
          select: c.connection_id
      )

    work_item =
      work_item_fixture(scope, %{
        connection_id: connection,
        item_id: item.id,
        external_ref: item.external_ref
      })

    set_state(work_item, state, scope.user)
  end

  defp set_state(work_item, :exploring, _user), do: work_item

  defp set_state(work_item, :declined, user) do
    work_item
    |> Ecto.Changeset.change(
      state: :declined,
      declined_at: DateTime.utc_now(),
      declined_by_id: user.id
    )
    |> Repo.update!()
  end

  defp set_state(work_item, :closed, _user) do
    work_item
    |> Ecto.Changeset.change(state: :closed, closed_at: DateTime.utc_now())
    |> Repo.update!()
  end

  defp set_state(work_item, :undone, _user) do
    work_item |> Ecto.Changeset.change(state: :undone) |> Repo.update!()
  end

  defp ids(page), do: Enum.map(page.rows, & &1.id)
  defp list(scope, params \\ %{}), do: Backlog.list_tickets(scope, params)

  # Every page of the list, from the first by Older, as `list/2` gives them.
  defp older_pages(scope, params) do
    Stream.unfold(list(scope, params), fn
      nil -> nil
      %{next: nil} = page -> {page, nil}
      page -> {page, list(scope, Keyword.put(params, :after, page.next))}
    end)
    |> Enum.to_list()
  end

  # The tickets in the order of `sort` (`{sort, order}`), with ties.
  defp sorted(tickets, {:comments, :desc}),
    do:
      Enum.sort_by(
        tickets,
        &{&1.comment_count, DateTime.to_unix(&1.source_updated_at), &1.public_id},
        :desc
      )

  defp sorted(tickets, {sort, order}) do
    field = if sort == :updated, do: :source_updated_at, else: :source_created_at
    Enum.sort_by(tickets, &{DateTime.to_unix(Map.fetch!(&1, field)), &1.public_id}, order)
  end

  defp end_connection(connection) do
    connection
    |> Ecto.Changeset.change(
      state: :ended,
      ended_at: DateTime.utc_now(),
      ended_reason: :adapter_reported
    )
    |> Repo.update!()
  end

  defp end_collection(collection) do
    collection
    |> Ecto.Changeset.change(ended_at: DateTime.utc_now(), ended_reason: :disconnected)
    |> Repo.update!()
  end

  defp comment(%Item{} = item, attrs) do
    unique = System.unique_integer([:positive])
    {deleted_at, attrs} = Map.pop(Map.new(attrs), :deleted_at)

    %Comment{organisation_id: item.organisation_id, item_id: item.id, deleted_at: deleted_at}
    |> Comment.changeset(
      Enum.into(attrs, %{
        external_ref: "comment-#{unique}",
        url: "https://forge.example.com/c/#{unique}",
        author_name: "Robin Example",
        author_kind: :person,
        body: "A comment",
        body_format: "markdown",
        source_created_at: @at,
        source_updated_at: @at
      })
    )
    |> Repo.insert!()
  end

  describe "views and counts" do
    setup %{scope: scope, collection: collection} do
      open = ticket(collection, minutes: 5)
      taken = ticket(collection, minutes: 4)
      declined = ticket(collection, minutes: 3)
      ended = ticket(collection, minutes: 2)
      closed = ticket(collection, minutes: 1, state: :closed, state_reason: "Not planned")
      closed_taken = ticket(collection, minutes: 0, state: :closed)

      work_item(scope, taken)
      work_item(scope, declined, :declined)
      work_item(scope, ended, :closed)
      work_item(scope, closed_taken)

      %{
        open: open,
        taken: taken,
        declined: declined,
        ended: ended,
        closed: closed,
        closed_taken: closed_taken
      }
    end

    test "each view holds its tickets, newest change first; the counts come with every page",
         ctx do
      counts = %{open: 4, taken: 1, declined: 1, closed: 2, total: 6}
      page = list(ctx.scope)

      assert ids(page) == Enum.map([ctx.open, ctx.taken, ctx.declined, ctx.ended], & &1.public_id)
      assert page.counts == counts
      assert page.next == nil

      assert ids(list(ctx.scope, view: :taken)) == [ctx.taken.public_id]
      assert ids(list(ctx.scope, %{"view" => "declined"})) == [ctx.declined.public_id]

      assert ids(list(ctx.scope, view: :closed)) ==
               [ctx.closed.public_id, ctx.closed_taken.public_id]

      assert length(list(ctx.scope, view: :all).rows) == 6
      assert list(ctx.scope, view: :taken).counts == counts
      # A view it does not know is the default.
      assert ids(list(ctx.scope, view: "elsewhere")) == ids(page)
    end

    test "a row carries the ticket and its work item as the components draw them", ctx do
      %{scope: scope} = ctx
      declined_item = Repo.get_by!(WorkItem, item_id: ctx.declined.id)
      taken_item = Repo.get_by!(WorkItem, item_id: ctx.taken.id)
      rows = Map.new(list(scope, view: :all).rows, &{&1.id, &1})
      path = "/#{scope.organisation.slug}/#{scope.workspace.slug}/work/"

      assert %{
               id: id,
               key: key,
               title: "The checkout keeps the old price",
               url: "https://forge.example.com/acme/shop/issues/12",
               repository: "acme/shop",
               repository_id: repository_id,
               filer: %{name: "Avery Example", kind: :person},
               labels: ["bug"],
               comment_count: 0,
               state: :open,
               state_reason: nil,
               work_item: %{state: :declined, number: number, path: declined_path}
             } = row = rows[ctx.declined.public_id]

      assert {id, key, repository_id} ==
               {ctx.declined.public_id, ctx.declined.key, ctx.collection.id}

      assert row.filed_at == ctx.declined.source_created_at
      assert row.updated_at == ctx.declined.source_updated_at
      assert number == declined_item.number
      assert declined_path == path <> Integer.to_string(number)
      assert row.work_item.declined_by == scope.user.email
      refute Map.has_key?(row, :body)

      assert rows[ctx.taken.public_id].work_item == %{
               number: taken_item.number,
               state: :exploring,
               path: path <> Integer.to_string(taken_item.number),
               declined_by: nil
             }

      assert rows[ctx.open.public_id].work_item == nil
      assert rows[ctx.closed.public_id].state_reason == "Not planned"
      # Who declined it, only on a declined one.
      assert %{state: :closed, declined_by: nil} = rows[ctx.ended.public_id].work_item
      assert %{state: :exploring, declined_by: nil} = rows[ctx.closed_taken.public_id].work_item
    end

    test "a declined work item names a deleted account as a former member, and no one where no person declined it",
         ctx do
      %{user: decliner} = member_fixture(ctx.scope, :member)
      by_person = ticket(ctx.collection)
      by_nobody = ticket(ctx.collection)

      work_item(ctx.scope, by_person)
      |> Ecto.Changeset.change(
        state: :declined,
        declined_at: DateTime.utc_now(),
        declined_by_id: decliner.id
      )
      |> Repo.update!()

      work_item(ctx.scope, by_nobody)
      |> Ecto.Changeset.change(state: :declined, declined_at: DateTime.utc_now())
      |> Repo.update!()

      declined_by = fn item ->
        Backlog.get_ticket(ctx.scope, item.public_id).work_item.declined_by
      end

      assert declined_by.(by_person) == decliner.email
      assert declined_by.(by_nobody) == nil

      decliner
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now(:second))
      |> Repo.update!()

      assert declined_by.(by_person) == People.former_member()
      assert declined_by.(by_nobody) == nil
    end

    test "a filer the source says is no person is a bot", ctx do
      bot = ticket(ctx.collection, filed_by_name: "deploy-bot", filed_by_kind: :automation)
      [row] = list(ctx.scope, filed_by: "deploy-bot").rows
      assert row.id == bot.public_id
      assert row.filer == %{name: "deploy-bot", kind: :bot}
    end
  end

  describe "search" do
    test "matches the title, the key and the filer's name, any case, with % and _ as they are",
         ctx do
      percent = ticket(ctx.collection, title: "Discount of 100% applies twice")
      underscore = ticket(ctx.collection, title: "order_id is empty")
      plain = ticket(ctx.collection, title: "Order 100 id", key: "#zz77")
      robin = ticket(ctx.collection, title: "Slow page", filed_by_name: "Robin Example")

      search = fn text -> list(ctx.scope, search: text) |> ids() |> Enum.sort() end

      assert search.("%") == [percent.public_id]
      assert search.("100%") == [percent.public_id]
      assert search.("_") == [underscore.public_id]
      assert search.("r_i") == [underscore.public_id]
      assert search.("ORDER") == Enum.sort([underscore.public_id, plain.public_id])
      assert search.("ZZ77") == [plain.public_id]
      assert search.("robin") == [robin.public_id]
      assert search.("\\") == []

      backslash = ticket(ctx.collection, title: ~S"Saves to C:\temp and fails")
      assert search.("\\") == [backslash.public_id]
      assert search.(~S":\t") == [backslash.public_id]

      assert search.("  ") ==
               Enum.sort(Enum.map([percent, underscore, plain, robin, backslash], & &1.public_id))

      assert list(ctx.scope, search: "%").counts == %{
               open: 1,
               taken: 0,
               declined: 0,
               closed: 0,
               total: 1
             }
    end

    test "a search too long, not UTF-8, with a NUL or not text matches nothing", ctx do
      longest = ticket(ctx.collection, title: String.duplicate("a", 1024))

      # 1,024 characters, a title's most, find it; one more finds nothing.
      assert ids(list(ctx.scope, search: String.duplicate("a", 1024))) == [longest.public_id]

      assert ids(list(ctx.scope, search: " " <> String.duplicate("a", 1024) <> " ")) ==
               [longest.public_id]

      wide = ticket(ctx.collection, title: String.duplicate("é", 1024))
      assert ids(list(ctx.scope, search: String.duplicate("é", 1024))) == [wide.public_id]
      assert list(ctx.scope, search: String.duplicate("é", 1025)).rows == []

      for text <- [String.duplicate("a", 1025), <<0xFF>>, "a" <> <<0>>, 12, %{}] do
        assert list(ctx.scope, search: text).rows == [], inspect(text)
        assert list(ctx.scope, search: text).counts.total == 0
      end

      assert length(list(ctx.scope, search: nil).rows) == 2
    end
  end

  describe "filters" do
    setup %{scope: scope, connection: connection, collection: collection} do
      other = source_collection_fixture(scope, connection, %{title: "acme/api"})
      lea = ticket(collection, filed_by_name: "Lea", minutes: 3)
      sam = ticket(other, filed_by_name: "Sam", minutes: 2)
      closed = ticket(other, filed_by_name: "Lea", state: :closed, minutes: 1)
      %{other: other, lea: lea, sam: sam, closed: closed}
    end

    test "by repository, by filer and by state, alone and together", ctx do
      assert ids(list(ctx.scope, repository: ctx.other.id)) == [ctx.sam.public_id]

      assert ids(list(ctx.scope, view: :all, repository: [ctx.other.id])) ==
               [ctx.sam.public_id, ctx.closed.public_id]

      assert ids(list(ctx.scope, %{"view" => "all", "filed_by" => ["Lea"]})) ==
               [ctx.lea.public_id, ctx.closed.public_id]

      assert ids(list(ctx.scope, view: :all, state: :closed)) == [ctx.closed.public_id]

      assert ids(list(ctx.scope, %{"view" => "all", "state" => "open"})) ==
               [ctx.lea.public_id, ctx.sam.public_id]

      page = list(ctx.scope, view: :all, filed_by: "Lea", repository: ctx.other.id)
      assert ids(page) == [ctx.closed.public_id]
      assert page.counts == %{open: 0, taken: 0, declined: 0, closed: 1, total: 1}

      # An empty filter is none.
      assert length(list(ctx.scope, repository: [], filed_by: "").rows) == 2
    end

    test "a value that is not one, or too many, matches nothing", ctx do
      many = for _ <- 1..101, do: Ecto.UUID.generate()

      for params <- [
            [repository: "acme/api"],
            [repository: [ctx.other.id, 7]],
            [repository: many],
            [repository: ctx.other.public_id],
            [filed_by: String.duplicate("a", 101)],
            [filed_by: List.duplicate("Lea", 101)],
            [filed_by: [<<0xFF>>]],
            [filed_by: "a" <> <<0>>],
            [filed_by: ["Lea", "Le" <> <<0>> <> "a"]],
            [filed_by: 7],
            [state: :declined],
            [state: "shut"]
          ] do
        page = list(ctx.scope, [view: :all] ++ params)
        assert page.rows == [], inspect(params)
        assert page.counts.total == 0, inspect(params)
      end
    end
  end

  describe "pages" do
    test "of 50 by keyset, in either order and by either time, each ticket once", ctx do
      tickets =
        for n <- 1..120 do
          ticket(ctx.collection, minutes: n, source_created_at: DateTime.add(@at, -n, :minute))
        end

      newest_first = tickets |> Enum.reverse() |> Enum.map(& &1.public_id)

      pages = fn params ->
        Stream.unfold(:start, fn
          nil ->
            nil

          cursor ->
            after_param = if cursor == :start, do: %{}, else: %{after: cursor}
            page = list(ctx.scope, Map.merge(Map.new(params), after_param))
            {page, page.next}
        end)
        |> Enum.to_list()
      end

      by_updated = pages.([])
      assert Enum.map(by_updated, &length(&1.rows)) == [50, 50, 20]
      assert Enum.flat_map(by_updated, &ids/1) == newest_first
      assert Enum.all?(by_updated, &(&1.counts.total == 120))
      assert List.last(by_updated).next == nil

      assert Enum.flat_map(pages.(order: :asc), &ids/1) == Enum.reverse(newest_first)
      # Created in the other order from updated.
      assert Enum.flat_map(pages.(sort: :created, order: :desc), &ids/1) ==
               Enum.reverse(newest_first)

      assert Enum.flat_map(pages.(%{"sort" => "created", "order" => "asc"}), &ids/1) ==
               newest_first
    end

    test "tickets changed in the same second keep one order across pages", ctx do
      tickets = for _ <- 1..55, do: ticket(ctx.collection)
      first = list(ctx.scope)
      second = list(ctx.scope, after: first.next)

      assert Enum.sort(ids(first) ++ ids(second)) == Enum.sort(Enum.map(tickets, & &1.public_id))

      assert ids(first) ==
               tickets |> Enum.map(& &1.public_id) |> Enum.sort(:desc) |> Enum.take(50)

      assert second.next == nil
    end

    test "a cursor not in the shape this list gives matches nothing; an empty one is none",
         ctx do
      item = ticket(ctx.collection)
      assert ids(list(ctx.scope, after: "")) == [item.public_id]
      assert ids(list(ctx.scope, %{"after" => ""})) == [item.public_id]

      for cursor <- [
            "x",
            "ud.12.tk_",
            "ud.12.wi_0123456789abcdef",
            "ud.a.tk_0123456789abcdef",
            "12.tk_0123456789abcdef",
            "xx.12.tk_0123456789abcdef",
            "ud.12.tk_0123456789abcdef.7",
            # Times out of the years 1 to 9999.
            "ud.-62135596801.tk_0123456789abcdef",
            "ud.253402300800.tk_0123456789abcdef",
            12,
            String.duplicate("1", 65)
          ] do
        assert list(ctx.scope, after: cursor).rows == [], inspect(cursor)
      end

      # One in that shape reads after the time and id it names, whichever row gave it.
      assert list(ctx.scope, after: "ud.0.tk_0123456789abcdef").rows == []

      assert ids(list(ctx.scope, after: "ud.99999999999.tk_zzzzzzzzzzzzzzzz")) ==
               [item.public_id]
    end

    test "a cursor of another sort or order matches nothing", ctx do
      item = ticket(ctx.collection, comment_count: 2)
      at = Integer.to_string(DateTime.to_unix(item.source_updated_at) + 60)
      later = "tk_zzzzzzzzzzzzzzzz"

      for {params, cursor} <- [
            {[], "ua.#{at}.#{later}"},
            {[], "cd.#{at}.#{later}"},
            {[], "md.9.#{at}.#{later}"},
            {[order: :asc], "ud.0.#{later}"},
            {[sort: :created], "ud.#{at}.#{later}"},
            {[sort: :comments], "ud.#{at}.#{later}"},
            {[sort: :comments], "md.#{at}.#{later}"},
            {[sort: :comments], "md.-1.#{at}.#{later}"},
            {[sort: :comments], "md.9223372036854775808.#{at}.#{later}"}
          ] do
        page = list(ctx.scope, [{:after, cursor} | params])
        assert {page.rows, page.next, page.prev, page.first} == {[], nil, nil, 0}, cursor
      end

      # Each, in the sort and order it names, reads after it.
      assert ids(list(ctx.scope, after: "ud.#{at}.#{later}")) == [item.public_id]
      assert ids(list(ctx.scope, order: :asc, after: "ua.0.#{later}")) == [item.public_id]

      assert ids(list(ctx.scope, sort: :comments, after: "md.9.#{at}.#{later}")) == [
               item.public_id
             ]
    end
  end

  describe "the pager" do
    setup %{collection: collection} do
      # 120 tickets: three to a minute changed and seven to a minute filed, so every sort
      # meets ties, and comments in four groups.
      tickets =
        for n <- 1..120 do
          ticket(collection,
            minutes: div(n, 3),
            source_created_at: DateTime.add(@at, -div(n, 7), :minute),
            comment_count: rem(n, 4)
          )
        end

      %{tickets: tickets}
    end

    test "Older to the last page and Newer back to the first, under every sort", ctx do
      for {sort, order} = key <- [
            {:updated, :desc},
            {:updated, :asc},
            {:created, :desc},
            {:created, :asc},
            {:comments, :desc}
          ] do
        params = [sort: sort, order: order]
        expected = ctx.tickets |> sorted(key) |> Enum.map(& &1.public_id)
        [one, two, three] = older_pages(ctx.scope, params)
        context = inspect(key)

        assert Enum.map([one, two, three], &ids/1) == [
                 Enum.slice(expected, 0, 50),
                 Enum.slice(expected, 50, 50),
                 Enum.slice(expected, 100, 20)
               ],
               context

        assert Enum.map([one, two, three], & &1.first) == [1, 51, 101], context
        assert {one.prev, three.next} == {nil, nil}, context
        assert Enum.all?([one.next, two.prev, two.next, three.prev], &is_binary/1), context

        # Newer from the last page is the second again, and Newer from it the first.
        back_two = list(ctx.scope, Keyword.put(params, :before, three.prev))
        assert back_two == two, context
        back_one = list(ctx.scope, Keyword.put(params, :before, back_two.prev))
        assert back_one == one, context

        # Older again from there walks the same pages.
        assert list(ctx.scope, Keyword.put(params, :after, back_one.next)) == two, context
      end
    end

    test "comments: the most first, then the latest change, then the public id, descending alone",
         ctx do
      rows = list(ctx.scope, sort: :comments).rows
      expected = ctx.tickets |> sorted({:comments, :desc}) |> Enum.take(50)

      assert Enum.map(rows, & &1.id) == Enum.map(expected, & &1.public_id)
      assert Enum.map(rows, & &1.comment_count) |> Enum.uniq() == [3, 2]

      # An order asked of it changes nothing; its string is the same sort.
      assert list(ctx.scope, sort: :comments, order: :asc) == list(ctx.scope, sort: :comments)

      assert list(ctx.scope, %{"sort" => "comments", "order" => "asc"}) ==
               list(ctx.scope, sort: :comments)
    end

    test "comments break their ties by the latest change, then the public id" do
      # Another organisation, so only these five are read.
      %{scope: scope} = sign_up_fixture()
      collection = source_collection_fixture(scope, ticket_connection_fixture(scope))

      most = ticket(collection, comment_count: 9, minutes: -10)
      later = ticket(collection, comment_count: 2, minutes: 5)
      tied = for _ <- 1..2, do: ticket(collection, comment_count: 2, minutes: 1)
      none = ticket(collection, comment_count: 0, minutes: 30)

      tied_ids = tied |> Enum.map(& &1.public_id) |> Enum.sort(:desc)

      assert ids(list(scope, sort: :comments)) ==
               [most.public_id, later.public_id] ++ tied_ids ++ [none.public_id]
    end

    test "first counts the rows ahead in the view, under the search and filters", ctx do
      %{scope: scope, collection: collection} = ctx

      # 60 tickets with a label, two of them closed, among the 120.
      labelled =
        for n <- 1..60 do
          ticket(collection,
            labels: ["ui"],
            minutes: 200 + n,
            state: if(n <= 2, do: :closed, else: :open)
          )
        end

      for {params, total} <- [
            {[label: "ui"], 58},
            {[label: "ui", view: :all], 60},
            {[label: ["ui", "nothing"], view: :all, sort: :comments], 60},
            {[repository: collection.id, view: :all], 180},
            {[search: "checkout", view: :all, sort: :created, order: :asc], 180}
          ] do
        pages = older_pages(scope, params)
        sizes = Enum.map(pages, &length(&1.rows))

        assert Enum.sum(sizes) == total, inspect(params)
        assert Enum.map(pages, & &1.first) == Enum.scan([1 | Enum.drop(sizes, -1)], &+/2)
        last = List.last(pages)
        back = list(scope, Keyword.put(params, :before, last.prev))
        assert back == Enum.at(pages, -2), inspect(params)
      end

      # The open view counts its 58 rows alone, the newest change first.
      [one, two] = older_pages(scope, label: "ui")
      assert {one.first, two.first, length(two.rows)} == {1, 51, 8}
      refute Enum.any?(one.rows ++ two.rows, &(&1.state == :closed))
      assert hd(one.rows).id == List.last(labelled).public_id
    end

    test "an Older page past the last row has none, and its prev reads the rows ahead", ctx do
      page = list(ctx.scope, after: "ud.0.tk_0123456789abcdef")
      assert {page.rows, page.next, page.first} == {[], nil, 0}
      assert page.prev == "ud.0.tk_0123456789abcdef"

      # Ahead of it are all 120: the 50 nearest it, the oldest changes.
      newer = list(ctx.scope, before: page.prev)
      expected = ctx.tickets |> sorted({:updated, :desc}) |> Enum.map(& &1.public_id)
      assert ids(newer) == Enum.slice(expected, 70, 50)
      assert {newer.first, newer.next} == {71, nil}

      # A cursor ahead of every row reads the first page: no prev, and first 1.
      ahead = list(ctx.scope, after: "ud.99999999999.tk_zzzzzzzzzzzzzzzz")
      assert {ids(ahead), ahead.prev, ahead.first} == {Enum.take(expected, 50), nil, 1}
    end

    test "a before cursor not in the shape this list gives, or of another sort, matches nothing",
         ctx do
      %{prev: prev} = list(ctx.scope, after: list(ctx.scope).next)
      empty = %{rows: [], next: nil, prev: nil, first: 0}

      for {params, cursor} <- [
            {[], "x"},
            {[], "ud.12.tk_"},
            {[], "ud.a.tk_0123456789abcdef"},
            {[], "12.tk_0123456789abcdef"},
            {[], 12},
            {[], String.duplicate("1", 65)},
            {[], "ud.-62135596801.tk_0123456789abcdef"},
            {[order: :asc], prev},
            {[sort: :created], prev},
            {[sort: :comments], prev}
          ] do
        page = list(ctx.scope, [{:before, cursor} | params])
        assert Map.take(page, [:rows, :next, :prev, :first]) == empty, inspect(cursor)
        assert page.counts.total == 120
      end

      # Both cursors at once match nothing; an empty one is none.
      page = list(ctx.scope, after: prev, before: prev)
      assert Map.take(page, [:rows, :next, :prev, :first]) == empty
      assert list(ctx.scope, before: "") == list(ctx.scope)
      assert list(ctx.scope, %{"before" => "", "after" => ""}) == list(ctx.scope)
    end
  end

  describe "labels" do
    test "a label filter holds the tickets that carry any of its labels, each matched exactly",
         ctx do
      ui = ticket(ctx.collection, labels: ["bug", "ui"], minutes: 4)
      capital = ticket(ctx.collection, labels: ["Bug"], minutes: 3)
      longer = ticket(ctx.collection, labels: ["bugfix"], minutes: 2)
      none = ticket(ctx.collection, labels: [], minutes: 1)
      closed = ticket(ctx.collection, labels: ["ui"], state: :closed)

      assert ids(list(ctx.scope, label: "bug")) == [ui.public_id]
      assert ids(list(ctx.scope, label: "Bug")) == [capital.public_id]
      assert ids(list(ctx.scope, label: ["bug", "bugfix"])) == [ui.public_id, longer.public_id]

      assert ids(list(ctx.scope, %{"label" => ["ui"], "view" => "all"})) ==
               [ui.public_id, closed.public_id]

      for label <- ["BUG", "bu", "%", "ui "] do
        assert list(ctx.scope, label: label).rows == [], label
      end

      page = list(ctx.scope, label: ["ui", "Bug"])
      assert page.counts == %{open: 2, taken: 0, declined: 0, closed: 1, total: 3}

      # With the other filters, all of them hold.
      assert ids(list(ctx.scope, label: "ui", state: :closed, view: :all)) == [closed.public_id]

      # An empty filter is none.
      assert length(list(ctx.scope, label: []).rows) == 4
      assert length(list(ctx.scope, label: "").rows) == 4
      assert none.public_id in ids(list(ctx.scope, label: nil))
    end

    test "a label that is not one, or too many, matches nothing", ctx do
      ticket(ctx.collection, labels: ["bug"])

      for label <- [
            [""],
            String.duplicate("a", 101),
            List.duplicate("bug", 101),
            [<<0xFF>>],
            "b" <> <<0>>,
            ["bug", "b" <> <<0>> <> "ug"],
            7,
            [%{}]
          ] do
        page = list(ctx.scope, view: :all, label: label)
        assert page.rows == [], inspect(label)
        assert page.counts.total == 0, inspect(label)
      end

      # 100 values, and a label of 100 characters, are a filter's most.
      assert length(list(ctx.scope, label: ["bug" | List.duplicate("x", 99)]).rows) == 1
      longest = ticket(ctx.collection, labels: [String.duplicate("é", 100)])
      assert ids(list(ctx.scope, label: String.duplicate("é", 100))) == [longest.public_id]
    end
  end

  describe "filter values" do
    test "every filer by name, with their tickets in every view, and a name search", ctx do
      ticket(ctx.collection, filed_by_name: "Lea")
      ticket(ctx.collection, filed_by_name: "Lea", state: :closed)
      ticket(ctx.collection, filed_by_name: "Sam")
      ticket(ctx.collection, filed_by_name: "Deploy-bot", filed_by_kind: :automation)
      ticket(ctx.collection, filed_by_name: "Deploy-bot", filed_by_kind: :automation)
      ticket(ctx.collection, filed_by_name: "50%_off")

      assert Backlog.filter_values(ctx.scope, :filed_by, nil) == [
               %{key: "Deploy-bot", label: "Deploy-bot", count: 2, avatar: :bot},
               %{key: "Lea", label: "Lea", count: 2, avatar: :person},
               %{key: "50%_off", label: "50%_off", count: 1, avatar: :person},
               %{key: "Sam", label: "Sam", count: 1, avatar: :person}
             ]

      assert Backlog.filter_values(ctx.scope, :filed_by, "LE") == [
               %{key: "Lea", label: "Lea", count: 2, avatar: :person}
             ]

      assert [%{key: "50%_off"}] = Backlog.filter_values(ctx.scope, :filed_by, "%")
      assert [%{key: "50%_off"}] = Backlog.filter_values(ctx.scope, :filed_by, "_")
      assert Backlog.filter_values(ctx.scope, :filed_by, String.duplicate("a", 1025)) == []
      assert Backlog.filter_values(ctx.scope, :filed_by, "nobody") == []
    end

    test "every label of the Backlog's tickets, with their tickets in every view, and a search",
         ctx do
      ticket(ctx.collection, labels: ["bug", "ui"])
      ticket(ctx.collection, labels: ["bug"], state: :closed)
      ticket(ctx.collection, labels: ["Bug", "50%_off"])
      ticket(ctx.collection, labels: [])

      assert Backlog.filter_values(ctx.scope, :label, nil) == [
               %{key: "bug", label: "bug", count: 2, avatar: nil},
               %{key: "50%_off", label: "50%_off", count: 1, avatar: nil},
               %{key: "Bug", label: "Bug", count: 1, avatar: nil},
               %{key: "ui", label: "ui", count: 1, avatar: nil}
             ]

      assert Backlog.filter_values(ctx.scope, :label, "") ==
               Backlog.filter_values(ctx.scope, :label, nil)

      assert Backlog.filter_values(ctx.scope, :label, "BU") == [
               %{key: "bug", label: "bug", count: 2, avatar: nil},
               %{key: "Bug", label: "Bug", count: 1, avatar: nil}
             ]

      assert [%{key: "50%_off"}] = Backlog.filter_values(ctx.scope, :label, "%")
      assert [%{key: "50%_off"}] = Backlog.filter_values(ctx.scope, :label, "_")
      assert Backlog.filter_values(ctx.scope, :label, String.duplicate("a", 1025)) == []
      assert Backlog.filter_values(ctx.scope, :label, "nothing") == []
    end

    test "at most 100 labels, the ones with the most tickets first", ctx do
      hundred = for n <- 1..100, do: "label-#{String.pad_leading(Integer.to_string(n), 3, "0")}"
      ticket(ctx.collection, labels: hundred)
      ticket(ctx.collection, labels: ["label-100", "shared"])
      ticket(ctx.collection, labels: ["shared"])

      values = Backlog.filter_values(ctx.scope, :label, nil)
      assert length(values) == 100

      assert Enum.take(values, 2) == [
               %{key: "label-100", label: "label-100", count: 2, avatar: nil},
               %{key: "shared", label: "shared", count: 2, avatar: nil}
             ]

      # The rest by their words, the last one left out.
      assert Enum.map(Enum.drop(values, 2), & &1.key) == Enum.slice(hundred, 0, 98)
    end

    test "the labels of this Backlog alone", ctx do
      ticket(ctx.collection, labels: ["mine"])

      gone = source_collection_fixture(ctx.scope, ctx.connection, %{title: "acme/gone"})
      ticket(gone, labels: ["ended"])
      end_collection(gone)

      unlinked = source_collection_fixture(ctx.scope, ctx.connection, %{workspace_id: nil})
      ticket(unlinked, labels: ["unlinked"])

      ticket(ctx.collection, labels: ["disconnected"])
      |> Ecto.Changeset.change(disconnected_at: DateTime.utc_now())
      |> Repo.update!()

      workspace = workspace_fixture(ctx.scope.organisation, "Second")
      there = workspace_scope(ctx.scope.user, workspace)
      ticket(source_collection_fixture(there, ctx.connection), labels: ["theirs"])

      %{scope: other} = sign_up_fixture()
      ticket(source_collection_fixture(other, ticket_connection_fixture(other)), labels: ["far"])

      assert Enum.map(Backlog.filter_values(ctx.scope, :label, nil), & &1.key) == ["mine"]
      assert Enum.map(Backlog.filter_values(there, :label, nil), & &1.key) == ["theirs"]
      assert Enum.map(Backlog.filter_values(other, :label, nil), & &1.key) == ["far"]
    end

    test "every live repository linked to the workspace, by its id, with its tickets", ctx do
      other = source_collection_fixture(ctx.scope, ctx.connection, %{title: "acme/api"})
      empty = source_collection_fixture(ctx.scope, ctx.connection, %{title: "acme/zoo"})
      gone = source_collection_fixture(ctx.scope, ctx.connection, %{title: "acme/gone"})
      unlinked = source_collection_fixture(ctx.scope, ctx.connection, %{workspace_id: nil})
      ticket(ctx.collection)
      ticket(ctx.collection, state: :closed)
      ticket(other)

      ticket(other)
      |> Ecto.Changeset.change(disconnected_at: DateTime.utc_now())
      |> Repo.update!()

      ticket(gone)
      end_collection(gone)
      ticket(unlinked)

      assert Backlog.filter_values(ctx.scope, :repository, "") == [
               %{key: ctx.collection.id, label: "acme/shop", count: 2, avatar: nil},
               %{key: other.id, label: "acme/api", count: 1, avatar: nil},
               %{key: empty.id, label: "acme/zoo", count: 0, avatar: nil}
             ]

      assert Backlog.filter_values(ctx.scope, :repository, "API") == [
               %{key: other.id, label: "acme/api", count: 1, avatar: nil}
             ]
    end
  end

  describe "what a Backlog never holds" do
    test "another workspace's tickets, nor another organisation's", ctx do
      mine = ticket(ctx.collection)
      workspace = workspace_fixture(ctx.scope.organisation, "Second")
      there = workspace_scope(ctx.scope.user, workspace)
      theirs_collection = source_collection_fixture(there, ctx.connection, %{title: "acme/b"})
      theirs = ticket(theirs_collection)

      %{scope: other} = sign_up_fixture()
      other_connection = ticket_connection_fixture(other)
      foreign = ticket(source_collection_fixture(other, other_connection))

      assert ids(list(ctx.scope, view: :all)) == [mine.public_id]
      assert ids(list(there, view: :all)) == [theirs.public_id]
      assert ids(list(other, view: :all)) == [foreign.public_id]

      assert Backlog.get_ticket(ctx.scope, theirs.public_id) == nil
      assert Backlog.get_ticket(ctx.scope, foreign.public_id) == nil
      assert Backlog.list_comments(ctx.scope, foreign.public_id) == []

      assert Backlog.filter_values(ctx.scope, :repository, nil) |> Enum.map(& &1.key) ==
               [ctx.collection.id]

      assert ids(list(ctx.scope, view: :all, repository: theirs_collection.id)) == []
      assert Backlog.backlog_facts(ctx.scope).open_tickets == 1
    end

    test "the tickets of an ended connection, in every read", ctx do
      item = ticket(ctx.collection)
      comment(item, %{})
      work_item(ctx.scope, item)
      end_connection(ctx.connection)

      assert list(ctx.scope, view: :all) == %{
               rows: [],
               counts: %{open: 0, taken: 0, declined: 0, closed: 0, total: 0},
               next: nil,
               prev: nil,
               first: 0
             }

      assert Backlog.get_ticket(ctx.scope, item.public_id) == nil
      assert Backlog.list_comments(ctx.scope, item.public_id) == []
      assert Backlog.filter_values(ctx.scope, :filed_by, nil) == []
      assert Backlog.filter_values(ctx.scope, :label, nil) == []
      assert Backlog.filter_values(ctx.scope, :repository, nil) == []

      assert Backlog.backlog_facts(ctx.scope) ==
               %{connected?: false, linked_collections: 0, listed?: false, open_tickets: 0}

      # Its work item stays.
      assert Repo.get_by!(WorkItem, item_id: item.id)
    end

    test "the tickets of an ended collection, while its connection is live", ctx do
      item = ticket(ctx.collection)
      live = source_collection_fixture(ctx.scope, ctx.connection)
      kept = ticket(live)
      end_collection(ctx.collection)

      assert ids(list(ctx.scope, view: :all)) == [kept.public_id]
      assert Backlog.get_ticket(ctx.scope, item.public_id) == nil
      assert Backlog.backlog_facts(ctx.scope).linked_collections == 1
    end

    test "a disconnected ticket", ctx do
      item = ticket(ctx.collection)
      kept = ticket(ctx.collection)

      item
      |> Ecto.Changeset.change(disconnected_at: DateTime.utc_now())
      |> Repo.update!()

      assert ids(list(ctx.scope, view: :all)) == [kept.public_id]
      assert list(ctx.scope).counts.total == 1
      assert Backlog.get_ticket(ctx.scope, item.public_id) == nil
      assert Backlog.backlog_facts(ctx.scope).open_tickets == 1
    end

    test "anything at all for a person who may not read the workspace's work items", ctx do
      item = ticket(ctx.collection)
      comment(item, %{})
      %{scope: other} = sign_up_fixture()

      nothing = %{
        rows: [],
        counts: %{open: 0, taken: 0, declined: 0, closed: 0, total: 0},
        next: nil,
        prev: nil,
        first: 0
      }

      no_facts = %{connected?: false, linked_collections: 0, listed?: false, open_tickets: 0}

      # Another organisation's person, in their scope and in a scope of ours.
      foreign = %{other | organisation: ctx.scope.organisation, workspace: ctx.scope.workspace}

      :ok = Edition.put_test_stub(EditionStubs.HidesNamed)
      :ok = EditionStubs.HidesNamed.put([:factory])
      hidden = Apiary.Access.reload(ctx.scope)

      for scope <- [foreign, hidden] do
        assert list(scope, view: :all) == nothing
        assert Backlog.get_ticket(scope, item.public_id) == nil
        assert Backlog.list_comments(scope, item.public_id) == []
        assert Backlog.filter_values(scope, :filed_by, nil) == []
        assert Backlog.filter_values(scope, :label, nil) == []
        assert Backlog.filter_values(scope, :repository, nil) == []
        assert Backlog.backlog_facts(scope) == no_facts
        assert {:error, _refused} = Backlog.subscribe(scope)
      end

      assert list(other, view: :all) == nothing
      assert Backlog.subscribe(%{ctx.scope | workspace: nil}) == {:error, :not_found}
    end
  end

  describe "a work item, by the ticket's organisation, adapter and ref" do
    test "is found from another record of the same ticket, never by the ticket's id", ctx do
      # The ticket's earlier record, of a collection that ended; its work item names it.
      earlier = source_collection_fixture(ctx.scope, ctx.connection)
      old = ticket(earlier, external_ref: "acme/shop#5")
      taken = work_item(ctx.scope, old)
      end_collection(earlier)

      # The same ticket, by its ref, in a live collection of the same adapter.
      new = ticket(ctx.collection, external_ref: "acme/shop#5")
      assert taken.item_id == old.id

      assert [%{id: id, work_item: %{number: number, state: :exploring}}] =
               list(ctx.scope).rows

      assert {id, number} == {new.public_id, taken.number}

      # A work item that names a ticket by its id with another ref is not that ticket's.
      other = ticket(ctx.collection, external_ref: "acme/shop#6", minutes: -1)

      work_item_fixture(ctx.scope, %{
        connection_id: ctx.connection.id,
        item_id: other.id,
        external_ref: "acme/shop#7"
      })

      assert Backlog.get_ticket(ctx.scope, other.public_id).work_item == nil
    end

    test "of another workspace shows its state alone", ctx do
      item = ticket(ctx.collection)
      workspace = workspace_fixture(ctx.scope.organisation, "Second")
      there = workspace_scope(ctx.scope.user, workspace)
      work_item(there, item, :declined)

      assert [%{work_item: %{number: nil, state: :declined, path: nil, declined_by: nil}}] =
               list(ctx.scope).rows
    end

    test "of another organisation, on the same adapter with the same ref, is not the ticket's",
         ctx do
      item = ticket(ctx.collection, external_ref: "acme/shop#11")
      %{scope: other} = sign_up_fixture()

      theirs =
        Repo.insert!(%Connection{
          public_id: Apiary.PublicId.generate(Connection.prefix()),
          organisation_id: other.organisation.id,
          adapter_id: ctx.connection.adapter_id,
          created_by_id: other.user.id,
          state: :connected,
          pass_nonce: :crypto.strong_rand_bytes(16),
          pass_nonce_used_at: DateTime.utc_now(),
          connected_at: DateTime.utc_now()
        })

      their_item =
        work_item_fixture(other, %{connection_id: theirs.id, external_ref: "acme/shop#11"})

      assert their_item.adapter_id == item.adapter_id
      assert Backlog.get_ticket(ctx.scope, item.public_id).work_item == nil
      assert [%{work_item: nil}] = list(ctx.scope).rows
    end

    test "of another adapter with the same ref is not the ticket's", ctx do
      item = ticket(ctx.collection, external_ref: "acme/shop#9")
      elsewhere = ticket_connection_fixture(ctx.scope)
      other = ticket(source_collection_fixture(ctx.scope, elsewhere), external_ref: "acme/shop#9")
      work_item(ctx.scope, other)

      assert Backlog.get_ticket(ctx.scope, item.public_id).work_item == nil
      assert Backlog.get_ticket(ctx.scope, other.public_id).work_item.state == :exploring
    end
  end

  describe "one ticket" do
    test "by its public id, with its text", ctx do
      item = ticket(ctx.collection, body: "The **text**", truncated: ["body"])

      assert %{
               id: id,
               title: "The checkout keeps the old price",
               body: "The **text**",
               body_format: "markdown",
               truncated: ["body"],
               work_item: nil,
               repository: "acme/shop"
             } = Backlog.get_ticket(ctx.scope, item.public_id)

      assert id == item.public_id
    end

    test "nil for an id that is not a ticket's public id, or names none here", ctx do
      ticket(ctx.collection)

      for id <- [
            nil,
            12,
            "",
            "tk_",
            "tk_0123456789ABCDEF",
            "tk_0123456789abcdefg",
            "wi_0123456789abcdef",
            "tk_0123456789abcdef",
            String.duplicate("tk_", 10_000),
            %{id: "tk_0123456789abcdef"}
          ] do
        assert Backlog.get_ticket(ctx.scope, id) == nil, inspect(id)
      end
    end

    test "its comments, oldest first, without the deleted ones", ctx do
      item = ticket(ctx.collection)
      second = comment(item, %{source_created_at: DateTime.add(@at, 60), author_name: "Sam"})

      first =
        comment(item, %{
          author_name: "deploy-bot",
          author_kind: :automation,
          body: "Built",
          url: "https://forge.example.com/c/first"
        })

      comment(item, %{deleted_at: DateTime.utc_now()})
      other = ticket(ctx.collection)
      comment(other, %{})
      ticket = Backlog.get_ticket(ctx.scope, item.public_id)

      assert [
               %{
                 id: first_id,
                 author: "deploy-bot",
                 author_kind: :bot,
                 at: @at,
                 body: "Built",
                 body_format: "markdown",
                 url: "https://forge.example.com/c/first",
                 truncated: []
               },
               %{id: second_id, author: "Sam", author_kind: :person}
             ] = Backlog.list_comments(ctx.scope, ticket)

      assert {first_id, second_id} == {first.id, second.id}
      assert length(Backlog.list_comments(ctx.scope, item.public_id)) == 2
      assert Backlog.list_comments(ctx.scope, "tk_nope") == []
    end
  end

  describe "the facts of an empty Backlog" do
    test "nothing connected, then connected, listed, linked and with open tickets" do
      %{scope: scope} = sign_up_fixture()

      assert Backlog.backlog_facts(scope) ==
               %{connected?: false, linked_collections: 0, listed?: false, open_tickets: 0}

      connection = ticket_connection_fixture(scope)

      assert Backlog.backlog_facts(scope) ==
               %{connected?: true, linked_collections: 0, listed?: false, open_tickets: 0}

      connection |> Ecto.Changeset.change(listed_at: DateTime.utc_now()) |> Repo.update!()
      collection = source_collection_fixture(scope, connection)
      source_collection_fixture(scope, connection, %{workspace_id: nil})

      assert Backlog.backlog_facts(scope) ==
               %{connected?: true, linked_collections: 1, listed?: true, open_tickets: 0}

      ticket(collection)
      ticket(collection, state: :closed)

      assert Backlog.backlog_facts(scope) ==
               %{connected?: true, linked_collections: 1, listed?: true, open_tickets: 1}
    end
  end

  describe "a collection's open tickets" do
    test "count those open at the source and not disconnected", ctx do
      ticket(ctx.collection)
      ticket(ctx.collection)
      ticket(ctx.collection, state: :closed)

      ticket(ctx.collection)
      |> Ecto.Changeset.change(disconnected_at: DateTime.utc_now())
      |> Repo.update!()

      empty = source_collection_fixture(ctx.scope, ctx.connection, %{title: "acme/zoo"})
      connection = Repo.get!(Connection, ctx.connection.id)

      counts =
        Map.new(Collections.list_collections(ctx.scope, connection), &{&1.id, &1.open_tickets})

      assert counts == %{ctx.collection.id => 2, empty.id => 0}
    end
  end

  describe "subscribing" do
    test "asks to read the workspace's work items, then hears the workspace's topic", ctx do
      assert Backlog.subscribe(ctx.scope) == :ok
      workspace_id = ctx.scope.workspace.id

      Phoenix.PubSub.broadcast(
        Apiary.PubSub,
        Topic.topic(workspace_id),
        {:tickets_changed, ["tk_x"]}
      )

      assert_receive {:tickets_changed, ["tk_x"]}
      assert Topic.topic(workspace_id) == "backlog:" <> workspace_id
    end
  end
end
