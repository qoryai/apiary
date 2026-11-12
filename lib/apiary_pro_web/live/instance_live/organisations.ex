defmodule ApiaryProWeb.InstanceLive.Organisations do
  @moduledoc """
  Instance settings › Organisations, the Instance level's second section, for the instance
  organisation's owners, the instance admins (`instance.read`), who reach it from the Qory
  Apiary menu's Instance settings; for anyone else the page is not found. Its paths are
  `ApiaryProWeb.InstanceLive.Paths`'. It is the one page that says the instance
  organisation is the instance owner.

  Every organisation on the instance, with its kind, its operator, its features and its
  status, in views (All, Operators, Clients, Suspended, Deleted), with a search by name or
  slug, a filter by operator and an order, all in the URL; its name leads to it, which an
  instance admin reads and does not change. The instance actions, each asked of
  `Apiary.Access` and each an audit entry, from the row's menu:

  - **New organisation**, a page: an organisation, or with `managed_organisations` an
    operator, whose first owner is the instance admin who creates it
    (`ApiaryPro.Operators.create_organisation/2`);
  - **Make operator** and **Make organisation**, confirmed on the row: an organisation that
    is no client made an operator, an operator without clients made an organisation
    (`ApiaryPro.Operators.change_kind/3`);
  - **Purge now**, confirmed on the row: an organisation purged at once on an erasure
    request, its slug typed to confirm (`ApiaryPro.Deletion.purge_on_request/3`);
  - **Suspend**, confirmed on the row, and **Activate**, at once: an organisation or an
    operator made read-only, its access keys refused, and working again
    (`ApiaryPro.Suspensions.suspend_organisation/2`, `activate_organisation/2`);
  - **Transfer ownership**, a page: the arbiter's offer of an organisation's ownership to
    one of its admins, with a reason, for an organisation whose owners are all suspended,
    a client as any other (`ApiaryPro.Transfers.arbitrate/4`);
  - **Features**, a page: what an operator is granted, opt-in, or what an organisation with
    no operator keeps of the instance's, opt-out (`ApiaryPro.Grants.set_organisation/3`);
    a client's are its operator's to grant.

  Of them only the change of kind is offered for the instance organisation, which may be
  of either kind: it is never purged or suspended, is transferred to no one and has every
  feature the instance has, and the server refuses the rest for it too. An organisation
  whose one owner is the instance admin who created it says so, with **Invite an owner**,
  which leads to its people.
  """
  use ApiaryProWeb, :live_view
  on_mount {ApiaryProWeb.InstanceLive.Components, :instance}

  alias Apiary.Access
  alias ApiaryPro.{Flags, Grants, Operators, Suspensions, Tenants, Transfers}
  alias ApiaryProWeb.{ConfirmComponents, FeatureComponents, OrganisationComponents}
  alias ApiaryProWeb.InstanceLive.Paths
  alias ApiaryWeb.{SettingsComponents, SetUpComponents}

  @pages [:new, :transfer, :features]

  @impl true
  # Creating an organisation is a page of Organisations, a step of the set-up in its frame
  # (`ApiaryWeb.SetUpComponents.frame/1`): Instance settings' sections beside it, the
  # breadcrumb ending Organisations and the act, the steps list
  # (`ApiaryProWeb.OrganisationComponents.new_organisation_steps/0`), the title, the form with
  # its first field focused, and its button with Cancel back to the list as it was left.
  # About organisations says who the creator becomes and what comes next.
  def render(%{live_action: :new} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      place={:instance}
      section={:organisations}
    >
      <:crumb>{crumb(@live_action)}</:crumb>

      <SetUpComponents.frame steps={@steps}>
        <div id="organisation-page" class="grid gap-5">
          <SetUpComponents.heading>{crumb(@live_action)}</SetUpComponents.heading>
          <.new_organisation form={@form} scope={@scope} back={list_path(@list, [])} />
        </div>

        <:context about={gettext("About organisations")}>
          <p>
            {gettext(
              "You become its first owner, because an instance admin creates it. You invite its people from its Organisation settings › People."
            )}
          </p>
          <p>{gettext("You can leave the organisation once another person is an owner.")}</p>
          <p>
            {gettext(
              "Work happens in workspaces. You choose what its first one does on the organisation's overview."
            )}
          </p>
        </:context>
      </SetUpComponents.frame>
    </Layouts.app>
    """
  end

  # The arbiter's transfer of an organisation's ownership and an organisation's features
  # are pages of Organisations, on the core's pattern of a form (`docs/ui.md`, A form is a
  # page; `page_form/1`): Instance settings' sections beside it, the breadcrumb ending
  # Organisations and the act, its title and one sentence, the form, and its button with
  # Cancel back to the list as it was left.
  def render(%{live_action: action} = assigns) when action in [:transfer, :features] do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      place={:instance}
      section={:organisations}
    >
      <:crumb>{crumb(@live_action)}</:crumb>

      <.page_form
        id="organisation-page"
        title={form_title(@live_action, @organisations, @target_id)}
        cancel={list_path(@list, [])}
        cancel_by="patch"
      >
        <:description :if={form_sentence(@live_action, @organisations, @target_id)}>
          {form_sentence(@live_action, @organisations, @target_id)}
        </:description>

        <.async_result assign={@organisations}>
          <:loading>
            <div id="organisation-page-loading" aria-busy="true">
              <span class="sr-only">{gettext("Loading the organisations")}</span>
              <span class="skeleton q-skel w-48"></span>
            </div>
          </:loading>
          <:failed>
            <.notice kind={:error} class="max-w-[80ch]">
              <span id="organisations-error">
                {gettext(
                  "The organisations could not be loaded. Reload the page; if it keeps happening, Qory Apiary's log has the reason."
                )}
              </span>
            </.notice>
          </:failed>
          <p
            :if={target(@organisations, @target_id) == []}
            id="organisation-gone"
            class="text-muted"
          >
            {gettext("That organisation is not there any more.")}
            <.link patch={list_path(@list, [])} class="link">
              {gettext("Back to the organisations")}
            </.link>
          </p>
          <%= for target <- target(@organisations, @target_id) do %>
            <.transfer
              :if={@live_action == :transfer}
              target={target}
              candidates={@candidates}
              form={@transfer_form}
              reason_max={@reason_max}
              scope={@scope}
              back={list_path(@list, [])}
            />
            <.organisation_features
              :if={@live_action == :features}
              target={target}
              may_grant={may_grant?(@scope, target)}
              refused={@features_refused}
              scope={@scope}
              back={list_path(@list, [])}
            />
          <% end %>
        </.async_result>
      </.page_form>
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
      place={:instance}
      section={:organisations}
    >
      <.settings_page section={:organisations} measure="list" title={gettext("Organisations")}>
        <:subtitle>
          {gettext(
            "Every organisation on this Qory Apiary. %{organisation} is the instance owner: its owners are the instance admins, who read every other organisation and change one only under Instance settings.",
            organisation: @scope.organisation.name
          )}
        </:subtitle>
        <:actions :if={may_create?(@scope)}>
          <.button id="new-organisation" variant="primary" patch={Paths.new_organisation()}>
            <.icon name="hero-plus-micro" class="size-4" /> {gettext("New organisation")}
          </.button>
        </:actions>

        <.async_result :let={rows} assign={@organisations}>
          <:loading>
            <div
              id="organisations-loading"
              class="overflow-hidden rounded-box border border-line bg-base-100 shadow-xs"
              aria-busy="true"
            >
              <span class="sr-only">{gettext("Loading the organisations")}</span>
              <div
                :for={n <- 1..6}
                class="flex items-center gap-6 border-b border-line px-4 py-3.5 last:border-b-0"
              >
                <span class={["skeleton q-skel", if(rem(n, 2) == 0, do: "w-40", else: "w-28")]}></span>
                <span class="skeleton q-skel w-20"></span>
                <span class="skeleton q-skel w-24 max-md:hidden"></span>
              </div>
            </div>
          </:loading>
          <:failed>
            <.notice kind={:error} class="max-w-[80ch]">
              <span id="organisations-error">
                {gettext(
                  "The organisations could not be loaded. Reload the page; if it keeps happening, Qory Apiary's log has the reason."
                )}
              </span>
            </.notice>
          </:failed>

          <div class="grid min-w-0 gap-3">
            <.views id="organisations-views" label={gettext("Views of the organisations")}>
              <:view
                :for={{view, label} <- views()}
                id={"organisations-view-#{view}"}
                patch={list_path(@list, view: view)}
                count={Format.number(Enum.count(rows, &in_view?(&1, view)))}
                current={@list.view == view}
              >
                {label}
              </:view>
            </.views>

            <div class="q-bar">
              <.list_search
                id="organisations-search"
                label={gettext("Find an organisation")}
                placeholder={gettext("Find by name or slug")}
                value={@list.q}
              />
              <.filter_menu
                :if={operators(rows) != []}
                id="organisations-filter"
                count={if @list.operator, do: 1, else: 0}
              >
                <.menu_heading title={gettext("Operator")} sub={gettext("Its clients")} />
                <.menu_item
                  :for={operator <- operators(rows)}
                  id={"organisations-filter-#{operator.id}"}
                  checked={@list.operator == operator.id}
                  patch={
                    list_path(@list,
                      operator: if(@list.operator == operator.id, do: nil, else: operator.id)
                    )
                  }
                >
                  {operator.name}
                </.menu_item>
              </.filter_menu>
              <.sort_menu id="organisations-sort" current={sort_label(@list.sort)}>
                <.menu_item
                  :for={{sort, label} <- sorts()}
                  id={"organisations-sort-#{sort}"}
                  checked={@list.sort == sort}
                  patch={list_path(@list, sort: sort)}
                >
                  {label}
                </.menu_item>
              </.sort_menu>
            </div>

            <.filter_tokens id="organisations-tokens" clear={list_path(@list, operator: nil)}>
              <:token
                :for={operator <- operators(rows)}
                :if={@list.operator == operator.id}
                patch={list_path(@list, operator: nil)}
                label={gettext("Remove the filter %{filter}", filter: operator.name)}
              >
                {gettext("Clients of %{operator}", operator: operator.name)}
              </:token>
            </.filter_tokens>

            <%!-- Always there, so a screen reader hears what the search left. --%>
            <div id="organisations-status" role="status" class="q-status">
              <p :if={narrowed?(@list)} class="text-[13px] text-muted">
                {ngettext(
                  "%{number} organisation matches",
                  "%{number} organisations match",
                  length(shown(rows, @list)),
                  number: Format.number(length(shown(rows, @list)))
                )}
              </p>
            </div>

            <div :if={shown(rows, @list) == []} id="organisations-none">
              <.empty_state icon={nil} tone="neutral" title={empty_title(@list)}>
                <:actions :if={narrowed?(@list)}>
                  <.button
                    id="organisations-clear"
                    patch={list_path(%{@list | q: nil, operator: nil}, [])}
                  >
                    {gettext("Clear the search and the filters")}
                  </.button>
                </:actions>
              </.empty_state>
            </div>

            <.table
              :if={shown(rows, @list) != []}
              id="organisations"
              label={gettext("Organisations")}
              rows={shown(rows, @list)}
              row_id={&"organisation-#{&1.organisation.id}"}
              row_class={&(!in_use?(&1) && "row-off")}
              confirming={confirming(@live_action, @scope, @organisations, @target_id)}
            >
              <:col :let={r} label={gettext("Organisation")} kind="title">
                <span class="q-nm q-fold-nm">
                  <.avatar name={r.organisation.name} kind="organisation" />
                  <%= if in_use?(r) do %>
                    <.link
                      id={"organisation-#{r.organisation.id}-link"}
                      navigate={~p"/#{r.organisation}"}
                      class="q-title q-org-name hover:underline"
                      title={r.organisation.name}
                    >
                      {r.organisation.name}
                    </.link>
                  <% else %>
                    <span class="q-title q-org-name" title={r.organisation.name}>
                      {r.organisation.name}
                    </span>
                  <% end %>
                  <span class="q-side q-mono" title={r.organisation.slug}>
                    {r.organisation.slug}
                  </span>
                  <%!-- Below 600 px of table, a line under the name: its slug, which gives way
                       beside the name there, its kind, whose column the table drops, and its
                       states. --%>
                  <span class="q-fold-line text-[12.5px] font-normal">
                    <span class="q-fold q-mono q-org-slug" title={r.organisation.slug}>
                      {r.organisation.slug}
                    </span>
                    <span :if={kind_word(r)} class="q-fold">{kind_word(r)}</span>
                    <span id={"organisation-#{r.organisation.id}-status"} class="q-fold-states">
                      <%= cond do %>
                        <% !in_use?(r) -> %>
                          <.state_word>
                            {gettext("Deleted, purged on %{date}",
                              date: Format.date(r.organisation.purge_after)
                            )}
                          </.state_word>
                        <% Tenants.suspended?(r.organisation) -> %>
                          <.state_word>{gettext("Suspended")}</.state_word>
                        <% true -> %>
                          <span class="sr-only">{gettext("In use")}</span>
                      <% end %>
                      <.state_word :if={r.owner_suspended} hot>
                        {gettext("Owner suspended")}
                      </.state_word>
                      <span
                        :if={r.only_owner?}
                        id={"organisation-#{r.organisation.id}-only-owner"}
                        title={gettext("Invite an owner, then leave it.")}
                      >
                        <.state_word hot>{gettext("You're its only owner")}</.state_word>
                      </span>
                    </span>
                  </span>
                </span>
              </:col>
              <:col :let={r} label={gettext("Kind")} from="sm">
                <span id={"organisation-#{r.organisation.id}-kind"}>
                  <%= cond do %>
                    <% Tenants.instance_organisation?(r.organisation) -> %>
                      <span class="sr-only">{kind_label(Tenants.kind(r.organisation))}</span>
                      {gettext("The instance owner")}
                    <% Tenants.operator?(r.organisation) -> %>
                      {kind_label(:operator)}
                    <% r.operator -> %>
                      {gettext("Client")}
                    <% true -> %>
                      <span class="sr-only">{kind_label(:organisation)}</span>
                  <% end %>
                </span>
              </:col>
              <:col :let={r} label={gettext("Operator")} from="sm">
                <span id={"organisation-#{r.organisation.id}-operator"}>
                  <%= cond do %>
                    <% r.operator -> %>
                      <span class="q-cut max-w-[24ch]" title={r.operator.name}>
                        {r.operator.name}
                      </span>
                    <% Tenants.operator?(r.organisation) and
                         Tenants.instance_organisation?(r.organisation) -> %>
                      <%!-- The instance organisation's clients, which its sidebar
                           lists only once there is one: the way to them, to add the
                           first. --%>
                      <.link
                        id={"organisation-#{r.organisation.id}-clients"}
                        navigate={~p"/#{r.organisation}/clients"}
                        class="q-link tabular-nums"
                      >
                        {ngettext("%{number} client", "%{number} clients", r.clients,
                          number: Format.number(r.clients)
                        )}
                      </.link>
                    <% Tenants.operator?(r.organisation) -> %>
                      <span class="tabular-nums">
                        {ngettext("%{number} client", "%{number} clients", r.clients,
                          number: Format.number(r.clients)
                        )}
                      </span>
                    <% true -> %>
                      <span class="sr-only">{gettext("None")}</span>
                  <% end %>
                </span>
              </:col>
              <%!-- The column that gives way: it takes the room the others leave, and a list
                   longer than that is cut, whole in its title. --%>
              <:col :let={r} label={gettext("Features")} from="md" class="w-[30%] max-w-0">
                <FeatureComponents.feature_words
                  id={"organisation-#{r.organisation.id}-features"}
                  features={r.features}
                  class="block truncate"
                  title={FeatureComponents.feature_text(r.features)}
                />
              </:col>
              <:col :let={r} label={gettext("Created")} from="sm">
                <span class="tabular-nums">{Format.day(r.organisation.inserted_at)}</span>
              </:col>
              <:confirm :let={r}>
                <.organisation_confirm
                  act={@live_action}
                  row={r}
                  scope={@scope}
                  form={@confirm_form}
                  back={list_path(@list, [])}
                />
              </:confirm>
              <:action :let={r}>
                <.button
                  :if={r.only_owner? and in_use?(r)}
                  id={"organisation-#{r.organisation.id}-invite-owner"}
                  variant="link"
                  navigate={~p"/#{r.organisation}/settings/people"}
                  aria-label={gettext("Invite an owner to %{name}", name: r.organisation.name)}
                >
                  {gettext("Invite an owner")}
                </.button>
                <.row_menu
                  id={"organisation-#{r.organisation.id}-menu"}
                  label={gettext("Actions for %{name}", name: r.organisation.name)}
                >
                  <.menu_item
                    :if={kind_change(@scope, r)}
                    id={"organisation-#{r.organisation.id}-kind-button"}
                    patch={Paths.organisation(r.organisation.id, :kind)}
                  >
                    {kind_item(kind_change(@scope, r))}
                  </.menu_item>
                  <.menu_item
                    :if={may_grant?(@scope, r)}
                    id={"organisation-#{r.organisation.id}-features-button"}
                    patch={Paths.organisation(r.organisation.id, :features)}
                    aria-label={gettext("Features of %{name}", name: r.organisation.name)}
                  >
                    {gettext("Features…")}
                  </.menu_item>
                  <.menu_item
                    :if={may_transfer?(@scope, r)}
                    id={"organisation-#{r.organisation.id}-transfer-button"}
                    patch={Paths.organisation(r.organisation.id, :transfer)}
                    aria-label={gettext("Transfer ownership of %{name}", name: r.organisation.name)}
                  >
                    {gettext("Transfer ownership…")}
                  </.menu_item>
                  <.menu_item
                    :if={suspension(@scope, r) == :suspend}
                    id={"organisation-#{r.organisation.id}-suspend-button"}
                    patch={Paths.organisation(r.organisation.id, :suspend)}
                    aria-label={gettext("Suspend %{name}", name: r.organisation.name)}
                  >
                    {gettext("Suspend…")}
                  </.menu_item>
                  <.menu_item
                    :if={suspension(@scope, r) == :activate}
                    id={"organisation-#{r.organisation.id}-activate-button"}
                    phx-click="activate_organisation"
                    phx-value-id={r.organisation.id}
                    aria-label={gettext("Activate %{name}", name: r.organisation.name)}
                  >
                    {gettext("Activate")}
                  </.menu_item>
                  <.menu_item
                    :if={may_purge?(@scope, r)}
                    id={"organisation-#{r.organisation.id}-purge-button"}
                    patch={Paths.organisation(r.organisation.id, :purge)}
                  >
                    {gettext("Purge now…")}
                  </.menu_item>
                </.row_menu>
              </:action>
            </.table>
          </div>
        </.async_result>
      </.settings_page>
    </Layouts.app>
    """
  end

  defp crumb(:new), do: gettext("New organisation")
  defp crumb(:transfer), do: gettext("Transfer ownership")
  defp crumb(:features), do: gettext("Features")

  # A form page's title and its sentence, which name the organisation once its row has
  # arrived.
  defp form_title(act, organisations, id) do
    case {act, target(organisations, id)} do
      {:transfer, [row]} ->
        gettext("Transfer the ownership of %{name}", name: row.organisation.name)

      {:features, [row]} ->
        gettext("Features of %{name}", name: row.organisation.name)

      {act, _none} ->
        crumb(act)
    end
  end

  defp form_sentence(act, organisations, id) do
    case {act, target(organisations, id)} do
      {:transfer, [row]} ->
        gettext(
          "The admin you choose is offered the ownership of %{name}, and becomes its owner only when they accept it. The offer replaces any pending one.",
          name: row.organisation.name
        )

      {:features, [row]} ->
        features_sentence(Tenants.operator?(row.organisation), Flags.feature_visibility?())

      _none ->
        nil
    end
  end

  # What the Features page says of the organisation it is open on: in words of what is
  # shown while features are shown by who asks (`ApiaryPro.Flags.feature_visibility?/0`).
  defp features_sentence(true = _operator?, false = _shown?),
    do:
      gettext(
        "An operator has only what you grant it, and grants its clients within that. A feature a new release adds reaches it once you grant it here."
      )

  defp features_sentence(false, false),
    do:
      gettext(
        "An organisation with no operator has what this instance has, but for what you take away here. A feature a new release adds reaches it."
      )

  defp features_sentence(true, true),
    do:
      gettext(
        "Its people see only the features you show here, and it shows its clients only those. Hidden features still work for its machines and runs. A feature a new release adds is hidden from it until you show it here."
      )

  defp features_sentence(false, true),
    do:
      gettext(
        "Its people see every feature this instance has, but those you hide here. Hidden features still work for its machines and runs. A feature a new release adds is shown to it."
      )

  # A client's features are its operator's to choose.
  defp client_features_sentence do
    if Flags.feature_visibility?(),
      do: gettext("A client's operator chooses which features it is shown."),
      else: gettext("A client's features are its operator's to grant.")
  end

  defp needs_runs do
    if Flags.feature_visibility?(),
      do: gettext("Every other feature needs Runs: show it, or hide them all."),
      else: gettext("Every other feature needs Runs: keep it, or take them all away.")
  end

  attr :form, :any, required: true
  attr :scope, :any, required: true
  attr :back, :string, required: true, doc: "the list as it was left"

  defp new_organisation(assigns) do
    ~H"""
    <.form
      for={@form}
      id="organisation-form"
      phx-change="validate"
      phx-submit="create"
      class="grid gap-4"
      novalidate
    >
      <OrganisationComponents.kind_field
        :if={Access.can?(@scope, :"instance.create_operator", @scope.organisation)}
        field={@form[:kind]}
      />
      <.input
        field={@form[:name]}
        type="text"
        label={gettext("Name")}
        autocomplete="off"
        required
        phx-mounted={JS.focus()}
      />
      <.page_form_foot id="organisation-save" cancel={@back} cancel_by="patch">
        <.button
          id="create-organisation"
          variant="primary"
          type="submit"
          loading_text={gettext("Creating")}
        >
          {gettext("Create")}
        </.button>
      </.page_form_foot>
    </.form>
    """
  end

  attr :target, :map, required: true
  attr :candidates, :list, required: true
  attr :form, :any, required: true
  attr :reason_max, :integer, required: true
  attr :scope, :any, required: true
  attr :back, :string, required: true, doc: "the list as it was left"

  defp transfer(assigns) do
    ~H"""
    <%= if @candidates == [] do %>
      <.notice kind={:warning}>
        <span id="transfer-no-admin">
          {gettext(
            "%{name} has no admin who can act, so there is nobody to offer its ownership to.",
            name: @target.organisation.name
          )}
        </span>
      </.notice>
      <div class="q-save">
        <.button id="transfer-back" patch={@back}>
          {gettext("Back to the organisations")}
        </.button>
      </div>
    <% else %>
      <.form
        for={@form}
        id="transfer-form"
        phx-change="validate_transfer"
        phx-submit="transfer"
        class="grid gap-4"
        novalidate
      >
        <.input
          field={@form[:membership_id]}
          type="radio"
          label={gettext("Offer it to")}
          options={Enum.map(@candidates, &{&1.user.email, &1.id})}
          required
        />
        <.input
          field={@form[:reason]}
          type="textarea"
          label={gettext("Reason")}
          hint={
            gettext(
              "At most %{count} characters, kept in the organisation's activity. Say why, and write no personal data.",
              count: @reason_max
            )
          }
          maxlength={@reason_max}
          rows="3"
          required
        />
        <.page_form_foot id="transfer-save" cancel={@back} cancel_by="patch">
          <.button
            id="transfer-confirm"
            variant="primary"
            type="submit"
            loading_text={gettext("Offering")}
          >
            {gettext("Offer the ownership")}
          </.button>
        </.page_form_foot>
      </.form>
      <%!-- The radio group's first choice takes the focus, as a form's first field does. --%>
      <span hidden phx-mounted={JS.focus_first(to: "#transfer-form")}></span>
    <% end %>
    """
  end

  attr :target, :map, required: true
  attr :may_grant, :boolean, required: true

  attr :refused, :map,
    default: nil,
    doc: "the save refused for the boxes it sent: those boxes, and why, under them"

  attr :scope, :any, required: true
  attr :back, :string, required: true, doc: "the list as it was left"

  defp organisation_features(assigns) do
    offered = Grants.shown(assigns.target.organisation)

    {has, errors} =
      case assigns.refused do
        %{id: id, features: sent, errors: errors} when id == assigns.target.organisation.id ->
          {Enum.filter(offered, &(Atom.to_string(&1) in sent)), errors}

        _none ->
          {assigns.target.features ++ Grants.parts_kept(assigns.target.organisation), []}
      end

    assigns = assign(assigns, offered: offered, has: has, errors: errors)

    ~H"""
    <p :if={!@may_grant} id="organisation-features-none" class="text-muted">
      {client_features_sentence()}
    </p>
    <.form
      :if={@may_grant}
      for={%{}}
      id="organisation-features-form"
      phx-submit="save_features"
      class="grid gap-4"
      novalidate
    >
      <FeatureComponents.feature_fields
        id="organisation-features"
        offered={@offered}
        has={@has}
        errors={@errors}
      />
      <.page_form_foot
        id="organisation-features-save"
        cancel={@back}
        cancel_by="patch"
      >
        <.button
          id="organisation-features-confirm"
          variant="primary"
          type="submit"
          loading_text={gettext("Saving")}
        >
          {gettext("Save features")}
        </.button>
      </.page_form_foot>
    </.form>
    """
  end

  # A change of kind, a purge and a suspension, each confirmed in place on the
  # organisation's row, at a separate path; Cancel and Escape go back to the list as it
  # was left.
  attr :act, :atom, required: true
  attr :row, :map, required: true
  attr :scope, :any, required: true
  attr :form, :any, required: true
  attr :back, :string, required: true, doc: "the list as it was left"

  defp organisation_confirm(%{act: :kind} = assigns) do
    assigns = assign(assigns, :to, kind_change(assigns.scope, assigns.row))

    ~H"""
    <.inline_confirm
      id="kind"
      question={kind_question(@to, @row.organisation.name)}
      cancel={@back}
    >
      {if @to == :operator,
        do:
          gettext(
            "%{name} becomes an operator: its owners and admins can create client organisations and reach them at their level. Nothing it holds changes.",
            name: @row.organisation.name
          ),
        else:
          gettext(
            "%{name} becomes an organisation again: it has no clients, and can create none. Nothing it holds changes.",
            name: @row.organisation.name
          )}
      <:action>
        <.button
          id="kind-confirm"
          variant="primary"
          size="xs"
          phx-click="change_kind"
          phx-value-kind={@to}
          loading_text={gettext("Saving")}
        >
          {kind_button(@to)}
        </.button>
      </:action>
    </.inline_confirm>
    """
  end

  defp organisation_confirm(%{act: :purge, row: %{clients: clients}} = assigns)
       when clients > 0 do
    ~H"""
    <.inline_confirm
      id="purge"
      question={gettext("Purge %{name} now?", name: @row.organisation.name)}
      cancel={@back}
    >
      <span id="purge-has-clients">
        {gettext(
          "%{name} is an operator with clients. Each client is deleted or purged first.",
          name: @row.organisation.name
        )}
      </span>
      <:action></:action>
    </.inline_confirm>
    """
  end

  defp organisation_confirm(%{act: :purge} = assigns) do
    ~H"""
    <ConfirmComponents.typed_confirm
      id="purge"
      question={gettext("Purge %{name} now?", name: @row.organisation.name)}
      form={@form}
      change="confirm"
      submit="purge"
      ready={@form[:slug].value == @row.organisation.slug}
      button={gettext("Yes, purge")}
      loading_text={gettext("Purging")}
      cancel={@back}
    >
      <:lost>
        {gettext(
          "For an erasure request received in writing. Everything %{name} holds is deleted at once, its workspaces, runs, members and activity among them, and the instance keeps one line of it, which names you as who asked. This cannot be undone: only a backup taken before still holds its data.",
          name: @row.organisation.name
        )}
      </:lost>
      <:field>
        <.input
          field={@form[:slug]}
          type="text"
          label={
            gettext("Type the organisation's slug, %{slug}, to confirm",
              slug: @row.organisation.slug
            )
          }
          autocomplete="off"
          spellcheck="false"
          debounce="0"
        />
      </:field>
    </ConfirmComponents.typed_confirm>
    """
  end

  defp organisation_confirm(%{act: :suspend} = assigns) do
    ~H"""
    <.inline_confirm
      id="suspend-organisation"
      question={gettext("Suspend %{name}?", name: @row.organisation.name)}
      cancel={@back}
    >
      {gettext(
        "%{name} becomes read-only: its people can sign in and read everything in it, and change nothing. It sends no invitations, and its access keys are refused, so no run starts or reports.",
        name: @row.organisation.name
      )}
      <span :if={Tenants.operator?(@row.organisation)} id="suspend-operator-clients">
        {gettext(
          "Its people lose their reach into its clients, which keep running: the clients' people and access keys work as before, and their admins are told that their owner is suspended."
        )}
      </span>
      {gettext("Nothing is removed. You can activate it again at any time.")}
      <:action>
        <.button
          id="suspend-organisation-confirm"
          variant="danger"
          size="xs"
          phx-click="suspend_organisation"
          loading_text={gettext("Suspending")}
        >
          {gettext("Yes, suspend")}
        </.button>
      </:action>
    </.inline_confirm>
    """
  end

  # The row that asks to confirm an act on it: the organisation's at the act's path, once
  # the rows have arrived and while the act is offered for it; none otherwise.
  defp confirming(act, scope, organisations, id) when act in [:kind, :purge, :suspend] do
    case target(organisations, id) do
      [row] -> if offered?(act, scope, row), do: "organisation-#{row.organisation.id}"
      _none -> nil
    end
  end

  defp confirming(_act, _scope, _organisations, _id), do: nil

  defp offered?(:kind, scope, row), do: not is_nil(kind_change(scope, row))
  defp offered?(:purge, scope, row), do: may_purge?(scope, row)
  defp offered?(:suspend, scope, row), do: suspension(scope, row) == :suspend

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: page_title(socket, gettext("Organisations")),
       target_id: nil,
       candidates: [],
       reason_max: Transfers.reason_max(),
       transfer_submitted: false,
       list: list_params(%{}),
       steps: OrganisationComponents.new_organisation_steps()
     )
     |> assign_form(%{"kind" => "organisation"})
     |> assign_confirm()
     |> assign_transfer()
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      if socket.assigns.live_action == :index,
        do: assign(socket, :list, list_params(params)),
        else: socket

    {:noreply, socket |> apply_action(socket.assigns.live_action, params) |> titled()}
  end

  # The browser's title names the page: a form's by its act alone, else the section, then
  # Instance settings (`ApiaryWeb.SettingsComponents.page_title/3`).
  defp titled(%{assigns: %{live_action: action}} = socket) when action in @pages,
    do: assign(socket, :page_title, page_title(socket, crumb(action)))

  defp titled(socket),
    do: assign(socket, :page_title, page_title(socket, gettext("Organisations")))

  defp page_title(socket, words),
    do: SettingsComponents.page_title(socket.assigns.current_scope, :instance, [words])

  defp apply_action(socket, :index, _params),
    do: assign(socket, target_id: nil, candidates: [])

  defp apply_action(socket, :new, _params) do
    if may_create?(socket.assigns.scope),
      do: assign_form(socket, %{"kind" => "organisation"}),
      else: back(socket)
  end

  defp apply_action(socket, action, %{"id" => id})
       when action in [:kind, :purge, :suspend, :features] do
    socket |> assign(target_id: id, features_refused: nil) |> assign_confirm()
  end

  # The admins the ownership may be offered to, read when the page opens: none offered
  # where there is none, and a refusal sends the page back.
  defp apply_action(socket, :transfer, %{"id" => id}) do
    case Transfers.arbitration_candidates(socket.assigns.scope, id) do
      {:ok, candidates} ->
        socket
        |> assign(target_id: id, candidates: candidates, transfer_submitted: false)
        |> assign_transfer()

      {:error, _reason} ->
        refused(socket)
    end
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, push_patch(socket, to: list_path(socket.assigns.list, q: q), replace: true)}
  end

  def handle_event("validate", %{"organisation" => params}, socket) do
    {:noreply, assign_form(socket, params, :validate)}
  end

  def handle_event("create", %{"organisation" => params}, socket) do
    params = Map.put_new(params, "kind", "organisation")

    case Operators.create_organisation(socket.assigns.scope, params) do
      {:ok, %{organisation: organisation}} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("%{name} is created, and you are its owner.", name: organisation.name)
         )
         |> push_navigate(to: ~p"/#{organisation}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}

      {:error, _reason} ->
        {:noreply, refused(socket)}
    end
  end

  def handle_event("change_kind", %{"kind" => kind}, socket) do
    %{scope: scope, target_id: id} = socket.assigns

    case Operators.change_kind(scope, id, kind) do
      {:ok, organisation} ->
        {:noreply,
         socket
         |> put_flash(:info, kind_changed(organisation))
         |> load()
         |> back()}

      {:error, :client} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("A client of an operator cannot be made an operator."))
         |> back()}

      {:error, :has_clients} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("An operator with clients cannot be made an organisation.")
         )
         |> back()}

      {:error, _reason} ->
        {:noreply, refused(socket)}
    end
  end

  def handle_event("confirm", %{"confirm" => params}, socket) do
    {:noreply, assign_confirm(socket, params)}
  end

  def handle_event("purge", %{"confirm" => %{"slug" => slug}}, socket) do
    %{scope: scope, target_id: id} = socket.assigns

    case ApiaryPro.Deletion.purge_on_request(scope, id, slug) do
      {:ok, _outcome} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("The organisation is purged."))
         |> load()
         |> back()}

      {:error, :confirmation} ->
        {:noreply, assign_confirm(socket, %{"slug" => slug}, :mismatch)}

      {:error, :has_clients} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("An operator with clients is not purged: each client is deleted first.")
         )
         |> back()}

      {:error, _reason} ->
        {:noreply, refused(socket)}
    end
  end

  def handle_event("suspend_organisation", _params, %{assigns: %{target_id: id}} = socket)
      when is_binary(id) do
    case Suspensions.suspend_organisation(socket.assigns.scope, id) do
      {:ok, organisation} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("%{name} is suspended.", name: organisation.name))
         |> load()
         |> back()}

      {:error, _reason} ->
        {:noreply, refused(socket)}
    end
  end

  def handle_event("activate_organisation", %{"id" => id}, socket) do
    case Suspensions.activate_organisation(socket.assigns.scope, id) do
      {:ok, organisation} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("%{name} is active again.", name: organisation.name))
         |> load()}

      {:error, _reason} ->
        {:noreply, refused(socket)}
    end
  end

  # Once the form was submitted, it is checked on every change: an error goes as soon as
  # its field is right, and comes back if the field is wrong again.
  def handle_event("validate_transfer", params, socket) do
    params = transfer_params(params)

    refused =
      if socket.assigns.transfer_submitted, do: missing_from_transfer(params), else: []

    {:noreply, assign_transfer(socket, params, refused)}
  end

  # Both fields are checked before anything is asked of the organisation, so the arbiter
  # hears of an admin not chosen and of a reason not given at once.
  def handle_event("transfer", params, %{assigns: %{target_id: id}} = socket)
      when is_binary(id) do
    scope = socket.assigns.scope
    params = transfer_params(params)
    socket = assign(socket, :transfer_submitted, true)

    with [] <- missing_from_transfer(params),
         {:ok, _transfer} <-
           Transfers.arbitrate(scope, id, params["membership_id"], params["reason"]) do
      candidate = Enum.find(socket.assigns.candidates, &(&1.id == params["membership_id"]))

      {:noreply,
       socket
       |> put_flash(:info, transfer_offered(candidate))
       |> load()
       |> back()}
    else
      [_ | _] = refused ->
        {:noreply, assign_transfer(socket, params, refused)}

      {:error, :reason} ->
        {:noreply, assign_transfer(socket, params, [:reason])}

      {:error, :not_admin} ->
        {:noreply,
         socket
         |> assign_transfer(params, [:not_admin])
         |> refresh_candidates()}

      {:error, :has_owner} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("It has an owner who can act; the instance does not overrule them.")
         )
         |> load()
         |> back()}

      {:error, :suspended} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("It is suspended. Activate it first."))
         |> load()
         |> back()}

      {:error, :busy} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Someone changed this at the same moment, so nothing was changed. Try again.")
         )}

      {:error, _reason} ->
        {:noreply, refused(socket)}
    end
  end

  def handle_event("save_features", params, %{assigns: %{target_id: id}} = socket)
      when is_binary(id) do
    scope = socket.assigns.scope

    features = FeatureComponents.checked(params["features"])

    case Grants.set_organisation(scope, id, features) do
      {:ok, _features} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("The organisation's features are saved."))
         |> load()
         |> back()}

      # Refused as the boxes are: it stays, the boxes as they were sent and why under them,
      # until the next save.
      {:error, :needs} ->
        {:noreply,
         assign(socket, :features_refused, %{
           id: id,
           features: features,
           errors: [needs_runs()]
         })}

      {:error, :client} ->
        {:noreply,
         socket
         |> put_flash(:error, client_features_sentence())
         |> load()
         |> back()}

      {:error, :busy} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("Someone changed this at the same moment, so nothing was changed. Try again.")
         )
         |> load()
         |> back()}

      {:error, _reason} ->
        {:noreply, refused(socket)}
    end
  end

  # A confirmation without its page or its row open, as a second click of a button whose
  # confirmation has closed sends: the page as it is now.
  def handle_event(event, _params, socket)
      when event in ~w(suspend_organisation transfer save_features) do
    {:noreply, socket |> load() |> back()}
  end

  defp load(socket) do
    scope = socket.assigns.scope

    assign_async(socket, :organisations, fn ->
      case Operators.list_organisations(scope) do
        {:ok, rows} ->
          {:ok,
           %{
             organisations: rows |> put_features() |> Enum.map(&put_owner_suspended/1)
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  # Whether no owner of the row's organisation may act because of a suspension, which its
  # status says and which the arbiter's transfer is for; never so for the instance
  # organisation, nor for an organisation marked for deletion.
  defp put_owner_suspended(%{organisation: organisation} = row) do
    owner_suspended =
      in_use?(row) and not Tenants.instance_organisation?(organisation) and
        Suspensions.owner_suspended?(organisation)

    Map.put(row, :owner_suspended, owner_suspended)
  end

  # What each row's organisation has, which its Features column shows: read for all the
  # rows at once.
  defp put_features(rows) do
    features = rows |> Enum.map(& &1.organisation) |> ApiaryPro.Features.of_all()
    Enum.map(rows, &Map.put(&1, :features, Map.fetch!(features, &1.organisation.id)))
  end

  # Features are granted to an operator and taken away from an organisation with no
  # operator, in use; a client's are its operator's, and the instance organisation has
  # all.
  defp may_grant?(scope, %{organisation: organisation} = row) do
    in_use?(row) and not Tenants.client?(organisation) and
      Access.can?(scope, :"instance.grant_features", organisation)
  end

  # The arbiter's choice of admin and reason, and what was refused of them. A radio group
  # none of whose choices is picked sends nothing, nor does a field sent as anything but
  # text: refused, each is a field all the same, so its error shows under it.
  defp assign_transfer(socket, params \\ %{}, refused \\ []) do
    errors = Enum.map(refused, &transfer_error/1)

    params =
      if refused == [],
        do: params,
        else: Map.merge(%{"membership_id" => "", "reason" => ""}, params)

    assign(socket, :transfer_form, to_form(params, as: :transfer, errors: errors))
  end

  defp transfer_error(:no_admin),
    do: {:membership_id, {dgettext_noop("errors", "choose an admin to offer it to"), []}}

  defp transfer_error(:not_admin),
    do:
      {:membership_id,
       {dgettext_noop("errors", "is no longer an admin who can act: choose another"), []}}

  defp transfer_error(:reason),
    do:
      {:reason,
       {dgettext_noop("errors", "is required, and at most %{max} characters"),
        [max: Transfers.reason_max()]}}

  # What the form lacks, before the offer is asked for: an admin, and a reason of at most
  # the length `ApiaryPro.Transfers.arbitrate/4` takes. Whether the admin may be offered it
  # is the offer's to say.
  defp missing_from_transfer(params) do
    reason = trimmed(params["reason"])

    Enum.reject(
      [
        trimmed(params["membership_id"]) == "" && :no_admin,
        (reason == "" or String.length(reason) > Transfers.reason_max()) && :reason
      ],
      &(&1 == false)
    )
  end

  # The form's fields as text: one sent as anything else, which no form of the page sends,
  # is not given, and is answered as such.
  defp transfer_params(%{"transfer" => %{} = params}),
    do: Map.filter(params, fn {_name, value} -> is_binary(value) end)

  defp transfer_params(_params), do: %{}

  defp trimmed(value) when is_binary(value), do: String.trim(value)
  defp trimmed(_value), do: ""

  defp refresh_candidates(%{assigns: %{target_id: id}} = socket) do
    case Transfers.arbitration_candidates(socket.assigns.scope, id) do
      {:ok, candidates} -> assign(socket, :candidates, candidates)
      {:error, _reason} -> refused(socket)
    end
  end

  defp transfer_offered(%{user: %{email: email}}),
    do:
      gettext(
        "The ownership is offered to %{email}. They become its owner when they accept it.",
        email: email
      )

  defp transfer_offered(_candidate),
    do: gettext("The ownership is offered. Its admin becomes its owner when they accept it.")

  defp assign_form(socket, params, action \\ nil) do
    changeset = Operators.change_client(params)
    changeset = if action, do: Map.put(changeset, :action, action), else: changeset
    assign(socket, :form, to_form(changeset))
  end

  # The slug typed to confirm a purge, and whether it was refused.
  defp assign_confirm(socket, params \\ %{}, refused \\ nil) do
    errors =
      if refused == :mismatch,
        do: [slug: {dgettext_noop("errors", "is not the slug"), []}],
        else: []

    assign(socket, :confirm_form, to_form(params, as: :confirm, errors: errors))
  end

  # Back to the list as it was left: its view, search, filter and order.
  defp back(socket),
    do: push_patch(socket, to: list_path(socket.assigns.list, []))

  defp refused(socket) do
    socket
    |> put_flash(
      :error,
      gettext("That is no longer possible. The page shows the instance as it is now.")
    )
    |> load()
    |> back()
  end

  # The row a page or a confirmation is about, in a list of one, once the rows have
  # arrived; none before.
  defp target(%{ok?: true, result: rows}, id) when is_binary(id),
    do: Enum.filter(rows, &(&1.organisation.id == id))

  defp target(_organisations, _id), do: []

  # What the row's suspension button does: suspend an organisation in use, activate a
  # suspended one; nil for none, and for the instance organisation.
  defp suspension(scope, %{organisation: organisation} = row) do
    cond do
      Tenants.suspended?(organisation) and
          Access.can?(scope, :"instance.activate_organisation", organisation) ->
        :activate

      not Tenants.suspended?(organisation) and in_use?(row) and
          Access.can?(scope, :"instance.suspend_organisation", organisation) ->
        :suspend

      true ->
        nil
    end
  end

  # The arbiter's transfer, offered where it may be made: an organisation whose owners are
  # all suspended, a client as any other, in use and not suspended itself.
  defp may_transfer?(scope, %{organisation: organisation} = row) do
    in_use?(row) and not Tenants.suspended?(organisation) and row.owner_suspended and
      Access.can?(scope, :"instance.transfer", organisation)
  end

  defp may_create?(scope),
    do:
      Access.can?(scope, :"instance.create_organisation", scope.organisation) or
        Access.can?(scope, :"instance.create_operator", scope.organisation)

  # The kind a row may be changed to, as the page offers it: an organisation that is no
  # client an operator, an operator without clients an organisation, the instance
  # organisation as any other; nil for none.
  defp kind_change(scope, %{organisation: organisation} = row) do
    cond do
      not in_use?(row) -> nil
      not Access.can?(scope, :"instance.change_kind", organisation) -> nil
      not Tenants.operator?(organisation) and not Tenants.client?(organisation) -> :operator
      Tenants.operator?(organisation) and row.clients == 0 -> :organisation
      true -> nil
    end
  end

  defp may_purge?(scope, %{organisation: organisation}),
    do: Access.can?(scope, :"instance.purge_organisation", organisation)

  defp in_use?(%{organisation: %{deletion_marked_at: nil}}), do: true
  defp in_use?(_row), do: false

  # The kind in words, as its column says it; nil for a plain organisation, which says none.
  defp kind_word(%{organisation: organisation} = row) do
    cond do
      Tenants.instance_organisation?(organisation) -> gettext("The instance owner")
      Tenants.operator?(organisation) -> kind_label(:operator)
      row.operator -> gettext("Client")
      true -> nil
    end
  end

  defp kind_label(:operator), do: gettext("Operator")
  defp kind_label(_organisation), do: gettext("Organisation")

  defp kind_button(:operator), do: gettext("Yes, make operator")
  defp kind_button(:organisation), do: gettext("Yes, make organisation")
  defp kind_button(nil), do: nil

  # The question of the change's confirmation, on the organisation's row.
  defp kind_question(:operator, name), do: gettext("Make %{name} an operator?", name: name)

  defp kind_question(:organisation, name),
    do: gettext("Make %{name} an organisation?", name: name)

  defp kind_question(nil, name), do: name

  # The menu's item, which asks to confirm the change on the row.
  defp kind_item(:operator), do: gettext("Make operator…")
  defp kind_item(:organisation), do: gettext("Make organisation…")
  defp kind_item(nil), do: nil

  defp kind_changed(%{name: name} = organisation) do
    if Tenants.operator?(organisation),
      do: gettext("%{name} is an operator now.", name: name),
      else: gettext("%{name} is an organisation now.", name: name)
  end

  ## The list's views, search, filter and order, all in the URL.

  @views ~w(all operators clients suspended deleted)
  @sorts ~w(name created)

  defp views do
    [
      {"all", gettext("All")},
      {"operators", gettext("Operators")},
      {"clients", gettext("Clients")},
      {"suspended", gettext("Suspended")},
      {"deleted", gettext("Deleted")}
    ]
  end

  defp sorts, do: [{"name", gettext("Name")}, {"created", gettext("Created, newest first")}]

  defp sort_label(sort), do: sorts() |> List.keyfind(sort, 0, {sort, sort}) |> elem(1)

  defp list_params(params) do
    %{
      view: if(params["view"] in @views, do: params["view"], else: "all"),
      q: query(params["q"]),
      operator:
        case Ecto.UUID.cast(params["operator"] || "") do
          {:ok, id} -> id
          :error -> nil
        end,
      sort: if(params["sort"] in @sorts, do: params["sort"], else: "name")
    }
  end

  defp query(q) do
    case String.trim(q || "") do
      "" -> nil
      q -> q
    end
  end

  # Whether the search or the filter narrows the view.
  defp narrowed?(list), do: not is_nil(list.q) or not is_nil(list.operator)

  # What an empty list says: that nothing matches where the search or the filter narrows
  # it, what the view keeps where only the view does.
  defp empty_title(list) do
    case {narrowed?(list), list.view} do
      {false, "operators"} -> gettext("No organisation is an operator")
      {false, "clients"} -> gettext("No organisation is a client")
      {false, "suspended"} -> gettext("No organisation is suspended")
      {false, "deleted"} -> gettext("No organisation is deleted")
      _matches -> gettext("No organisation matches")
    end
  end

  defp list_path(list, changes) do
    list = Enum.into(changes, list)

    Paths.organisations(
      view: list.view != "all" && list.view,
      q: list.q,
      operator: list.operator,
      sort: list.sort != "name" && list.sort
    )
  end

  # The operators among the rows, by name: the values of the Filter menu's one section.
  defp operators(rows) do
    rows
    |> Enum.filter(&Tenants.operator?(&1.organisation))
    |> Enum.map(& &1.organisation)
  end

  defp in_view?(_row, "all"), do: true
  defp in_view?(row, "operators"), do: in_use?(row) and Tenants.operator?(row.organisation)
  defp in_view?(row, "clients"), do: in_use?(row) and not is_nil(row.operator)
  defp in_view?(row, "suspended"), do: in_use?(row) and Tenants.suspended?(row.organisation)
  defp in_view?(row, "deleted"), do: not in_use?(row)

  # The rows the view, the search and the operator keep, in the order chosen.
  defp shown(rows, list) do
    rows
    |> Enum.filter(&in_view?(&1, list.view))
    |> Enum.filter(&(is_nil(list.operator) or (&1.operator && &1.operator.id == list.operator)))
    |> Enum.filter(&matches?([&1.organisation.name, &1.organisation.slug], list.q))
    |> then(fn rows ->
      if list.sort == "created",
        do: Enum.sort_by(rows, & &1.organisation.inserted_at, {:desc, DateTime}),
        else: rows
    end)
  end

  defp matches?(_words, nil), do: true

  defp matches?(words, q) do
    q = String.downcase(q)
    Enum.any?(words, &(is_binary(&1) and String.contains?(String.downcase(&1), q)))
  end
end
