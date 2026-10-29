defmodule Apiary.Sources.Backlog do
  # The Backlog of a workspace, read for people: the tickets (`Apiary.Sources.Item`) of
  # the collections linked to the workspace, their comments, the values its filters
  # offer, and the facts an empty Backlog speaks from.
  #
  # **What a Backlog holds.** A ticket is in the Backlog of the scope's workspace while its
  # collection is live (no `ended_at`), assigned to that workspace with its Backlog on
  # (`backlog`), with items, as its adapter has (`items`), so linked
  # (`Apiary.Adapters.Collection.linked?/1`), the collection's
  # connection is connected (not pending, not ended), and the ticket is not disconnected
  # (no `disconnected_at`). A ticket of an ended collection, or of an ended connection,
  # is in no Backlog, whatever its row still says; its work item stays where it is.
  #
  # **Who reads it.** Every read asks `work_item.read` of the scope's workspace first
  # (`Apiary.Access.can?/3`, from the scope as it was loaded), and answers nothing to
  # anyone else: no rows, no counts, no ticket. `subscribe/1` asks the same with the
  # membership read again (`Apiary.Access.authorize/3`).
  #
  # **A row** is a plain map, the shape `ApiaryWeb.BacklogComponents` draws (`row/0`). Its
  # `id` is the ticket's public id (`tk_…`), the one id the pages address a ticket by; its
  # `key` is the ticket's short name at its source, such as `#1231`, or nil, shown as text
  # and never parsed. The source's ref is never in a row. Its `integration` is the adapter
  # the ticket came through, by the adapter's title (`Apiary.Adapters.title/1`) and its
  # public id (`na_…`), read in the same query as the row. A row's work item is the one of
  # the ticket's organisation, adapter and ref, the key that makes it one per ticket
  # (`work_items` (`organisation_id`, `adapter_id`, `external_ref`)), never the ticket's
  # id: a work item taken in from an earlier record of the same ticket is still its work
  # item. A work item of another workspace of the organisation shows its state alone, with
  # no number, page or name of that workspace.
  #
  # **Views** (`list_tickets/2`): `:open`, the tickets open at their source with no work
  # item, or one undone or closed; `:taken`, the open ones whose work item is live;
  # `:declined`, the open ones whose work item was declined; `:closed`, every ticket
  # closed at its source; `:all`, every one. An open ticket is in one of Open, Taken in
  # and Declined. The counts of each view, and the total, come from one grouped query,
  # under the same search and filters as the page, without its view.
  #
  # **The facts** (`backlog_facts/1`) are what an empty Backlog says why it is empty
  # from: the integrations that bring items the organisation is connected through, each
  # by its adapter's title and public id, with their words and their collections' counts;
  # the collections linked to the workspace; the adapters of the instance it could
  # install; and what the person may do and whom to ask. They are read with the
  # connections, after the same gate as every read.
  #
  # Every text a ticket holds came from an adapter and is untrusted: these reads return it
  # as data. Every input a person gives (a search, a filter value, a cursor, a public id)
  # is bounded and checked before a query reads it.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  import Ecto.Query, warn: false

  alias Apiary.{Access, Adapters, Organisations, Repo}
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Adapters.{Collection, Collections, Connection}
  alias Apiary.Lingo.Domain
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Runs.Filters
  alias Apiary.Sources.{Comment, Item, Topic}
  alias Apiary.WorkItems.WorkItem
  alias ApiaryWeb.People

  # The rows a page holds; the characters a search or a name search holds at most, a
  # title's most; the values one filter takes at most; the values a filter offers at most;
  # the characters a filer's name holds at most.
  @page_size 50
  @max_search 1024
  @max_filter_values 100
  @max_offered 100
  @max_name 100

  @views [:open, :taken, :declined, :closed, :all]
  @sorts [:updated, :created, :comments]
  @orders [:desc, :asc]
  @params [
    :view,
    :search,
    :collection,
    :filed_by,
    :label,
    :state,
    :updated,
    :sort,
    :order,
    :after,
    :before
  ]

  # The most a ticket's comments are counted at, as the database keeps them.
  @max_comments 9_223_372_036_854_775_807
  # The seconds since 1970 a cursor's time may name: from the year 1 to the year 9999.
  @cursor_seconds -62_135_596_800..253_402_300_799

  @typedoc "A view of the Backlog."
  @type view :: :open | :taken | :declined | :closed | :all

  @typedoc "Who filed a ticket, or wrote a comment, as the components draw them."
  @type filer :: %{name: String.t(), kind: :person | :bot}

  @typedoc """
  The integration a ticket came through, or one the organisation is connected through: its
  adapter's title (`Apiary.Adapters.title/1`) and its public id (`na_…`), the id its
  page in Organisation settings › Integrations is addressed by.
  """
  @type integration :: %{name: String.t(), id: String.t()}

  @typedoc """
  A ticket's work item, as a row shows it: its number in the workspace, its state, its
  page in the workspace, and, when declined, who declined it, as
  `ApiaryWeb.People.email/1` gives an account: the email address of an account in use,
  priya@example.com, "Former member" for a deleted one, nil where no person declined it.
  `declined_by` is nil for a work item that is not declined. One of another workspace has
  its state alone.
  """
  @type work_item :: %{
          number: pos_integer | nil,
          state: Apiary.WorkItems.State.state(),
          path: String.t() | nil,
          declined_by: String.t() | nil
        }

  @typedoc "A ticket as the Backlog's list draws it."
  @type row :: %{
          id: String.t(),
          key: String.t() | nil,
          title: String.t(),
          url: String.t(),
          repository: String.t(),
          repository_id: Ecto.UUID.t(),
          integration: integration,
          filer: filer,
          labels: [String.t()],
          comment_count: non_neg_integer,
          filed_at: DateTime.t(),
          updated_at: DateTime.t(),
          state: :open | :closed,
          state_reason: String.t() | nil,
          work_item: work_item | nil
        }

  @typedoc "A ticket as it opens: its row, with its text and the fields the adapter cut."
  @type ticket :: %{
          id: String.t(),
          key: String.t() | nil,
          title: String.t(),
          url: String.t(),
          repository: String.t(),
          repository_id: Ecto.UUID.t(),
          integration: integration,
          filer: filer,
          labels: [String.t()],
          comment_count: non_neg_integer,
          filed_at: DateTime.t(),
          updated_at: DateTime.t(),
          state: :open | :closed,
          state_reason: String.t() | nil,
          work_item: work_item | nil,
          body: String.t(),
          body_format: String.t(),
          truncated: [String.t()]
        }

  @typedoc "A comment as a ticket draws it."
  @type comment :: %{
          id: Ecto.UUID.t(),
          author: String.t(),
          author_kind: :person | :bot,
          at: DateTime.t(),
          updated_at: DateTime.t(),
          url: String.t(),
          body: String.t(),
          body_format: String.t(),
          truncated: [String.t()]
        }

  @typedoc "How many tickets each view holds, and in all."
  @type counts :: %{
          open: non_neg_integer,
          taken: non_neg_integer,
          declined: non_neg_integer,
          closed: non_neg_integer,
          total: non_neg_integer
        }

  @typedoc """
  A page of the Backlog: its rows, the counts, the cursors of the page after (`next`) and
  the page before (`prev`), and the place of its first row in the view, from 1 (`first`),
  0 when it has no rows.
  """
  @type page :: %{
          rows: [row],
          counts: counts,
          next: String.t() | nil,
          prev: String.t() | nil,
          first: non_neg_integer
        }

  @typedoc "A value a filter offers: its key, its words, how many tickets, its mark."
  @type value :: %{
          key: String.t(),
          label: String.t(),
          count: non_neg_integer,
          avatar: :person | :bot | nil
        }

  @typedoc """
  What an adapter calls one of its items or collections and many, lower case, as its
  description names them (`Apiary.Adapters.item_noun/1`, `collection_noun/1`); nil where
  it names none.
  """
  @type noun :: %{one: String.t(), other: String.t()} | nil

  @typedoc """
  An integration the organisation is connected through whose adapter has items: its
  adapter's title, public id and words; whether a listing has named its connection and
  whether one has been complete; the live collections its connection reaches and those
  of them assigned to no workspace; and the live collections it has assigned to the
  workspace, linked, with items and their Backlog off, and without items.
  """
  @type source :: %{
          name: String.t(),
          id: String.t(),
          item_noun: noun,
          collection_noun: noun,
          listed?: boolean,
          listing_complete?: boolean,
          collections: non_neg_integer,
          unassigned: non_neg_integer,
          assigned: non_neg_integer,
          linked: non_neg_integer,
          switched_off: non_neg_integer,
          without_items: non_neg_integer
        }

  @typedoc """
  A collection linked to the workspace: its public id (`sc_…`), its title as its source
  names it, its integration, its adapter's words, whether its connection's listing has
  been complete, and how many tickets of the Backlog are open in it.
  """
  @type linked :: %{
          id: String.t(),
          title: String.t(),
          integration: integration,
          item_noun: noun,
          collection_noun: noun,
          listing_complete?: boolean,
          open_tickets: non_neg_integer
        }

  @typedoc """
  An adapter of the instance with items that the organisation is not connected through:
  its title (`Apiary.Adapters.title/1`), its public id and its words.
  """
  @type offered :: %{name: String.t(), id: String.t(), item_noun: noun, collection_noun: noun}

  @typedoc "The facts an empty Backlog, and the page's line under its title, speak from."
  @type facts :: %{
          connected?: boolean,
          listed?: boolean,
          integrations: [integration],
          sources: [source],
          assigned_collections: non_neg_integer,
          linked_collections: non_neg_integer,
          switched_off: non_neg_integer,
          without_items: non_neg_integer,
          collection_nouns: [{noun, pos_integer}],
          linked: [linked],
          open_tickets: non_neg_integer,
          take_in?: boolean,
          offered: [offered],
          may: %{install: boolean, assign: boolean, switch: boolean},
          ask: %{install: [String.t()], assign: [String.t()], switch: [String.t()]}
        }

  @no_counts %{open: 0, taken: 0, declined: 0, closed: 0, total: 0}
  @no_rows %{rows: [], next: nil, prev: nil, first: 0}
  @no_page Map.put(@no_rows, :counts, @no_counts)

  ## The list

  @doc false
  # list_tickets/3 is a page of the Backlog of the scope's workspace, to a person who may
  # read its work items, and an empty page (no rows, every count 0) to anyone else.
  # `params`, a map or a keyword list, with atom keys or their strings:
  #
  #   * `view:` one of `t:view/0` (`:open` by default), or its string;
  #   * `search:` text the title, the key, the full form (the repository's title followed
  #     by the key, `acme/shop#1231`, or the title alone without a key) or the filer's
  #     name holds, any case, its `%`, `_` and `\` as they are, the spaces around it left
  #     out; at most 1,024 characters of valid UTF-8 with no NUL, else nothing matches;
  #   * `collection:` a collection's id, the one Qory Apiary gives it, or a list of them:
  #     the tickets of those collections;
  #   * `filed_by:` a filer's name, as stored, or a list of them;
  #   * `label:` a label, as stored, or a list of them: the tickets that carry any of
  #     them, each matched exactly;
  #   * `state:` `:open` or `:closed` (or its string), the ticket's state at its source;
  #   * `updated:` a window the runs list offers, by its value (`1h`, `24h`, `7d`, `14d`
  #     or `30d`, `Apiary.Runs.Filters.windows/0`): the tickets whose latest change at
  #     their source is at or after that long before `now`, the read's moment to the
  #     second;
  #   * `sort:` `:updated` (the default) or `:created`, the ticket's times at its source,
  #     and `order:` `:desc` (the default) or `:asc`; or `:comments`, the most comments
  #     first, then the latest change at the source, then the public id, always
  #     descending, whatever `order:` says;
  #   * `after:` the cursor of the page before (`next`), for the page after it (Older);
  #   * `before:` the cursor of the page after (`prev`), for the page before it (Newer).
  #
  # A filter takes at most 100 values; one with more, or with a value that is not one
  # (a repository that is no id, a name or a label that is not 1 to 100 characters of
  # valid UTF-8 with no NUL, a state or a window it does not offer), matches nothing, and
  # so does a cursor not in the shape this function gives, a cursor of another sort or
  # order, and `after:` and `before:` together. An empty filter, or an empty cursor, is
  # none. A view, a sort or an order it does not know is its default. The rows are at
  # most `page_size/0`; `next` is the cursor of the page after, or nil for the last;
  # `prev` the cursor of the page before, or nil for the first. A page `before:` names
  # that would hold the first row is the first page, as it is read with no cursor.
  # `first` is the place of the page's first row in the view, from 1, counted in the
  # database from the rows ahead of it under the same view, search and filters; 0 for a
  # page with no rows. The counts are of every view, under the same search and filters,
  # without the view and the cursor. A cursor names a row's place in its sort alone, so it
  # holds under any filter, a window too, whose start each page counts back from `now`.
  @spec list_tickets(Scope.t(), map | keyword, DateTime.t()) :: page
  def list_tickets(scope, params, now \\ DateTime.utc_now())

  def list_tickets(%Scope{} = scope, params, %DateTime{} = now)
      when is_map(params) or is_list(params) do
    case workspace(scope) do
      {:ok, organisation_id, %Workspace{} = workspace} ->
        params = normalise(params)

        filtered =
          organisation_id
          |> backlog(workspace.id)
          |> search(params.search)
          |> collections(params.collection)
          |> filers(params.filed_by)
          |> labels(params.label)
          |> state(params.state)
          |> updated(params.updated, now)

        filtered
        |> view(params.view)
        |> page(params, scope)
        |> Map.put(:counts, counts(filtered))

      :error ->
        @no_page
    end
  end

  def list_tickets(%Scope{}, _params, _now), do: @no_page

  # The rows a page holds at most.
  @doc false
  @spec page_size() :: pos_integer
  def page_size, do: @page_size

  # A page of `query`, the view already in it: its rows, `next`, `prev` and `first`.
  defp page(query, params, scope) do
    sort = {params.sort, params.order}

    case {params.after, params.before} do
      {nil, nil} -> first_page(query, sort, scope)
      {cursor, nil} -> older(query, sort, cursor, scope)
      {nil, cursor} -> newer(query, sort, cursor, scope)
      {_after, _before} -> @no_rows
    end
  end

  defp first_page(query, sort, scope) do
    {rows, more} = query |> fetch(sort, :forward, scope) |> Enum.split(@page_size)

    %{
      rows: Enum.map(rows, &row/1),
      next: if(more != [], do: last_cursor(rows, sort)),
      prev: nil,
      first: if(rows == [], do: 0, else: 1)
    }
  end

  # The page after the row the cursor names. Its `first` and `prev` come from the rows
  # ahead of its first row, or, on a page with no rows, of the cursor's row.
  defp older(query, sort, cursor, scope) do
    case parse_cursor(cursor, sort) do
      {:ok, position} ->
        {rows, more} =
          query
          |> beyond(sort, :behind, position)
          |> fetch(sort, :forward, scope)
          |> Enum.split(@page_size)

        anchor = if rows == [], do: position, else: position(hd(rows), sort)
        ahead = count_ahead(query, sort, anchor)

        %{
          rows: Enum.map(rows, &row/1),
          next: if(more != [], do: last_cursor(rows, sort)),
          prev: if(ahead > 0, do: cursor(anchor, sort)),
          first: if(rows == [], do: 0, else: ahead + 1)
        }

      :error ->
        @no_rows
    end
  end

  # The page before the row the cursor names, read backwards and turned round; the first
  # page when it would hold the first row.
  defp newer(query, sort, cursor, scope) do
    with {:ok, position} <- parse_cursor(cursor, sort),
         reversed = query |> beyond(sort, :ahead, position) |> fetch(sort, :backward, scope),
         {page, [_more | _]} <- Enum.split(reversed, @page_size) do
      rows = Enum.reverse(page)
      first = position(hd(rows), sort)
      last = position(List.last(rows), sort)

      %{
        rows: Enum.map(rows, &row/1),
        next: if(Repo.exists?(beyond(query, sort, :behind, last)), do: cursor(last, sort)),
        prev: cursor(first, sort),
        first: count_ahead(query, sort, first) + 1
      }
    else
      :error -> @no_rows
      {_page, []} -> first_page(query, sort, scope)
    end
  end

  # At most a page and one more row of `query`, in the sort's order (`:forward`) or
  # against it (`:backward`).
  defp fetch(query, sort, direction, scope) do
    query
    |> order(sort, direction)
    |> limit(@page_size + 1)
    |> select_row(scope)
    |> Repo.all()
  end

  defp order(query, {:comments, :desc}, direction) do
    order = if direction == :forward, do: :desc, else: :asc

    order_by(query, [item: i], [
      {^order, i.comment_count},
      {^order, i.source_updated_at},
      {^order, i.public_id}
    ])
  end

  defp order(query, {sort, order}, direction) do
    order = if direction == :forward, do: order, else: flip(order)
    field = sort_field(sort)
    order_by(query, [item: i], [{^order, field(i, ^field)}, {^order, i.public_id}])
  end

  defp flip(:desc), do: :asc
  defp flip(:asc), do: :desc

  # How many rows of `query` are ahead of `position`, in the sort's order.
  defp count_ahead(query, sort, position) do
    query
    |> beyond(sort, :ahead, position)
    |> select([item: i], count(i.id))
    |> Repo.one()
  end

  defp sort_field(:updated), do: :source_updated_at
  defp sort_field(:created), do: :source_created_at

  # The place of a selected row in the sort's order: its sort time and public id, or, by
  # comments, its comments, its latest change at the source and its public id.
  defp position(selected, {:comments, :desc}),
    do: {selected.comment_count, selected.source_updated_at, selected.id}

  defp position(selected, {:updated, _order}), do: {selected.source_updated_at, selected.id}
  defp position(selected, {:created, _order}), do: {selected.source_created_at, selected.id}

  defp last_cursor(rows, sort), do: rows |> List.last() |> position(sort) |> cursor(sort)

  # Every ticket of the Backlog of the workspace `workspace_id` of the organisation
  # `organisation_id`, with its collection, its connection, its adapter and its work item,
  # if any, named `:item`, `:collection`, `:connection`, `:adapter` and `:work_item`.
  defp backlog(organisation_id, workspace_id) do
    from i in Item,
      as: :item,
      join: c in Collection,
      as: :collection,
      on: c.id == i.collection_id and c.organisation_id == i.organisation_id,
      join: k in Connection,
      as: :connection,
      on: k.id == c.connection_id and k.organisation_id == c.organisation_id,
      join: n in Node,
      as: :adapter,
      on: n.id == c.adapter_id,
      left_join: w in WorkItem,
      as: :work_item,
      on:
        w.organisation_id == i.organisation_id and w.adapter_id == i.adapter_id and
          w.external_ref == i.external_ref,
      where:
        i.organisation_id == ^organisation_id and c.workspace_id == ^workspace_id and
          c.backlog and c.items and n.items and is_nil(c.ended_at) and k.state == :connected and
          is_nil(k.ended_at) and is_nil(i.disconnected_at)
  end

  # With no work item the left join gives NULL, so `is_nil(w.id)`: a NOT IN would leave
  # those tickets out.
  defp view(query, :open),
    do:
      where(
        query,
        [item: i, work_item: w],
        i.state == :open and (is_nil(w.id) or w.state in [:undone, :closed])
      )

  defp view(query, :taken),
    do: where(query, [item: i, work_item: w], i.state == :open and w.state == :exploring)

  defp view(query, :declined),
    do: where(query, [item: i, work_item: w], i.state == :open and w.state == :declined)

  defp view(query, :closed), do: where(query, [item: i], i.state == :closed)
  defp view(query, :all), do: query

  defp search(query, nil), do: query

  defp search(query, text) do
    case pattern(text) do
      nil ->
        query

      :none ->
        where(query, false)

      pattern ->
        where(
          query,
          [item: i, collection: c],
          ilike(i.title, ^pattern) or ilike(i.key, ^pattern) or
            ilike(fragment("? || coalesce(?, '')", c.title, i.key), ^pattern) or
            ilike(i.filed_by_name, ^pattern)
        )
    end
  end

  # The ILIKE pattern of a search: nil for none, `:none` for one that matches nothing.
  # Its size is bounded before anything else reads it, and its `%`, `_` and `\` are
  # escaped, so each matches itself.
  defp pattern(nil), do: nil

  defp pattern(text) when is_binary(text) and byte_size(text) <= @max_search * 4 do
    text = String.trim(text)

    cond do
      text == "" ->
        nil

      not String.valid?(text) or String.contains?(text, <<0>>) or
          String.length(text) > @max_search ->
        :none

      true ->
        "%" <> String.replace(text, ~r/[\\%_]/, "\\\\\\0") <> "%"
    end
  end

  defp pattern(_text), do: :none

  defp collections(query, nil), do: query

  defp collections(query, ids) do
    case cast_ids(ids) do
      {:ok, ids} -> where(query, [collection: c], c.id in ^ids)
      :error -> where(query, false)
    end
  end

  defp cast_ids(ids) when is_list(ids) and length(ids) <= @max_filter_values do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, cast} ->
      case is_binary(id) and Ecto.UUID.cast(id) do
        {:ok, id} -> {:cont, {:ok, [id | cast]}}
        _not -> {:halt, :error}
      end
    end)
  end

  defp cast_ids(_ids), do: :error

  defp filers(query, nil), do: query

  defp filers(query, names) do
    if is_list(names) and length(names) <= @max_filter_values and Enum.all?(names, &name?/1),
      do: where(query, [item: i], i.filed_by_name in ^names),
      else: where(query, false)
  end

  defp labels(query, nil), do: query

  defp labels(query, labels) do
    if is_list(labels) and length(labels) <= @max_filter_values and Enum.all?(labels, &name?/1),
      do: where(query, [item: i], fragment("? && ?::text[]", i.labels, ^labels)),
      else: where(query, false)
  end

  # A filer's name, or a label: 1 to 100 characters of valid UTF-8 with no NUL.
  defp name?(name) when is_binary(name) and byte_size(name) <= @max_name * 4,
    do:
      String.valid?(name) and not String.contains?(name, <<0>>) and
        String.length(name) in 1..@max_name

  defp name?(_name), do: false

  defp state(query, nil), do: query

  defp state(query, state) when state in [:open, :closed],
    do: where(query, [item: i], i.state == ^state)

  defp state(query, _state), do: where(query, false)

  # A window back from `now`, the second it was read in, by its value: the tickets whose
  # latest change at their source is at or after its start.
  defp updated(query, nil, _now), do: query
  defp updated(query, :invalid, _now), do: where(query, false)

  defp updated(query, window, now) do
    since = now |> DateTime.truncate(:second) |> DateTime.add(-Filters.window_seconds(window))
    where(query, [item: i], i.source_updated_at >= type(^since, :utc_datetime))
  end

  # The rows of `query` behind `position` (after it, in the sort's order) or ahead of it
  # (before it), by their place in that order.
  defp beyond(query, {:comments, :desc}, side, position),
    do: compare(query, position, :comment_count, if(side == :behind, do: :<, else: :>))

  defp beyond(query, {sort, order}, side, position) do
    operator =
      case {order, side} do
        {:desc, :behind} -> :<
        {:desc, :ahead} -> :>
        {:asc, :behind} -> :>
        {:asc, :ahead} -> :<
      end

    compare(query, position, sort_field(sort), operator)
  end

  defp compare(query, {at, public_id}, field, :<) do
    where(
      query,
      [item: i],
      fragment(
        "(?, ?) < (?, ?)",
        field(i, ^field),
        i.public_id,
        type(^at, :utc_datetime),
        ^public_id
      )
    )
  end

  defp compare(query, {at, public_id}, field, :>) do
    where(
      query,
      [item: i],
      fragment(
        "(?, ?) > (?, ?)",
        field(i, ^field),
        i.public_id,
        type(^at, :utc_datetime),
        ^public_id
      )
    )
  end

  defp compare(query, {count, at, public_id}, :comment_count, :<) do
    where(
      query,
      [item: i],
      fragment(
        "(?, ?, ?) < (?, ?, ?)",
        i.comment_count,
        i.source_updated_at,
        i.public_id,
        type(^count, :integer),
        type(^at, :utc_datetime),
        ^public_id
      )
    )
  end

  defp compare(query, {count, at, public_id}, :comment_count, :>) do
    where(
      query,
      [item: i],
      fragment(
        "(?, ?, ?) > (?, ?, ?)",
        i.comment_count,
        i.source_updated_at,
        i.public_id,
        type(^count, :integer),
        type(^at, :utc_datetime),
        ^public_id
      )
    )
  end

  # A cursor names a row's place in one sort and order: the sort's mark, a `.`, the row's
  # sort time in seconds since 1970, a `.`, and its public id; by comments, the mark, its
  # comments, its latest change at the source in seconds, and its public id, each after a
  # `.`. The mark is `ud`, `ua`, `cd` or `ca` (updated or created, descending or
  # ascending), or `md` (comments).
  defp cursor({count, at, public_id}, sort),
    do: Enum.join([mark(sort), Integer.to_string(count), seconds(at), public_id], ".")

  defp cursor({at, public_id}, sort), do: Enum.join([mark(sort), seconds(at), public_id], ".")

  defp seconds(%DateTime{} = at), do: Integer.to_string(DateTime.to_unix(at))

  defp mark({:updated, :desc}), do: "ud"
  defp mark({:updated, :asc}), do: "ua"
  defp mark({:created, :desc}), do: "cd"
  defp mark({:created, :asc}), do: "ca"
  defp mark({:comments, :desc}), do: "md"

  # The place a cursor of `sort` names, or `:error` for a cursor not in that shape, or of
  # another sort or order. Its size is bounded before it is split.
  defp parse_cursor(cursor, sort) when is_binary(cursor) and byte_size(cursor) <= 64 do
    mark = mark(sort)

    case {sort, String.split(cursor, ".")} do
      {{:comments, :desc}, [^mark, count, seconds, public_id]} ->
        with {:ok, count} <- parse_count(count),
             {:ok, at} <- parse_seconds(seconds),
             true <- Item.public_id?(public_id) do
          {:ok, {count, at, public_id}}
        else
          _not -> :error
        end

      {{time, _order}, [^mark, seconds, public_id]} when time in [:updated, :created] ->
        with {:ok, at} <- parse_seconds(seconds),
             true <- Item.public_id?(public_id) do
          {:ok, {at, public_id}}
        else
          _not -> :error
        end

      _not ->
        :error
    end
  end

  defp parse_cursor(_cursor, _sort), do: :error

  defp parse_count(text) do
    case Integer.parse(text) do
      {count, ""} when count in 0..@max_comments -> {:ok, count}
      _not -> :error
    end
  end

  defp parse_seconds(text) do
    case Integer.parse(text) do
      {seconds, ""} when seconds in @cursor_seconds -> DateTime.from_unix(seconds)
      _not -> :error
    end
  end

  # How many tickets of the query each view holds, and in all, by one grouped query.
  defp counts(query) do
    query
    |> group_by([item: i, work_item: w], [i.state, w.state])
    |> select([item: i, work_item: w], {i.state, w.state, count(i.id)})
    |> Repo.all()
    |> Enum.reduce(@no_counts, fn {state, work_item_state, n}, counts ->
      counts
      |> Map.update!(:total, &(&1 + n))
      |> held(state, work_item_state, n)
    end)
  end

  # The view a ticket's state and its work item's put it in: an open one in one of Open,
  # Taken in and Declined, a closed one in Closed.
  defp held(counts, :open, work_item_state, n) when work_item_state in [nil, :undone, :closed],
    do: Map.update!(counts, :open, &(&1 + n))

  defp held(counts, :open, :exploring, n), do: Map.update!(counts, :taken, &(&1 + n))
  defp held(counts, :open, :declined, n), do: Map.update!(counts, :declined, &(&1 + n))
  defp held(counts, :closed, _work_item_state, n), do: Map.update!(counts, :closed, &(&1 + n))

  defp select_row(query, %Scope{organisation: organisation, workspace: workspace}) do
    path = "/" <> organisation.slug <> "/" <> workspace.slug <> "/work/"

    query
    |> join(:left, [work_item: w], u in User, as: :declined_by, on: u.id == w.declined_by_id)
    |> select([item: i, collection: c, adapter: n, work_item: w, declined_by: u], %{
      id: i.public_id,
      key: i.key,
      title: i.title,
      url: i.url,
      repository: c.title,
      repository_id: c.id,
      integration_name: coalesce(n.title, n.name),
      integration_id: n.public_id,
      filed_by_name: i.filed_by_name,
      filed_by_kind: i.filed_by_kind,
      labels: i.labels,
      comment_count: i.comment_count,
      source_created_at: i.source_created_at,
      source_updated_at: i.source_updated_at,
      state: i.state,
      state_reason: i.state_reason,
      work_item_id: w.id,
      work_item_here: w.workspace_id == ^workspace.id,
      work_item_number: w.number,
      work_item_state: w.state,
      declined_by: u,
      path: ^path
    })
  end

  defp row(selected) do
    %{
      id: selected.id,
      key: selected.key,
      title: selected.title,
      url: selected.url,
      repository: selected.repository,
      repository_id: selected.repository_id,
      integration: %{name: selected.integration_name, id: selected.integration_id},
      filer: %{name: selected.filed_by_name, kind: kind(selected.filed_by_kind)},
      labels: selected.labels,
      comment_count: selected.comment_count,
      filed_at: selected.source_created_at,
      updated_at: selected.source_updated_at,
      state: selected.state,
      state_reason: selected.state_reason,
      work_item: work_item(selected)
    }
  end

  defp work_item(%{work_item_id: nil}), do: nil

  defp work_item(%{work_item_here: true} = selected) do
    %{
      number: selected.work_item_number,
      state: selected.work_item_state,
      path: selected.path <> Integer.to_string(selected.work_item_number),
      declined_by:
        if(selected.work_item_state == :declined,
          do: People.email(selected.declined_by)
        )
    }
  end

  defp work_item(selected),
    do: %{number: nil, state: selected.work_item_state, path: nil, declined_by: nil}

  # The components' word for who wrote it: a person, or a bot for anything else.
  defp kind(:person), do: :person
  defp kind(_automation), do: :bot

  # The params, each its value or nil, by atom keys or their strings alone.
  defp normalise(params) do
    params = Map.new(params)
    get = fn key -> Map.get(params, key, Map.get(params, Atom.to_string(key))) end
    values = Map.new(@params, &{&1, get.(&1)})
    sort = choice(values.sort, @sorts, :updated)

    %{
      view: choice(values.view, @views, :open),
      search: values.search,
      collection: list(values.collection),
      filed_by: list(values.filed_by),
      label: list(values.label),
      state: state_value(values.state),
      updated: window(values.updated),
      sort: sort,
      order: if(sort == :comments, do: :desc, else: choice(values.order, @orders, :desc)),
      after: if(values.after == "", do: nil, else: values.after),
      before: if(values.before == "", do: nil, else: values.before)
    }
  end

  # `value`, when it is one of `choices` or the string of one; else `default`.
  defp choice(value, choices, default) do
    Enum.find(choices, default, &(&1 == value or Atom.to_string(&1) == value))
  end

  defp list(nil), do: nil
  defp list(""), do: nil
  defp list([]), do: nil
  defp list(values) when is_list(values), do: values
  defp list(value), do: [value]

  defp state_value(nil), do: nil
  defp state_value(""), do: nil
  defp state_value(state) when state in [:open, :closed], do: state
  defp state_value("open"), do: :open
  defp state_value("closed"), do: :closed
  defp state_value(_state), do: :invalid

  # A window's value, when it is one the runs list offers; `:invalid` for any other.
  defp window(nil), do: nil
  defp window(""), do: nil

  defp window(value) do
    if List.keymember?(Filters.windows(), value, 1), do: value, else: :invalid
  end

  ## The filters' values

  @doc false
  # filter_values/3 is what a filter of the Backlog of the scope's workspace offers, to a
  # person who may read its work items, and `[]` to anyone else; at most 100 values, the
  # ones with the most tickets first, then by their words. `query` narrows them to the
  # words that hold it, any case, as `list_tickets/2`'s search reads text; nil or "" for
  # all.
  #
  #   * `:filed_by`: every filer of the Backlog's tickets, by the name stored: `key` and
  #     `label` are the name, `count` their tickets in every view, `avatar` `:person` when
  #     a person filed one of them, else `:bot`.
  #   * `:label`: every label the Backlog's tickets carry, as stored: `key` and `label`
  #     are the label, `count` the tickets that carry it in every view, `avatar` nil.
  #   * `:collection`: every live collection linked to the workspace (its Backlog on, with
  #     items, as its adapter has), whose connection is connected: `key` is the collection's id, the one Qory Apiary gives it, `label` its
  #     title, `count` its tickets in every view, `avatar` nil.
  @spec filter_values(Scope.t(), :filed_by | :label | :collection, String.t() | nil) ::
          [value]
  def filter_values(%Scope{} = scope, kind, query)
      when kind in [:filed_by, :label, :collection] do
    with {:ok, organisation_id, %Workspace{id: workspace_id}} <- workspace(scope),
         pattern when pattern != :none <- pattern(query) do
      values(kind, organisation_id, workspace_id, pattern)
    else
      _nothing -> []
    end
  end

  defp values(:filed_by, organisation_id, workspace_id, pattern) do
    organisation_id
    |> backlog(workspace_id)
    |> then(fn q ->
      if pattern, do: where(q, [item: i], ilike(i.filed_by_name, ^pattern)), else: q
    end)
    |> group_by([item: i], i.filed_by_name)
    |> order_by([item: i], desc: count(i.id), asc: i.filed_by_name)
    |> limit(@max_offered)
    |> select([item: i], %{
      key: i.filed_by_name,
      label: i.filed_by_name,
      count: count(i.id),
      person?: fragment("bool_or(? = 'person')", i.filed_by_kind)
    })
    |> Repo.all()
    |> Enum.map(fn value ->
      value
      |> Map.put(:avatar, if(value.person?, do: :person, else: :bot))
      |> Map.delete(:person?)
    end)
  end

  # A ticket carries each label once, so a label's rows are its tickets.
  defp values(:label, organisation_id, workspace_id, pattern) do
    organisation_id
    |> backlog(workspace_id)
    |> join(:inner_lateral, [item: i], l in fragment("SELECT unnest(?) AS name", i.labels),
      as: :label,
      on: true
    )
    |> then(fn q ->
      if pattern, do: where(q, [label: l], ilike(l.name, ^pattern)), else: q
    end)
    |> group_by([label: l], l.name)
    |> order_by([item: i, label: l], desc: count(i.id), asc: l.name)
    |> limit(@max_offered)
    |> select([item: i, label: l], %{key: l.name, label: l.name, count: count(i.id)})
    |> Repo.all()
    |> Enum.map(&Map.put(&1, :avatar, nil))
  end

  defp values(:collection, organisation_id, workspace_id, pattern) do
    from(c in Collection,
      join: k in Connection,
      on: k.id == c.connection_id and k.organisation_id == c.organisation_id,
      join: n in Node,
      on: n.id == c.adapter_id,
      left_join: i in Item,
      on:
        i.collection_id == c.id and i.organisation_id == c.organisation_id and
          is_nil(i.disconnected_at),
      where:
        c.organisation_id == ^organisation_id and c.workspace_id == ^workspace_id and
          c.backlog and c.items and n.items and is_nil(c.ended_at) and k.state == :connected and
          is_nil(k.ended_at),
      group_by: [c.id, c.title],
      order_by: [desc: count(i.id), asc: c.title, asc: c.id],
      limit: @max_offered,
      select: %{key: c.id, label: c.title, count: count(i.id)}
    )
    |> then(fn q -> if pattern, do: where(q, [c], ilike(c.title, ^pattern)), else: q end)
    |> Repo.all()
    |> Enum.map(&Map.put(&1, :avatar, nil))
  end

  ## One ticket

  @doc false
  # get_ticket/2 is the ticket of the Backlog of the scope's workspace whose public id
  # (`tk_…`) is `public_id`, as it opens (`t:ticket/0`), to a person who may read the
  # workspace's work items; nil for anyone else, for an id that is not a ticket's public
  # id, which is refused before any query, and for a ticket in no Backlog of that
  # workspace: of another workspace or organisation, of an ended collection or
  # connection, or disconnected.
  @spec get_ticket(Scope.t(), term) :: ticket | nil
  def get_ticket(%Scope{} = scope, public_id) do
    with true <- Item.public_id?(public_id),
         {:ok, organisation_id, %Workspace{id: workspace_id}} <- workspace(scope),
         %{} = selected <-
           organisation_id
           |> backlog(workspace_id)
           |> where([item: i], i.public_id == ^public_id)
           |> select_row(scope)
           |> select_merge([item: i], %{
             body: i.body,
             body_format: i.body_format,
             truncated: i.truncated
           })
           |> Repo.one() do
      selected
      |> row()
      |> Map.merge(Map.take(selected, [:body, :body_format, :truncated]))
    else
      _none -> nil
    end
  end

  @doc false
  # list_comments/2 is the comments of `ticket`, a ticket `get_ticket/2` gave or its
  # public id, oldest first (by their time at the source), without the ones deleted at
  # the source, to a person who may read the workspace's work items; `[]` for anyone
  # else, and for a ticket in no Backlog of the scope's workspace, which it asks again.
  @spec list_comments(Scope.t(), ticket | String.t()) :: [comment]
  def list_comments(%Scope{} = scope, %{id: public_id}), do: list_comments(scope, public_id)

  def list_comments(%Scope{} = scope, public_id) do
    with true <- Item.public_id?(public_id),
         {:ok, organisation_id, %Workspace{id: workspace_id}} <- workspace(scope),
         item_id when is_binary(item_id) <-
           organisation_id
           |> backlog(workspace_id)
           |> where([item: i], i.public_id == ^public_id)
           |> select([item: i], i.id)
           |> Repo.one() do
      Repo.all(
        from c in Comment,
          where:
            c.item_id == ^item_id and c.organisation_id == ^organisation_id and
              is_nil(c.deleted_at),
          order_by: [asc: c.source_created_at, asc: c.inserted_at, asc: c.id],
          select: %{
            id: c.id,
            author: c.author_name,
            author_kind: c.author_kind,
            at: c.source_created_at,
            updated_at: c.source_updated_at,
            url: c.url,
            body: c.body,
            body_format: c.body_format,
            truncated: c.truncated
          }
      )
      |> Enum.map(&Map.update!(&1, :author_kind, fn kind -> kind(kind) end))
    else
      _none -> []
    end
  end

  ## The facts of an empty Backlog

  # The linked collections the facts name at most.
  @most_linked 5

  @no_here %{assigned: 0, linked: 0, switched_off: 0, without_items: 0}

  @doc false
  # backlog_facts/1 is what an empty Backlog of the scope's workspace, and the line under
  # the page's title, speak from, to a person who may read its work items (`t:facts/0`):
  #
  #   * `connected?`, whether the organisation has a connection that is connected;
  #     `listed?`, whether an adapter's listing has named one of them (its `listed_at`);
  #   * `integrations`, the integrations of those connections whose adapter has items,
  #     each by its adapter's title and public id, by its adapter's name
  #     (`t:integration/0`);
  #   * `sources`, the same integrations in the same order, each with its adapter's words
  #     for its items and its collections, whether a listing has named its connection
  #     (`listed?`) and whether one has been complete (`listing_complete?`), how many live
  #     collections its connection reaches and how many of them are assigned to no
  #     workspace (`collections` and `unassigned`, `Apiary.Adapters.Collections.counts/2`,
  #     the numbers of the integration's page), and how many live collections it has
  #     assigned to the workspace (`assigned`), linked (`linked`), with items and their
  #     Backlog off (`switched_off`), and without items (`without_items`)
  #     (`t:source/0`);
  #   * `assigned_collections`, `linked_collections`, `switched_off` and `without_items`,
  #     the sources' counts summed: `assigned_collections` is the count the line under the
  #     title says, whatever the collections' Backlog switch and items;
  #   * `collection_nouns`, the words of each source with a collection assigned to the
  #     workspace for its collections, each once, in the order of `sources`, with how many
  #     of its collections are assigned (`{noun, count}`); the words alone are
  #     `collection_nouns/1`'s;
  #   * `linked`, the first 5 linked collections, by their adapter's name, then their
  #     title, each with how many tickets of the Backlog are open in it (`t:linked/0`);
  #   * `open_tickets`, how many tickets the Backlog holds open at their source, whatever
  #     their work item; `take_in?`, whether Take in may take an open ticket of the Open
  #     view: any, where the workspace's domain needs no target
  #     (`Apiary.Lingo.Domain.target_required?/1`), else one with a target, the ticket's,
  #     else its collection's;
  #   * `offered`, the instance's adapters with items that no connected connection of the
  #     organisation goes through and that serve the workspace's domain
  #     (`Apiary.Lingo.Domain.serves?/2`), by name (`t:offered/0`), as
  #     `Apiary.Adapters.list_adapters/1` gives them to the person;
  #   * `may`, whether the person may install an integration (`install`,
  #     `adapter.connect`), assign a collection to a workspace (`assign`,
  #     `collection.assign`) and turn a Backlog switch (`switch`,
  #     `collection.set_backlog`), as `Apiary.Access.can?/3` answers; `ask`, under the
  #     same keys, the short names of the members whose level holds the action, in
  #     `Apiary.Organisations.list_members/1`'s order, without a suspended membership or a
  #     deleted account, for each action the person may not take, and `[]` for each they
  #     may.
  #
  # The queries are the same whatever the number of collections: one each for the
  # connections, the assigned counts, the open tickets, Take in, the linked collections
  # and their open tickets, and the instance's adapters; `counts/2`'s two per source; and
  # the members', once, only for a person who may not take one of the three actions.
  # Everything empty, false or 0 to anyone else.
  @spec backlog_facts(Scope.t()) :: facts
  def backlog_facts(%Scope{} = scope) do
    case workspace(scope) do
      {:ok, organisation_id, %Workspace{id: workspace_id} = workspace} ->
        connections = connected(organisation_id)
        sources = sources(scope, connections, assigned_here(organisation_id, workspace_id))
        linked = linked(organisation_id, workspace_id)
        may = may(scope)

        %{
          connected?: connections != [],
          listed?: Enum.any?(connections, fn {connection, _adapter} -> connection.listed_at end),
          integrations: Enum.map(sources, &Map.take(&1, [:name, :id])),
          sources: sources,
          assigned_collections: sum(sources, :assigned),
          linked_collections: sum(sources, :linked),
          switched_off: sum(sources, :switched_off),
          without_items: sum(sources, :without_items),
          collection_nouns: assigned_nouns(sources),
          linked: linked,
          open_tickets: open_tickets(organisation_id, workspace_id),
          take_in?: take_in?(organisation_id, workspace),
          offered: offered(scope, connections),
          may: may,
          ask: ask(scope, may)
        }

      :error ->
        no_facts()
    end
  end

  # The facts of a person who may not read the workspace's work items.
  defp no_facts do
    %{
      connected?: false,
      listed?: false,
      integrations: [],
      sources: [],
      assigned_collections: 0,
      linked_collections: 0,
      switched_off: 0,
      without_items: 0,
      collection_nouns: [],
      linked: [],
      open_tickets: 0,
      take_in?: false,
      offered: [],
      may: %{install: false, assign: false, switch: false},
      ask: %{install: [], assign: [], switch: []}
    }
  end

  @doc false
  # collection_nouns/1 is the words of the sources of the scope's workspace for their
  # collections, to a person who may read its work items: of each adapter with items
  # through which a connected connection has a live collection assigned to the
  # workspace, by name, `Apiary.Adapters.collection_noun/1`, each once (nil, the
  # source's that names none, too). The sources of `backlog_facts/1`'s
  # `collection_nouns`; `[]` to anyone else.
  @spec collection_nouns(Scope.t()) :: [noun]
  def collection_nouns(%Scope{} = scope) do
    case workspace(scope) do
      {:ok, organisation_id, %Workspace{id: workspace_id}} ->
        Repo.all(
          from n in Node,
            join: c in Collection,
            on: c.adapter_id == n.id,
            join: k in Connection,
            on: k.id == c.connection_id and k.organisation_id == c.organisation_id,
            where:
              c.organisation_id == ^organisation_id and c.workspace_id == ^workspace_id and
                n.items and is_nil(c.ended_at) and k.state == :connected and
                is_nil(k.ended_at),
            distinct: [asc: n.name, asc: n.public_id],
            order_by: [asc: n.name, asc: n.public_id]
        )
        |> Enum.map(&Adapters.collection_noun/1)
        |> Enum.uniq()

      :error ->
        []
    end
  end

  # The organisation's connected connections, each with its adapter, by the adapter's
  # name.
  defp connected(organisation_id) do
    Repo.all(
      from k in Connection,
        join: n in Node,
        on: n.id == k.adapter_id,
        where:
          k.organisation_id == ^organisation_id and k.state == :connected and
            is_nil(k.ended_at),
        order_by: [asc: n.name, asc: n.public_id, asc: k.id],
        select: {k, n}
    )
  end

  # The live collections of a connected connection assigned to the workspace, counted by
  # adapter in one query: all of them, the linked ones, those with items and their
  # Backlog off, and those without items.
  defp assigned_here(organisation_id, workspace_id) do
    Repo.all(
      from c in Collection,
        join: k in Connection,
        on: k.id == c.connection_id and k.organisation_id == c.organisation_id,
        where:
          c.organisation_id == ^organisation_id and c.workspace_id == ^workspace_id and
            is_nil(c.ended_at) and k.state == :connected and is_nil(k.ended_at),
        group_by: c.adapter_id,
        select:
          {c.adapter_id,
           %{
             assigned: count(c.id),
             linked: filter(count(c.id), c.backlog and c.items),
             switched_off: filter(count(c.id), not c.backlog and c.items),
             without_items: filter(count(c.id), not c.items)
           }}
    )
    |> Map.new()
  end

  # The sources: the connected connections through an adapter with items, one per adapter.
  defp sources(scope, connections, here) do
    for {connection, adapter} <- Enum.uniq_by(connections, fn {_k, n} -> n.id end),
        adapter.items do
      counts = Collections.counts(scope, connection)

      Map.merge(
        %{
          name: Adapters.title(adapter),
          id: adapter.public_id,
          item_noun: Adapters.item_noun(adapter),
          collection_noun: Adapters.collection_noun(adapter),
          listed?: not is_nil(connection.listed_at),
          listing_complete?: Collections.listing_complete?(connection),
          collections: counts.total,
          unassigned: counts.unassigned
        },
        Map.get(here, adapter.id, @no_here)
      )
    end
  end

  defp sum(sources, key), do: sources |> Enum.map(&Map.fetch!(&1, key)) |> Enum.sum()

  # The sources' words for their collections, each once in the sources' order, with how
  # many collections assigned to the workspace each counts.
  defp assigned_nouns(sources) do
    assigned = Enum.filter(sources, &(&1.assigned > 0))

    for noun <- assigned |> Enum.map(& &1.collection_noun) |> Enum.uniq() do
      {noun, assigned |> Enum.filter(&(&1.collection_noun == noun)) |> sum(:assigned)}
    end
  end

  # The first linked collections of the workspace, with their open tickets.
  defp linked(organisation_id, workspace_id) do
    rows =
      Repo.all(
        from c in Collection,
          join: k in Connection,
          on: k.id == c.connection_id and k.organisation_id == c.organisation_id,
          join: n in Node,
          on: n.id == c.adapter_id,
          where:
            c.organisation_id == ^organisation_id and c.workspace_id == ^workspace_id and
              c.backlog and c.items and n.items and is_nil(c.ended_at) and
              k.state == :connected and is_nil(k.ended_at),
          order_by: [asc: n.name, asc: n.public_id, asc: c.title, asc: c.id],
          limit: @most_linked,
          select: {c, k.listing_completed_at, n}
      )

    ids = Enum.map(rows, fn {collection, _at, _adapter} -> collection.id end)

    open =
      organisation_id
      |> backlog(workspace_id)
      |> where([item: i, collection: c], i.state == :open and c.id in ^ids)
      |> group_by([collection: c], c.id)
      |> select([item: i, collection: c], {c.id, count(i.id)})
      |> Repo.all()
      |> Map.new()

    for {collection, completed_at, adapter} <- rows do
      %{
        id: collection.public_id,
        title: collection.title,
        integration: %{name: Adapters.title(adapter), id: adapter.public_id},
        item_noun: Adapters.item_noun(adapter),
        collection_noun: Adapters.collection_noun(adapter),
        listing_complete?: not is_nil(completed_at),
        open_tickets: Map.get(open, collection.id, 0)
      }
    end
  end

  defp open_tickets(organisation_id, workspace_id) do
    organisation_id
    |> backlog(workspace_id)
    |> where([item: i], i.state == :open)
    |> select([item: i], count(i.id))
    |> Repo.one()
  end

  # Whether Take in may take a ticket of the Open view: any, where the workspace's domain
  # needs no target, else one with a target, the ticket's, else its collection's, as Take
  # in reads it (`Apiary.WorkItems.Moves`).
  defp take_in?(organisation_id, %Workspace{id: workspace_id} = workspace) do
    open = organisation_id |> backlog(workspace_id) |> view(:open)

    if Domain.target_required?(workspace) do
      open
      |> where(
        [item: i, collection: c],
        not is_nil(i.target_system) or not is_nil(c.target_system)
      )
      |> Repo.exists?()
    else
      Repo.exists?(open)
    end
  end

  # The instance's adapters with items that no connected connection of the organisation
  # goes through and that serve the workspace's domain, by name.
  defp offered(scope, connections) do
    connected = MapSet.new(connections, fn {_connection, adapter} -> adapter.id end)

    for adapter <- Adapters.list_adapters(scope),
        adapter.items,
        not MapSet.member?(connected, adapter.id),
        Domain.serves?(adapter.domains, scope.workspace) do
      %{
        name: Adapters.title(adapter),
        id: adapter.public_id,
        item_noun: Adapters.item_noun(adapter),
        collection_noun: Adapters.collection_noun(adapter)
      }
    end
  end

  @actions %{
    install: :"adapter.connect",
    assign: :"collection.assign",
    switch: :"collection.set_backlog"
  }

  defp may(%Scope{organisation: organisation} = scope),
    do: Map.new(@actions, fn {key, action} -> {key, Access.can?(scope, action, organisation)} end)

  # For each action the person may not take, who may: the short names of the members whose
  # level holds it, as `ApiaryWeb.SettingsLive` reads a level's actions.
  defp ask(scope, may) do
    if Enum.all?(may, fn {_key, may?} -> may? end) do
      Map.new(@actions, fn {key, _action} -> {key, []} end)
    else
      roles = Access.roles()

      members =
        for %{suspended_at: nil, user: %User{deleted_at: nil} = user} = member <-
              Organisations.list_members(scope),
            do: {member.level, People.short(People.email(user))}

      Map.new(@actions, fn {key, action} ->
        names =
          if Map.fetch!(may, key),
            do: [],
            else: for({level, name} <- members, action in Map.get(roles, level, []), do: name)

        {key, names}
      end)
    end
  end

  ## Changes

  @doc false
  # subscribe/1 subscribes the caller to the topic of the Backlog of the scope's workspace
  # (`Apiary.Sources.Topic.topic/1`), for a person who may read its work items
  # (`work_item.read`, asked of the person as they are now): `:ok`, or `Apiary.Access`'s
  # refusal; `{:error, :not_found}` for a scope with no workspace.
  @spec subscribe(Scope.t()) :: :ok | {:error, Access.reason()}
  def subscribe(%Scope{workspace: %Workspace{id: workspace_id} = workspace} = scope) do
    with :ok <- Access.authorize(scope, :"work_item.read", workspace),
         do: Phoenix.PubSub.subscribe(Apiary.PubSub, Topic.topic(workspace_id))
  end

  def subscribe(%Scope{}), do: {:error, :not_found}

  # The scope's organisation's id and its workspace, when the scope's person may read the
  # workspace's work items; `:error` otherwise.
  defp workspace(
         %Scope{
           organisation: %Organisation{id: organisation_id},
           workspace: %Workspace{organisation_id: organisation_id} = workspace
         } = scope
       ) do
    if Access.can?(scope, :"work_item.read", workspace),
      do: {:ok, organisation_id, workspace},
      else: :error
  end

  defp workspace(%Scope{}), do: :error
end
