defmodule Apiary.WorkItems.WorkList do
  # WorkList reads the Work items list of a workspace for people
  # (`ApiaryWeb.WorkItemListComponents`): a page of its work items, by view, search and
  # filters, with the count of each view.
  #
  # **Who reads it.** Every read asks `work_item.read` of the scope's workspace first
  # (`Apiary.Access.can?/3`, from the scope as it was loaded), and answers an empty page,
  # every count 0, to anyone else.
  #
  # **Views:** `:open`, the live work items; `:you`, those that wait for the reader, none
  # before the member's step comes (`Apiary.WorkItems.count_waiting_on/1`); `:declined`;
  # `:closed`, those closed or undone. The counts of each view come from one grouped
  # query, under the same search and filters as the page, without its view.
  #
  # **A row** is a plain map: the work item's public id (`id`), its number in the
  # workspace, its title as taken in, its ticket's key at the source or nil, shown as text
  # and never parsed, the title of the collection that holds its ticket (`repository`, as
  # `Apiary.WorkItems.ticket_names/2` names it), its state and take in, its owner's
  # account id, when it was taken in and last changed, and for an ended one when and by
  # whom it ended (`ended_at`, `ended_by_id`, nil where no person did). The ticket's ref at
  # the source is never in a row.
  #
  # **Order and pages.** The rows go from the latest changed to the earliest, then by
  # public id, at most `page_size/0` a page. A cursor names a row's place in that order,
  # `u.`, its last change in microseconds since 1970, `.` and its public id, opaque to the
  # page; `next` is the cursor of the page after, nil for the last, and `prev` that of the
  # page before, nil for the first.
  #
  # Every input a person gives (a search, a filter value, a cursor) is bounded and checked
  # before a query reads it.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  import Ecto.Query, warn: false

  alias Apiary.{Access, Repo, WorkItems}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Runs.Filters
  alias Apiary.WorkItems.{WorkItem, WorkItemEvent}

  @page_size 50
  @max_search 1024
  @max_filter_values 100
  @max_title 1024
  @views [:open, :you, :declined, :closed]
  @no_counts %{open: 0, you: 0, declined: 0, closed: 0}
  @no_page %{rows: [], counts: @no_counts, next: nil, prev: nil}
  # The microseconds since 1970 a cursor's time may name: from the year 1 to the year 9999.
  @cursor_microseconds -62_135_596_800_000_000..253_402_300_799_999_999

  @typedoc "A view of the Work items list."
  @type view :: :open | :you | :declined | :closed

  @typedoc "A work item as the list draws it."
  @type row :: %{
          id: String.t(),
          number: pos_integer,
          title: String.t(),
          key: String.t() | nil,
          repository: String.t(),
          state: Apiary.WorkItems.State.state(),
          take_in: pos_integer,
          owner_id: Ecto.UUID.t(),
          taken_in_at: DateTime.t(),
          updated_at: DateTime.t(),
          ended_at: DateTime.t() | nil,
          ended_by_id: Ecto.UUID.t() | nil
        }

  @typedoc "How many work items each view holds."
  @type counts :: %{
          open: non_neg_integer,
          you: non_neg_integer,
          declined: non_neg_integer,
          closed: non_neg_integer
        }

  @typedoc "A page of the list: its rows, the counts, and the cursors after and before."
  @type page :: %{rows: [row], counts: counts, next: String.t() | nil, prev: String.t() | nil}

  # page_size/0 is the rows a page holds at most.
  @doc false
  @spec page_size() :: pos_integer
  def page_size, do: @page_size

  # list/3 is a page of the list of the scope's workspace, to a person who may read its
  # work items, and an empty page to anyone else. `params`, a map or a keyword list, with
  # atom keys or their strings:
  #
  #   * `view:` one of `t:view/0` (`:open` by default), or its string;
  #   * `search:` text the title or the ticket's key holds, any case, its `%`, `_` and
  #     `\` as they are, or the work item's number, with or without a `#` before it; at
  #     most 1,024 characters of valid UTF-8 with no NUL, else nothing matches;
  #   * `owner:` an owner's account id, or a list of them;
  #   * `repository:` the title of a collection, as a row names it, or a list of them;
  #   * `updated:` a window the runs list offers, by its value (`1h`, `24h`, `7d`, `14d`
  #     or `30d`): the work items last changed at or after that long before `now`;
  #   * `after:` the cursor of the page before (`next`), for the page after it;
  #   * `before:` the cursor of the page after (`prev`), for the page before it.
  #
  # A filter takes at most 100 values; one with more, or with a value that is not one,
  # matches nothing, and so does a cursor not in the shape this module gives, and
  # `after:` and `before:` together. An empty filter, or an empty cursor, is none. A view
  # it does not know is `:open`.
  @doc false
  @spec list(Scope.t(), map | keyword, DateTime.t()) :: page
  def list(scope, params, now \\ DateTime.utc_now())

  def list(%Scope{} = scope, params, %DateTime{} = now)
      when is_map(params) or is_list(params) do
    case workspace(scope) do
      {:ok, organisation_id, workspace_id} ->
        params = normalise(params)

        filtered =
          organisation_id
          |> work_items(workspace_id)
          |> search(params.search)
          |> owners(params.owner)
          |> repositories(params.repository)
          |> updated(params.updated, now)

        filtered
        |> view(params.view)
        |> page(params)
        |> Map.put(:counts, counts(filtered))

      :error ->
        @no_page
    end
  end

  def list(%Scope{}, _params, _now), do: @no_page

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

  # The work items of the workspace, each with its ticket (`:ticket`) and its latest undo
  # (`:undone`).
  defp work_items(organisation_id, workspace_id) do
    from w in WorkItem,
      as: :work_item,
      left_lateral_join: t in subquery(WorkItems.ticket_query()),
      as: :ticket,
      on: true,
      left_lateral_join:
        u in subquery(
          from e in WorkItemEvent,
            where: e.work_item_id == parent_as(:work_item).id and e.kind == :undone,
            order_by: [desc: e.at, desc: e.id],
            limit: 1,
            select: %{at: e.at, actor_id: e.actor_id}
        ),
      as: :undone,
      on: true,
      where: w.organisation_id == ^organisation_id and w.workspace_id == ^workspace_id
  end

  defp view(query, :open), do: where(query, [work_item: w], w.state == :exploring)
  # Nothing waits on a person before the member's step comes.
  defp view(query, :you), do: where(query, false)
  defp view(query, :declined), do: where(query, [work_item: w], w.state == :declined)

  defp view(query, :closed),
    do: where(query, [work_item: w], w.state in [:closed, :undone])

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

  defp repositories(query, nil), do: query

  defp repositories(query, titles) do
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

  defp page(query, params) do
    case {params.after, params.before} do
      {nil, nil} -> first_page(query)
      {cursor, nil} -> older(query, cursor)
      {nil, cursor} -> newer(query, cursor)
      {_after, _before} -> %{rows: [], next: nil, prev: nil}
    end
  end

  defp first_page(query) do
    {rows, more} = query |> fetch(:desc) |> Enum.split(@page_size)
    %{rows: rows, next: if(more != [], do: cursor(List.last(rows))), prev: nil}
  end

  defp older(query, cursor) do
    case parse_cursor(cursor) do
      {:ok, position} ->
        {rows, more} =
          query |> beyond(:behind, position) |> fetch(:desc) |> Enum.split(@page_size)

        anchor = if rows == [], do: position, else: position(hd(rows))

        %{
          rows: rows,
          next: if(more != [], do: cursor(List.last(rows))),
          prev: if(Repo.exists?(beyond(query, :ahead, anchor)), do: encode(anchor))
        }

      :error ->
        %{rows: [], next: nil, prev: nil}
    end
  end

  defp newer(query, cursor) do
    with {:ok, position} <- parse_cursor(cursor),
         reversed = query |> beyond(:ahead, position) |> fetch(:asc),
         {page, [_more | _]} <- Enum.split(reversed, @page_size) do
      rows = Enum.reverse(page)
      last = position(List.last(rows))

      %{
        rows: rows,
        next: if(Repo.exists?(beyond(query, :behind, last)), do: encode(last)),
        prev: cursor(hd(rows))
      }
    else
      :error -> %{rows: [], next: nil, prev: nil}
      {_page, []} -> first_page(query)
    end
  end

  defp fetch(query, order) do
    query
    |> order_by([work_item: w], [{^order, w.updated_at}, {^order, w.public_id}])
    |> limit(@page_size + 1)
    |> select([work_item: w, ticket: t, undone: u], %{
      id: w.public_id,
      number: w.number,
      title: w.title,
      key: t.key,
      repository: coalesce(t.title, w.collection_title),
      state: w.state,
      take_in: w.take_in,
      owner_id: w.owner_id,
      taken_in_at: w.taken_in_at,
      updated_at: w.updated_at,
      ended_at:
        fragment(
          "CASE ? WHEN 'declined' THEN ? WHEN 'closed' THEN ? WHEN 'undone' THEN ? END",
          w.state,
          w.declined_at,
          w.closed_at,
          u.at
        ),
      ended_by_id:
        fragment(
          "CASE ? WHEN 'declined' THEN ? WHEN 'closed' THEN ? WHEN 'undone' THEN ? END",
          w.state,
          w.declined_by_id,
          w.closed_by_id,
          u.actor_id
        )
    })
    |> Repo.all()
    |> Enum.map(&typed/1)
  end

  # The fragments come back as the database gives them: the time as a naive one, the id
  # as its bytes.
  defp typed(row) do
    %{
      row
      | state: if(is_binary(row.state), do: String.to_existing_atom(row.state), else: row.state),
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

  # The rows behind `position` (later in the order: changed earlier) or ahead of it.
  defp beyond(query, :behind, {at, public_id}),
    do:
      where(
        query,
        [work_item: w],
        fragment(
          "(?, ?) < (?, ?)",
          w.updated_at,
          w.public_id,
          type(^at, :utc_datetime_usec),
          ^public_id
        )
      )

  defp beyond(query, :ahead, {at, public_id}),
    do:
      where(
        query,
        [work_item: w],
        fragment(
          "(?, ?) > (?, ?)",
          w.updated_at,
          w.public_id,
          type(^at, :utc_datetime_usec),
          ^public_id
        )
      )

  defp position(row), do: {row.updated_at, row.id}
  defp cursor(row), do: row |> position() |> encode()

  defp encode({%DateTime{} = at, public_id}),
    do: "u." <> Integer.to_string(DateTime.to_unix(at, :microsecond)) <> "." <> public_id

  defp parse_cursor(cursor) when is_binary(cursor) and byte_size(cursor) <= 64 do
    with ["u", micro, public_id] <- String.split(cursor, "."),
         {micro, ""} when micro in @cursor_microseconds <- Integer.parse(micro),
         true <- Apiary.PublicId.valid?(WorkItem.prefix(), public_id),
         {:ok, at} <- DateTime.from_unix(micro, :microsecond) do
      {:ok, {at, public_id}}
    else
      _not -> :error
    end
  end

  defp parse_cursor(_cursor), do: :error

  # How many work items of the query each view holds, by one grouped query.
  defp counts(query) do
    query
    |> exclude(:select)
    |> group_by([work_item: w], w.state)
    |> select([work_item: w], {w.state, count(w.id)})
    |> Repo.all()
    |> Enum.reduce(@no_counts, fn
      {:exploring, n}, counts ->
        Map.update!(counts, :open, &(&1 + n))

      {:declined, n}, counts ->
        Map.update!(counts, :declined, &(&1 + n))

      {state, n}, counts when state in [:closed, :undone] ->
        Map.update!(counts, :closed, &(&1 + n))
    end)
  end

  ## Parameters

  defp normalise(params) do
    params = Map.new(params, fn {key, value} -> {to_string(key), value} end)

    %{
      view: view_of(params["view"]),
      search: blank(params["search"]),
      owner: values(params["owner"]),
      repository: values(params["repository"]),
      updated: window(params["updated"]),
      after: blank(params["after"]),
      before: blank(params["before"])
    }
  end

  defp view_of(view) when view in @views, do: view

  defp view_of(view) when is_binary(view),
    do: Enum.find(@views, :open, &(Atom.to_string(&1) == view))

  defp view_of(_view), do: :open

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
