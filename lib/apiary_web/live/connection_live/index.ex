defmodule ApiaryWeb.ConnectionLive.Index do
  @moduledoc """
  Where the runs of the hive reached out to (`docs/design/brief-runs.md`, rd13 and re6): one
  row per host, port and path across the runs in range, with the reason and the outcome of
  the most recent attempt, and behind each row's chevron the runs that reached it. "Per
  repository" is this page with `repo` set, which the runs list links to.

  Every filter is a query parameter (`decision`, `repo`, `host`, `since`, `from`, `to`,
  `page`), read through `Apiary.Runs.Filters`. A destination's runs are read only when its
  row opens, ten at a time. While batches land the table does not move under the reader:
  the summary gains "New activity", which asks again and keeps the open rows open.
  """
  use ApiaryWeb, :live_view

  alias Apiary.Runs
  alias Apiary.Runs.Filters

  @hits_page 10

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:connections}
      width="full"
    >
      <.header>
        Connections
        <:subtitle>
          Where the runs of this <.term word="hive" />
          reached out to, and what the policy made of it. One row per host, port and path, across runs.
          <span :if={@filters.repo} id="connections-repo-note">
            Showing
            <.mono>{repo_label(@filters.repo)}</.mono>
            only.
          </span>
        </:subtitle>
      </.header>

      <.notice :if={@load_error} kind={:error} class="max-w-[80ch]">
        <span id="connections-error">
          The connections could not be loaded. Reload the page; if it keeps happening, the server log has the reason.
        </span>
      </.notice>

      <.notice :if={@dropped != []} kind={:warning} class="max-w-[80ch]">
        <span id="connections-dropped">{dropped_sentence(@dropped)}</span>
      </.notice>

      <div :if={!@load_error} class="grid grid-cols-[minmax(0,1fr)] gap-6">
        <.filter_bar
          id="connections-filters"
          clear={Filters.any?(@filters) && path(Filters.clear(@filters))}
        >
          <.segments id="connections-decision" label="Decision">
            <:segment
              :for={{label, value} <- [{"All", nil}, {"Allowed", "allowed"}, {"Denied", "denied"}]}
              patch={path(Filters.put(@filters, decision: value))}
              pressed={@filters.decision == value}
            >
              {label}
            </:segment>
          </.segments>
          <.filter
            name="repo"
            total={facet_total(@facets, :repo)}
            query={@narrow["repo"]}
            label="Repository"
            value={Filters.repo_value(@filters.repo)}
            options={
              with_chosen(
                facet_options(@facets, :repo),
                Filters.repo_value(@filters.repo),
                repo_label(@filters.repo)
              )
            }
            remove={path(Filters.put(@filters, repo: nil))}
          />
          <.filter
            name="host"
            total={facet_total(@facets, :host)}
            query={@narrow["host"]}
            label="Host"
            value={@filters.host}
            options={with_chosen(facet_options(@facets, :host), @filters.host, @filters.host)}
            remove={path(Filters.put(@filters, host: nil))}
          />
          <.filter
            name="since"
            label="Seen"
            value={range_value(@filters)}
            value_label={Filters.range_label(@filters)}
            options={for {label, value} <- Filters.ranges(:connections), do: {label, value, nil}}
            dates={
              %{
                from: @filters.from && Date.to_iso8601(@filters.from),
                to: @filters.to && Date.to_iso8601(@filters.to)
              }
            }
            remove={
              @filters.since != "90d" && path(Filters.put(@filters, since: "90d", from: nil, to: nil))
            }
          />
          <:trailing>
            <span id="connections-summary" class="q-summary">
              <span :if={@listing}>
                <b>{delimited(@listing.summary.destinations)}</b>
                {if @listing.summary.destinations == 1, do: "destination", else: "destinations"}
              </span>
              <span :if={@listing && @listing.summary.denied > 0}>
                <b>{delimited(@listing.summary.denied)}</b> denied
              </span>
              <span :if={@listing}>
                <b>{delimited(@listing.summary.runs)}</b>
                {if @listing.summary.runs == 1, do: "run", else: "runs"}
              </span>
              <span :if={!@listing} class="skeleton q-skel w-44"></span>
              <.link :if={@stale} id="connections-refresh" phx-click="refresh" href="#">
                New activity
              </.link>
            </span>
          </:trailing>
        </.filter_bar>

        <div
          :if={@listing == nil}
          id="connections-loading"
          class="overflow-x-auto rounded-box border border-line bg-base-100 shadow-xs"
          aria-busy="true"
        >
          <table class="table q-cxt">
            <thead>
              <tr>
                <th :for={
                  label <-
                    [
                      "Destination",
                      "Runs",
                      "Attempts",
                      "Allowed / denied",
                      "Reason",
                      "Outcome",
                      "Last seen"
                    ]
                }>
                  {label}
                </th>
              </tr>
            </thead>
            <tbody>
              <tr :for={n <- 1..8}>
                <td>
                  <span class={["skeleton q-skel", if(rem(n, 2) == 0, do: "w-56", else: "w-44")]}></span>
                </td>
                <td><span class="skeleton q-skel w-6"></span></td>
                <td><span class="skeleton q-skel w-8"></span></td>
                <td><span class="skeleton q-skel w-24"></span></td>
                <td><span class="skeleton q-skel w-48"></span></td>
                <td><span class="skeleton q-skel w-16"></span></td>
                <td><span class="skeleton q-skel w-20"></span></td>
              </tr>
            </tbody>
          </table>
        </div>

        <.connections_table
          :if={@listing && @listing.rows != []}
          id="destinations"
          label="Connections of this hive"
          variant="hive"
          rows={@listing.rows}
          row_id={&destination_id/1}
          open={@open}
          run_path={&run_path/1}
        />

        <.empty_state
          :if={@listing && @listing.rows == []}
          icon="hero-arrows-right-left"
          tone="neutral"
          title={empty_title(@filters)}
        >
          <span id="connections-empty">
            {if narrowed?(@filters),
              do: "No destination matches them in this range.",
              else:
                "Widen the range, or wait for a run to reach out. Only programs that honour the proxy variables are seen."}
          </span>
          <:actions>
            <.button
              :if={narrowed?(@filters)}
              id="connections-clear"
              patch={path(Filters.clear(@filters))}
            >
              Clear filters
            </.button>
          </:actions>
        </.empty_state>

        <div
          :if={@listing && @listing.rows != []}
          class="flex flex-wrap items-center justify-between gap-3"
        >
          <p id="connections-footer" class="max-w-[80ch] text-[12.5px] text-faint">
            Denied destinations come first, then the most recent. The reason and outcome are those of the last attempt across the runs shown.
          </p>
          <div :if={@listing.pages > 1} class="flex items-center gap-2">
            <.button
              id="connections-previous"
              patch={path(%{@filters | page: @listing.page - 1})}
              disabled={@listing.page <= 1}
            >
              Previous
            </.button>
            <.button
              id="connections-next"
              patch={path(%{@filters | page: @listing.page + 1})}
              disabled={@listing.page >= @listing.pages}
            >
              Next
            </.button>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Runs.subscribe(socket.assigns.current_scope)

    {:ok,
     assign(socket,
       page_title: "Connections",
       filters: %Filters{kind: :connections},
       listing: nil,
       facets: %{},
       open: %{},
       stale: false,
       load_error: false,
       dropped: [],
       narrow: %{}
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = Filters.parse(params, :connections)

    if Filters.to_params(filters) == params do
      # What is open belongs to the view it was opened in.
      open = if Filters.same?(filters, socket.assigns.filters), do: socket.assigns.open, else: %{}
      {:noreply, socket |> keep_dropped() |> assign(filters: filters, open: open) |> load()}
    else
      {:noreply,
       socket
       |> assign(:dropped, filters.dropped)
       |> put_private(:rewrote, true)
       |> push_patch(to: path(%{filters | dropped: []}), replace: true)}
    end
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, push_patch(socket, to: path(Filters.change(socket.assigns.filters, params)))}
  end

  def handle_event("narrow", %{"_filter" => name, "q" => q}, socket)
      when name in ~w(repo host) and is_binary(q) do
    %{current_scope: scope, filters: filters} = socket.assigns
    narrow = Map.put(socket.assigns.narrow, name, String.slice(q, 0, 256))

    {:noreply,
     socket
     |> assign(:narrow, narrow)
     |> start_async(:facets, fn ->
       %{
         filters: filters,
         narrow: narrow,
         facets: Runs.destination_facets(scope, filters, narrow: narrow)
       }
     end)}
  end

  def handle_event("narrow", _params, socket), do: {:noreply, socket}

  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  def handle_event("toggle_destination", params, socket) do
    %{open: open} = socket.assigns

    case find_row(socket, params) do
      nil ->
        {:noreply, socket}

      row ->
        key = destination_key(row)

        if is_map_key(open, key),
          do: {:noreply, assign(socket, :open, Map.delete(open, key))},
          else:
            {:noreply, assign(socket, :open, Map.put(open, key, hits(socket, row, @hits_page)))}
    end
  end

  def handle_event("more_destination_runs", params, socket) do
    with %{} = row <- find_row(socket, params),
         key = destination_key(row),
         %{runs: shown} <- socket.assigns.open[key] do
      more = hits(socket, row, length(shown) + @hits_page)
      {:noreply, update(socket, :open, &Map.put(&1, key, more))}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_async(:load, {:ok, %{filters: filters} = loaded}, socket) do
    if filters == socket.assigns.filters do
      {:noreply,
       assign(socket,
         listing: loaded.listing,
         facets: loaded.facets,
         open: loaded.open,
         stale: false,
         load_error: false
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_async(:facets, {:ok, %{filters: filters, narrow: narrow, facets: facets}}, socket) do
    if filters == socket.assigns.filters and narrow == socket.assigns.narrow,
      do: {:noreply, assign(socket, :facets, facets)},
      else: {:noreply, socket}
  end

  def handle_async(:facets, {:exit, _reason}, socket), do: {:noreply, socket}

  def handle_async(:load, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, load_error: true)}

  @impl true
  def handle_info({:run_changed, _run}, socket) do
    if socket.assigns.listing && !socket.assigns.stale,
      do: {:noreply, assign(socket, :stale, true)},
      else: {:noreply, socket}
  end

  defp load(socket) do
    %{current_scope: scope, filters: filters, open: open, narrow: narrow} = socket.assigns

    if connected?(socket) do
      start_async(socket, :load, fn ->
        now = DateTime.utc_now()
        listing = Runs.page_destinations(scope, filters, now)

        # The rows that were open stay open, read again, for as long as they are on the page.
        open =
          for row <- listing.rows,
              key = destination_key(row),
              %{runs: shown} <- [open[key]],
              into: %{} do
            {key,
             Runs.destination_runs(scope, filters, {row.host, row.port, row.path},
               now: now,
               limit: max(length(shown), @hits_page)
             )}
          end

        %{
          filters: filters,
          listing: listing,
          facets: Runs.destination_facets(scope, filters, now: now, narrow: narrow),
          open: open
        }
      end)
    else
      socket
    end
  end

  defp hits(socket, row, limit) do
    %{current_scope: scope, filters: filters} = socket.assigns
    Runs.destination_runs(scope, filters, {row.host, row.port, row.path}, limit: limit)
  end

  # What the browser names is matched whole, host, port and path, against the rows the
  # page holds: never by a DOM id, and it only ever picks one of those rows.
  defp find_row(%{assigns: %{listing: %{rows: rows}}}, %{
         "host" => host,
         "port" => port,
         "path" => path
       })
       when is_binary(host) and is_binary(port) and is_binary(path) do
    Enum.find(rows, &(&1.host == host and Integer.to_string(&1.port) == port and &1.path == path))
  end

  defp find_row(_socket, _id), do: nil

  # The notice of a rewritten link stays for the view the rewrite led to, and goes with the
  # reader's next change.
  defp keep_dropped(socket) do
    if socket.private[:rewrote],
      do: put_private(socket, :rewrote, false),
      else: assign(socket, :dropped, [])
  end

  defp dropped_sentence([name]),
    do: "The link's #{name} filter could not be read, so it is not applied."

  defp dropped_sentence(names),
    do: "The link's #{Enum.join(names, ", ")} filters could not be read, so they are not applied."

  defp path(%Filters{} = filters), do: ~p"/hive/connections?#{Filters.to_params(filters)}"
  defp run_path(run), do: ~p"/hive/runs/#{run.run_id}/connections"

  defp narrowed?(%Filters{} = f), do: f.decision != nil or f.repo != nil or f.host != nil

  defp empty_title(%Filters{} = filters) do
    cond do
      narrowed?(filters) -> "No connections match these filters"
      label = Filters.range_label(filters) -> "No connections in the #{label}" |> tidy_range()
      true -> "No connections recorded"
    end
  end

  # "in the last 7 days" reads; "in the 14 Sep 2026 to 16 Sep 2026" does not.
  defp tidy_range("No connections in the last" <> _ = title), do: title
  defp tidy_range("No connections in the from " <> rest), do: "No connections from " <> rest
  defp tidy_range("No connections in the to " <> rest), do: "No connections up to " <> rest
  defp tidy_range("No connections in the " <> rest), do: "No connections in " <> rest

  defp facet_options(facets, name), do: (facets[name] || %{options: []}).options
  defp facet_total(facets, name), do: facets[name] && facets[name].total

  defp with_chosen(options, nil, _label), do: options || []

  defp with_chosen(options, value, label) do
    options = options || []

    if Enum.any?(options, fn {_label, v, _count} -> v == value end),
      do: options,
      else: [{label, value, 0} | options]
  end

  defp repo_label(:none), do: "Unassigned"
  defp repo_label({forge, path}), do: "#{forge}/#{path}"
  defp repo_label(nil), do: nil

  defp range_value(%Filters{from: nil, to: nil, since: "all"}), do: nil
  defp range_value(%Filters{from: nil, to: nil, since: since}), do: since
  defp range_value(%Filters{}), do: "dates"
end
