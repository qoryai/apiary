defmodule Apiary.WorkItems.WorkList do
  # WorkList reads the Work items list of a workspace for people
  # (`ApiaryWeb.WorkItemListComponents`): a page of its work items, by view, stage, search
  # and filters, with the count of each view and of each stage; the Open view's stage
  # bands; the values the Filter menu offers; and how many work items wait for the
  # reader, the sidebar's count.
  #
  # **Who reads it.** Every read asks `work_item.read` of the scope's workspace first
  # (`Apiary.Access.can?/3`, from the scope as it was loaded), and answers an empty page,
  # every count 0, to anyone else.
  #
  # **The status.** Where Explore stands for each work item comes from
  # `Apiary.WorkItems.Explore.with_status/1`, in the same query: a run whose outcome is
  # not stored yet reads as running there until it is. A live work item's stage follows
  # from it (`Apiary.WorkItems.Explore.stage/1`): Confirm while Qory's proposal waits,
  # Shape once confirmed, Explore otherwise.
  #
  # **Views:** `:open`, the live work items, of one stage with `stage:`; `:you`, those that
  # wait for the reader: the live work items the reader owns whose proposal waits at
  # Confirm, as the sidebar counts them (`waiting_on/1`); `:declined`; `:closed`, those
  # closed or undone. The counts of each view and each stage come from one grouped query,
  # under the same search and filters as the page, without its view and stage.
  #
  # **A row** is a plain map: the work item's public id (`id`), its number in the
  # workspace, its title as taken in, its ticket's key at the source or nil, shown as text
  # and never parsed, the title of the collection that holds its ticket (`repository`, as
  # `Apiary.WorkItems.ticket_names/2` names it), the name of the integration its ticket
  # came through (`integration`), its state and take in, where Explore stands for it
  # (`status`; for an ended one, that of its last take in), the attempt and the run limit
  # of its take in's latest run (`attempt`, `of`, nil before its first run), its owner's
  # account id, when it was taken in (`taken_in_at`, at its latest take in), created
  # (`inserted_at`) and last changed, and for an ended one when and by whom it ended
  # (`ended_at`, `ended_by_id`, nil where no person did), with the reason the instance
  # gave where it closed the work item (`ended_reason`, nil otherwise). The ticket's ref
  # at the source is never in a row.
  #
  # **Order and pages.** The rows go by the sort, from the latest changed to the earliest
  # (`:updated`, the default) or from the latest created to the earliest (`:created`),
  # then by public id; those of `:you` from the earliest changed, oldest first, whatever
  # the sort. At most `page_size/0` a page. A cursor names a row's place in its sort
  # alone: `u.` and its last change, or `c.` and when it was created, in microseconds
  # since 1970, then `.` and its public id, opaque to the page; a cursor of the other sort
  # matches nothing. `next` is the cursor of the page after, nil for the last, and `prev`
  # that of the page before, nil for the first.
  #
  # **The bands** (`bands/3`) are the Open view by stage: at most `band_size/0` rows of
  # each stage, those that wait for the reader first, then by the sort.
  #
  # Every input a person gives (a search, a filter value, a cursor) is bounded and checked
  # before a query reads it.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  import Ecto.Query, warn: false

  alias Apiary.{Access, Repo, WorkItems}
  alias Apiary.Accounts.Scope
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Runs.Filters
  alias Apiary.WorkItems.{Explore, WorkItem, WorkItemEvent}

  @page_size 50
  @band_size 8
  @max_offered 100
  @max_search 1024
  @max_filter_values 100
  @max_title 1024
  @views [:open, :you, :declined, :closed]
  @sorts [:updated, :created]
  @stages [:explore, :confirm, :shape]
  @explore_statuses [:queued, :running, :questions, :no_result, :lost, :cancelled, :used_up]
  @no_counts %{open: 0, you: 0, declined: 0, closed: 0}
  @no_stages %{
    explore: 0,
    confirm: 0,
    shape: 0,
    exploring: 0,
    answers: 0,
    no_result: 0,
    waiting: 0,
    waiting_you: 0,
    ready: 0
  }
  @no_page %{
    rows: [],
    counts: @no_counts,
    stages: @no_stages,
    first: 1,
    next: nil,
    prev: nil
  }
  @no_bands %{
    bands: %{explore: [], confirm: [], shape: []},
    counts: @no_counts,
    stages: @no_stages
  }
  # The microseconds since 1970 a cursor's time may name: from the year 1 to the year 9999.
  @cursor_microseconds -62_135_596_800_000_000..253_402_300_799_999_999

  @typedoc "A view of the Work items list."
  @type view :: :open | :you | :declined | :closed

  @typedoc "An order of the list: by the last change, or by when the work item was created."
  @type sort :: :updated | :created

  @typedoc "A stage of a live work item."
  @type stage :: :explore | :confirm | :shape

  @typedoc "A work item as the list draws it."
  @type row :: %{
          id: String.t(),
          number: pos_integer,
          title: String.t(),
          key: String.t() | nil,
          repository: String.t(),
          integration: String.t(),
          state: Apiary.WorkItems.State.state(),
          take_in: pos_integer,
          status: Explore.status(),
          attempt: pos_integer | nil,
          of: pos_integer | nil,
          owner_id: Ecto.UUID.t(),
          taken_in_at: DateTime.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t(),
          ended_at: DateTime.t() | nil,
          ended_by_id: Ecto.UUID.t() | nil,
          ended_reason: String.t() | nil
        }

  @typedoc "How many work items each view holds."
  @type counts :: %{
          open: non_neg_integer,
          you: non_neg_integer,
          declined: non_neg_integer,
          closed: non_neg_integer
        }

  @typedoc """
  The live work items in each stage, and what in each needs a look: how many Qory is
  exploring (`exploring`), how many wait for answers (`answers`), how many Explore left
  without a result (`no_result`: no result, lost or cancelled), how many wait at Confirm
  (`waiting`) and how many of those for the reader (`waiting_you`), and how many are
  ready for Shape (`ready`).
  """
  @type stages :: %{
          explore: non_neg_integer,
          confirm: non_neg_integer,
          shape: non_neg_integer,
          exploring: non_neg_integer,
          answers: non_neg_integer,
          no_result: non_neg_integer,
          waiting: non_neg_integer,
          waiting_you: non_neg_integer,
          ready: non_neg_integer
        }

  @typedoc """
  A page of the list: its rows, the counts of the views and the stages, the place of its
  first row in the whole list, from 1, and the cursors after and before.
  """
  @type page :: %{
          rows: [row],
          counts: counts,
          stages: stages,
          first: pos_integer,
          next: String.t() | nil,
          prev: String.t() | nil
        }

  @typedoc "The Open view by stage: each stage's first rows, with the counts."
  @type bands :: %{bands: %{stage => [row]}, counts: counts, stages: stages}

  @typedoc "A value the Filter menu offers: its key, and how many work items have it."
  @type value :: %{key: String.t(), count: non_neg_integer}

  # page_size/0 is the rows a page holds at most.
  @doc false
  @spec page_size() :: pos_integer
  def page_size, do: @page_size

  # band_size/0 is the rows a band of the Open view holds at most.
  @doc false
  @spec band_size() :: pos_integer
  def band_size, do: @band_size

  # list/3 is a page of the list of the scope's workspace, to a person who may read its
  # work items, and an empty page to anyone else. `params`, a map or a keyword list, with
  # atom keys or their strings:
  #
  #   * `view:` one of `t:view/0` (`:open` by default), or its string;
  #   * `stage:` one of `t:stage/0`, or its string: in the view `:open`, the work items of
  #     that stage alone; any other value matches nothing, and so does a stage in another
  #     view;
  #   * `search:` text the title or the ticket's key holds, any case, its `%`, `_` and
  #     `\` as they are, or the work item's number, with or without a `#` before it; at
  #     most 1,024 characters of valid UTF-8 with no NUL, else nothing matches;
  #   * `owner:` an owner's account id, or a list of them;
  #   * `collection:` the title of a collection, as a row names it, or a list of them;
  #   * `updated:` a window the runs list offers, by its value (`1h`, `24h`, `7d`, `14d`
  #     or `30d`): the work items last changed at or after that long before `now`;
  #   * `sort:` one of `t:sort/0` (`:updated` by default), or its string; the view `:you`
  #     goes by the last change, oldest first, whatever the sort;
  #   * `after:` the cursor of the page before (`next`), for the page after it;
  #   * `before:` the cursor of the page after (`prev`), for the page before it.
  #
  # A filter takes at most 100 values; one with more, or with a value that is not one,
  # matches nothing, and so does a cursor not in the shape this module gives, a cursor of
  # the other sort, and `after:` and `before:` together. An empty filter, an empty stage
  # or an empty cursor is none. A view it does not know is `:open`, and a sort it does not
  # know `:updated`.
  @doc false
  @spec list(Scope.t(), map | keyword, DateTime.t()) :: page
  def list(scope, params, now \\ DateTime.utc_now())

  def list(%Scope{} = scope, params, %DateTime{} = now)
      when is_map(params) or is_list(params) do
    case workspace(scope) do
      {:ok, organisation_id, workspace_id} ->
        params = normalise(params)
        reader = scope.user.id
        filtered = filtered(organisation_id, workspace_id, params, now)

        filtered
        |> view(params.view, reader)
        |> stage(params.view, params.stage)
        |> page(params, order(params))
        |> Map.merge(counts(filtered, reader))

      :error ->
        @no_page
    end
  end

  def list(%Scope{}, _params, _now), do: @no_page

  # bands/3 is the Open view of the scope's workspace by stage, to a person who may read
  # its work items, under the search and the filters of `params` as `list/3` reads them
  # (its view, stage and cursors aside): each stage's first `band_size/0` rows, the work
  # items that wait for the reader first, then by its sort; with the counts of the views
  # and the stages. Nothing to anyone else.
  @doc false
  @spec bands(Scope.t(), map | keyword, DateTime.t()) :: bands
  def bands(scope, params, now \\ DateTime.utc_now())

  def bands(%Scope{} = scope, params, %DateTime{} = now)
      when is_map(params) or is_list(params) do
    case workspace(scope) do
      {:ok, organisation_id, workspace_id} ->
        params = normalise(params)
        reader = scope.user.id
        filtered = filtered(organisation_id, workspace_id, params, now)
        open = view(filtered, :open, reader)

        bands =
          Map.new(@stages, fn stage ->
            rows =
              open
              |> stage(:open, stage)
              |> order_by([work_item: w, explore_status: s],
                desc:
                  fragment(
                    "(? = 'confirm' AND ? = ?)",
                    s.status,
                    w.owner_id,
                    type(^reader, :binary_id)
                  )
              )
              |> rows({params.sort, :desc}, @band_size)

            {stage, rows}
          end)

        Map.put(counts(filtered, reader), :bands, bands)

      :error ->
        @no_bands
    end
  end

  def bands(%Scope{}, _params, _now), do: @no_bands

  # waiting_on/1 is how many live work items of the scope's workspace wait for the scope's
  # person, the view `:you` with no search and no filter: those the person owns whose
  # proposal waits at Confirm. 0 to a person who may not read its work items.
  @doc false
  @spec waiting_on(Scope.t()) :: non_neg_integer
  def waiting_on(%Scope{} = scope) do
    case workspace(scope) do
      {:ok, organisation_id, workspace_id} ->
        organisation_id
        |> work_items(workspace_id)
        |> view(:you, scope.user.id)
        |> select([work_item: w], count(w.id))
        |> Repo.one()

      :error ->
        0
    end
  end

  # filter_values/3 is what the Filter menu offers for `kind` in the scope's workspace,
  # to a person who may read its work items: the owners of its work items, by account id
  # (`:owner`), or the titles of the collections that hold their tickets (`:collection`),
  # most work items first, at most 100. `query`, unless nil or blank, keeps the
  # collections whose title holds it, any case, as a search reads it; the page names the
  # owners, so it narrows them itself. None to anyone else.
  @doc false
  @spec filter_values(Scope.t(), :owner | :collection, String.t() | nil) :: [value]
  def filter_values(%Scope{} = scope, kind, query) when kind in [:owner, :collection] do
    with {:ok, organisation_id, workspace_id} <- workspace(scope),
         pattern when pattern != :none <- pattern(query) do
      organisation_id
      |> work_items(workspace_id)
      |> offered(kind, pattern)
    else
      _nothing -> []
    end
  end

  defp offered(query, :owner, _pattern) do
    query
    |> group_by([work_item: w], w.owner_id)
    |> order_by([work_item: w], desc: count(w.id), asc: w.owner_id)
    |> limit(@max_offered)
    |> select([work_item: w], %{key: w.owner_id, count: count(w.id)})
    |> Repo.all()
  end

  defp offered(query, :collection, pattern) do
    query =
      case pattern do
        {pattern, _number} ->
          where(
            query,
            [work_item: w, ticket: t],
            ilike(coalesce(t.title, w.collection_title), ^pattern)
          )

        nil ->
          query
      end

    query
    |> group_by([work_item: w, ticket: t], coalesce(t.title, w.collection_title))
    |> order_by([work_item: w, ticket: t],
      desc: count(w.id),
      asc: coalesce(t.title, w.collection_title)
    )
    |> limit(@max_offered)
    |> select([work_item: w, ticket: t], %{
      key: coalesce(t.title, w.collection_title),
      count: count(w.id)
    })
    |> Repo.all()
  end

  defp workspace(
         %Scope{
           organisation: %Organisation{id: organisation_id},
           workspace: %Workspace{organisation_id: organisation_id} = workspace
         } = scope
       ) do
    if Access.can?(scope, :"work_item.read", workspace),
      do: {:ok, organisation_id, workspace.id},
      else: :error
  end

  defp workspace(%Scope{}), do: :error

  defp filtered(organisation_id, workspace_id, params, now) do
    organisation_id
    |> work_items(workspace_id)
    |> search(params.search)
    |> owners(params.owner)
    |> collections(params.collection)
    |> updated(params.updated, now)
  end

  # The work items of the workspace, each with its ticket (`:ticket`), its latest undo or
  # close (`:ended`), and where Explore stands for it (`:explore_status`).
  defp work_items(organisation_id, workspace_id) do
    from(w in WorkItem,
      as: :work_item,
      left_lateral_join: t in subquery(WorkItems.ticket_query()),
      as: :ticket,
      on: true,
      left_lateral_join:
        e in subquery(
          from e in WorkItemEvent,
            where: e.work_item_id == parent_as(:work_item).id and e.kind in [:undone, :closed],
            order_by: [desc: e.at, desc: e.id],
            limit: 1,
            select: %{
              kind: e.kind,
              at: e.at,
              actor_id: e.actor_id,
              reason: fragment("?->>'reason'", e.data)
            }
        ),
      as: :ended,
      on: true,
      where: w.organisation_id == ^organisation_id and w.workspace_id == ^workspace_id
    )
    |> Explore.with_status()
  end

  defp view(query, :open, _reader), do: where(query, [work_item: w], w.state == :exploring)

  # The reader's live work items whose proposal waits at Confirm.
  defp view(query, :you, reader),
    do:
      where(
        query,
        [work_item: w, explore_status: s],
        w.state == :exploring and w.owner_id == ^reader and
          s.status == ^Explore.status_name(:confirm)
      )

  defp view(query, :declined, _reader), do: where(query, [work_item: w], w.state == :declined)

  defp view(query, :closed, _reader),
    do: where(query, [work_item: w], w.state in [:closed, :undone])

  defp stage(query, :open, :explore),
    do: where(query, [explore_status: s], s.status in ^Explore.status_names(@explore_statuses))

  defp stage(query, :open, stage) when stage in [:confirm, :shape],
    do: where(query, [explore_status: s], s.status == ^Explore.status_name(stage))

  defp stage(query, _view, nil), do: query
  defp stage(query, _view, _stage), do: where(query, false)

  defp order(%{view: :you}), do: {:updated, :asc}
  defp order(%{sort: sort}), do: {sort, :desc}

  ## Search and filters

  defp search(query, nil), do: query

  defp search(query, text) do
    case pattern(text) do
      nil ->
        query

      :none ->
        where(query, false)

      {pattern, nil} ->
        where(
          query,
          [work_item: w, ticket: t],
          ilike(w.title, ^pattern) or ilike(t.key, ^pattern)
        )

      {pattern, number} ->
        where(
          query,
          [work_item: w, ticket: t],
          ilike(w.title, ^pattern) or ilike(t.key, ^pattern) or w.number == ^number
        )
    end
  end

  # The ILIKE pattern of a search, and the number it names, if any: nil for none, `:none`
  # for one that matches nothing. Its size is bounded before anything else reads it, and
  # its `%`, `_` and `\` are escaped, so each matches itself.
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
        {"%" <> String.replace(text, ~r/[\\%_]/, "\\\\\\0") <> "%", number_in(text)}
    end
  end

  defp pattern(_text), do: :none

  defp number_in(text) do
    digits = String.trim_leading(text, "#")

    case byte_size(digits) <= 18 and Integer.parse(digits) do
      {number, ""} when number >= 1 -> number
      _not -> nil
    end
  end

  defp owners(query, nil), do: query

  defp owners(query, ids) do
    case cast_ids(ids) do
      {:ok, ids} -> where(query, [work_item: w], w.owner_id in ^ids)
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

  defp collections(query, nil), do: query

  defp collections(query, titles) do
    if is_list(titles) and length(titles) <= @max_filter_values and Enum.all?(titles, &title?/1),
      do:
        where(
          query,
          [work_item: w, ticket: t],
          coalesce(t.title, w.collection_title) in ^titles
        ),
      else: where(query, false)
  end

  defp title?(title) when is_binary(title) and byte_size(title) <= @max_title * 4,
    do:
      String.valid?(title) and not String.contains?(title, <<0>>) and
        String.length(title) in 1..@max_title

  defp title?(_title), do: false

  defp updated(query, nil, _now), do: query
  defp updated(query, :invalid, _now), do: where(query, false)

  defp updated(query, window, now) do
    since = DateTime.add(now, -Filters.window_seconds(window))
    where(query, [work_item: w], w.updated_at >= ^since)
  end

  ## Pages

  # `order` is the list's: its sort, and `:desc` from the latest, or `:asc` from the
  # earliest. A row behind a place comes after it in that order, one ahead of it before
  # it.
  # `first` is the place of the page's first row in the whole list, from 1.
  defp page(query, params, order) do
    page =
      case {params.after, params.before} do
        {nil, nil} -> first_page(query, order)
        {cursor, nil} -> later(query, cursor, order)
        {nil, cursor} -> earlier(query, cursor, order)
        {_after, _before} -> %{rows: [], next: nil, prev: nil}
      end

    Map.put(page, :first, first(query, page, order))
  end

  defp first(_query, %{prev: nil}, _order), do: 1

  defp first(query, %{rows: [row | _]}, order),
    do: Repo.aggregate(beyond(query, order, :ahead, position(row, order)), :count) + 1

  defp first(_query, _page, _order), do: 1

  defp first_page(query, order) do
    {rows, more} = query |> rows(order, @page_size + 1) |> Enum.split(@page_size)
    %{rows: rows, next: if(more != [], do: cursor(List.last(rows), order)), prev: nil}
  end

  defp later(query, cursor, order) do
    case parse_cursor(cursor, order) do
      {:ok, position} ->
        {rows, more} =
          query
          |> beyond(order, :behind, position)
          |> rows(order, @page_size + 1)
          |> Enum.split(@page_size)

        anchor = if rows == [], do: position, else: position(hd(rows), order)

        %{
          rows: rows,
          next: if(more != [], do: cursor(List.last(rows), order)),
          prev: if(Repo.exists?(beyond(query, order, :ahead, anchor)), do: encode(anchor, order))
        }

      :error ->
        %{rows: [], next: nil, prev: nil}
    end
  end

  defp earlier(query, cursor, order) do
    with {:ok, position} <- parse_cursor(cursor, order),
         reversed =
           query |> beyond(order, :ahead, position) |> rows(reverse(order), @page_size + 1),
         {page, [_more | _]} <- Enum.split(reversed, @page_size) do
      rows = Enum.reverse(page)
      last = position(List.last(rows), order)

      %{
        rows: rows,
        next: if(Repo.exists?(beyond(query, order, :behind, last)), do: encode(last, order)),
        prev: cursor(hd(rows), order)
      }
    else
      :error -> %{rows: [], next: nil, prev: nil}
      {_page, []} -> first_page(query, order)
    end
  end

  defp reverse({sort, :desc}), do: {sort, :asc}
  defp reverse({sort, :asc}), do: {sort, :desc}

  # The column a sort goes by.
  defp sort_field(:updated), do: :updated_at
  defp sort_field(:created), do: :inserted_at

  # At most `limit` rows of the query in `order`, after any order the query has, each
  # with its integration and its take in's latest run.
  defp rows(query, {sort, direction}, limit) do
    sort_field = sort_field(sort)

    query
    |> join(:inner, [work_item: w], n in Node, on: n.id == w.adapter_id, as: :adapter)
    |> join(
      :left_lateral,
      [work_item: w],
      r in subquery(
        from d in DispatchRun,
          where:
            d.work_item_id == parent_as(:work_item).id and
              d.take_in == parent_as(:work_item).take_in,
          order_by: [desc: d.attempt],
          limit: 1,
          select: %{attempt: d.attempt, of: d.of}
      ),
      on: true,
      as: :latest_run
    )
    |> order_by([work_item: w], [
      {^direction, field(w, ^sort_field)},
      {^direction, w.public_id}
    ])
    |> limit(^limit)
    |> select(
      [work_item: w, ticket: t, ended: e, explore_status: s, adapter: n, latest_run: r],
      %{
        id: w.public_id,
        number: w.number,
        title: w.title,
        key: t.key,
        repository: coalesce(t.title, w.collection_title),
        integration: n.name,
        state: w.state,
        take_in: w.take_in,
        status: s.status,
        attempt: r.attempt,
        of: r.of,
        owner_id: w.owner_id,
        taken_in_at: w.taken_in_at,
        inserted_at: w.inserted_at,
        updated_at: w.updated_at,
        ended_at:
          fragment(
            "CASE ? WHEN 'declined' THEN ? WHEN 'closed' THEN ? WHEN 'undone' THEN (CASE WHEN ? = 'undone' THEN ? END) END",
            w.state,
            w.declined_at,
            w.closed_at,
            e.kind,
            e.at
          ),
        ended_by_id:
          fragment(
            "CASE ? WHEN 'declined' THEN ? WHEN 'closed' THEN ? WHEN 'undone' THEN (CASE WHEN ? = 'undone' THEN ? END) END",
            w.state,
            w.declined_by_id,
            w.closed_by_id,
            e.kind,
            e.actor_id
          ),
        ended_reason:
          fragment(
            "CASE WHEN ? = 'closed' AND ? IS NULL AND ? = 'closed' THEN ? END",
            w.state,
            w.closed_by_id,
            e.kind,
            e.reason
          )
      }
    )
    |> Repo.all()
    |> Enum.map(&typed/1)
  end

  # The fragments come back as the database gives them: the time as a naive one, the id
  # as its bytes; the status as its name.
  defp typed(row) do
    %{
      row
      | state: if(is_binary(row.state), do: String.to_existing_atom(row.state), else: row.state),
        status: Explore.status_of(row.status),
        ended_at: utc(row.ended_at),
        ended_by_id: uuid(row.ended_by_id)
    }
  end

  defp utc(nil), do: nil
  defp utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")
  defp utc(%DateTime{} = at), do: at

  defp uuid(nil), do: nil
  defp uuid(<<_::128>> = raw), do: Ecto.UUID.load!(raw)
  defp uuid(id) when is_binary(id), do: id

  # The rows behind `position` in `order` (after it), or ahead of it (before it).
  defp beyond(query, {sort, direction}, side, position) do
    if {direction, side} in [{:desc, :behind}, {:asc, :ahead}],
      do: placed_before(query, sort_field(sort), position),
      else: placed_after(query, sort_field(sort), position)
  end

  defp placed_before(query, sort_field, {at, public_id}),
    do:
      where(
        query,
        [work_item: w],
        fragment(
          "(?, ?) < (?, ?)",
          field(w, ^sort_field),
          w.public_id,
          type(^at, :utc_datetime_usec),
          ^public_id
        )
      )

  defp placed_after(query, sort_field, {at, public_id}),
    do:
      where(
        query,
        [work_item: w],
        fragment(
          "(?, ?) > (?, ?)",
          field(w, ^sort_field),
          w.public_id,
          type(^at, :utc_datetime_usec),
          ^public_id
        )
      )

  defp position(row, {sort, _direction}), do: {Map.fetch!(row, sort_field(sort)), row.id}
  defp cursor(row, order), do: row |> position(order) |> encode(order)

  defp encode({%DateTime{} = at, public_id}, {sort, _direction}),
    do:
      mark(sort) <>
        "." <> Integer.to_string(DateTime.to_unix(at, :microsecond)) <> "." <> public_id

  # The mark a cursor of a sort starts with.
  defp mark(:updated), do: "u"
  defp mark(:created), do: "c"

  # The place a cursor names, or `:error` for a cursor not in the shape `encode/2` gives,
  # or of the other sort.
  defp parse_cursor(cursor, {sort, _direction})
       when is_binary(cursor) and byte_size(cursor) <= 64 do
    mark = mark(sort)

    with [^mark, micro, public_id] <- String.split(cursor, "."),
         {micro, ""} when micro in @cursor_microseconds <- Integer.parse(micro),
         true <- Apiary.PublicId.valid?(WorkItem.prefix(), public_id),
         {:ok, at} <- DateTime.from_unix(micro, :microsecond) do
      {:ok, {at, public_id}}
    else
      _not -> :error
    end
  end

  defp parse_cursor(_cursor, _order), do: :error

  # How many work items of the query each view and each stage holds, by one grouped
  # query: by state and status, with how many of each the reader owns.
  defp counts(query, reader) do
    query
    |> exclude(:select)
    |> group_by([work_item: w, explore_status: s], [w.state, s.status])
    |> select([work_item: w, explore_status: s], {
      w.state,
      s.status,
      count(w.id),
      filter(count(w.id), w.owner_id == ^reader)
    })
    |> Repo.all()
    |> Enum.reduce(%{counts: @no_counts, stages: @no_stages}, fn {state, status, n, mine}, acc ->
      add(acc, state, Explore.status_of(status), n, mine)
    end)
  end

  defp add(acc, :exploring, status, n, mine) do
    acc
    |> bump(:counts, :open, n)
    |> bump(:stages, Explore.stage(status), n)
    |> attention(status, n, mine)
  end

  defp add(acc, :declined, _status, n, _mine), do: bump(acc, :counts, :declined, n)

  defp add(acc, state, _status, n, _mine) when state in [:closed, :undone],
    do: bump(acc, :counts, :closed, n)

  defp attention(acc, :running, n, _mine), do: bump(acc, :stages, :exploring, n)
  defp attention(acc, :questions, n, _mine), do: bump(acc, :stages, :answers, n)

  defp attention(acc, status, n, _mine) when status in [:no_result, :lost, :cancelled],
    do: bump(acc, :stages, :no_result, n)

  defp attention(acc, :confirm, n, mine) do
    acc
    |> bump(:stages, :waiting, n)
    |> bump(:stages, :waiting_you, mine)
    |> bump(:counts, :you, mine)
  end

  defp attention(acc, :shape, n, _mine), do: bump(acc, :stages, :ready, n)
  defp attention(acc, _status, _n, _mine), do: acc

  defp bump(acc, group, key, n), do: update_in(acc, [group, key], &(&1 + n))

  ## Parameters

  defp normalise(params) do
    params = Map.new(params, fn {key, value} -> {to_string(key), value} end)

    %{
      view: view_of(params["view"]),
      stage: stage_of(params["stage"]),
      search: blank(params["search"]),
      owner: values(params["owner"]),
      collection: values(params["collection"]),
      updated: window(params["updated"]),
      sort: sort_of(params["sort"]),
      after: blank(params["after"]),
      before: blank(params["before"])
    }
  end

  defp view_of(view) when view in @views, do: view

  defp view_of(view) when is_binary(view),
    do: Enum.find(@views, :open, &(Atom.to_string(&1) == view))

  defp view_of(_view), do: :open

  defp sort_of(sort) when sort in @sorts, do: sort

  defp sort_of(sort) when is_binary(sort),
    do: Enum.find(@sorts, :updated, &(Atom.to_string(&1) == sort))

  defp sort_of(_sort), do: :updated

  defp stage_of(nil), do: nil
  defp stage_of(""), do: nil
  defp stage_of(stage) when stage in @stages, do: stage

  defp stage_of(stage) when is_binary(stage),
    do: Enum.find(@stages, :invalid, &(Atom.to_string(&1) == stage))

  defp stage_of(_stage), do: :invalid

  defp blank(nil), do: nil
  defp blank(""), do: nil
  defp blank(value), do: value

  defp values(nil), do: nil
  defp values([]), do: nil
  defp values(""), do: nil
  defp values(value) when is_binary(value), do: [value]
  defp values(values), do: values

  defp window(nil), do: nil
  defp window(""), do: nil

  defp window(value) when is_binary(value) do
    if Enum.any?(Filters.windows(), fn {_words, key} -> key == value end),
      do: value,
      else: :invalid
  end

  defp window(_value), do: :invalid
end
