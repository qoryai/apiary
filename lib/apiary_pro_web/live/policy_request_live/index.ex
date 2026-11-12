defmodule ApiaryProWeb.PolicyRequestLive.Index do
  @moduledoc """
  A client's policy requests, an organisation's page: `/:org/policy-requests`, for a
  reader who may `security_policy.read`, where `security` is on. The operator that
  provides the harness the client runs asks for changes to its security policy; the
  policy is the client's, and its people decide (`ApiaryPro.PolicyRequests`). In a client,
  the organisation's sidebar leads here (`ApiaryProWeb.Edition`), and so does the
  workspace's policy page while a request waits.

  The list is on the core's pattern (`docs/ui.md`, Lists), newest first: one row a
  request, its name (its note's first line) leading to its page, the operator that sent
  it, its first change, when it was sent and the client's answer. The views are All,
  Waiting, Answered and Withdrawn (`?view=`), counted under the search, `?q=`, words of the
  note or of a host, in the URL. The page reads the 200 newest requests, and says so when
  there are that many.

  A request's page, `/:org/policy-requests/:id` (`:id` the client's answer), holds its
  note, its changes in the words of the policy's history, and the answer. While it is
  pending, whoever may write the policy (`policy_request.accept`,
  `policy_request.decline`) chooses there the workspaces it goes into, every one they may
  write by default, and accepts it: the changes are made there as their writes of the
  policy, all or none, and a change that no longer fits says why. Or they decline it, with
  a reason or none, confirmed in place on its row, `/:org/policy-requests/:id/decline`,
  which the row's ⋯ menu and the request's page lead to, and whose Cancel goes back to the
  list. The operator's people read the page and answer nothing.
  """
  use ApiaryProWeb, :live_view
  use ApiaryWeb.Features, :security
  on_mount {ApiaryWeb.Access, :"security_policy.read"}

  import ApiaryProWeb.RequestComponents,
    only: [
      first_change: 1,
      request_changes: 1,
      request_lines: 1,
      request_name: 1,
      request_state: 1
    ]

  alias Apiary.{Access, Policy}
  alias ApiaryPro.PolicyRequests
  alias ApiaryProWeb.ConfirmComponents
  alias ApiaryWeb.{People, SettingsComponents, UserAuth}
  alias Phoenix.LiveView.AsyncResult

  @impl true
  # One request, its answer page: its name the title, the operator and the day it came,
  # its state; its note and changes; then the answer given, or the form that gives it.
  def render(%{live_action: :show} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:policy_requests}
      width="read"
    >
      <:crumb navigate={list_path(@current_scope, list_params(%{}))}>
        {gettext("Policy requests")}
      </:crumb>
      <:crumb :if={picked(@rows, @answer_id)}>
        {request_name(picked(@rows, @answer_id).request)}
      </:crumb>
      <:crumb :if={missing_id(@rows, @answer_id)}>
        {gettext("Request %{id}", id: missing_id(@rows, @answer_id))}
      </:crumb>

      <.async_result :let={rows} assign={@rows}>
        <:loading>
          <div id="received-loading" class="grid gap-3" aria-busy="true">
            <span class="sr-only">{gettext("Loading the policy requests")}</span>
            <span class="skeleton q-skel w-64"></span>
            <span class="skeleton q-skel w-48"></span>
          </div>
        </:loading>
        <:failed>
          <.notice kind={:error} class="max-w-[80ch]">
            <span id="received-error">
              {gettext(
                "The policy requests could not be loaded. Reload the page; if it keeps happening, Qory Apiary's log has the reason."
              )}
            </span>
          </.notice>
        </:failed>

        <div :if={is_nil(find(rows, @answer_id))} id="received-gone" class="grid gap-2">
          <p class="text-muted">
            {gettext("That request is not there, or is older than the 200 newest.")}
          </p>
          <p>
            <.link
              navigate={list_path(@current_scope, list_params(%{}))}
              class="text-accent hover:underline"
            >
              {gettext("Back to the policy requests")}
            </.link>
          </p>
        </div>

        <.answer_page
          :for={row <- List.wrap(find(rows, @answer_id))}
          row={row}
          scope={@current_scope}
          answerable={@answerable}
          workspaces={@workspaces}
          refused={@refused[row.answer.id]}
        />
      </.async_result>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:policy_requests}
    >
      <:crumb>{gettext("Policy requests")}</:crumb>

      <.page_header title={gettext("Policy requests")}>
        <:description>
          {gettext(
            "The changes the operator of %{organisation} asks for in its security policy, for the harness it provides. The policy is yours: accept a request in the workspaces you choose, or decline it.",
            organisation: @current_scope.organisation.name
          )}
        </:description>
      </.page_header>

      <.read_only scope={@current_scope} />

      <.async_result :let={rows} assign={@rows}>
        <:loading>
          <div
            id="received-loading"
            class="overflow-hidden rounded-box border border-line bg-base-100 shadow-xs"
            aria-busy="true"
          >
            <span class="sr-only">{gettext("Loading the policy requests")}</span>
            <div
              :for={n <- 1..3}
              class="flex h-11 items-center gap-6 border-b border-line px-4 last:border-b-0"
            >
              <span class={["skeleton q-skel", if(rem(n, 2) == 0, do: "w-40", else: "w-56")]}></span>
              <span class="skeleton q-skel w-24"></span>
              <span class="skeleton q-skel w-32 max-md:hidden"></span>
            </div>
          </div>
        </:loading>
        <:failed>
          <.notice kind={:error} class="max-w-[80ch]">
            <span id="received-error">
              {gettext(
                "The policy requests could not be loaded. Reload the page; if it keeps happening, Qory Apiary's log has the reason."
              )}
            </span>
          </.notice>
        </:failed>

        <div :if={rows == []} id="received-empty">
          <.empty_state icon="hero-shield-check" tone="neutral" title={gettext("No requests")}>
            {gettext(
              "When the harness your operator provides needs a change to your policy, its request is here for you to accept or decline."
            )}
          </.empty_state>
        </div>

        <.received_list
          :if={rows != []}
          rows={rows}
          list={@list}
          scope={@current_scope}
          answers={answers?(@current_scope, @answerable)}
          confirming={
            @live_action == :decline && confirming(rows, @answer_id, @current_scope, @answerable)
          }
          declined={@declined}
        />
      </.async_result>
    </Layouts.app>
    """
  end

  attr :scope, :any, required: true

  # What a person of the operator reads here, and why they answer nothing.
  defp read_only(assigns) do
    ~H"""
    <.notice :if={Access.reader(@scope) == :operator} class="max-w-[80ch]">
      <span id="requests-read-only">
        {gettext(
          "You read these requests as a person of the operator. The people of %{organisation} answer them.",
          organisation: @scope.organisation.name
        )}
      </span>
    </.notice>
    """
  end

  attr :rows, :list, required: true
  attr :list, :map, required: true
  attr :scope, :any, required: true
  attr :answers, :boolean, required: true, doc: "whether the reader answers here"
  attr :confirming, :any, required: true, doc: "the id of the row that asks, or nil"
  attr :declined, :map, required: true

  # The list on the core's pattern (`docs/ui.md`, Lists): the views, the search, what the
  # search left, then one row a request, Answer for one that waits and its ⋯ menu holding
  # Decline…, which the row confirms in place, with the reason.
  defp received_list(assigns) do
    assigns =
      assign(assigns,
        narrowed: not is_nil(assigns.list.q),
        found: Enum.filter(assigns.rows, &matches?(&1, assigns.list.q))
      )

    assigns =
      assign(assigns, :shown, Enum.filter(assigns.found, &in_view?(&1, assigns.list.view)))

    ~H"""
    <div class="grid gap-3">
      <.views id="received-views" label={gettext("Views")}>
        <:view
          :for={{view, label} <- views()}
          id={"received-view-#{view}"}
          patch={list_path(@scope, %{@list | view: view})}
          count={Format.number(Enum.count(@found, &in_view?(&1, view)))}
          current={@list.view == view}
        >
          {label}
        </:view>
      </.views>

      <div class="q-bar">
        <.list_search
          id="received-search"
          value={@list.q}
          label={gettext("Find a request")}
          placeholder={gettext("Find a request by its note or host")}
        />
      </div>

      <%!-- Always there, so a screen reader hears what the search left. --%>
      <div id="received-status" role="status" class="q-status">
        <p :if={@narrowed && @shown != []} id="received-summary">
          {ngettext("%{number} request matches", "%{number} requests match", length(@shown),
            number: Format.number(length(@shown))
          )}
        </p>
        <div :if={@shown == []} id="received-none">
          <.empty_state
            icon={nil}
            tone="neutral"
            title={if @narrowed, do: gettext("No request matches"), else: gettext("No request here")}
          >
            <p :if={@narrowed}>{gettext("No request has that note or host.")}</p>
            <p :if={!@narrowed}>{empty_view(@list.view)}</p>
            <:actions :if={@narrowed}>
              <.button id="received-none-clear" patch={list_path(@scope, %{@list | q: nil})}>
                {gettext("Clear filters")}
              </.button>
            </:actions>
          </.empty_state>
        </div>
      </div>

      <.table
        :if={@shown != []}
        id="received"
        label={gettext("Policy requests")}
        rows={@shown}
        row_id={&"received-#{&1.answer.id}"}
        confirming={@confirming}
      >
        <:col :let={row} label={gettext("Request")} kind="title">
          <span class="q-nm">
            <.link
              id={"received-#{row.answer.id}-link"}
              navigate={answer_path(@scope, row.answer)}
              class="q-title truncate hover:underline"
              title={request_name(row.request)}
            >
              {request_name(row.request)}
            </.link>
          </span>
        </:col>
        <:col :let={row} label={gettext("From")} from="sm">
          <span id={"received-#{row.answer.id}-from"}>
            {if row.operator, do: row.operator.name, else: gettext("A former operator")}
          </span>
        </:col>
        <:col :let={row} label={gettext("Changes")} from="md">
          <.first_change_cell
            id={"received-#{row.answer.id}-first-change"}
            changes={row.request.changes}
          />
        </:col>
        <:col :let={row} label={gettext("Sent")} from="md">
          <span class="tabular-nums">{Format.day(row.request.inserted_at)}</span>
        </:col>
        <:col :let={row} label={gettext("Answer")}>
          <span id={"received-#{row.answer.id}-state"}>
            <.request_state state={row.answer.state} for={:client} />
          </span>
        </:col>
        <:confirm :let={row}>
          <ConfirmComponents.reason_confirm
            id={"received-#{row.answer.id}-decline"}
            question={gettext("Decline “%{request}”?", request: request_name(row.request))}
            form={to_form(%{}, as: :decline)}
            submit="decline"
            button={gettext("Yes, decline")}
            loading_text={gettext("Declining")}
            cancel={list_path(@scope, @list)}
          >
            {gettext("Nothing changes in the policy. The operator reads the reason you give.")}
            <:field>
              <input type="hidden" name="answer_id" value={row.answer.id} />
              <.input
                id={"received-#{row.answer.id}-reason"}
                name="decline[reason]"
                value={typed_reason(@declined, row.answer.id)}
                errors={reason_errors(@declined, row.answer.id)}
                type="text"
                label={gettext("Reason")}
                optional
                maxlength={PolicyRequests.reason_max()}
                autocomplete="off"
              />
            </:field>
          </ConfirmComponents.reason_confirm>
        </:confirm>
        <:action :let={row}>
          <.button
            :if={row.answer.state == :pending && @answers}
            id={"received-#{row.answer.id}-answer-link"}
            variant="link"
            navigate={answer_path(@scope, row.answer)}
            aria-label={gettext("Answer “%{request}”", request: request_name(row.request))}
          >
            {gettext("Answer")}
          </.button>
          <.row_menu
            :if={row.answer.state == :pending && @answers}
            id={"received-#{row.answer.id}-menu"}
            label={gettext("Actions for “%{request}”", request: request_name(row.request))}
          >
            <.menu_item
              id={"received-#{row.answer.id}-decline-link"}
              patch={decline_path(@scope, row.answer, @list)}
              aria-label={gettext("Decline “%{request}”", request: request_name(row.request))}
            >
              {gettext("Decline…")}
            </.menu_item>
          </.row_menu>
        </:action>
      </.table>

      <p :if={length(@rows) >= 200} id="received-capped" class="text-[12.5px]/[18px] text-faint">
        {gettext("Only the 200 newest requests are listed.")}
      </p>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :scope, :any, required: true
  attr :answerable, :list, required: true
  attr :workspaces, :map, required: true
  attr :refused, :string, default: nil

  defp answer_page(assigns) do
    assigns = assign(assigns, :id, "received-#{assigns.row.answer.id}")

    ~H"""
    <.page_header title={request_name(@row.request)}>
      <:badge>
        <span id={"#{@id}-state"}>
          <.request_state state={@row.answer.state} for={:client} />
        </span>
      </:badge>
      <:description>
        {if @row.operator,
          do:
            gettext("From %{operator}, on %{date}",
              operator: @row.operator.name,
              date: Format.date(@row.request.inserted_at)
            ),
          else:
            gettext("From a former operator, on %{date}", date: Format.date(@row.request.inserted_at))}
      </:description>
    </.page_header>

    <.read_only scope={@scope} />

    <SettingsComponents.part
      id="received-note-part"
      title={gettext("Why the harness needs this")}
      level={:h2}
    >
      <%!-- The note keeps its line breaks, and no break of the markup's. --%>
      <p id={"#{@id}-note"} class="max-w-[72ch]">
        <span class="whitespace-pre-line">{@row.request.note}</span>
      </p>
    </SettingsComponents.part>

    <SettingsComponents.part id="received-changes-part" title={gettext("Changes")} level={:h2}>
      <.request_changes id={"#{@id}-changes"} lines={request_lines(@row.request.changes)} />
    </SettingsComponents.part>

    <SettingsComponents.part
      :if={@row.answer.state != :pending}
      id="received-answer-part"
      title={gettext("Answer")}
      level={:h2}
    >
      <p id={"#{@id}-answer"}>
        <.rich text={answered(@row.answer, @workspaces, @scope.user.email)} />
      </p>
    </SettingsComponents.part>

    <p
      :if={@row.answer.state == :pending && !answers?(@scope, @answerable)}
      id={"#{@id}-waiting"}
      class="text-muted"
    >
      {gettext("Waiting for an answer from a person who writes the policy here.")}
    </p>

    <SettingsComponents.part
      :if={@row.answer.state == :pending && answers?(@scope, @answerable)}
      id="received-your-answer"
      title={gettext("Your answer")}
      level={:h2}
    >
      <.form for={%{}} id={"#{@id}-accept"} phx-submit="accept" class="grid gap-4" novalidate>
        <input type="hidden" name="answer_id" value={@row.answer.id} />
        <fieldset class="fieldset" aria-describedby={@refused && "#{@id}-refused"}>
          <legend class="mb-1 text-[13px]/[18px] font-medium">{gettext("Workspaces")}</legend>
          <.input
            :for={workspace <- @answerable}
            id={"#{@id}-workspace-#{workspace.id}"}
            name={"workspaces[#{workspace.id}]"}
            type="checkbox"
            label={workspace.name}
            checked
          />
        </fieldset>
        <p :if={@refused} id={"#{@id}-refused"} role="alert" class="text-error">{@refused}</p>
        <SettingsComponents.save id={"#{@id}-foot"}>
          <.button
            id={"#{@id}-accept-button"}
            type="submit"
            variant="primary"
            loading_text={gettext("Accepting")}
          >
            {gettext("Accept")}
          </.button>
          <.button
            id={"#{@id}-decline-open"}
            navigate={decline_path(@scope, @row.answer, list_params(%{}))}
          >
            {gettext("Decline…")}
          </.button>
        </SettingsComponents.save>
      </.form>
    </SettingsComponents.part>
    """
  end

  attr :id, :string, required: true
  attr :changes, :map, required: true

  # A row's Changes: its first line, and how many more, cut to the cell; whole in its
  # title.
  defp first_change_cell(assigns) do
    assigns = assign(assigns, :first, first_change(assigns.changes))

    ~H"""
    <span
      :if={@first}
      id={@id}
      class="block max-w-[44ch] truncate"
      title={first_change_text(@first)}
    >
      <.rich text={elem(elem(@first, 0), 1)} />{more_words(elem(@first, 1))}
    </span>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    # While the operator owns its clients (`ApiaryPro.Flags.operator_infrastructure?/0`),
    # policy requests are not there: the page is not found, as a path that does not exist.
    if ApiaryPro.Flags.operator_infrastructure?(), do: raise(ApiaryWeb.NotFound)

    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(
       page_title: gettext("Policy requests"),
       list: list_params(%{}),
       answer_id: nil,
       rows: AsyncResult.loading(),
       refused: %{},
       declined: %{},
       answerable: PolicyRequests.answerable_workspaces(scope),
       workspaces: workspace_names(scope)
     )
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(list: list_params(params), answer_id: params["id"])
      |> apply_action(socket.assigns.live_action)

    {:noreply, titled(socket)}
  end

  defp apply_action(socket, action) when action in [:index, :show], do: socket

  # The row asks only a person who answers here; anyone else is told so, on the list.
  defp apply_action(socket, :decline) do
    scope = socket.assigns.current_scope

    if answers?(scope, socket.assigns.answerable) do
      socket
    else
      socket
      |> put_flash(:error, forbidden(scope))
      |> push_patch(to: list_path(scope, socket.assigns.list))
    end
  end

  # The browser's title: the request a page is about, the list's name and the
  # organisation's.
  defp titled(socket) do
    page =
      with :show <- socket.assigns.live_action,
           %{request: request} <- picked(socket.assigns.rows, socket.assigns.answer_id) do
        [request_name(request)]
      else
        _list -> []
      end

    title =
      Enum.join(
        page ++ [gettext("Policy requests"), socket.assigns.current_scope.organisation.name],
        " · "
      )

    assign(socket, :page_title, title)
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    list = %{socket.assigns.list | q: blank(q)}
    {:noreply, push_patch(socket, to: list_path(socket.assigns.current_scope, list))}
  end

  # What the form said of an answer before goes with each attempt: it says only what this
  # one was refused for. Accepted, the list follows, with a flash.
  def handle_event("accept", %{"answer_id" => id} = params, socket) do
    scope = socket.assigns.current_scope
    workspaces = checked(params["workspaces"])
    socket = assign(socket, :refused, Map.delete(socket.assigns.refused, id))

    # No workspace chosen is answered by the form, before anything is locked.
    with [_ | _] <- workspaces,
         {:ok, answer} <- PolicyRequests.accept(scope, id, workspaces) do
      {:noreply,
       socket
       |> put_flash(
         :info,
         ngettext(
           "Accepted: the changes are made in %{number} workspace.",
           "Accepted: the changes are made in %{number} workspaces.",
           length(answer.workspace_ids),
           number: Format.number(length(answer.workspace_ids))
         )
       )
       |> assign(:refused, %{})
       |> push_navigate(to: list_path(scope, list_params(%{})))}
    else
      [] ->
        message = gettext("Choose at least one workspace to accept it in.")
        {:noreply, assign(socket, :refused, Map.put(socket.assigns.refused, id, message))}

      {:error, %Policy.Error{message: message}} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Nothing was changed: %{reason}", reason: message))
         |> assign(:refused, Map.put(socket.assigns.refused, id, message))}

      {:error, reason} ->
        {:noreply, refused(socket, reason, :"policy_request.accept")}
    end
  end

  # Declined, the list follows, with no row asking; a reason refused is said under its
  # field, in the row.
  def handle_event("decline", %{"answer_id" => id} = params, socket) do
    scope = socket.assigns.current_scope
    reason = get_in(params, ["decline", "reason"])
    # The reason stays as it was typed, without the error an attempt before had.
    socket = assign(socket, :declined, Map.put(socket.assigns.declined, id, {reason, nil}))

    case PolicyRequests.decline(scope, id, reason) do
      {:ok, _answer} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Declined: nothing changes in the policy."))
         |> assign(:declined, Map.delete(socket.assigns.declined, id))
         |> load()
         |> push_patch(to: list_path(scope, socket.assigns.list))}

      # Answered under the field, the reason kept as it was typed.
      {:error, {:reason, message}} ->
        {:noreply,
         assign(socket, :declined, Map.put(socket.assigns.declined, id, {reason, message}))}

      {:error, reason} ->
        {:noreply, refused(socket, reason, :"policy_request.decline")}
    end
  end

  # An event without the answer it is about: as for an answer that is not there.
  def handle_event(event, _params, socket) when event in ["accept", "decline"],
    do: {:noreply, refused(socket, :not_found, nil)}

  defp refused(socket, :answered, _action) do
    socket
    |> put_flash(:error, gettext("That request is answered already."))
    |> load()
  end

  defp refused(socket, :withdrawn, _action) do
    socket
    |> put_flash(:error, gettext("The operator withdrew that request meanwhile."))
    |> load()
  end

  defp refused(socket, :busy, _action) do
    put_flash(
      socket,
      :error,
      gettext("Someone changed this at the same moment, so nothing was changed. Try again.")
    )
  end

  defp refused(socket, :not_found, _action) do
    socket
    |> put_flash(
      :error,
      gettext("That request, or a workspace chosen, is not there any more. Nothing was changed.")
    )
    |> load()
  end

  defp refused(socket, _forbidden, _action) do
    socket
    |> put_flash(:error, forbidden(socket.assigns.current_scope))
    |> UserAuth.reload_scope()
  end

  # Why the person answers nothing here: they read the organisation, or they do not write
  # its policy.
  defp forbidden(scope) do
    if Access.reader(scope),
      do: ApiaryWeb.Access.reads_only(scope),
      else: gettext("Only a person who writes the policy here answers a policy request.")
  end

  # The requests, read again after a change; what was read before stays on the page until
  # they arrive. The page's title names the request a page is about once it has.
  defp load(socket) do
    scope = socket.assigns.current_scope
    start_async(socket, :rows, fn -> PolicyRequests.list_received(scope) end)
  end

  @impl true
  def handle_async(:rows, {:ok, {:ok, rows}}, socket),
    do: {:noreply, socket |> assign(:rows, AsyncResult.ok(socket.assigns.rows, rows)) |> titled()}

  def handle_async(:rows, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, :rows, AsyncResult.failed(socket.assigns.rows, reason))}

  def handle_async(:rows, {:exit, reason}, socket),
    do:
      {:noreply, assign(socket, :rows, AsyncResult.failed(socket.assigns.rows, {:exit, reason}))}

  defp workspace_names(scope),
    do: scope |> Apiary.Organisations.list_workspaces() |> Map.new(&{&1.id, &1.name})

  # What became of a request, in a sentence, rich text: who accepted it and where, who
  # declined it and why, or why it was withdrawn. Who is their first letter, with the
  # address as its tooltip; `reader` is the reader's address.
  defp answered(%{state: :accepted} = answer, workspaces, reader) do
    names =
      answer.workspace_ids
      |> Enum.map(&(workspaces[&1] || gettext("a deleted workspace")))
      |> Enum.join(", ")

    rich_gettext("Accepted by %{person} in %{workspaces}",
      person: letter(person(answer), reader),
      workspaces: names
    )
  end

  defp answered(%{state: :declined, reason: reason} = answer, _workspaces, reader)
       when is_binary(reason),
       do:
         rich_gettext("Declined by %{person}: %{reason}",
           person: letter(person(answer), reader),
           reason: reason
         )

  defp answered(%{state: :declined} = answer, _workspaces, reader),
    do: rich_gettext("Declined by %{person}", person: letter(person(answer), reader))

  defp answered(%{state: :withdrawn, reason: "left"}, _workspaces, _reader),
    do: gettext("Withdrawn: the organisation left its operator")

  defp answered(%{state: :withdrawn, reason: "dropped"}, _workspaces, _reader),
    do: gettext("Withdrawn: the operator dropped the organisation")

  defp answered(%{state: :withdrawn, reason: "deleted"}, _workspaces, _reader),
    do: gettext("Withdrawn: the organisation was deleted")

  defp answered(%{state: :withdrawn}, _workspaces, _reader),
    do: gettext("Withdrawn by the operator")

  # Who answered: their address, or "Former member" for a deleted account.
  defp person(answer), do: People.email(answer.answered_by) || People.former_member()

  # A person in a sentence: their first letter, with the address as its tooltip
  # (`ApiaryWeb.CoreComponents.avatar/1`).
  defp letter(email, reader) do
    assigns = %{email: email, reader: reader}
    ~H|<.avatar email={@email} reader={@reader} size="xs" />|
  end

  defp checked(boxes) when is_map(boxes), do: for({id, "true"} <- boxes, do: id)
  defp checked(ids) when is_list(ids), do: Enum.filter(ids, &is_binary/1)
  defp checked(_boxes), do: []

  # A decline tried and not made: the reason as it was typed, and, when it was refused for
  # the reason, why, under the field.
  defp typed_reason(declined, id) do
    case declined do
      %{^id => {reason, _message}} when is_binary(reason) -> reason
      _none -> ""
    end
  end

  defp reason_errors(declined, id) do
    case declined do
      %{^id => {_reason, message}} when is_binary(message) -> [message]
      _none -> []
    end
  end

  # Whether the person answers here: they may accept and decline, and write the policy of
  # a workspace at least, since an answer is the whole client's.
  defp answers?(scope, answerable),
    do:
      answerable != [] and Access.can?(scope, :"policy_request.accept", scope.organisation) and
        Access.can?(scope, :"policy_request.decline", scope.organisation)

  defp more_words(0), do: nil

  defp more_words(more),
    do:
      " " <>
        ngettext("and %{number} more", "and %{number} more", more, number: Format.number(more))

  defp first_change_text({{_kind, text}, more}),
    do: ApiaryWeb.RichText.plain_text(text) <> (more_words(more) || "")

  ## The list's views and search, in the URL

  defp views do
    [
      {"all", gettext("All")},
      {"waiting", gettext("Waiting")},
      {"answered", gettext("Answered")},
      {"withdrawn", gettext("Withdrawn")}
    ]
  end

  defp in_view?(_row, "all"), do: true
  defp in_view?(row, "waiting"), do: row.answer.state == :pending
  defp in_view?(row, "answered"), do: row.answer.state in [:accepted, :declined]
  defp in_view?(row, "withdrawn"), do: row.answer.state == :withdrawn

  defp empty_view("waiting"), do: gettext("Every request is answered.")
  defp empty_view("answered"), do: gettext("No request is answered yet.")
  defp empty_view(_withdrawn), do: gettext("No request is withdrawn.")

  # A request is found by words of its note or of a host it changes, whatever their case.
  defp matches?(_row, nil), do: true

  defp matches?(row, q) do
    q = String.downcase(q)

    [row.request.note | hosts(row.request.changes)]
    |> Enum.any?(&(is_binary(&1) and String.contains?(String.downcase(&1), q)))
  end

  defp hosts(%{"rules" => rules}) when is_list(rules),
    do: for(%{"rule" => %{"host" => host}} <- rules, do: host)

  defp hosts(_changes), do: []

  defp list_params(params) do
    %{
      view: if(params["view"] in ~w(waiting answered withdrawn), do: params["view"], else: "all"),
      q: blank(params["q"])
    }
  end

  defp blank(q) when is_binary(q), do: if(String.trim(q) == "", do: nil, else: String.trim(q))
  defp blank(_q), do: nil

  defp query(list),
    do:
      Enum.filter([{"view", list.view != "all" && list.view}, {"q", list.q}], fn {_k, v} -> v end)

  defp list_path(scope, list) do
    case query(list) do
      [] -> ~p"/#{scope.organisation}/policy-requests"
      query -> ~p"/#{scope.organisation}/policy-requests?#{query}"
    end
  end

  defp answer_path(scope, answer), do: ~p"/#{scope.organisation}/policy-requests/#{answer.id}"

  # Decline… keeps the list as it was, so its row asks where it was.
  defp decline_path(scope, answer, list) do
    case query(list) do
      [] -> ~p"/#{scope.organisation}/policy-requests/#{answer.id}/decline"
      query -> ~p"/#{scope.organisation}/policy-requests/#{answer.id}/decline?#{query}"
    end
  end

  # The answer a page or a confirmation is about, among the rows read.
  defp find(rows, id) when is_binary(id), do: Enum.find(rows, &(&1.answer.id == id))
  defp find(_rows, _id), do: nil

  defp picked(%AsyncResult{ok?: true, result: rows}, id), do: find(rows, id)
  defp picked(_rows, _id), do: nil

  # The short form of the id a request that is not here was asked by, once the rows have
  # arrived, as the core's page of a run that is not there says it: the first 8
  # characters, when it is an id at all; nil for an address that is none, whose
  # breadcrumb ends with Policy requests, and while the rows load.
  defp missing_id(%AsyncResult{ok?: true, result: rows}, id) when is_binary(id) do
    with nil <- find(rows, id),
         {:ok, id} <- Ecto.UUID.cast(id) do
      String.slice(id, 0, 8)
    else
      _found_or_none -> nil
    end
  end

  defp missing_id(_rows, _id), do: nil

  # The row that asks to decline: once the rows have arrived, while the answer is
  # pending, for a person who answers here.
  defp confirming(rows, id, scope, answerable) do
    with %{answer: %{state: :pending} = answer} <- find(rows, id),
         true <- answers?(scope, answerable) do
      "received-#{answer.id}"
    else
      _no -> nil
    end
  end
end
