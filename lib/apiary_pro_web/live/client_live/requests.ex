defmodule ApiaryProWeb.ClientLive.Requests do
  @moduledoc """
  An operator's policy requests, an organisation's page: `/:org/clients/requests`, for a
  reader who may `client.read` in an operator where `security` is on; elsewhere the path
  is not found. The policy of each client is the client's: when the harness the operator
  provides needs a host or a mode, the operator asks, and each client decides
  (`ApiaryPro.PolicyRequests`).

  The list is on the core's pattern (`docs/ui.md`, Lists), newest first: one row a
  request, its name (its note's first line) leading to its page, how many clients
  accepted, declined, have not answered or had it withdrawn, its first change, when it was
  sent and by whom. The views are All, Waiting (a client has not answered), Answered and
  Withdrawn (`?view=`), counted under the search, `?q=`, words of the note, of a host or
  of a client's name, and the Filter menu's Client, `?client=`, all in the URL. The page
  reads the 200 newest requests, and says so when there are that many.

  A request's page, `/:org/clients/requests/:id`, holds its note, its changes in the
  words of the policy's history, and each client's answer: pending, accepted in how many
  workspaces, declined with the reason, or withdrawn. An owner or an admin of the
  operator writes one on a separate page, `/:org/clients/requests/new`
  (`policy_request.send`): the changes one by one, each read back as the policy would take
  it, the mode if it is to change, the clients it goes to, every one that may receive it
  by default, and a note saying why the harness needs them. They withdraw a request from
  the clients that have not answered it (`policy_request.withdraw`), from its row's ⋯
  menu or its page, confirmed in place on its row, `/:org/clients/requests/:id/withdraw`,
  whose Cancel goes back to the list. The operator's members read the list.
  """
  use ApiaryProWeb, :live_view
  use ApiaryWeb.Features, :security
  on_mount {ApiaryWeb.Access, :"client.read"}

  import ApiaryProWeb.RequestComponents,
    only: [
      answer_tally: 1,
      first_change: 1,
      request_changes: 1,
      request_lines: 1,
      request_name: 1,
      request_state: 1
    ]

  alias Apiary.{Access, Policy}
  alias ApiaryPro.PolicyRequests
  alias ApiaryWeb.{People, SettingsComponents, UserAuth}
  alias Phoenix.LiveView.AsyncResult

  @blank_change %{
    "change" => "rule_added",
    "action" => "allow",
    "host" => "",
    "paths" => "",
    "locked" => "false"
  }

  @impl true
  # Writing a request is a page of the list, on the core's pattern of a form (`docs/ui.md`,
  # A form is a page): the breadcrumb ending Policy requests / New request, its title and
  # one sentence, the changes one by one, the mode, the clients and the note, and Send
  # request with Cancel back to the list.
  def render(%{live_action: :new} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:client_requests}
      width="read"
    >
      <:crumb navigate={~p"/#{@current_scope.organisation}/clients/requests"}>
        {gettext("Policy requests")}
      </:crumb>
      <:crumb>{gettext("New request")}</:crumb>

      <.page_form
        id="request-new"
        title={gettext("New policy request")}
        cancel={~p"/#{@current_scope.organisation}/clients/requests"}
        cancel_by="patch"
      >
        <:description>
          {gettext(
            "Say what the harness needs. Each client's people see the changes and the note, and accept them in the workspaces they choose, or decline. Nothing changes in a client until it accepts."
          )}
        </:description>

        <div id="new-request-page" class="grid gap-6">
          <%!-- What is in the request reads first, then the fields that add to it: a part
               of the page, as the core lays a form page out, never a box inside it. --%>
          <SettingsComponents.part id="request-changes-part" title={gettext("Changes")}>
            <div id="request-draft" class="grid gap-2">
              <p :if={@draft == []} id="request-draft-empty" class="text-muted">
                {gettext("No change yet: add the rules the harness needs, or change the mode below.")}
              </p>
              <div
                :for={{line, index} <- Enum.with_index(request_lines(%{"rules" => @draft}))}
                id={"request-draft-#{index}"}
                class="flex items-start gap-2"
              >
                <div class="min-w-0 grow">
                  <.request_changes id={"request-draft-#{index}-line"} lines={[line]} />
                </div>
                <.button
                  id={"request-draft-#{index}-remove"}
                  type="button"
                  size="xs"
                  variant="ghost"
                  phx-click="remove_change"
                  phx-value-index={index}
                  aria-label={gettext("Take this change out")}
                >
                  <.icon name="hero-x-mark-micro" class="size-4" />
                </.button>
              </div>
            </div>

            <.form
              for={@change_form}
              id="request-change-form"
              phx-change="change_draft"
              phx-submit="add_change"
              class="grid gap-3"
              novalidate
            >
              <div class="grid gap-3 sm:grid-cols-2">
                <.input
                  field={@change_form[:change]}
                  type="select"
                  label={gettext("Change")}
                  phx-mounted={JS.focus()}
                  options={[
                    {gettext("Add a rule"), "rule_added"},
                    {gettext("Change a rule"), "rule_changed"},
                    {gettext("Remove a rule"), "rule_removed"}
                  ]}
                />
                <.input
                  :if={@change_form[:change].value != "rule_removed"}
                  field={@change_form[:action]}
                  type="select"
                  label={gettext("Rule")}
                  options={[{gettext("Allow"), "allow"}, {gettext("Deny"), "deny"}]}
                />
              </div>
              <.input
                field={@change_form[:host]}
                type="text"
                label={gettext("Host")}
                placeholder="api.example"
                autocomplete="off"
                spellcheck="false"
              />
              <.input
                :if={allowing?(@change_form)}
                field={@change_form[:paths]}
                type="textarea"
                label={gettext("Paths")}
                hint={gettext("One a line. None for every path.")}
                optional
                rows="2"
              />
              <.input
                :if={@change_form[:change].value != "rule_removed"}
                field={@change_form[:locked]}
                type="checkbox"
                label={gettext("Locked: only an owner of the client accepts it")}
              />
              <p :if={@change_error} id="request-change-error" role="alert" class="text-error">
                {@change_error}
              </p>
              <div>
                <.button id="request-add-change" type="submit" size="sm">
                  <.icon name="hero-plus-micro" class="size-4" /> {gettext("Add to the request")}
                </.button>
              </div>
            </.form>
          </SettingsComponents.part>

          <.form
            for={@form}
            id="request-form"
            phx-change="validate"
            phx-submit="send"
            class="grid gap-4"
            novalidate
          >
            <.input
              field={@form[:mode]}
              type="select"
              label={gettext("Mode")}
              options={[
                {gettext("Leave the mode as it is"), ""},
                {gettext("Observe"), "observe"},
                {gettext("Enforce"), "enforce"}
              ]}
            />
            <fieldset id="request-clients" class="fieldset">
              <legend class="mb-1 text-[13px]/[18px] font-medium">{gettext("Clients")}</legend>
              <p :if={@recipients == []} id="request-no-clients" class="text-muted">
                {gettext(
                  "No client can receive a request now: a client needs the security policy, and not to be suspended."
                )}
              </p>
              <.input
                :for={client <- @recipients}
                id={"request-client-#{client.id}"}
                name={"request[clients][#{client.id}]"}
                type="checkbox"
                label={client.name}
                checked={client.id in @chosen}
              />
            </fieldset>
            <.input
              field={@form[:note]}
              type="textarea"
              label={gettext("Why the harness needs this")}
              rows="3"
              maxlength={PolicyRequests.note_max()}
            />
            <p :if={@send_error} id="request-send-error" role="alert" class="text-error">
              {@send_error}
            </p>
            <.page_form_foot
              id="request-save"
              cancel={~p"/#{@current_scope.organisation}/clients/requests"}
              cancel_by="patch"
            >
              <.button
                id="send-request"
                variant="primary"
                type="submit"
                loading_text={gettext("Sending")}
              >
                {gettext("Send request")}
              </.button>
            </.page_form_foot>
          </.form>
        </div>
      </.page_form>
    </Layouts.app>
    """
  end

  # One request, a page of the list: its name the title, when and by whom it was sent,
  # its note, its changes and each client's answer, in parts of the page, at the list's
  # width, as a node's page is, so the answers' table has room for its columns.
  # Withdraw… leads to the list, where the request's row asks.
  def render(%{live_action: :show} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:client_requests}
    >
      <:crumb navigate={list_path(@current_scope, list_params(%{}))}>
        {gettext("Policy requests")}
      </:crumb>
      <:crumb
        :if={picked(@requests, @request_id)}
        title={request_name(picked(@requests, @request_id).request)}
      >
        {request_name(picked(@requests, @request_id).request)}
      </:crumb>
      <:crumb :if={missing_id(@requests, @request_id)}>
        {gettext("Request %{id}", id: missing_id(@requests, @request_id))}
      </:crumb>

      <.async_result :let={requests} assign={@requests}>
        <:loading>
          <div id="requests-loading" class="grid gap-3" aria-busy="true">
            <span class="sr-only">{gettext("Loading the policy requests")}</span>
            <span class="skeleton q-skel w-64"></span>
            <span class="skeleton q-skel w-48"></span>
          </div>
        </:loading>
        <:failed>
          <.notice kind={:error} class="max-w-[80ch]">
            <span id="requests-error">
              {gettext(
                "The policy requests could not be loaded. Reload the page; if it keeps happening, Qory Apiary's log has the reason."
              )}
            </span>
          </.notice>
        </:failed>

        <.gone
          :if={is_nil(find(requests, @request_id))}
          id="request-gone"
          to={list_path(@current_scope, list_params(%{}))}
        />

        <.request_page
          :for={row <- List.wrap(find(requests, @request_id))}
          row={row}
          scope={@current_scope}
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
      nav={:client_requests}
    >
      <:crumb>{gettext("Policy requests")}</:crumb>

      <.page_header title={gettext("Policy requests")}>
        <:description>
          {gettext(
            "The changes the harness of %{operator} needs in its clients' security policy. The policy is each client's: its people accept a request, in the workspaces they choose, or decline it.",
            operator: @current_scope.organisation.name
          )}
        </:description>
        <:actions :if={may?(@current_scope, :"policy_request.send")}>
          <.button
            id="new-request"
            variant="primary"
            patch={~p"/#{@current_scope.organisation}/clients/requests/new"}
          >
            <.icon name="hero-plus-micro" class="size-4" /> {gettext("New request")}
          </.button>
        </:actions>
      </.page_header>

      <.async_result :let={requests} assign={@requests}>
        <:loading>
          <div
            id="requests-loading"
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
            <span id="requests-error">
              {gettext(
                "The policy requests could not be loaded. Reload the page; if it keeps happening, Qory Apiary's log has the reason."
              )}
            </span>
          </.notice>
        </:failed>

        <div :if={requests == []} id="requests-empty">
          <.empty_state icon="hero-shield-check" tone="neutral" title={gettext("No requests yet")}>
            <p>
              {gettext(
                "When the harness needs a host or a mode a client's policy does not give it, ask the client here. Its people decide."
              )}
            </p>
            <p :if={!may?(@current_scope, :"policy_request.send")} id="requests-who">
              {gettext("Only owners and admins of %{operator} send a request or withdraw one.",
                operator: @current_scope.organisation.name
              )}
            </p>
            <:actions :if={may?(@current_scope, :"policy_request.send")}>
              <.button patch={~p"/#{@current_scope.organisation}/clients/requests/new"}>
                {gettext("Write the first request")}
              </.button>
            </:actions>
          </.empty_state>
        </div>

        <.request_list
          :if={requests != []}
          requests={requests}
          list={@list}
          scope={@current_scope}
          confirming={@live_action == :withdraw && confirming(requests, @request_id, @current_scope)}
        />
      </.async_result>
    </Layouts.app>
    """
  end

  attr :requests, :list, required: true
  attr :list, :map, required: true
  attr :scope, :any, required: true
  attr :confirming, :any, required: true, doc: "the id of the request whose row asks, or nil"

  # The list on the core's pattern (`docs/ui.md`, Lists): the views, the bar with the
  # search and the Client filter, the filter in force, what the search left, then one row
  # a request, its ⋯ menu holding Withdraw…, which the row confirms in place.
  defp request_list(assigns) do
    assigns =
      assign(assigns,
        clients: clients(assigns.requests),
        narrowed: narrowed?(assigns.list),
        found: Enum.filter(assigns.requests, &found?(&1, assigns.list))
      )

    assigns =
      assign(assigns,
        shown: Enum.filter(assigns.found, &in_view?(&1, assigns.list.view)),
        client: Enum.find(assigns.clients, &(&1.id == assigns.list.client))
      )

    ~H"""
    <div class="grid gap-3">
      <.views id="requests-views" label={gettext("Views")}>
        <:view
          :for={{view, label} <- views()}
          id={"requests-view-#{view}"}
          patch={list_path(@scope, %{@list | view: view})}
          count={Format.number(Enum.count(@found, &in_view?(&1, view)))}
          current={@list.view == view}
        >
          {label}
        </:view>
      </.views>

      <div class="q-bar">
        <.list_search
          id="requests-search"
          value={@list.q}
          label={gettext("Find a request")}
          placeholder={gettext("Find a request by its note, host or client")}
        />
        <.filter_menu id="requests-filter" count={if(@client, do: 1, else: 0)}>
          <.menu_heading title={gettext("Client")} />
          <.menu_item
            :for={client <- @clients}
            id={"requests-filter-client-#{client.id}"}
            patch={
              list_path(@scope, %{
                @list
                | client: if(@list.client == client.id, do: nil, else: client.id)
              })
            }
            checked={@list.client == client.id}
          >
            {client.name}
          </.menu_item>
        </.filter_menu>
      </div>

      <.filter_tokens id="requests-tokens" clear={@narrowed && list_path(@scope, cleared(@list))}>
        <:token
          :if={@client}
          id="requests-token-client"
          patch={list_path(@scope, %{@list | client: nil})}
          label={
            gettext("Remove the filter %{filter}",
              filter: gettext("To %{client}", client: @client.name)
            )
          }
        >
          {gettext("To %{client}", client: @client.name)}
        </:token>
      </.filter_tokens>

      <%!-- Always there, so a screen reader hears what the search left. --%>
      <div id="requests-status" role="status" class="q-status">
        <p :if={@narrowed && @shown != []} id="requests-summary">
          {ngettext("%{number} request matches", "%{number} requests match", length(@shown),
            number: Format.number(length(@shown))
          )}
        </p>
        <div :if={@shown == []} id="requests-none">
          <.empty_state
            icon={nil}
            tone="neutral"
            title={if @narrowed, do: gettext("No request matches"), else: gettext("No request here")}
          >
            <p :if={@narrowed}>{gettext("No request has that note, host or client.")}</p>
            <p :if={!@narrowed}>{empty_view(@list.view)}</p>
            <:actions :if={@narrowed}>
              <.button id="requests-none-clear" patch={list_path(@scope, cleared(@list))}>
                {gettext("Clear filters")}
              </.button>
            </:actions>
          </.empty_state>
        </div>
      </div>

      <.table
        :if={@shown != []}
        id="requests"
        label={gettext("Policy requests")}
        rows={@shown}
        row_id={&"request-#{&1.request.id}"}
        row_class={&(&1.request.withdrawn_at && "row-off")}
        confirming={@confirming}
      >
        <:col :let={row} label={gettext("Request")} kind="title">
          <span class="q-nm">
            <.link
              id={"request-#{row.request.id}-link"}
              navigate={request_path(@scope, row.request)}
              class="q-title q-cut q-req-title hover:underline"
              title={request_name(row.request)}
            >
              {request_name(row.request)}
            </.link>
            <.state_word :if={row.request.withdrawn_at} id={"request-#{row.request.id}-withdrawn"}>
              {gettext("Withdrawn")}
            </.state_word>
          </span>
        </:col>
        <:col :let={row} label={gettext("Answers")}>
          <.tally id={"request-#{row.request.id}-tally"} answers={row.answers} />
        </:col>
        <:col :let={row} label={gettext("Changes")} from="md">
          <.first_change_cell
            id={"request-#{row.request.id}-first-change"}
            changes={row.request.changes}
          />
        </:col>
        <:col :let={row} label={gettext("Sent")} from="sm">
          <span class="tabular-nums">{Format.day(row.request.inserted_at)}</span>
        </:col>
        <:col :let={row} label={gettext("By")} from="lg">
          <.avatar email={author(row.request)} reader={@scope.user.email} size="xs" />
        </:col>
        <:confirm :let={row}>
          <.inline_confirm
            id={"request-#{row.request.id}-confirm"}
            question={gettext("Withdraw “%{request}”?", request: request_name(row.request))}
            cancel={list_path(@scope, @list)}
          >
            {withdraw_sentence(row)}
            <:action>
              <.button
                id={"request-#{row.request.id}-withdraw-confirm"}
                variant="danger"
                size="xs"
                phx-click="withdraw"
                phx-value-id={row.request.id}
                loading_text={gettext("Withdrawing")}
              >
                {gettext("Yes, withdraw")}
              </.button>
            </:action>
          </.inline_confirm>
        </:confirm>
        <:action :let={row}>
          <.row_menu
            :if={withdrawable?(row) && may?(@scope, :"policy_request.withdraw")}
            id={"request-#{row.request.id}-menu"}
            label={gettext("Actions for “%{request}”", request: request_name(row.request))}
          >
            <.menu_item
              id={"request-#{row.request.id}-withdraw"}
              patch={withdraw_path(@scope, row.request, @list)}
              aria-label={gettext("Withdraw “%{request}”", request: request_name(row.request))}
            >
              {gettext("Withdraw…")}
            </.menu_item>
          </.row_menu>
        </:action>
      </.table>

      <p
        :if={length(@requests) >= 200}
        id="requests-capped"
        class="text-[12.5px]/[18px] text-faint"
      >
        {gettext("Only the 200 newest requests are listed.")}
      </p>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :scope, :any, required: true

  defp request_page(assigns) do
    ~H"""
    <.page_header title={request_name(@row.request)}>
      <:badge :if={@row.request.withdrawn_at}>
        <.state_word id={"request-#{@row.request.id}-withdrawn"}>{gettext("Withdrawn")}</.state_word>
      </:badge>
      <:description>
        <.rich text={
          rich_gettext("Sent on %{date} by %{person}.",
            date: Format.date(@row.request.inserted_at),
            person: letter(author(@row.request), @scope.user.email)
          )
        } />
      </:description>
      <:actions :if={withdrawable?(@row) && may?(@scope, :"policy_request.withdraw")}>
        <.button
          id={"request-#{@row.request.id}-withdraw-open"}
          navigate={withdraw_path(@scope, @row.request, list_params(%{}))}
        >
          {gettext("Withdraw…")}
        </.button>
      </:actions>
    </.page_header>

    <SettingsComponents.part
      id="request-note-part"
      title={gettext("Why the harness needs this")}
      level={:h2}
    >
      <%!-- The note keeps its line breaks, and no break of the markup's. --%>
      <p id={"request-#{@row.request.id}-note"} class="max-w-[72ch]">
        <span class="whitespace-pre-line">{@row.request.note}</span>
      </p>
    </SettingsComponents.part>

    <SettingsComponents.part id="request-changes-part" title={gettext("Changes")} level={:h2}>
      <.request_changes
        id={"request-#{@row.request.id}-changes"}
        lines={request_lines(@row.request.changes)}
      />
    </SettingsComponents.part>

    <SettingsComponents.part
      id="request-answers-part"
      title={gettext("Answers")}
      count={length(@row.answers)}
      level={:h2}
    >
      <.table
        id={"request-#{@row.request.id}-answers"}
        label={gettext("Answers")}
        rows={@row.answers}
        row_id={&"answer-#{&1.answer.id}"}
      >
        <:col :let={a} label={gettext("Client")} kind="title">
          <span id={"answer-#{a.answer.id}-client"} class="q-nm">
            <.avatar name={a.client.name} kind="organisation" />
            <.link
              :if={linked?(a.client, @scope.organisation)}
              navigate={~p"/#{a.client}"}
              class="q-title hover:underline"
            >
              {a.client.name}
            </.link>
            <span :if={!linked?(a.client, @scope.organisation)} class="q-title">
              {a.client.name}
            </span>
          </span>
        </:col>
        <:col :let={a} label={gettext("Answer")}>
          <span id={"answer-#{a.answer.id}-state"}><.request_state state={a.answer.state} /></span>
        </:col>
        <:col :let={a} label={gettext("Details")} from="sm">
          <span
            id={"answer-#{a.answer.id}-details"}
            class="block max-w-[40ch] truncate"
            title={details(a.answer)}
          >
            {details(a.answer)}
          </span>
        </:col>
        <:col :let={a} label={gettext("By")} from="md">
          {if a.answer.answered_by_id,
            do: People.email(a.answer.answered_by) || People.former_member()}
        </:col>
        <:col :let={a} label={gettext("Answered")} from="md">
          <span class="tabular-nums">{Format.day(a.answer.answered_at)}</span>
        </:col>
      </.table>
    </SettingsComponents.part>
    """
  end

  attr :id, :string, required: true
  attr :answers, :list, required: true

  # A row's Answers: how many clients accepted, declined, have not answered or had it
  # withdrawn, the declined lifted, as the fact that needs the operator. Each part holds
  # its words and the comma after them, and the space between two parts is outside both,
  # so a narrow table breaks the line there and no line starts with a comma
  # (`.q-req-tally`).
  defp tally(assigns) do
    tally = answer_tally(assigns.answers)

    assigns =
      assign(assigns,
        parts:
          Enum.with_index(tally, fn {state, n}, i ->
            {tally_words(state, n), state == :declined, i}
          end),
        last: length(tally) - 1
      )

    ~H"""
    <span id={@id} class="q-req-tally" phx-no-format><%= for {t, hot, i} <- @parts do %>{space(i)}<span><span class={hot && "q-hot"}>{t}</span>{comma(i, @last)}</span><% end %></span>
    """
  end

  defp space(0), do: nil
  defp space(_index), do: " "

  defp comma(last, last), do: nil
  defp comma(_index, _last), do: ","

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
      class="q-cut max-w-[44ch]"
      title={first_change_text(@first)}
    >
      <.rich text={elem(elem(@first, 0), 1)} />{more_words(elem(@first, 1))}
    </span>
    """
  end

  attr :id, :string, required: true
  attr :to, :string, required: true

  # A request that is not among the 200 newest the page reads, or not there at all.
  defp gone(assigns) do
    ~H"""
    <div id={@id} class="grid gap-2">
      <p class="text-muted">
        {gettext("That request is not there, or is older than the 200 newest.")}
      </p>
      <p>
        <.link navigate={@to} class="text-accent hover:underline">
          {gettext("Back to the policy requests")}
        </.link>
      </p>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    # While the operator owns its clients (`ApiaryPro.Flags.operator_infrastructure?/0`),
    # policy requests are not there: the page is not found, as a path that does not exist.
    if ApiaryPro.Flags.operator_infrastructure?(), do: raise(ApiaryWeb.NotFound)

    {:ok,
     socket
     |> assign(
       page_title: gettext("Policy requests"),
       list: list_params(%{}),
       request_id: nil,
       requests: AsyncResult.loading()
     )
     |> reset_form()
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(list: list_params(params), request_id: params["id"])
      |> apply_action(socket.assigns.live_action)

    {:noreply, titled(socket)}
  end

  defp apply_action(socket, action) when action in [:index, :show], do: socket

  # The row asks only a reader who may withdraw; anyone else is told so, on the list.
  defp apply_action(socket, :withdraw) do
    scope = socket.assigns.current_scope

    if may?(scope, :"policy_request.withdraw") do
      socket
    else
      socket
      |> put_flash(:error, refusal(:"policy_request.withdraw"))
      |> push_patch(to: list_path(scope, socket.assigns.list))
    end
  end

  defp apply_action(socket, :new) do
    scope = socket.assigns.current_scope

    case PolicyRequests.recipients(scope) do
      {:ok, recipients} ->
        socket
        |> reset_form()
        |> assign(recipients: recipients, chosen: Enum.map(recipients, & &1.id))

      {:error, _refused} ->
        socket
        |> put_flash(:error, refusal(:"policy_request.send"))
        |> push_patch(to: ~p"/#{scope.organisation}/clients/requests")
    end
  end

  # The browser's title: the page, the list's name and the organisation's.
  defp titled(socket) do
    page =
      case socket.assigns.live_action do
        :new ->
          [gettext("New request")]

        :show ->
          case picked(socket.assigns.requests, socket.assigns.request_id) do
            %{request: request} -> [request_name(request)]
            nil -> []
          end

        _list ->
          []
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

  def handle_event("change_draft", %{"change" => params}, socket) do
    {:noreply, assign(socket, change_form: to_form(params, as: :change), change_error: nil)}
  end

  def handle_event("add_change", %{"change" => params}, socket) do
    entry = draft_entry(params)

    case Policy.requested_changes(%{"rules" => socket.assigns.draft ++ [entry]}) do
      {:ok, %{"rules" => rules}} ->
        {:noreply,
         assign(socket,
           draft: rules,
           change_form:
             to_form(Map.merge(@blank_change, Map.take(params, ["change"])), as: :change),
           change_error: nil
         )}

      {:error, %Policy.Error{message: message}} ->
        {:noreply,
         assign(socket, change_form: to_form(params, as: :change), change_error: message)}
    end
  end

  def handle_event("remove_change", %{"index" => index}, socket) do
    draft =
      case Integer.parse(to_string(index)) do
        {i, ""} -> List.delete_at(socket.assigns.draft, i)
        _other -> socket.assigns.draft
      end

    {:noreply, assign(socket, :draft, draft)}
  end

  def handle_event("validate", %{"request" => params}, socket) do
    {:noreply,
     assign(socket,
       form: to_form(Map.take(params, ["mode", "note"]), as: :request),
       chosen: chosen(params, socket.assigns.chosen)
     )}
  end

  def handle_event("send", params, socket) do
    scope = socket.assigns.current_scope
    request = Map.get(params, "request", %{})

    attrs = %{
      "changes" => %{"rules" => socket.assigns.draft, "mode" => request["mode"]},
      "note" => request["note"],
      "clients" => if(is_map(request["clients"]), do: checked(request["clients"]))
    }

    case PolicyRequests.send_request(scope, attrs) do
      {:ok, request} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           ngettext(
             "The request is sent to %{number} client.",
             "The request is sent to %{number} clients.",
             length(request.answers),
             number: Format.number(length(request.answers))
           )
         )
         |> reset_form()
         |> load()
         |> push_patch(to: ~p"/#{scope.organisation}/clients/requests")}

      {:error, %Policy.Error{message: message}} ->
        {:noreply,
         assign(socket,
           send_error: message,
           form: to_form(Map.take(request, ["mode", "note"]), as: :request)
         )}

      {:error, _refused} ->
        {:noreply,
         socket
         |> put_flash(:error, refusal(:"policy_request.send"))
         |> UserAuth.reload_scope()
         |> push_patch(to: ~p"/#{scope.organisation}/clients/requests")}
    end
  end

  # Whatever the answer, the list follows, with no row asking.
  def handle_event("withdraw", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    back = list_path(scope, socket.assigns.list)

    case PolicyRequests.withdraw(scope, id) do
      {:ok, _request} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext(
             "The request is withdrawn from the clients that had not answered it. The answers given stay."
           )
         )
         |> load()
         |> push_patch(to: back)}

      {:error, :withdrawn} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("That request is withdrawn already."))
         |> load()
         |> push_patch(to: back)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("That request is not there any more."))
         |> load()
         |> push_patch(to: back)}

      {:error, _refused} ->
        {:noreply,
         socket
         |> put_flash(:error, refusal(:"policy_request.withdraw"))
         |> UserAuth.reload_scope()
         |> push_patch(to: back)}
    end
  end

  # The requests, read again after a change; what was read before stays on the page
  # until they arrive. The page's title names the request a page is about once it has.
  defp load(socket) do
    scope = socket.assigns.current_scope
    start_async(socket, :requests, fn -> read(scope) end)
  end

  @impl true
  def handle_async(:requests, {:ok, {:ok, rows}}, socket) do
    {:noreply,
     socket |> assign(:requests, AsyncResult.ok(socket.assigns.requests, rows)) |> titled()}
  end

  def handle_async(:requests, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, :requests, AsyncResult.failed(socket.assigns.requests, reason))}

  def handle_async(:requests, {:exit, reason}, socket),
    do:
      {:noreply,
       assign(socket, :requests, AsyncResult.failed(socket.assigns.requests, {:exit, reason}))}

  # The requests with each client as it is now, its operator read with it, so a row
  # leads to a client only while it is still the operator's.
  defp read(scope) do
    with {:ok, rows} <- PolicyRequests.list_sent(scope) do
      clients =
        rows
        |> Enum.flat_map(& &1.answers)
        |> Enum.map(& &1.client)
        |> Enum.uniq_by(& &1.id)
        |> ApiaryPro.Tenants.put()
        |> Map.new(&{&1.id, &1})

      {:ok,
       Enum.map(rows, fn row ->
         %{row | answers: Enum.map(row.answers, &%{&1 | client: clients[&1.client.id]})}
       end)}
    end
  end

  defp reset_form(socket) do
    assign(socket,
      form: to_form(%{"mode" => "", "note" => ""}, as: :request),
      change_form: to_form(@blank_change, as: :change),
      change_error: nil,
      send_error: nil,
      draft: [],
      recipients: Map.get(socket.assigns, :recipients, []),
      chosen: Map.get(socket.assigns, :chosen, [])
    )
  end

  # A change of the draft as the form says it: the fields its action takes.
  defp draft_entry(%{"change" => "rule_removed"} = params),
    do: %{"change" => "rule_removed", "host" => params["host"]}

  defp draft_entry(params) do
    %{
      "change" => params["change"],
      "action" => params["action"],
      "host" => params["host"],
      "paths" => if(params["action"] != "deny", do: paths(params["paths"])),
      "locked" => params["locked"] == "true"
    }
  end

  # The paths a form's text names, one a line; none for every path.
  defp paths(text) when is_binary(text) do
    case String.split(text, ~r/[\s,]+/u, trim: true) do
      [] -> nil
      paths -> paths
    end
  end

  defp paths(_text), do: nil

  defp allowing?(form),
    do: form[:change].value != "rule_removed" and form[:action].value != "deny"

  defp chosen(%{"clients" => clients}, _chosen) when is_map(clients), do: checked(clients)
  defp chosen(_params, chosen), do: chosen

  defp checked(boxes), do: for({id, "true"} <- boxes, do: id)

  # Who sent a request: their address, or "Former member" for a deleted account.
  defp author(request), do: People.email(request.author) || People.former_member()

  # A person in a sentence: their first letter, with the address as its tooltip
  # (`ApiaryWeb.CoreComponents.avatar/1`).
  defp letter(email, reader) do
    assigns = %{email: email, reader: reader}
    ~H|<.avatar email={@email} reader={@reader} size="xs" />|
  end

  # A request is withdrawn while a client has not answered it.
  defp withdrawable?(%{request: %{withdrawn_at: nil}, answers: answers}),
    do: Enum.any?(answers, &(&1.answer.state == :pending))

  defp withdrawable?(_row), do: false

  defp withdraw_sentence(row) do
    waiting = Enum.count(row.answers, &(&1.answer.state == :pending))

    ngettext(
      "It is withdrawn from the %{number} client that has not answered it. The answers given stay.",
      "It is withdrawn from the %{number} clients that have not answered it. The answers given stay.",
      waiting,
      number: Format.number(waiting)
    )
  end

  defp details(%{state: :accepted, workspace_ids: ids}),
    do:
      ngettext("In %{number} workspace", "In %{number} workspaces", length(ids),
        number: Format.number(length(ids))
      )

  defp details(%{state: :declined, reason: reason}) when is_binary(reason),
    do: gettext("Reason: %{reason}", reason: reason)

  defp details(%{state: :withdrawn, reason: "left"}), do: gettext("The client left")
  defp details(%{state: :withdrawn, reason: "dropped"}), do: gettext("The client was dropped")
  defp details(%{state: :withdrawn, reason: "deleted"}), do: gettext("The client was deleted")
  defp details(_answer), do: nil

  # A client leads to itself while it is in use and still the operator's: its people read
  # it there.
  defp linked?(client, operator),
    do:
      is_nil(client.deletion_marked_at) and
        ApiaryPro.Tenants.operator_id(client) == operator.id

  defp tally_words(:accepted, n), do: gettext("%{number} accepted", number: Format.number(n))
  defp tally_words(:declined, n), do: gettext("%{number} declined", number: Format.number(n))
  defp tally_words(:pending, n), do: gettext("%{number} waiting", number: Format.number(n))
  defp tally_words(:withdrawn, n), do: gettext("%{number} withdrawn", number: Format.number(n))

  defp more_words(0), do: nil

  defp more_words(more),
    do:
      " " <>
        ngettext("and %{number} more", "and %{number} more", more, number: Format.number(more))

  defp first_change_text({{_kind, text}, more}),
    do: ApiaryWeb.RichText.plain_text(text) <> (more_words(more) || "")

  defp may?(scope, action), do: Access.can?(scope, action, scope.organisation)

  defp refusal(:"policy_request.send"),
    do: gettext("Only owners and admins of an operator send its clients a policy request.")

  defp refusal(:"policy_request.withdraw"),
    do: gettext("Only owners and admins of an operator withdraw its policy requests.")

  ## The list's views, search and filter, all in the URL

  defp views do
    [
      {"all", gettext("All")},
      {"waiting", gettext("Waiting")},
      {"answered", gettext("Answered")},
      {"withdrawn", gettext("Withdrawn")}
    ]
  end

  # Waiting: a client has not answered it; Answered: every client has; Withdrawn: the
  # operator withdrew it. The three make All, since only a request that waits is withdrawn.
  defp in_view?(_row, "all"), do: true
  defp in_view?(row, "waiting"), do: is_nil(row.request.withdrawn_at) and waiting?(row)
  defp in_view?(row, "answered"), do: is_nil(row.request.withdrawn_at) and not waiting?(row)
  defp in_view?(row, "withdrawn"), do: not is_nil(row.request.withdrawn_at)

  defp waiting?(row), do: Enum.any?(row.answers, &(&1.answer.state == :pending))

  defp empty_view("waiting"), do: gettext("Every request is answered.")
  defp empty_view("answered"), do: gettext("No request is answered by every client yet.")
  defp empty_view(_withdrawn), do: gettext("No request is withdrawn.")

  # The search and the client a request is kept by: words of its note, of a host it
  # changes or of a client's name, whatever their case; and a client it went to.
  defp found?(row, list), do: matches?(row, list.q) and sent_to?(row, list.client)

  defp matches?(_row, nil), do: true

  defp matches?(row, q) do
    q = String.downcase(q)

    [row.request.note | hosts(row.request.changes)]
    |> Enum.concat(Enum.map(row.answers, & &1.client.name))
    |> Enum.any?(&(is_binary(&1) and String.contains?(String.downcase(&1), q)))
  end

  defp hosts(%{"rules" => rules}) when is_list(rules),
    do: for(%{"rule" => %{"host" => host}} <- rules, do: host)

  defp hosts(_changes), do: []

  defp sent_to?(_row, nil), do: true
  defp sent_to?(row, id), do: Enum.any?(row.answers, &(&1.client.id == id))

  # Every client a listed request went to, by name, for the Client filter.
  defp clients(requests) do
    requests
    |> Enum.flat_map(& &1.answers)
    |> Enum.map(& &1.client)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(&{String.downcase(&1.name), &1.id})
  end

  defp narrowed?(list), do: not is_nil(list.q) or not is_nil(list.client)

  defp cleared(list), do: %{list | q: nil, client: nil}

  defp list_params(params) do
    %{
      view: if(params["view"] in ~w(waiting answered withdrawn), do: params["view"], else: "all"),
      q: blank(params["q"]),
      client: if(is_binary(params["client"]) and params["client"] != "", do: params["client"])
    }
  end

  defp blank(q) when is_binary(q), do: if(String.trim(q) == "", do: nil, else: String.trim(q))
  defp blank(_q), do: nil

  defp query(list) do
    Enum.filter(
      [{"view", list.view != "all" && list.view}, {"q", list.q}, {"client", list.client}],
      fn {_key, value} -> value end
    )
  end

  defp list_path(scope, list) do
    case query(list) do
      [] -> ~p"/#{scope.organisation}/clients/requests"
      query -> ~p"/#{scope.organisation}/clients/requests?#{query}"
    end
  end

  defp request_path(scope, request),
    do: ~p"/#{scope.organisation}/clients/requests/#{request.id}"

  # Withdraw… keeps the list as it was, so its row asks where it was.
  defp withdraw_path(scope, request, list) do
    case query(list) do
      [] -> ~p"/#{scope.organisation}/clients/requests/#{request.id}/withdraw"
      query -> ~p"/#{scope.organisation}/clients/requests/#{request.id}/withdraw?#{query}"
    end
  end

  # The request a page or a confirmation is about, among the rows read.
  defp find(rows, id) when is_binary(id), do: Enum.find(rows, &(&1.request.id == id))
  defp find(_rows, _id), do: nil

  defp picked(%AsyncResult{ok?: true, result: rows}, id), do: find(rows, id)
  defp picked(_requests, _id), do: nil

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

  # The row that asks to withdraw its request: once the rows have arrived, while a client
  # has not answered it, for a reader who may.
  defp confirming(rows, id, scope) do
    with %{} = row <- find(rows, id),
         true <- withdrawable?(row) and may?(scope, :"policy_request.withdraw") do
      "request-#{row.request.id}"
    else
      _no -> nil
    end
  end
end
