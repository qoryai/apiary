defmodule ApiaryProWeb.ClientLive.Index do
  @moduledoc """
  An operator's clients, an organisation's page: `/:org/clients`, for a reader who may
  `client.read` in an operator; in an organisation of another kind the path is not found.
  An operator provides a harness its clients run; each client is a separate organisation,
  which owns its people. Each client is listed with its status, in use or deleted and
  waiting for its purge, its owners, and since when it is the operator's client; its name
  leads to it, where the
  operator's people read everything and change nothing (`Apiary.Access`, Reach).

  An owner or an admin of the operator creates a client on a page of the list,
  `/:org/clients/new` (`client.create`): it is named, gets a slug and no workspace, and
  the address given is invited to the organisation, to be its first owner, against the
  operator's invitations (`ApiaryPro.Operators.create_client/3`). The first workspace is
  created from the kind cards on the client's overview (`/:org`): by its first person, an
  owner or, while the operator owns its clients, an admin, or by an owner of the operator
  while it owns them. A client with no
  workspace has Set up in its row's menu, a link to that page, for a person
  `workspace.create` allows in the client. While a client has no owner, they invite one
  again on another page, `/:org/clients/:id/owner` (`client.invite_owner`).
  Each page is a form on the core's pattern (`docs/ui.md`, A form is a page), its button
  beside Cancel back to the list. The New client page has a column beside the form, About
  clients (`ApiaryWeb.PageComponents.context_column/1`): what a client is, who its first
  person becomes and what they do, and what the operator's people can do in it.

  **Without mail** (`Apiary.Mail.configured?/0`) nothing is emailed: the invitation is
  kept, and each page shows its link in place of the form, once
  (`ApiaryWeb.CoreComponents.one_time_link/1`), for the operator's person to copy and
  send themselves, with Done back to the list; the invite page's button creates an
  invitation link. As on the core's People page, a link lives in the page's process
  alone, wrapped in a function so no inspection of the process's state prints it, until
  the reader leaves: any path starts without it, and no path, flash or title carries it.

  An owner of the operator drops a client that has an owner, confirmed in place on the
  client's row, never in a dialog, `/:org/clients/:id/drop` (`client.drop`), where the
  client's name is typed: it is an organisation with no operator at once. A client with no
  owner yet is deleted instead, by an owner of the operator, confirmed on its row the same
  way, `/:org/clients/:id/delete` (`client.delete`); while it has none, its Owner cell
  names each pending invitation of its first owner and when it expires, and its owners and
  admins revoke one from its row (`client.revoke_owner_invitation`). Without mail they
  make a new link for one from its row too (`client.renew_owner_invitation`): the old link
  stops working, and the new one is shown once, in place on the client's row, with Done,
  held as the pages' links are; with mail it is emailed. The list follows the membership
  changes a parting tells the operator's people of.

  The list is one column, on the core's pattern of Nodes: its views, its search, its
  Features filter and its order are in the URL, and a status line, always there, says how
  many clients the search and the filters leave, or, where none is left, why, with Clear
  filters. Nothing beside it repeats a page or a view: the operator's policy requests are
  a separate page in the sidebar (`ApiaryProWeb.ClientLive.Requests`), and the clients
  without an owner are a view.

  Each client shows its features; an owner of the operator grants them on a page of the
  list, `/:org/clients/:id/features` (`client.grant_features`, `ApiaryPro.Grants`), of the
  operator's features. Of the features a grant can name, a client has only what it is
  granted: such a feature the operator gains reaches it once granted here. A save refused
  because the other features need Runs stays on the page, the boxes as they were sent and
  why under them.
  """
  # Hidden (`ApiaryPro.Flags.transfers?/0`), so not in the published documentation: the
  # organisations their owners offered to the operator (`ApiaryPro.Transfers`) are listed
  # above the clients, where an owner of the operator accepts one (`client.accept`), after
  # the offer's row asks in place, `/:org/clients/offers/:id/accept`, its button not red:
  # it becomes a client, its people keeping their levels. The list follows the membership
  # changes an offer and an acceptance tell the operator's people of too.
  use ApiaryProWeb, :live_view
  use ApiaryWeb.Features, :managed_organisations
  on_mount {ApiaryWeb.Access, :"client.read"}

  alias Apiary.{Access, Deletion, Features, Mail}
  alias ApiaryPro.{Flags, Grants, Operators, Reach, Transfers}
  alias ApiaryProWeb.{ConfirmComponents, FeatureComponents}
  alias ApiaryWeb.{People, SettingsComponents, UserAuth}
  alias Phoenix.LiveView.AsyncResult

  @impl true
  # Creating a client, inviting its owner and granting its features are pages of the
  # list, on the core's pattern of a form (`docs/ui.md`, A form is a page): the breadcrumb
  # ending Clients and the act, its title and one sentence, the form with its first field
  # focused, and its button with Cancel back to the list. New client has no sentence under
  # its title: its context is a column beside the form.
  def render(%{live_action: action} = assigns)
      when action in [:new, :invite_owner, :invite_admin, :features] do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:clients}
      width={if @live_action == :new, do: "list", else: "read"}
    >
      <:crumb navigate={clients_path(@current_scope)}>{gettext("Clients")}</:crumb>
      <:crumb>{crumb(@live_action)}</:crumb>

      <%= if @live_action == :new do %>
        <.new_client
          form={@form}
          scope={@current_scope}
          link={@link}
          mail?={@mail?}
          owns?={@owns?}
        />
      <% else %>
        <.async_result assign={@clients}>
          <:loading>
            <div id="client-page-loading" aria-busy="true">
              <span class="sr-only">{gettext("Loading the clients")}</span>
              <span class="skeleton q-skel w-48"></span>
            </div>
          </:loading>
          <:failed>
            <.notice kind={:error} class="max-w-[80ch]">
              <span id="clients-error">
                {gettext(
                  "The clients could not be loaded. Reload the page; if it keeps happening, Qory Apiary's log has the reason."
                )}
              </span>
            </.notice>
          </:failed>
          <p :if={chosen(@clients, @client_id) == []} id="client-gone" class="text-muted">
            {gettext("That client is not there any more.")}
            <.link patch={clients_path(@current_scope)} class="link">
              {gettext("Back to the clients")}
            </.link>
          </p>
          <%= for client <- chosen(@clients, @client_id) do %>
            <.invite_owner
              :if={@live_action in [:invite_owner, :invite_admin]}
              client={client}
              form={@owner_form}
              scope={@current_scope}
              link={@link}
              mail?={@mail?}
              owns?={@owns?}
            />
            <.client_features
              :if={@live_action == :features}
              client={client}
              scope={@current_scope}
              refused={@refused_features}
            />
          <% end %>
        </.async_result>
      <% end %>
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
      nav={:clients}
    >
      <:crumb>{gettext("Clients")}</:crumb>

      <.page_header title={gettext("Clients")}>
        <:description>
          <%= if @owns? do %>
            {gettext(
              "The organisations that run the harness %{operator} provides. %{operator} owns each one: its owners and admins run the workspaces, machines and keys there. Each client's admins manage its people.",
              operator: @current_scope.organisation.name
            )}
          <% else %>
            {gettext(
              "The organisations that run the harness %{operator} provides. Each client's owners manage its people. The people of %{operator} read everything in each client, to keep it working, and change nothing there.",
              operator: @current_scope.organisation.name
            )}
          <% end %>
        </:description>
        <:actions :if={Access.can?(@current_scope, :"client.create", @current_scope.organisation)}>
          <.button
            id="new-client"
            variant="primary"
            patch={~p"/#{@current_scope.organisation}/clients/new"}
          >
            <.icon name="hero-plus-micro" class="size-4" /> {gettext("New client")}
          </.button>
        </:actions>
      </.page_header>

      <%!-- The organisations offered to the operator are shown only while they may be
           offered and accepted (`ApiaryPro.Flags.transfers?/0`): an offer made before is
           not listed either. --%>
      <.async_result :let={offers} :if={@transfers?} assign={@offers}>
        <:failed>
          <.notice kind={:error} class="max-w-[80ch]">
            <span id="offers-error">
              {gettext(
                "The organisations offered to %{operator} could not be loaded. Reload the page; if it keeps happening, Qory Apiary's log has the reason.",
                operator: @current_scope.organisation.name
              )}
            </span>
          </.notice>
        </:failed>

        <section :if={offers != []} id="offers" class="grid gap-3">
          <div>
            <h2 class="flex items-baseline gap-2 text-[14px]/5 font-semibold">
              {gettext("Offered to %{operator}", operator: @current_scope.organisation.name)}
              <span class="text-[12.5px] font-normal tabular-nums text-faint">
                {Format.number(length(offers))}
              </span>
            </h2>
            <p class="mt-0.5 max-w-[72ch] text-[12.5px]/[18px] text-muted">
              {if Access.can?(@current_scope, :"client.accept", @current_scope.organisation),
                do:
                  gettext(
                    "Their owners offer these organisations to %{operator}. When you accept one, it is a client: it runs the harness of %{operator}, its people keep their levels, and the people of %{operator} read everything in it.",
                    operator: @current_scope.organisation.name
                  ),
                else:
                  gettext(
                    "Their owners offer these organisations to %{operator}. An owner of %{operator} accepts one; it is a client then: it runs the harness of %{operator}, its people keep their levels, and the people of %{operator} read everything in it.",
                    operator: @current_scope.organisation.name
                  )}
              <span id="offers-features">
                {gettext(
                  "Once accepted, an organisation has what %{operator} grants its clients, which may be fewer features than it has now.",
                  operator: @current_scope.organisation.name
                )}
              </span>
            </p>
          </div>
          <.table
            id="offers-list"
            label={gettext("Offered to %{operator}", operator: @current_scope.organisation.name)}
            rows={offers}
            row_id={&"offer-#{&1.organisation.id}"}
            confirming={offer_confirming(@live_action, offers, @offer_id)}
          >
            <:col :let={o} label={gettext("Organisation")} kind="title">
              <span class="q-nm">
                <.avatar name={o.organisation.name} kind="organisation" />
                <span class="q-title">{o.organisation.name}</span>
                <span class="q-side q-mono">{o.organisation.slug}</span>
              </span>
            </:col>
            <:col :let={o} label={gettext("Offered")} from="sm">
              <span class="tabular-nums">{Format.day(o.transfer.inserted_at)}</span>
            </:col>
            <:confirm :let={o}>
              <.inline_confirm
                id={"offer-#{o.organisation.id}-confirm"}
                question={gettext("Accept %{name} as a client?", name: o.organisation.name)}
                cancel={clients_path(@current_scope)}
              >
                {gettext(
                  "It becomes a client of %{operator} at once: its people keep their levels, the people of %{operator} read everything in it, and it has only the features %{operator} grants its clients.",
                  operator: @current_scope.organisation.name
                )}
                <:action>
                  <%!-- Not red: nothing is lost that cannot be had again, so the row
                       keeps the neutral tint. --%>
                  <.button
                    id={"offer-#{o.organisation.id}-confirm-button"}
                    variant="primary"
                    size="xs"
                    phx-click="accept_client"
                    phx-value-id={o.organisation.id}
                    loading_text={gettext("Accepting")}
                  >
                    {gettext("Yes, accept")}
                  </.button>
                </:action>
              </.inline_confirm>
            </:confirm>
            <:action :let={o}>
              <.button
                :if={may?(@current_scope, :"client.accept")}
                id={"offer-#{o.organisation.id}-accept"}
                variant="link"
                patch={~p"/#{@current_scope.organisation}/clients/offers/#{o.organisation.id}/accept"}
                aria-label={gettext("Accept %{name} as a client", name: o.organisation.name)}
              >
                {gettext("Accept")}
              </.button>
            </:action>
          </.table>
        </section>
      </.async_result>

      <.async_result :let={clients} assign={@clients}>
        <:loading>
          <div
            id="clients-loading"
            class="overflow-hidden rounded-box border border-line bg-base-100 shadow-xs"
            aria-busy="true"
          >
            <span class="sr-only">{gettext("Loading the clients")}</span>
            <div
              :for={n <- 1..4}
              class="flex h-11 items-center gap-6 border-b border-line px-4 last:border-b-0"
            >
              <span class={["skeleton q-skel", if(rem(n, 2) == 0, do: "w-40", else: "w-28")]}></span>
              <span class="skeleton q-skel w-20"></span>
              <span class="skeleton q-skel w-24 max-md:hidden"></span>
            </div>
          </div>
        </:loading>
        <:failed>
          <.notice kind={:error} class="max-w-[80ch]">
            <span id="clients-error">
              {gettext(
                "The clients could not be loaded. Reload the page; if it keeps happening, Qory Apiary's log has the reason."
              )}
            </span>
          </.notice>
        </:failed>

        <div :if={clients == []} id="clients-empty">
          <.empty_state
            icon="hero-building-storefront"
            tone="neutral"
            title={gettext("No clients yet")}
          >
            <p>
              {gettext(
                "A client is a separate organisation, with its workspaces, people and activity, that runs the harness %{operator} provides.",
                operator: @current_scope.organisation.name
              )}
            </p>
            <%!-- A reader who adds no client is told who does, where the button would be. --%>
            <p :if={!may?(@current_scope, :"client.create")} id="clients-who">
              <%= if @owns? do %>
                {gettext(
                  "Only owners and admins of %{operator} add a client and invite its first admin.",
                  operator: @current_scope.organisation.name
                )}
              <% else %>
                {gettext(
                  "Only owners and admins of %{operator} add a client and invite its first owner; only owners drop one.",
                  operator: @current_scope.organisation.name
                )}
              <% end %>
            </p>
            <:actions :if={Access.can?(@current_scope, :"client.create", @current_scope.organisation)}>
              <.button patch={~p"/#{@current_scope.organisation}/clients/new"}>
                {gettext("Create the first client")}
              </.button>
            </:actions>
          </.empty_state>
        </div>

        <div :if={clients != []} class="grid gap-3">
          <.views id="clients-views" label={gettext("Views")}>
            <:view
              :for={{view, label} <- view_labels(@owns?)}
              id={"clients-view-#{view}"}
              patch={list_path(@current_scope, @list, view: view)}
              count={Format.number(Enum.count(clients, &in_view?(&1, view)))}
              current={@list.view == view}
            >
              {label}
            </:view>
          </.views>

          <div class="q-bar">
            <.list_search
              id="clients-search"
              label={gettext("Find a client")}
              placeholder={
                if @owns?,
                  do: gettext("Find a client by name, slug or admin"),
                  else: gettext("Find a client by name, slug or owner")
              }
              value={@list.q}
            />
            <.filter_menu id="clients-filter" count={length(@list.features)}>
              <.menu_heading title={gettext("Features")} sub={filter_sub()} />
              <.menu_item
                :for={feature <- filter_features()}
                id={"clients-filter-#{feature}"}
                checked={feature in @list.features}
                multiple
                patch={list_path(@current_scope, @list, features: toggle(@list.features, feature))}
              >
                {FeatureComponents.label(feature)}
              </.menu_item>
            </.filter_menu>
            <.sort_menu id="clients-sort" current={sort_label(@list.sort)}>
              <.menu_item
                :for={{sort, label} <- sorts()}
                id={"clients-sort-#{sort}"}
                checked={@list.sort == sort}
                patch={list_path(@current_scope, @list, sort: sort)}
              >
                {label}
              </.menu_item>
            </.sort_menu>
          </div>
          <.filter_tokens
            id="clients-tokens"
            clear={list_path(@current_scope, @list, features: [])}
          >
            <:token
              :for={feature <- @list.features}
              patch={list_path(@current_scope, @list, features: @list.features -- [feature])}
              label={gettext("Remove the filter %{filter}", filter: FeatureComponents.label(feature))}
            >
              {feature_chip(feature)}
            </:token>
          </.filter_tokens>

          <%!-- Always there, so a screen reader hears what the search left. --%>
          <div id="clients-status" role="status" class="q-status">
            <p
              :if={narrowed?(@list) && shown(clients, @list) != []}
              id="clients-summary"
            >
              {ngettext(
                "%{number} client matches",
                "%{number} clients match",
                length(shown(clients, @list)),
                number: Format.number(length(shown(clients, @list)))
              )}
            </p>
            <div :if={shown(clients, @list) == []} id="clients-none">
              <.empty_state
                icon={nil}
                tone="neutral"
                title={
                  if narrowed?(@list),
                    do: gettext("No client matches"),
                    else: gettext("No client here")
                }
              >
                <p :if={narrowed?(@list)}>
                  {if @owns?,
                    do: gettext("No client has that name, slug, admin or feature."),
                    else: gettext("No client has that name, slug, owner or feature.")}
                </p>
                <p :if={!narrowed?(@list) && none_sentence(@list.view, @owns?)}>
                  {none_sentence(@list.view, @owns?)}
                </p>
                <:actions :if={narrowed?(@list)}>
                  <.button
                    id="clients-none-clear"
                    patch={list_path(@current_scope, @list, q: nil, features: [])}
                  >
                    {gettext("Clear filters")}
                  </.button>
                </:actions>
              </.empty_state>
            </div>
          </div>

          <.table
            :if={shown(clients, @list) != []}
            id="clients"
            label={gettext("Clients")}
            rows={shown(clients, @list)}
            row_id={&"client-#{&1.organisation.id}"}
            row_class={&(!in_use?(&1) && "row-off")}
            confirming={
              (@renewed && "client-#{@renewed.client_id}") ||
                confirming(@live_action, @clients, @client_id)
            }
          >
            <:col :let={c} label={gettext("Client")} kind="title">
              <span class="q-nm">
                <.avatar name={c.organisation.name} kind="organisation" />
                <%= if in_use?(c) do %>
                  <.link
                    id={"client-#{c.organisation.id}-link"}
                    navigate={~p"/#{c.organisation}"}
                    class="q-title hover:underline"
                    title={c.organisation.name}
                  >
                    {c.organisation.name}
                  </.link>
                <% else %>
                  <span class="q-title" title={c.organisation.name}>{c.organisation.name}</span>
                <% end %>
                <span class="q-side q-mono">{c.organisation.slug}</span>
                <span id={"client-#{c.organisation.id}-status"} class="text-[12.5px] font-normal">
                  <%= cond do %>
                    <% !in_use?(c) -> %>
                      <.state_word>
                        {gettext("Deleted, purged on %{date}",
                          date: Format.date(c.organisation.purge_after)
                        )}
                      </.state_word>
                    <% ApiaryPro.Tenants.suspended?(c.organisation) -> %>
                      <.state_word>{gettext("Suspended")}</.state_word>
                    <% true -> %>
                      <span class="sr-only">{gettext("In use")}</span>
                  <% end %>
                </span>
              </span>
            </:col>
            <:col
              :let={c}
              label={if @owns?, do: gettext("Admins"), else: gettext("Owner")}
              from="sm"
            >
              <span
                id={"client-#{c.organisation.id}-owners"}
                class="block max-w-[36ch] truncate"
                title={owners_text(c, @owns?)}
              >
                <%= if people(c) == [] do %>
                  <span class="q-faint">{nobody_yet(@owns?)}</span>
                  <span :for={i <- c.owner_invitations} id={"owner-invitation-#{i.id}"}>
                    <%!-- The expiry before the address, so the cut takes the address. --%> ·
                    <span
                      id={"owner-invitation-#{i.id}-expires"}
                      class={expires_soon?(i) && "q-hot"}
                    >
                      {expires(i)}
                    </span>
                    · {gettext("Invited: %{email}", email: i.email)}
                  </span>
                <% else %>
                  {Enum.map_join(people(c), ", ", &People.email/1)}
                <% end %>
              </span>
            </:col>
            <:col :let={c} label={gettext("Members")} kind="num" from="md">
              {Format.number(c.people)}
            </:col>
            <%!-- The column that gives way, as the instance's organisations' does: it
                   takes the room the others leave, and a list longer than that is cut,
                   whole in its title. --%>
            <:col :let={c} label={gettext("Features")} from="md" class="w-[30%] max-w-0">
              <FeatureComponents.feature_words
                id={"client-#{c.organisation.id}-features"}
                features={c.features}
                class="block truncate"
                title={FeatureComponents.feature_text(c.features)}
              />
            </:col>
            <:col :let={c} label={gettext("Joined")} from="sm">
              <span id={"client-#{c.organisation.id}-joined"} class="tabular-nums">
                {Format.day(joined(c))}
              </span>
            </:col>
            <:confirm :let={c}>
              <%!-- A new link for its owner's invitation, shown once in place of the row's
                     cells, with no step before it. --%>
              <.one_time_link
                :if={@renewed && @renewed.client_id == c.organisation.id}
                id={"owner-invitation-#{@renewed.invitation.id}-link"}
                kind={:invitation}
                url={@renewed.url.()}
                expires_at={@renewed.invitation.expires_at}
                for={@renewed.invitation.email}
                class="py-1"
              >
                <:actions>
                  <.button
                    id={"owner-invitation-#{@renewed.invitation.id}-link-done"}
                    variant="primary"
                    size="xs"
                    phx-click="link_done"
                  >
                    {gettext("Done")}
                  </.button>
                </:actions>
              </.one_time_link>
              <.client_confirm
                :if={!@renewed}
                act={@live_action}
                client={c}
                form={@drop_form}
                scope={@current_scope}
                owns?={@owns?}
              />
            </:confirm>
            <:action :let={c}>
              <.row_menu
                :if={in_use?(c)}
                id={"client-#{c.organisation.id}-menu"}
                label={gettext("Actions for %{name}", name: c.organisation.name)}
              >
                <.menu_item
                  :if={may_set_up?(@current_scope, c)}
                  id={"client-#{c.organisation.id}-set-up"}
                  navigate={~p"/#{c.organisation}"}
                >
                  {gettext("Set up")}
                </.menu_item>
                <.menu_item
                  :if={!@owns? && c.owners == [] && may?(@current_scope, :"client.invite_owner")}
                  id={"client-#{c.organisation.id}-invite-owner"}
                  patch={~p"/#{@current_scope.organisation}/clients/#{c.organisation.id}/owner"}
                  aria-label={gettext("Invite the owner of %{name}", name: c.organisation.name)}
                >
                  {gettext("Invite owner…")}
                </.menu_item>
                <.menu_item
                  :if={@owns? && people(c) == [] && may?(@current_scope, :"client.invite_admin")}
                  id={"client-#{c.organisation.id}-invite-admin"}
                  patch={~p"/#{@current_scope.organisation}/clients/#{c.organisation.id}/admin"}
                  aria-label={gettext("Invite the first admin of %{name}", name: c.organisation.name)}
                >
                  {gettext("Invite the first admin…")}
                </.menu_item>
                <.menu_item
                  :for={i <- c.owner_invitations}
                  :if={
                    !@mail? && people(c) == [] &&
                      may?(@current_scope, first_action(:renew, @owns?))
                  }
                  id={"owner-invitation-#{i.id}-renew"}
                  phx-click={first_event(:renew, @owns?)}
                  phx-value-client={c.organisation.id}
                  phx-value-id={i.id}
                  hint={i.email}
                  aria-label={gettext("Make a new link for %{email}", email: i.email)}
                >
                  {gettext("Make a new link")}
                </.menu_item>
                <.menu_item
                  :for={i <- c.owner_invitations}
                  :if={people(c) == [] && may?(@current_scope, first_action(:revoke, @owns?))}
                  id={"owner-invitation-#{i.id}-revoke"}
                  phx-click={first_event(:revoke, @owns?)}
                  phx-value-client={c.organisation.id}
                  phx-value-id={i.id}
                  hint={i.email}
                  aria-label={gettext("Revoke the invitation of %{email}", email: i.email)}
                >
                  {gettext("Revoke the invitation")}
                </.menu_item>
                <.menu_item
                  :if={may_grant?(@current_scope)}
                  id={"client-#{c.organisation.id}-features-button"}
                  patch={~p"/#{@current_scope.organisation}/clients/#{c.organisation.id}/features"}
                  aria-label={gettext("Features of %{name}", name: c.organisation.name)}
                >
                  {gettext("Features…")}
                </.menu_item>
                <.menu_item
                  :if={deletable?(c, @owns?) && may?(@current_scope, :"client.delete")}
                  id={"client-#{c.organisation.id}-delete"}
                  patch={~p"/#{@current_scope.organisation}/clients/#{c.organisation.id}/delete"}
                  aria-label={gettext("Delete %{name}", name: c.organisation.name)}
                >
                  {gettext("Delete…")}
                </.menu_item>
                <.menu_item
                  :if={c.owners != [] && may?(@current_scope, :"client.drop")}
                  id={"client-#{c.organisation.id}-drop"}
                  patch={~p"/#{@current_scope.organisation}/clients/#{c.organisation.id}/drop"}
                  aria-label={gettext("Drop %{name}", name: c.organisation.name)}
                >
                  {gettext("Drop…")}
                </.menu_item>
              </.row_menu>
            </:action>
          </.table>
        </div>
      </.async_result>
    </Layouts.app>
    """
  end

  defp crumb(:new), do: gettext("New client")
  defp crumb(:invite_owner), do: gettext("Invite owner")
  defp crumb(:invite_admin), do: gettext("Invite the first admin")
  defp crumb(:features), do: gettext("Features")

  attr :form, :any, required: true
  attr :scope, :any, required: true

  attr :link, :map,
    default: nil,
    doc: "the client created without mail, and its owner's link, shown once in place of the form"

  attr :mail?, :boolean, default: true
  attr :owns?, :boolean, default: false

  defp new_client(assigns) do
    ~H"""
    <.settings_page section={:clients} title={gettext("New client")}>
      <%!-- The client created without mail, and its owner's link, once, in place of the form. --%>
      <div :if={@link} id="client-created" class="grid gap-3">
        <p id="client-created-name" class="text-[13px]/5">
          {gettext("%{name} is created.", name: @link.client.name)}
        </p>
        <.owner_link link={@link} scope={@scope} />
      </div>
      <.form
        :if={!@link}
        for={@form}
        id="client-form"
        phx-change="validate"
        phx-submit="create"
        class="grid gap-4"
        novalidate
      >
        <.input
          field={@form[:name]}
          type="text"
          label={gettext("Name")}
          autocomplete="off"
          required
          phx-mounted={JS.focus()}
        />
        <.input
          field={@form[:email]}
          type="email"
          label={email_label(@owns?)}
          autocomplete="off"
          required
        />
        <.page_form_foot id="client-save" cancel={clients_path(@scope)} cancel_by="patch">
          <.button
            id="create-client"
            variant="primary"
            type="submit"
            loading_text={gettext("Creating")}
          >
            {gettext("Create client")}
          </.button>
        </.page_form_foot>
      </.form>
      <:context :if={!@link} about={gettext("About clients")}>
        <p id="client-about">
          {gettext(
            "A client is a separate organisation that runs the harness %{operator} provides. It starts with no workspace.",
            operator: @scope.organisation.name
          )}
        </p>
        <%= if @owns? do %>
          <p id="client-first-person">
            {gettext(
              "The person you invite becomes its first admin when they accept. They invite and manage its people."
            )}
          </p>
          <p id="client-operator-reach">
            {gettext(
              "The first admin creates the client's first workspace. Owners and admins of %{operator} run its workspaces, machines and keys.",
              operator: @scope.organisation.name
            )}
          </p>
        <% else %>
          <p id="client-first-person">
            {gettext(
              "The person you invite becomes its owner when they accept. They set up its first workspace and invite its people."
            )}
          </p>
          <p id="client-operator-reach">
            {gettext(
              "The people of %{operator} read everything in the client and change nothing there.",
              operator: @scope.organisation.name
            )}
          </p>
        <% end %>
      </:context>
    </.settings_page>
    """
  end

  attr :client, :map, required: true
  attr :form, :any, required: true
  attr :scope, :any, required: true

  attr :link, :map,
    default: nil,
    doc: "the invitation made without mail, and its link, shown once in place of the form"

  attr :mail?, :boolean, default: true
  attr :owns?, :boolean, default: false

  defp invite_owner(assigns) do
    ~H"""
    <.page_form
      id="invite-owner"
      title={
        if @owns?,
          do: gettext("Invite the first admin of %{name}", name: @client.organisation.name),
          else: gettext("Invite the owner of %{name}", name: @client.organisation.name)
      }
      cancel={clients_path(@scope)}
      cancel_by="patch"
    >
      <:description :if={!@link}>
        <%= if @owns? do %>
          {gettext(
            "%{name} has no admin yet. The person you invite is its first admin once they accept, and invites and manages its people. The invitation counts against the invitations of %{operator}.",
            name: @client.organisation.name,
            operator: @scope.organisation.name
          )}
        <% else %>
          {gettext(
            "%{name} has no owner yet. The person you invite is its owner once they accept, and invites and manages its people. The invitation counts against the invitations of %{operator}.",
            name: @client.organisation.name,
            operator: @scope.organisation.name
          )}
        <% end %>
      </:description>
      <%!-- The link made without mail, once, in place of the form. --%>
      <.owner_link :if={@link} link={@link} scope={@scope} />
      <.form
        :if={!@link}
        for={@form}
        id="invite-owner-form"
        phx-submit={if @owns?, do: "invite_admin", else: "invite_owner"}
        class="grid gap-4"
        novalidate
      >
        <input type="hidden" name="client_id" value={@client.organisation.id} />
        <.input
          field={@form[:email]}
          type="email"
          label={email_label(@owns?)}
          autocomplete="off"
          required
          phx-mounted={JS.focus()}
        />
        <.page_form_foot id="invite-owner-save" cancel={clients_path(@scope)} cancel_by="patch">
          <.button
            :if={@mail?}
            id="invite-owner-confirm"
            variant="primary"
            type="submit"
            loading_text={gettext("Inviting")}
          >
            {gettext("Send invitation")}
          </.button>
          <.button
            :if={!@mail?}
            id="invite-owner-confirm"
            variant="primary"
            type="submit"
            loading_text={gettext("Creating…")}
          >
            {gettext("Create invitation link")}
          </.button>
        </.page_form_foot>
      </.form>
    </.page_form>
    """
  end

  # The link of a client's first owner's invitation, made without mail: shown once, in the
  # core's component, with Done back to the list. The link is held in the page's process
  # alone, in a function so no inspection of its state prints it, and never in a path, a
  # flash or the title.
  attr :link, :map, required: true
  attr :scope, :any, required: true

  defp owner_link(assigns) do
    ~H"""
    <.one_time_link
      id="owner-link"
      kind={:invitation}
      url={@link.url.()}
      expires_at={@link.invitation.expires_at}
      for={@link.invitation.email}
    >
      <:actions>
        <.button id="owner-link-done" variant="primary" patch={clients_path(@scope)}>
          {gettext("Done")}
        </.button>
      </:actions>
    </.one_time_link>
    """
  end

  attr :client, :map, required: true
  attr :scope, :any, required: true

  attr :refused, :map,
    default: nil,
    doc: "the save refused for the boxes it sent: those boxes, and why, under them"

  defp client_features(assigns) do
    offered = offered(assigns.client.organisation)

    {has, errors} =
      case assigns.refused do
        %{client_id: id, features: sent, errors: errors}
        when id == assigns.client.organisation.id ->
          {Enum.filter(offered, &(Atom.to_string(&1) in sent)), errors}

        _none ->
          {assigns.client.features ++ Grants.parts_kept(assigns.client.organisation), []}
      end

    assigns = assign(assigns, offered: offered, has: has, errors: errors)

    ~H"""
    <.page_form
      id="client-features-page"
      title={gettext("Features of %{name}", name: @client.organisation.name)}
      cancel={clients_path(@scope)}
      cancel_by="patch"
    >
      <:description>
        {client_features_sentence(@client.organisation, @scope.organisation)}
      </:description>
      <.form
        for={%{}}
        id="client-features-form"
        phx-submit="save_client_features"
        class="grid gap-4"
        novalidate
      >
        <input type="hidden" name="client_id" value={@client.organisation.id} />
        <FeatureComponents.feature_fields
          id="client-features"
          offered={@offered}
          has={@has}
          errors={@errors}
          operator={@scope.organisation.name}
        />
        <.page_form_foot id="client-features-save" cancel={clients_path(@scope)} cancel_by="patch">
          <.button
            id="client-features-confirm"
            variant="primary"
            type="submit"
            loading_text={gettext("Saving")}
          >
            {gettext("Save features")}
          </.button>
        </.page_form_foot>
      </.form>
    </.page_form>
    """
  end

  # A drop or a deletion, confirmed in place on the client's row, at a separate path, the
  # client's name typed; Cancel and Escape go back to the list.
  attr :act, :atom, required: true
  attr :client, :map, required: true
  attr :form, :any, required: true
  attr :scope, :any, required: true
  attr :owns?, :boolean, default: false

  defp client_confirm(%{act: :drop} = assigns) do
    ~H"""
    <ConfirmComponents.typed_confirm
      id="drop-client"
      question={gettext("Drop %{name}?", name: @client.organisation.name)}
      form={@form}
      change="confirm_drop"
      submit="drop_client"
      ready={@form[:name].value == @client.organisation.name}
      button={gettext("Yes, drop")}
      loading_text={gettext("Dropping")}
      cancel={clients_path(@scope)}
    >
      <:lost>
        {gettext(
          "%{name} leaves %{operator} at once.",
          name: @client.organisation.name,
          operator: @scope.organisation.name
        )}
      </:lost>
      <:field>
        <input type="hidden" name="client_id" value={@client.organisation.id} />
        <.input
          field={@form[:name]}
          type="text"
          label={gettext("Type the name of %{name} to confirm", name: @client.organisation.name)}
          autocomplete="off"
          spellcheck="false"
          debounce="0"
        />
      </:field>
    </ConfirmComponents.typed_confirm>
    """
  end

  defp client_confirm(%{act: :delete} = assigns) do
    ~H"""
    <SettingsComponents.deletion_confirm
      id="delete-client"
      question={gettext("Delete %{name}?", name: @client.organisation.name)}
      form={@form}
      change="confirm_drop"
      submit="delete_client"
      ready={@form[:name].value == @client.organisation.name}
      cancel={clients_path(@scope)}
    >
      <:lost>
        <%= if @owns? do %>
          {gettext(
            "Nobody has joined %{name} yet. It disappears at once, with its pending invitations, and is purged after %{days}.",
            name: @client.organisation.name,
            days: ngettext("%{count} day", "%{count} days", Deletion.grace_days())
          )}
        <% else %>
          {gettext(
            "%{name} has no owner yet, so nobody else is in it. It disappears at once, with its pending invitations, and is purged after %{days}.",
            name: @client.organisation.name,
            days: ngettext("%{count} day", "%{count} days", Deletion.grace_days())
          )}
        <% end %>
      </:lost>
      <:field>
        <input type="hidden" name="client_id" value={@client.organisation.id} />
        <.input
          field={@form[:name]}
          type="text"
          label={gettext("Type the name of %{name} to confirm", name: @client.organisation.name)}
          autocomplete="off"
          spellcheck="false"
          debounce="0"
        />
      </:field>
    </SettingsComponents.deletion_confirm>
    """
  end

  # The row that asks to confirm its drop or its deletion: the client's, at the act's
  # path, once the rows have arrived and while it is in use.
  defp confirming(act, clients, id) when act in [:drop, :delete] do
    case chosen(clients, id) do
      [client] -> "client-#{client.organisation.id}"
      _none -> nil
    end
  end

  defp confirming(_act, _clients, _id), do: nil

  # The offer's row that asks to accept it, at its path, while it is offered.
  defp offer_confirming(:accept_offer, offers, id) do
    if Enum.any?(offers, &(&1.organisation.id == id)), do: "offer-#{id}"
  end

  defp offer_confirming(_act, _offers, _id), do: nil

  defp clients_path(scope), do: ~p"/#{scope.organisation}/clients"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: gettext("Clients"),
       form: to_form(Operators.change_new_client()),
       offer_id: nil,
       refused_features: nil,
       owner_form: to_form(%{}, as: :owner),
       drop_form: to_form(%{}, as: :confirm),
       client_id: nil,
       clients: AsyncResult.loading(),
       list: list_params(%{}),
       link: nil,
       renewed: nil,
       mail?: Mail.configured?(),
       # Whether the operator owns its clients (`ApiaryPro.Flags.operator_infrastructure?/0`):
       # the page's words, the first person's invitation and Drop follow it.
       owns?: Flags.operator_infrastructure?(),
       # Whether the organisations offered to the operator are shown
       # (`ApiaryPro.Flags.transfers?/0`).
       transfers?: Flags.transfers?()
     )
     |> load()
     |> follow_offers()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # Every path starts without a link shown: it is shown once, until the reader leaves.
    socket = assign(socket, link: nil, renewed: nil, mail?: Mail.configured?())

    socket =
      if socket.assigns.live_action == :index,
        do: assign(socket, :list, list_params(params)),
        else: socket

    {:noreply, socket |> apply_action(socket.assigns.live_action, params) |> titled()}
  end

  # The browser's title names the page, the act's else the list, and the operator, as the
  # core's Audit log names its organisation.
  defp titled(%{assigns: %{live_action: action}} = socket)
       when action in [:new, :invite_owner, :invite_admin, :features],
       do: assign(socket, :page_title, title(socket, [crumb(action), gettext("Clients")]))

  defp titled(socket), do: assign(socket, :page_title, title(socket, [gettext("Clients")]))

  defp title(socket, words),
    do: Enum.join(words ++ [socket.assigns.current_scope.organisation.name], " · ")

  defp apply_action(socket, :features, %{"id" => id}) do
    scope = socket.assigns.current_scope

    if may_grant?(scope) do
      assign(socket, client_id: id, refused_features: nil)
    else
      socket
      |> put_flash(:error, grant_refused(scope))
      |> push_patch(to: ~p"/#{scope.organisation}/clients")
    end
  end

  # An offer's row asks before it is accepted, at a separate path. Where `Apiary.Access`
  # does not find the action, the path is not found either, as a page that is not there,
  # with nothing said; refused, it goes back to the list and says why.
  defp apply_action(socket, :accept_offer, %{"id" => id}) do
    scope = socket.assigns.current_scope

    case Access.check(scope, :"client.accept", scope.organisation) do
      :ok ->
        assign(socket, client_id: nil, offer_id: id)

      {:error, :not_found} ->
        raise ApiaryWeb.NotFound

      {:error, _forbidden} ->
        socket
        |> put_flash(:error, refusal(:"client.accept", scope))
        |> push_patch(to: ~p"/#{scope.organisation}/clients")
    end
  end

  defp apply_action(socket, action, %{"id" => id})
       when action in [:invite_owner, :invite_admin, :drop, :delete] do
    scope = socket.assigns.current_scope
    hidden!(action, socket.assigns.owns?)

    needed =
      case action do
        :drop -> :"client.drop"
        :delete -> :"client.delete"
        :invite_owner -> :"client.invite_owner"
        :invite_admin -> :"client.invite_admin"
      end

    if may?(scope, needed) do
      socket
      |> assign(
        client_id: id,
        owner_form: to_form(%{}, as: :owner),
        drop_form: to_form(%{}, as: :confirm)
      )
      |> refuse_undeletable()
    else
      socket
      |> put_flash(:error, refusal(needed, scope))
      |> push_patch(to: ~p"/#{scope.organisation}/clients")
    end
  end

  defp apply_action(socket, action, _params),
    do: apply_action(assign(socket, client_id: nil, offer_id: nil), action)

  # While the operator owns its clients, the first owner's invitation and the drop are
  # not found, as pages that are not there; while it does not, the first admin's
  # invitation is.
  defp hidden!(action, true) when action in [:invite_owner, :drop], do: raise(ApiaryWeb.NotFound)
  defp hidden!(:invite_admin, false), do: raise(ApiaryWeb.NotFound)
  defp hidden!(_action, _owns?), do: :ok

  defp apply_action(socket, :index), do: socket

  defp apply_action(socket, :new) do
    scope = socket.assigns.current_scope

    if Access.can?(scope, :"client.create", scope.organisation) do
      assign(socket, :form, to_form(Operators.change_new_client()))
    else
      socket
      |> put_flash(:error, refusal(:"client.create", scope))
      |> push_patch(to: ~p"/#{scope.organisation}/clients")
    end
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    scope = socket.assigns.current_scope
    {:noreply, push_patch(socket, to: list_path(scope, socket.assigns.list, q: q), replace: true)}
  end

  def handle_event("save_client_features", %{"client_id" => id} = params, socket) do
    scope = socket.assigns.current_scope

    case Grants.set_client(scope, id, FeatureComponents.checked(params["features"])) do
      {:ok, _features} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("The client's features are saved."))
         |> load()
         |> push_patch(to: ~p"/#{scope.organisation}/clients")}

      # Refused as the boxes are: it stays, the boxes as they were sent and why under them,
      # until the next save.
      {:error, :needs} ->
        {:noreply,
         assign(socket, :refused_features, %{
           client_id: id,
           features: FeatureComponents.checked(params["features"]),
           errors: [needs_runs()]
         })}

      {:error, :above} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           above_operator(scope.organisation)
         )
         |> load()
         |> push_patch(to: ~p"/#{scope.organisation}/clients")}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("That client is not there any more."))
         |> load()
         |> push_patch(to: ~p"/#{scope.organisation}/clients")}

      {:error, :busy} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("Someone changed this at the same moment, so nothing was changed. Try again.")
         )
         |> load()
         |> push_patch(to: ~p"/#{scope.organisation}/clients")}

      {:error, _refused} ->
        {:noreply,
         socket
         |> put_flash(:error, grant_refused(scope))
         |> UserAuth.reload_scope()
         |> push_patch(to: ~p"/#{scope.organisation}/clients")}
    end
  end

  def handle_event("validate", %{"organisation" => params}, socket) do
    changeset = params |> Operators.change_new_client() |> Map.put(:action, :validate)
    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("create", %{"organisation" => params}, socket) do
    scope = socket.assigns.current_scope

    case Operators.create_client(scope, params, &url(~p"/invitations/#{&1}")) do
      {:ok, %{organisation: client, sent: {:ok, invitation}}} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           if(socket.assigns.owns?,
             do:
               gettext("%{name} is created, and %{email} is invited to be its first admin.",
                 name: client.name,
                 email: invitation.email
               ),
             else:
               gettext("%{name} is created, and %{email} is invited to be its owner.",
                 name: client.name,
                 email: invitation.email
               )
           )
         )
         |> load()
         |> push_patch(to: ~p"/#{scope.organisation}/clients")}

      # Without mail: the client is created, and its owner's link is shown once in place
      # of the form, in a function so no inspection of the process's state prints it.
      {:ok, %{organisation: client, sent: {:ok, invitation, {:link, link}}}} ->
        {:noreply,
         socket
         |> assign(:link, %{client: client, invitation: invitation, url: fn -> link end})
         |> load()}

      # Mail set since the invitation was written, for an inviter whose address is not
      # confirmed: the client is created, and its owner's invitation withdrawn unsent.
      {:ok, %{sent: {:error, :unconfirmed}}} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext(
             "Confirm your email address before you invite anyone: sign in again with the link we email you."
           )
         )
         |> load()
         |> push_patch(to: ~p"/#{scope.organisation}/clients")}

      {:ok, %{organisation: client}} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           if(socket.assigns.owns?,
             do:
               gettext(
                 "%{name} is created, but the invitation of its first admin could not be sent. Invite its first admin again here.",
                 name: client.name
               ),
             else:
               gettext(
                 "%{name} is created, but the invitation of its owner could not be sent. Invite its owner again here.",
                 name: client.name
               )
           )
         )
         |> load()
         |> push_patch(to: ~p"/#{scope.organisation}/clients")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}

      # With mail, an inviter whose address is not confirmed: nothing is created.
      {:error, :unconfirmed} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "Confirm your email address before you invite anyone: sign in again with the link we email you."
           )
         )}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, refusal(:"client.create", scope))
         |> UserAuth.reload_scope()
         |> push_patch(to: ~p"/#{scope.organisation}/clients")}
    end
  end

  def handle_event("invite_owner", params, socket), do: invite_first(params, socket, :owner)
  def handle_event("invite_admin", params, socket), do: invite_first(params, socket, :admin)

  def handle_event("confirm_drop", %{"confirm" => params}, socket) do
    {:noreply, assign(socket, :drop_form, to_form(params, as: :confirm))}
  end

  def handle_event("delete_client", %{"client_id" => id} = params, socket) do
    scope = socket.assigns.current_scope
    typed = get_in(params, ["confirm", "name"])

    case ApiaryPro.Deletion.delete_client(scope, id, typed) do
      {:ok, client} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("%{name} is deleted, and is purged on %{date}.",
             name: client.name,
             date: Format.date(client.purge_after)
           )
         )
         |> load()
         |> push_patch(to: ~p"/#{scope.organisation}/clients")}

      {:error, :confirmation} ->
        errors = [name: {dgettext_noop("errors", "is not the name"), []}]

        {:noreply,
         assign(socket, :drop_form, to_form(%{"name" => typed}, as: :confirm, errors: errors))}

      {:error, :has_owner} ->
        {:noreply,
         socket
         |> put_flash(:error, undeletable(:has_owner))
         |> load()
         |> push_patch(to: ~p"/#{scope.organisation}/clients")}

      {:error, :has_people} ->
        {:noreply,
         socket
         |> put_flash(:error, undeletable(:has_people))
         |> load()
         |> push_patch(to: ~p"/#{scope.organisation}/clients")}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("That client is not there any more."))
         |> load()
         |> push_patch(to: ~p"/#{scope.organisation}/clients")}

      {:error, _forbidden} ->
        {:noreply,
         socket
         |> put_flash(:error, refusal(:"client.delete", scope))
         |> UserAuth.reload_scope()
         |> push_patch(to: ~p"/#{scope.organisation}/clients")}
    end
  end

  def handle_event("revoke_owner_invitation", params, socket),
    do: revoke_first(params, socket, :owner)

  def handle_event("revoke_admin_invitation", params, socket),
    do: revoke_first(params, socket, :admin)

  def handle_event("renew_owner_invitation", params, socket),
    do: renew_first(params, socket, :owner)

  def handle_event("renew_admin_invitation", params, socket),
    do: renew_first(params, socket, :admin)

  def handle_event("link_done", _params, socket),
    do: {:noreply, assign(socket, :renewed, nil)}

  def handle_event("drop_client", %{"client_id" => id} = params, socket) do
    scope = socket.assigns.current_scope
    typed = get_in(params, ["confirm", "name"])

    case Transfers.drop(scope, id, typed) do
      {:ok, client} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("%{name} is no client of %{operator} any more.",
             name: client.name,
             operator: scope.organisation.name
           )
         )
         |> load()
         |> push_patch(to: ~p"/#{scope.organisation}/clients")}

      {:error, :busy} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Someone changed this at the same moment, so nothing was changed. Try again.")
         )}

      {:error, :confirmation} ->
        errors = [name: {dgettext_noop("errors", "is not the name"), []}]

        {:noreply,
         assign(socket, :drop_form, to_form(%{"name" => typed}, as: :confirm, errors: errors))}

      {:error, :no_owner} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext(
             "That client has no owner yet, so nobody would be left in it: delete it instead."
           )
         )
         |> load()
         |> push_patch(to: ~p"/#{scope.organisation}/clients")}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("That client is not there any more."))
         |> load()
         |> push_patch(to: ~p"/#{scope.organisation}/clients")}

      {:error, _forbidden} ->
        {:noreply,
         socket
         |> put_flash(:error, refusal(:"client.drop", scope))
         |> UserAuth.reload_scope()
         |> push_patch(to: ~p"/#{scope.organisation}/clients")}
    end
  end

  def handle_event("accept_client", %{"id" => id}, socket), do: accept_client(id, socket)

  # The invitation of a client's first person: its first owner, or, while the operator
  # owns its clients, its first admin.
  defp invite_first(%{"client_id" => id} = params, socket, first) do
    scope = socket.assigns.current_scope
    attrs = Map.get(params, "owner", %{})

    case invite_fun(first).(scope, id, attrs, &url(~p"/invitations/#{&1}")) do
      # Without mail: the link, shown once in place of the form, as the create page's.
      {:ok, invitation, {:link, link}} ->
        {:noreply,
         socket
         |> assign(:link, %{invitation: invitation, url: fn -> link end})
         |> load()}

      {:ok, invitation} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           if(first == :admin,
             do: gettext("%{email} is invited to be the first admin.", email: invitation.email),
             else: gettext("%{email} is invited to be the owner.", email: invitation.email)
           )
         )
         |> load()
         |> push_patch(to: ~p"/#{scope.organisation}/clients")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :owner_form, to_form(changeset, as: :owner, action: :insert))}

      {:error, :has_owner} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("That client has an owner now, who invites its people.")
         )
         |> load()
         |> push_patch(to: ~p"/#{scope.organisation}/clients")}

      {:error, :has_admin} ->
        {:noreply,
         socket
         |> put_flash(:error, has_admin())
         |> load()
         |> push_patch(to: ~p"/#{scope.organisation}/clients")}

      {:error, :suspended} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("That client is suspended, so it takes on no one until it is activated.")
         )
         |> push_patch(to: ~p"/#{scope.organisation}/clients")}

      {:error, reason} when reason in [:delivery_failed, :delivery_failed_pending] ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("The invitation could not be sent. Try again.")
         )
         |> load()
         |> push_patch(to: ~p"/#{scope.organisation}/clients")}

      {:error, :unconfirmed} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "Confirm your email address before you invite anyone: sign in again with the link we email you."
           )
         )}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("That client is not there any more."))
         |> load()
         |> push_patch(to: ~p"/#{scope.organisation}/clients")}

      {:error, _forbidden} ->
        {:noreply,
         socket
         |> put_flash(:error, refusal(first_action(:invite, first == :admin), scope))
         |> UserAuth.reload_scope()
         |> push_patch(to: ~p"/#{scope.organisation}/clients")}
    end
  end

  defp revoke_first(%{"client" => client_id, "id" => id}, socket, first) do
    scope = socket.assigns.current_scope

    revoke =
      if first == :admin,
        do: &Operators.revoke_admin_invitation/3,
        else: &Operators.revoke_owner_invitation/3

    case revoke.(scope, client_id, id) do
      {:ok, invitation} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("The invitation of %{email} is revoked.", email: invitation.email)
         )
         |> load()}

      {:error, :has_owner} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("That client has an owner now, who invites its people."))
         |> load()}

      {:error, :has_admin} ->
        {:noreply,
         socket
         |> put_flash(:error, has_admin())
         |> load()}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("That invitation is no longer pending: it was accepted or revoked meanwhile.")
         )
         |> load()}

      {:error, _forbidden} ->
        {:noreply,
         socket
         |> put_flash(:error, refusal(first_action(:revoke, first == :admin), scope))
         |> UserAuth.reload_scope()}
    end
  end

  defp renew_first(%{"client" => client_id, "id" => id}, socket, first) do
    scope = socket.assigns.current_scope

    renew =
      if first == :admin,
        do: &Operators.renew_admin_invitation/4,
        else: &Operators.renew_owner_invitation/4

    case renew.(scope, client_id, id, &url(~p"/invitations/#{&1}")) do
      # Without mail: the new link, shown once on the client's row, in a function so no
      # inspection of the process's state prints it.
      {:ok, invitation, {:link, link}} ->
        {:noreply,
         socket
         |> assign(:renewed, %{client_id: client_id, invitation: invitation, url: fn -> link end})
         |> load()}

      # Mail was set meanwhile: the new link is emailed.
      {:ok, invitation} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Invitation sent to %{email}.", email: invitation.email))
         |> load()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           no_new_link(changeset, socket.assigns.clients, id, socket.assigns.current_scope)
         )
         |> load()}

      {:error, :has_owner} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("That client has an owner now, who invites its people."))
         |> load()}

      {:error, :has_admin} ->
        {:noreply,
         socket
         |> put_flash(:error, has_admin())
         |> load()}

      {:error, :suspended} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("That client is suspended, so it takes on no one until it is activated.")
         )}

      {:error, reason} when reason in [:delivery_failed, :delivery_failed_pending] ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("The invitation could not be sent. Try again."))
         |> load()}

      {:error, :unconfirmed} ->
        # With mail, for an inviter whose address is not confirmed. Mail set since the
        # new link was made withdraws the invitation unsent, so the list is read again.
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext(
             "Confirm your email address before you invite anyone: sign in again with the link we email you."
           )
         )
         |> load()}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("That invitation is no longer pending: it was accepted or revoked meanwhile.")
         )
         |> load()}

      {:error, _forbidden} ->
        {:noreply,
         socket
         |> put_flash(:error, refusal(first_action(:renew, first == :admin), scope))
         |> UserAuth.reload_scope()}
    end
  end

  defp accept_client(id, socket) do
    scope = socket.assigns.current_scope
    operator = scope.organisation.name

    case Transfers.accept_client(scope, id) do
      {:ok, client} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext(
             "%{name} is a client of %{operator} now: it runs its harness, and its people keep their levels.",
             name: client.name,
             operator: operator
           )
         )
         |> load()
         |> to_list()}

      {:error, :changed} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext(
             "That organisation became an operator or a client meanwhile, so it cannot be accepted."
           )
         )
         |> load()
         |> to_list()}

      {:error, :busy} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("Someone changed this at the same moment, so nothing was changed. Try again.")
         )
         |> to_list()}

      {:error, :suspended} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext(
             "That organisation is suspended, so it does not become a client until it is activated."
           )
         )
         |> load()
         |> to_list()}

      {:error, :forbidden} ->
        socket =
          socket
          |> put_flash(:error, refusal(:"client.accept", scope))
          |> UserAuth.reload_scope()

        {:noreply, if(socket.redirected, do: socket, else: socket |> load() |> to_list())}

      {:error, _not_found} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("That offer is no longer pending: it was withdrawn or accepted meanwhile.")
         )
         |> load()
         |> to_list()}
    end
  end

  defp invite_fun(:owner), do: &Operators.invite_owner/4
  defp invite_fun(:admin), do: &Operators.invite_admin/4

  # The action of a client's first person's invitation, and its row's event: the first
  # owner's, or the first admin's while the operator owns its clients.
  defp first_action(:invite, false), do: :"client.invite_owner"
  defp first_action(:invite, true), do: :"client.invite_admin"
  defp first_action(:revoke, false), do: :"client.revoke_owner_invitation"
  defp first_action(:revoke, true), do: :"client.revoke_admin_invitation"
  defp first_action(:renew, false), do: :"client.renew_owner_invitation"
  defp first_action(:renew, true), do: :"client.renew_admin_invitation"

  defp first_event(:revoke, false), do: "revoke_owner_invitation"
  defp first_event(:revoke, true), do: "revoke_admin_invitation"
  defp first_event(:renew, false), do: "renew_owner_invitation"
  defp first_event(:renew, true), do: "renew_admin_invitation"

  defp has_admin, do: gettext("That client has an admin now, who invites its people.")

  defp email_label(true), do: gettext("The admin's email address")
  defp email_label(false), do: gettext("The owner's email address")

  defp nobody_yet(true), do: gettext("No admin yet")
  defp nobody_yet(false), do: gettext("No owner yet")

  # A client's people in its Owner cell: its owners, and while the operator owns its
  # clients its admins too (`ApiaryPro.Operators.list_clients/1`), under Admins.
  defp people(client), do: client.owners ++ Map.get(client, :admins, [])

  # Whether Delete is offered for a client: while the operator owns its clients
  # (`ApiaryPro.Flags.operator_infrastructure?/0`), only while nobody has joined it, as
  # `ApiaryPro.Deletion.delete_client/3` asks; otherwise while it has no owner yet.
  defp deletable?(client, true), do: client.people == 0
  defp deletable?(client, false), do: people(client) == []

  # Why a client is not deleted, as `ApiaryPro.Deletion.delete_client/3` answers: it has
  # an owner, or, while the operator owns its clients, someone has joined it.
  defp undeletable(:has_owner),
    do: gettext("That client has an owner now: drop it instead, and its owner keeps it.")

  defp undeletable(:has_people),
    do: gettext("Someone has joined that client now, so it can't be deleted.")

  # A client's delete path, typed for a client whose Delete is not offered: back to the
  # list, with what its deletion would answer. Asked when the path opens, and again when
  # the rows arrive, which may be after it.
  defp refuse_undeletable(%{assigns: %{live_action: :delete, client_id: id}} = socket) do
    case chosen(socket.assigns.clients, id) do
      [client] ->
        if deletable?(client, socket.assigns.owns?),
          do: socket,
          else:
            socket
            |> put_flash(:error, undeletable(undeletable_reason(socket.assigns.owns?)))
            |> push_patch(to: clients_path(socket.assigns.current_scope))

      _none ->
        socket
    end
  end

  defp refuse_undeletable(socket), do: socket

  defp undeletable_reason(true), do: :has_people
  defp undeletable_reason(false), do: :has_owner

  # The clients, read again after a change; what was read before stays on the page until
  # they arrive.
  defp load(socket) do
    scope = socket.assigns.current_scope

    socket
    |> start_async(:clients, fn ->
      with {:ok, rows} <- Operators.list_clients(scope) do
        features = rows |> Enum.map(& &1.organisation) |> ApiaryPro.Features.of_all()

        {:ok, Enum.map(rows, &Map.put(&1, :features, Map.fetch!(features, &1.organisation.id)))}
      end
    end)
    |> assign_async(:offers, fn ->
      case Transfers.list_offers(scope) do
        {:ok, rows} -> {:ok, %{offers: rows}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @impl true
  def handle_async(:clients, {:ok, {:ok, rows}}, socket) do
    {:noreply,
     socket
     |> assign(:clients, AsyncResult.ok(socket.assigns.clients, rows))
     |> refuse_undeletable()}
  end

  def handle_async(:clients, {:ok, {:error, reason}}, socket),
    do:
      {:noreply,
       assign(socket, :clients, AsyncResult.failed(socket.assigns.clients, {:error, reason}))}

  def handle_async(:clients, {:exit, reason}, socket),
    do:
      {:noreply,
       assign(socket, :clients, AsyncResult.failed(socket.assigns.clients, {:exit, reason}))}

  # An organisation offered to the operator, or an offer withdrawn, tells the operator's
  # people (`ApiaryPro.Transfers`): `ApiaryWeb.UserAuth` loads the scope again on that, and
  # here the offers and the clients with it (`ApiaryWeb.UserAuth.on_membership_change/2`).
  defp follow_offers(socket) do
    UserAuth.on_membership_change(socket, &load/1)
  end

  defp may_grant?(scope), do: may?(scope, :"client.grant_features")

  defp may?(scope, action), do: Access.can?(scope, action, scope.organisation)

  # Whether the client has no workspace and the person may make its first, as the client's
  # overview asks (`workspace.create`): the scope moved into the client,
  # reaching it through the operator, as the person's membership in the operator says. No
  # read: `Apiary.Access.can?/3` takes the scope as it is.
  defp may_set_up?(
         %{membership: %Apiary.Organisations.Membership{} = via} = scope,
         %{workspace?: false, organisation: client}
       ) do
    in_client = %{Reach.in_client(scope, client) | reach: {:operator, via}}

    Access.can?(in_client, :"workspace.create", client)
  end

  defp may_set_up?(_scope, _client), do: false

  defp grant_refused(scope) do
    if Flags.feature_visibility?(),
      do:
        gettext("Only an owner of %{operator} chooses what its clients are shown.",
          operator: scope.organisation.name
        ),
      else:
        gettext("Only an owner of %{operator} grants its clients their features.",
          operator: scope.organisation.name
        )
  end

  # The words of the Features page and the list's filter: of what is shown while features
  # are shown by who asks (`ApiaryPro.Flags.feature_visibility?/0`).
  defp client_features_sentence(client, operator) do
    if Flags.feature_visibility?(),
      do:
        gettext(
          "People in %{name} see only the features you show here, of those %{operator} is shown; people of %{operator} see in it what %{operator} sees. Hidden features still work for its machines and runs. A feature a new release adds is hidden from it until you show it here.",
          name: client.name,
          operator: operator.name
        ),
      else:
        gettext(
          "The client has only what %{operator} grants it, of what %{operator} has. A feature a new release adds reaches it once you grant it here.",
          operator: operator.name
        )
  end

  defp above_operator(operator) do
    if Flags.feature_visibility?(),
      do: gettext("%{operator} can show only what it is shown.", operator: operator.name),
      else: gettext("%{operator} can grant only what it has itself.", operator: operator.name)
  end

  defp needs_runs do
    if Flags.feature_visibility?(),
      do: gettext("Every other feature needs Runs: show it, or hide them all."),
      else: gettext("Every other feature needs Runs: keep it, or take them all away.")
  end

  defp filter_sub do
    if Flags.feature_visibility?(),
      do: gettext("Shown all chosen"),
      else: gettext("It has every one chosen")
  end

  defp feature_chip(feature) do
    if Flags.feature_visibility?(),
      do: gettext("%{feature} shown", feature: FeatureComponents.label(feature)),
      else: gettext("Has %{feature}", feature: FeatureComponents.label(feature))
  end

  # Why the page does not offer an action of the operator's over its clients.
  defp refusal(:"client.create", _scope),
    do: gettext("Only owners and admins of an operator create its clients.")

  defp refusal(:"client.invite_owner", _scope),
    do: gettext("Only owners and admins of an operator invite the owners of its clients.")

  defp refusal(:"client.revoke_owner_invitation", _scope),
    do:
      gettext(
        "Only owners and admins of an operator revoke the invitations of its clients' owners."
      )

  defp refusal(:"client.renew_owner_invitation", _scope),
    do:
      gettext(
        "Only owners and admins of an operator make new links for the invitations of its clients' owners."
      )

  defp refusal(:"client.invite_admin", _scope),
    do: gettext("Only owners and admins of an operator invite the first admins of its clients.")

  defp refusal(:"client.revoke_admin_invitation", _scope),
    do:
      gettext(
        "Only owners and admins of an operator revoke the invitations of its clients' first admins."
      )

  defp refusal(:"client.renew_admin_invitation", _scope),
    do:
      gettext(
        "Only owners and admins of an operator make new links for the invitations of its clients' first admins."
      )

  defp refusal(:"client.delete", scope),
    do:
      gettext("Only an owner of %{operator} deletes a client.", operator: scope.organisation.name)

  defp refusal(:"client.drop", scope),
    do: gettext("Only an owner of %{operator} drops a client.", operator: scope.organisation.name)

  defp refusal(:"client.accept", scope),
    do:
      gettext("Only an owner of %{operator} accepts an organisation offered to it.",
        operator: scope.organisation.name
      )

  # Back to the list from an offer's row that asked; the list is where the event came
  # from otherwise.
  defp to_list(%{assigns: %{live_action: :accept_offer, current_scope: scope}} = socket),
    do: push_patch(socket, to: ~p"/#{scope.organisation}/clients")

  defp to_list(socket), do: socket

  # A new link refused over the day's invitations, said of the invitation's address; the
  # operator's allowance is the one counted, and the operator is the organisation the page
  # is in.
  defp no_new_link(%Ecto.Changeset{}, clients, id, scope) do
    email =
      case clients do
        %{ok?: true, result: rows} ->
          Enum.find_value(rows, "", fn row ->
            Enum.find_value(row.owner_invitations, &(&1.id == id && &1.email))
          end)

        _loading ->
          ""
      end

    gettext(
      "No new link for %{email} now: %{organisation} sent as many invitations in the last 24 hours as it may. Try again later, or %{contact_support}.",
      email: email,
      organisation: scope.organisation.name,
      contact_support: ApiaryWeb.Support.plain(mid_sentence: true)
    )
  end

  # The client a page or a confirmation is about, in a list of one, once the rows have
  # arrived.
  defp chosen(%{ok?: true, result: rows}, id) when is_binary(id),
    do: Enum.filter(rows, &(&1.organisation.id == id and in_use?(&1)))

  defp chosen(_clients, _id), do: []

  # What a client may be granted and a page offers: its operator's built features, but
  # `managed_organisations`.
  defp offered(client), do: Grants.shown(client)

  defp in_use?(%{organisation: %{deletion_marked_at: nil}}), do: true
  defp in_use?(_client), do: false

  # When an owner invitation expires, in the Owner cell, which marks one under a day away.
  defp expires(invitation),
    do: gettext("expires %{date}", date: Format.day(invitation.expires_at))

  defp expires_soon?(invitation),
    do: DateTime.diff(invitation.expires_at, DateTime.utc_now(), :hour) < 24

  ## The list's views, search, filter and order, all in the URL.

  @views ~w(all no_owner suspended deleted)
  @sorts ~w(name joined members)

  defp view_labels(owns?) do
    [
      {"all", gettext("All")},
      {"no_owner", if(owns?, do: gettext("Without an admin"), else: gettext("Without an owner"))},
      {"suspended", gettext("Suspended")},
      {"deleted", gettext("Deleted")}
    ]
  end

  defp sorts do
    [
      {"name", gettext("Name")},
      {"joined", gettext("Joined, newest first")},
      {"members", gettext("Most members")}
    ]
  end

  defp sort_label(sort), do: sorts() |> List.keyfind(sort, 0, {sort, sort}) |> elem(1)

  # The features a client may have, and so be filtered by: its operator's to grant.
  defp filter_features,
    do:
      Enum.filter(
        Features.built(),
        &(&1 != :managed_organisations and FeatureComponents.label(&1))
      )

  defp list_params(params) do
    features =
      params
      |> Map.get("features", "")
      |> to_string()
      |> String.split(",", trim: true)

    %{
      view: if(params["view"] in @views, do: params["view"], else: "all"),
      q:
        case String.trim(params["q"] || "") do
          "" -> nil
          q -> q
        end,
      features: Enum.filter(filter_features(), &(Atom.to_string(&1) in features)),
      sort: if(params["sort"] in @sorts, do: params["sort"], else: "name")
    }
  end

  defp list_path(scope, list, changes) do
    list = Enum.into(changes, list)

    query =
      [
        {"view", list.view != "all" && list.view},
        {"q", list.q not in [nil, ""] && list.q},
        {"features", list.features != [] && Enum.map_join(list.features, ",", &Atom.to_string/1)},
        {"sort", list.sort != "name" && list.sort}
      ]
      |> Enum.filter(fn {_key, value} -> value end)

    if query == [],
      do: ~p"/#{scope.organisation}/clients",
      else: ~p"/#{scope.organisation}/clients?#{query}"
  end

  defp toggle(list, item), do: if(item in list, do: list -- [item], else: list ++ [item])

  # Narrowed by the search or a feature, where Clear filters gives the view back whole.
  defp narrowed?(list), do: list.q != nil or list.features != []

  # What a view with no client says, as the core's Nodes says its views'.
  defp none_sentence("no_owner", true), do: gettext("Every client has an admin.")
  defp none_sentence("no_owner", false), do: gettext("Every client has an owner.")
  defp none_sentence("suspended", _owns?), do: gettext("No client is suspended.")
  defp none_sentence("deleted", _owns?), do: gettext("No client is deleted.")
  defp none_sentence(_view, _owns?), do: nil

  defp in_view?(_client, "all"), do: true
  defp in_view?(client, "no_owner"), do: in_use?(client) and people(client) == []

  defp in_view?(client, "suspended"),
    do: in_use?(client) and ApiaryPro.Tenants.suspended?(client.organisation)

  defp in_view?(client, "deleted"), do: not in_use?(client)

  # The rows the view, the search and the filters keep, in the order chosen.
  defp shown(clients, list) do
    clients
    |> Enum.filter(&in_view?(&1, list.view))
    |> Enum.filter(&matches?(&1, list.q))
    |> Enum.filter(fn c -> Enum.all?(list.features, &(&1 in c.features)) end)
    |> order(list.sort)
  end

  defp matches?(_client, nil), do: true

  defp matches?(client, q) do
    q = String.downcase(q)

    [client.organisation.name, client.organisation.slug]
    |> Enum.concat(Enum.map(people(client), &People.email/1))
    |> Enum.concat(Enum.map(client.owner_invitations, & &1.email))
    |> Enum.any?(&(is_binary(&1) and String.contains?(String.downcase(&1), q)))
  end

  defp order(rows, "joined"), do: Enum.sort_by(rows, &joined/1, {:desc, DateTime})
  defp order(rows, "members"), do: Enum.sort_by(rows, &(-&1.people))
  defp order(rows, _name), do: rows

  # The Owner cell's words whole, for its title where the cell cuts them.
  defp owners_text(client, owns?) do
    case people(client) do
      [] ->
        invited =
          Enum.map(
            client.owner_invitations,
            &(expires(&1) <> " · " <> gettext("Invited: %{email}", email: &1.email))
          )

        Enum.join([nobody_yet(owns?) | invited], " · ")

      people ->
        Enum.map_join(people, ", ", &People.email/1)
    end
  end

  defp joined(client),
    do: ApiaryPro.Tenants.operator_since(client.organisation) || client.organisation.inserted_at
end
