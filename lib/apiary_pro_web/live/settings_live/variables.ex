defmodule ApiaryProWeb.SettingsLive.Variables do
  @moduledoc """
  The organisation's variables, the Variables tab of its settings' Secrets and variables
  section, in the frame's second column
  (`ApiaryWeb.SettingsComponents.sections/2`, `ApiaryWeb.PageComponents.settings_page/1`),
  with the `organisation_variables` feature: `/:org/settings/variables`, the names and
  values every workspace of the organisation inherits, above each workspace's variables
  (`ApiaryPro.OrganisationVariables`). It is laid out as the core's workspace Variables
  tab (`ApiaryWeb.SecretLive.Index`): New variable beside a search and a Filter menu
  (Lock: Locked, Not locked), the filters in force as tokens, all in the URL
  (`ApiaryWeb.SecretLive.Query`), a status line that says what they left, then a table
  sorted by name, each variable with its value, its lock, how many workspaces and
  targets override it or have their override set aside by the lock
  (`ApiaryPro.OrganisationVariables.overrides/1`), and who changed it last.

  Nothing opens over the page: each act is at a separate path. New variable
  (`/new`) and Change value (`/:id/change`) are form pages of the section
  (`ApiaryWeb.PageComponents.page_form/1`): their title, one sentence, the form, its
  button, and Cancel back to the list; the breadcrumb's Secrets and variables leads back
  too.
  Lock (`/:id/lock`), Unlock (`/:id/unlock`) and Delete (`/:id/delete`) ask to confirm in
  place, on the variable's row (`CoreComponents.inline_confirm/1`): a lock and an unlock
  reach every workspace, so neither acts from the menu at once. A refusal of the back end
  keeps the confirmation open, says why under its question, and keeps the focus on its
  button. Cancel, Escape and a lock or an unlock done give the focus back to the row's
  menu button; a deletion done, to the next row's.

  A run receives only its security policy: the run configuration a gateway fetches holds
  it alone (`Apiary.Policy.Render`). Every view says so, in the core's
  line (`ApiaryWeb.PageComponents.not_on_runs/1`): the sentence of the core's Variables
  tab, word for word, then the page's.

  Owners and admins read and change them (`organisation_variable.edit`). A reader, an
  instance admin, reads them and sees no control, and one line that says who changes them;
  a suspended organisation's are read only, as the notice above the page says. A member
  does not open the page, and where the feature is off it is not there. The page follows
  every change of the variables (`ApiaryPro.OrganisationVariables.subscribe/1`).
  """
  use ApiaryProWeb, :live_view
  use ApiaryWeb.Features, :organisation_variables
  on_mount {ApiaryWeb.Access, :"organisation_variable.read"}

  alias Apiary.Access
  alias Apiary.Secrets
  alias ApiaryPro.OrganisationVariables
  alias ApiaryPro.OrganisationVariables.Variable
  alias ApiaryProWeb.SettingsLive.SecretsAndVariables
  alias ApiaryWeb.{People, SettingsComponents, UserAuth}
  alias ApiaryWeb.SecretLive.Query

  # The acts that are a page of the section; the rest ask to confirm on their row.
  @pages [:new, :change]

  # The acts that ask to confirm on their row.
  @confirms [:lock, :unlock, :delete]

  @impl true
  def render(%{act: act} = assigns) when act in @pages do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:organisation}
      sections={@sections}
      section={:secrets}
      section_path={list_path(@current_scope, @query)}
    >
      <:crumb>{crumb_words(@act)}</:crumb>

      <.page_form
        id="variable-page"
        title={form_title(assigns)}
        cancel={list_path(@current_scope, @query)}
        cancel_by="patch"
      >
        <:description>{form_sentence(assigns)}</:description>
        <.not_in_runs />
        <.form_page {assigns} />
      </.page_form>
    </Layouts.app>
    """
  end

  # The section: its title and sentence, the line that a run receives only its security
  # policy, who changes them, New variable beside the search and Filter, and the list, as
  # the core's Variables tab has them. One status line, there from the start, says what a
  # search or a filter left.
  def render(assigns) do
    assigns =
      assign(assigns,
        tokens: Query.tokens(assigns.query),
        shown: Query.variables(assigns.variables, %{}, assigns.query)
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:organisation}
      sections={@sections}
      section={:secrets}
    >
      <.settings_page section={:secrets} measure="list" title={SecretsAndVariables.title()}>
        <:subtitle>{SecretsAndVariables.sentence(@current_scope.organisation)}</:subtitle>

        <SecretsAndVariables.tabs
          organisation={@current_scope.organisation}
          current={:variables}
          secrets={@secrets_count}
          variables={length(@variables)}
        />

        <div id="secrets-tabs-panel" class="grid gap-5">
          <div class="-mt-2 grid gap-1">
            <p id="variables-inherit" class="text-[13px]/5 text-muted">
              {gettext(
                "Names and values every workspace of %{organisation} inherits. A workspace may override one that is not locked; a locked one holds in every workspace and target.",
                organisation: @current_scope.organisation.name
              )}
            </p>

            <.not_in_runs />

            <p
              :if={!@may_edit && !@suspended}
              id="variables-read-only"
              class="text-[13px]/5 text-muted"
            >
              {gettext("Only owners and admins of %{organisation} change its variables.",
                organisation: @current_scope.organisation.name
              )}
            </p>
          </div>

          <.variables_bar {assigns} />

          <%!-- Always there, so a screen reader hears the tab it came to from Secrets
               and what a search or a filter left. Out of sight unless one narrows the
               list. --%>
          <div
            id="variables-status"
            role="status"
            class={["q-status", !(Query.narrowed?(@query) && @variables != []) && "sr-only"]}
          >
            <span :if={@switched} class="sr-only">
              {SecretsAndVariables.switch_words(:variables, length(@variables))}
            </span>
            <p :if={Query.narrowed?(@query) && @variables != []} class="text-[13px] text-muted">
              {ngettext("%{number} variable matches", "%{number} variables match", length(@shown),
                number: Format.number(length(@shown))
              )}
            </p>
          </div>

          <div :if={@variables == []} id="variables-empty">
            <.empty_state icon="hero-variable" tone="neutral" title={gettext("No variables yet")}>
              {inherited_sentence(@current_scope)}
              <:actions :if={@may_edit}>
                <.button patch={new_path(@current_scope)}>
                  {gettext("New variable")}
                </.button>
              </:actions>
            </.empty_state>
          </div>

          <div :if={@variables != [] && @shown == []} id="variables-no-match">
            <.empty_state icon={nil} tone="neutral" title={gettext("No variable matches")}>
              <:actions>
                <.button id="variables-clear" patch={list_path(@current_scope, Query.clear(@query))}>
                  {gettext("Clear the search")}
                </.button>
              </:actions>
            </.empty_state>
          </div>

          <.table
            :if={@shown != []}
            id="variables"
            label={gettext("Variables")}
            rows={@shown}
            row_id={&"variable-#{&1.id}"}
            confirming={confirming(@act, @variable)}
          >
            <:col :let={variable} label={gettext("Name")} kind="title">
              <%!-- Below 600 px of table, where Lock and Overrides are gone, the lock
                 shows beside the name and the count on a line under it (q-var-fold). --%>
              <span class="q-nm q-var-nm">
                <span class="q-title font-mono" title={variable.name}>{variable.name}</span>
                <span :if={variable.locked} class="q-var-fold q-var-lock">
                  <.icon name="hero-lock-closed-micro" class="size-3.5 text-faint" />
                  <span class="sr-only">{gettext("Locked")}</span>
                </span>
                <span class="q-var-fold q-var-line">
                  <.below variable={variable} counts={counts(@overrides, variable)} />
                </span>
              </span>
            </:col>
            <:col :let={variable} label={gettext("Value")}>
              <span
                :if={variable.value != ""}
                id={"variable-#{variable.id}-value"}
                class="q-cut max-w-[28ch] font-mono text-[12.5px]"
                title={variable.value}
              >
                {variable.value}
              </span>
              <span :if={variable.value == ""} id={"variable-#{variable.id}-value"} class="q-faint">
                {gettext("Empty")}
              </span>
            </:col>
            <:col :let={variable} label={gettext("Lock")} from="sm">
              <span
                :if={variable.locked}
                id={"variable-#{variable.id}-lock"}
                class="inline-flex items-center gap-1"
              >
                <.icon name="hero-lock-closed-micro" class="size-3.5 text-faint" />{gettext("Locked")}
              </span>
              <span :if={!variable.locked} id={"variable-#{variable.id}-lock"} class="sr-only">
                {gettext("Not locked")}
              </span>
            </:col>
            <:col :let={variable} label={gettext("Overrides")} from="sm">
              <.below
                id={"variable-#{variable.id}-below"}
                variable={variable}
                counts={counts(@overrides, variable)}
              />
            </:col>
            <:col :let={variable} label={gettext("Changed")} from="md">
              <.changed
                at={variable.updated_at}
                by={variable.updated_by_id}
                people={@people}
                reader={@current_scope.user.email}
              />
            </:col>
            <:action :let={variable}>
              <.row_menu
                :if={@may_edit}
                id={"variable-#{variable.id}-menu"}
                label={gettext("Actions for %{name}", name: variable.name)}
              >
                <.menu_item
                  id={"variable-#{variable.id}-change"}
                  patch={variable_path(@current_scope, variable, :change)}
                  aria-label={gettext("Change value of %{name}", name: variable.name)}
                >
                  {gettext("Change value…")}
                </.menu_item>
                <.menu_item
                  :if={!variable.locked}
                  id={"variable-#{variable.id}-lock-item"}
                  patch={variable_path(@current_scope, variable, :lock)}
                  aria-label={gettext("Lock %{name}", name: variable.name)}
                >
                  {gettext("Lock…")}
                </.menu_item>
                <.menu_item
                  :if={variable.locked}
                  id={"variable-#{variable.id}-unlock-item"}
                  patch={variable_path(@current_scope, variable, :unlock)}
                  aria-label={gettext("Unlock %{name}", name: variable.name)}
                >
                  {gettext("Unlock…")}
                </.menu_item>
                <.menu_divider />
                <.menu_item
                  id={"variable-#{variable.id}-delete"}
                  patch={variable_path(@current_scope, variable, :delete)}
                  aria-label={gettext("Delete variable %{name}", name: variable.name)}
                >
                  {gettext("Delete variable…")}
                </.menu_item>
              </.row_menu>
            </:action>
            <:confirm :let={variable}>
              <.confirm
                act={@act}
                variable={variable}
                counts={counts(@overrides, variable)}
                refusal={@refusal}
                cancel={JS.push("cancel_confirm")}
              />
            </:confirm>
          </.table>
          <.focus_back focus={@focus} />
        </div>
      </.settings_page>
    </Layouts.app>
    """
  end

  # That a run receives only its security policy, on every view of the page: the core's line, its
  # first sentence the core's Variables tab's msgid word for word, the second the page's.
  defp not_in_runs(assigns) do
    ~H"""
    <.not_on_runs id="variables-not-in-runs">
      {gettext("A run receives only its security policy.")}
      {gettext(
        "Qory Apiary keeps the variables and works out what each workspace and target inherits."
      )}
    </.not_on_runs>
    """
  end

  # New variable, beside the search and the Filter while there are any, and the filters
  # in force under them: the core's Variables tab's bar, without its Targets filter and
  # its Sort.
  defp variables_bar(assigns) do
    ~H"""
    <div :if={@may_edit || @variables != []} class="q-bar">
      <.button :if={@may_edit} id="new-variable" variant="primary" patch={new_path(@current_scope)}>
        <.icon name="hero-plus-micro" class="size-4" /> {gettext("New variable")}
      </.button>
      <.list_search
        :if={@variables != []}
        id="variables-search"
        value={@query.q}
        label={gettext("Find a variable")}
        placeholder={gettext("Find a variable by name or value")}
        change="find"
      />
      <.filter_menu :if={@variables != []} id="variables-filter" count={length(@tokens)}>
        <.menu_heading title={gettext("Lock")} />
        <.menu_item
          :for={{lock, words} <- [yes: gettext("Locked"), no: gettext("Not locked")]}
          id={"variables-filter-lock-#{lock}"}
          patch={list_path(@current_scope, Query.toggle(@query, {:lock, lock}))}
          checked={@query.lock == lock}
        >
          {words}
        </.menu_item>
      </.filter_menu>
    </div>

    <.filter_tokens id="variables-tokens" clear={list_path(@current_scope, Query.clear(@query))}>
      <:token
        :for={token <- @tokens}
        id={"variables-token-#{elem(token, 0)}"}
        patch={list_path(@current_scope, Query.toggle(@query, token))}
        label={gettext("Remove the filter %{filter}", filter: token_words(token))}
      >
        {token_words(token)}
      </:token>
    </.filter_tokens>
    """
  end

  defp token_words({:lock, :yes}), do: gettext("Locked")
  defp token_words({:lock, :no}), do: gettext("Not locked")

  attr :id, :string, default: nil
  attr :variable, Variable, required: true
  attr :counts, :map, required: true, doc: "how many workspaces and targets override it"

  # How many workspaces and targets override the value: in force in place of the
  # organisation's where it is not locked, set aside by the lock where it is.
  defp below(assigns) do
    assigns = assign(assigns, :total, assigns.counts.workspaces + assigns.counts.repositories)

    ~H"""
    <span :if={@total == 0} id={@id} class="q-faint">{gettext("Not overridden")}</span>
    <span :if={@total > 0 && @variable.locked} id={@id}>
      {ngettext(
        "%{number} value set aside by the lock",
        "%{number} values set aside by the lock",
        @total,
        number: Format.number(@total)
      )}
    </span>
    <span :if={@total > 0 && !@variable.locked} id={@id} class="q-parts">
      <span :if={@counts.workspaces > 0}>
        {ngettext(
          "%{number} workspace overrides it",
          "%{number} workspaces override it",
          @counts.workspaces,
          number: Format.number(@counts.workspaces)
        )}
      </span>
      <span :if={@counts.workspaces > 0 && @counts.repositories > 0} aria-hidden="true">·</span>
      <span :if={@counts.repositories > 0}>
        {ngettext(
          "%{number} target overrides it",
          "%{number} targets override it",
          @counts.repositories,
          number: Format.number(@counts.repositories)
        )}
      </span>
    </span>
    """
  end

  attr :at, :any, required: true
  attr :by, :any, required: true, doc: "the user id of who changed it"
  attr :people, :map, required: true
  attr :reader, :string, required: true, doc: "the reader's address"

  # The time, and who: the first letter of their account's address, with the address as
  # its tooltip, or "Former member" for a deleted account; the time alone for no one.
  defp changed(assigns) do
    assigns = assign(assigns, :person, People.account(assigns.people, assigns.by))

    ~H"""
    <span class="tabular-nums">
      <%= if @person do %>
        <.rich text={
          rich_gettext("%{time} by %{person}",
            time: {:part, :time},
            person: letter(@person, @reader)
          )
        }>
          <:part name={:time}><.time_ago at={@at} /></:part>
        </.rich>
      <% else %>
        <.time_ago at={@at} />
      <% end %>
    </span>
    """
  end

  # Who changed it, in a sentence: their first letter, with the address as its tooltip
  # (`ApiaryWeb.CoreComponents.avatar/1`).
  defp letter(email, reader) do
    assigns = %{email: email, reader: reader}
    ~H|<.avatar email={@email} reader={@reader} size="xs" />|
  end

  attr :focus, :any, required: true, doc: "`{id, n}`: the element to focus, once, or nil"

  # Where the focus goes after a confirmation's act or its Cancel, so that it never falls
  # to the body: a mark the server draws anew each time (`focus/2`), whose `phx-mounted`
  # focuses the element once the patch that draws it has been applied.
  defp focus_back(assigns) do
    ~H"""
    <span
      :if={@focus}
      id={"variables-focus-#{elem(@focus, 1)}"}
      hidden
      phx-mounted={JS.focus(to: "#" <> elem(@focus, 0))}
    />
    """
  end

  ## The pages of a form

  defp form_page(%{act: :new} = assigns) do
    ~H"""
    <.form
      for={@form}
      id="variable-form"
      phx-change="validate_variable"
      phx-submit="create_variable"
      class="grid gap-4"
      novalidate
    >
      <.input
        field={@form[:name]}
        label={gettext("Name")}
        placeholder="NPM_REGISTRY"
        hint={gettext("Letters, digits and _, starting with a letter or _.")}
        autocomplete="off"
        spellcheck="false"
        class="font-mono"
        phx-mounted={JS.focus()}
      />
      <.input
        field={@form[:value]}
        label={gettext("Value")}
        placeholder="https://registry.example.com"
        hint={gettext("Plain text on one line.")}
        autocomplete="off"
        spellcheck="false"
        class="font-mono"
      />
      <.input
        field={@form[:locked]}
        type="checkbox"
        label={gettext("Locked: no workspace or target may override it")}
      />
      <.page_form_foot id="variable-save" cancel={list_path(@current_scope, @query)} cancel_by="patch">
        <.button variant="primary" type="submit" loading_text={gettext("Saving")}>
          {gettext("Save variable")}
        </.button>
      </.page_form_foot>
    </.form>
    """
  end

  defp form_page(%{act: :change} = assigns) do
    assigns = assign(assigns, :unshown, unshown(assigns.form, assigns.variable))

    ~H"""
    <.form for={@form} id="variable-form" phx-submit="change_variable" class="grid gap-4" novalidate>
      <.input
        field={@form[:value]}
        label={gettext("Value")}
        hint={gettext("Plain text on one line.")}
        autocomplete="off"
        spellcheck="false"
        class="font-mono"
        phx-mounted={JS.focus()}
      />
      <p
        :if={@unshown != []}
        id="variable-refused"
        role="alert"
        class="flex items-center gap-1.5 text-[12.5px]/[18px] text-error"
      >
        <.icon name="hero-exclamation-circle-micro" class="size-4 flex-none" />
        <span>{Enum.join(@unshown, " ")}</span>
      </p>
      <.page_form_foot id="variable-save" cancel={list_path(@current_scope, @query)} cancel_by="patch">
        <.button variant="primary" type="submit" loading_text={gettext("Saving")}>
          {gettext("Change value")}
        </.button>
      </.page_form_foot>
    </.form>
    """
  end

  # The back end's reasons on a field the form does not draw (Change value draws the value
  # alone): a refusal on the name, another spelling below or a limit, said on the line
  # above the form's foot, with the variable as its subject where it needs one.
  defp unshown(form, variable),
    do:
      for(
        {field, _error} = error <- form.source.errors,
        field != :value,
        do: reason(variable, error)
      )

  defp form_title(%{act: :new}), do: gettext("New variable")

  defp form_title(%{act: :change, variable: variable}),
    do: gettext("Change the value of %{name}", name: variable.name)

  defp crumb_words(:new), do: gettext("New variable")
  defp crumb_words(:change), do: gettext("Change value")

  defp form_sentence(%{act: :new, current_scope: scope}), do: inherited_sentence(scope)

  # A locked variable's value holds in every workspace and target, whatever they set;
  # an unlocked one's reaches only those that do not override it.
  defp form_sentence(%{act: :change, variable: %Variable{locked: true, name: name}}),
    do:
      gettext("Every workspace and target inherits the new value: %{name} is locked.", name: name)

  defp form_sentence(%{act: :change}),
    do:
      gettext(
        "Each workspace that does not override it inherits the new value, and so does each of its targets that does not override it."
      )

  defp inherited_sentence(scope),
    do:
      gettext(
        "Each workspace of %{organisation} that does not override a variable set here inherits it, and so does each of its targets that does not override it. A locked variable holds in every workspace and target, and sets their overrides aside.",
        organisation: scope.organisation.name
      )

  ## The confirmations in place

  defp confirming(act, %Variable{} = variable) when act in @confirms,
    do: "variable-#{variable.id}"

  defp confirming(_act, _variable), do: nil

  attr :act, :atom, required: true
  attr :variable, Variable, required: true
  attr :counts, :map, required: true
  attr :refusal, :string, default: nil, doc: "why the back end refused it, once it did"
  attr :cancel, :any, required: true, doc: "what Cancel and Escape send"

  defp confirm(%{act: :lock} = assigns) do
    assigns = assign(assigns, :below, assigns.counts.workspaces + assigns.counts.repositories)

    ~H"""
    <.inline_confirm
      id={"variable-#{@variable.id}-confirm"}
      question={gettext("Lock %{name}?", name: @variable.name)}
      cancel={@cancel}
    >
      {gettext("While it is locked, no workspace or target may override it.")}
      <span :if={@below > 0} id="lock-below">
        {ngettext(
          "%{number} workspace or target override is set aside while the lock holds.",
          "%{number} workspace or target overrides are set aside while the lock holds.",
          @below,
          number: Format.number(@below)
        )}
      </span>
      <.refusal_line refusal={@refusal} />
      <:action>
        <.button
          variant="primary"
          id={"variable-#{@variable.id}-confirm-act"}
          size="xs"
          phx-click="lock_variable"
          loading_text={gettext("Locking")}
        >
          {gettext("Lock")}
        </.button>
      </:action>
    </.inline_confirm>
    """
  end

  defp confirm(%{act: :unlock} = assigns) do
    assigns = assign(assigns, :aside, back_in_force(assigns.counts))

    ~H"""
    <.inline_confirm
      id={"variable-#{@variable.id}-confirm"}
      question={gettext("Unlock %{name}?", name: @variable.name)}
      cancel={@cancel}
    >
      {gettext("Workspaces and targets may override it again.")}
      <.back_in_force_line :if={@aside > 0} id="unlock-below" number={@aside} />
      <.refusal_line refusal={@refusal} />
      <:action>
        <.button
          variant="primary"
          id={"variable-#{@variable.id}-confirm-act"}
          size="xs"
          phx-click="unlock_variable"
          loading_text={gettext("Unlocking")}
        >
          {gettext("Unlock")}
        </.button>
      </:action>
    </.inline_confirm>
    """
  end

  defp confirm(%{act: :delete} = assigns) do
    assigns = assign(assigns, :aside, back_in_force(assigns.counts))

    ~H"""
    <.inline_confirm
      id={"variable-#{@variable.id}-confirm"}
      question={gettext("Delete %{name}?", name: @variable.name)}
      cancel={@cancel}
    >
      {gettext(
        "Workspaces no longer inherit it; a workspace or target that overrides it keeps its value. This cannot be undone."
      )}
      <.back_in_force_line :if={@variable.locked && @aside > 0} id="delete-below" number={@aside} />
      <.refusal_line refusal={@refusal} />
      <:action>
        <.button
          variant="danger"
          id={"variable-#{@variable.id}-confirm-act"}
          size="xs"
          phx-click="delete_variable"
          loading_text={gettext("Deleting")}
        >
          {gettext("Yes, delete")}
        </.button>
      </:action>
    </.inline_confirm>
    """
  end

  # How many values the organisation's lock sets aside an unlock or a deletion puts back
  # in force: a repository's whose workspace locks the name itself stays set aside, by
  # the workspace's lock (`ApiaryPro.OrganisationVariables.overrides/1`).
  defp back_in_force(counts),
    do: counts.workspaces + counts.repositories - counts.workspace_locked

  attr :id, :string, required: true
  attr :number, :integer, required: true

  defp back_in_force_line(assigns) do
    ~H"""
    <span id={@id}>
      {ngettext(
        "%{number} value set aside comes back in force.",
        "%{number} values set aside come back in force.",
        @number,
        number: Format.number(@number)
      )}
    </span>
    """
  end

  attr :refusal, :string, default: nil

  defp refusal_line(assigns) do
    ~H"""
    <span
      :if={@refusal}
      id="variable-refused"
      role="alert"
      class="block font-medium text-error-soft-content"
    >
      {@refusal}
    </span>
    """
  end

  ## Paths

  # The list, with its search and its filter in the URL (`ApiaryWeb.SecretLive.Query`).
  defp list_path(scope, %Query{} = query) do
    base = ~p"/#{scope.organisation}/settings/variables"

    case Query.to_params(query) do
      [] -> base
      params -> base <> "?" <> URI.encode_query(params)
    end
  end

  defp new_path(scope), do: ~p"/#{scope.organisation}/settings/variables/new"

  defp variable_path(scope, variable, :change),
    do: ~p"/#{scope.organisation}/settings/variables/#{variable.id}/change"

  defp variable_path(scope, variable, :lock),
    do: ~p"/#{scope.organisation}/settings/variables/#{variable.id}/lock"

  defp variable_path(scope, variable, :unlock),
    do: ~p"/#{scope.organisation}/settings/variables/#{variable.id}/unlock"

  defp variable_path(scope, variable, :delete),
    do: ~p"/#{scope.organisation}/settings/variables/#{variable.id}/delete"

  ## Mount, and the paths of the pages and the confirmations

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket), do: OrganisationVariables.subscribe(scope)

    socket =
      socket
      |> assign(
        act: nil,
        variable: nil,
        form: nil,
        refusal: nil,
        focus: nil,
        query: %Query{},
        switched: false
      )
      |> mays()

    case read(scope) do
      {:ok, data} -> {:ok, socket |> assign(data) |> say_switch()}
      {:error, _reason} -> raise ApiaryWeb.NotFound
    end
  end

  # Come from the Secrets tab, the status line says so once the page is up: said into the
  # line already there, a screen reader hears it.
  defp say_switch(socket) do
    if SecretsAndVariables.switched?(socket, :secrets), do: send(self(), :switched)
    socket
  end

  defp mays(socket) do
    scope = socket.assigns.current_scope

    assign(socket,
      sections: SettingsComponents.sections(scope, :organisation),
      may_edit: Access.can?(scope, :"organisation_variable.edit", scope.organisation),
      suspended: ApiaryPro.Access.suspended?(scope)
    )
  end

  # Everything the list shows, read again after every change.
  defp read(scope) do
    with {:ok, variables} <- OrganisationVariables.list(scope),
         {:ok, overrides} <- OrganisationVariables.overrides(scope),
         {:ok, secrets} <- Secrets.list_organisation_secrets(scope) do
      {:ok,
       %{
         variables: variables,
         overrides: overrides,
         people: people(variables),
         secrets_count: length(secrets)
       }}
    end
  end

  # user id => email, of the accounts that changed a variable, read in one query
  # (`ApiaryWeb.People.accounts/1`).
  defp people(variables), do: variables |> Enum.map(& &1.updated_by_id) |> People.accounts()

  defp counts(overrides, %Variable{name: name}),
    do:
      Map.get(overrides, String.downcase(name), %{
        workspaces: 0,
        repositories: 0,
        workspace_locked: 0
      })

  # The list read again. Refused, the scope is read again with what the reader may: a
  # membership that is gone sends the page to `/`; one that may no longer read the
  # variables (made a member, or the feature turned off) is sent to the organisation's
  # settings, rather than kept on a list it no longer reads.
  defp reload(socket) do
    case read(socket.assigns.current_scope) do
      {:ok, data} -> assign(socket, data)
      {:error, _reason} -> socket |> reload_scope() |> reread()
    end
  end

  defp reread(%{redirected: to} = socket) when not is_nil(to), do: socket

  defp reread(socket) do
    scope = socket.assigns.current_scope

    case read(scope) do
      {:ok, data} ->
        socket |> mays() |> assign(data)

      {:error, _reason} ->
        socket
        |> put_flash(
          :error,
          gettext("The variables of %{organisation} are no longer open to you.",
            organisation: scope.organisation.name
          )
        )
        |> push_navigate(to: ~p"/#{scope.organisation}/settings")
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    action = socket.assigns.live_action

    socket =
      socket
      |> assign(act: nil, variable: nil, form: nil, refusal: nil)
      |> then(&if(action == :index, do: assign(&1, :query, query(params)), else: &1))
      |> open(action, params)

    {:noreply, titled(socket)}
  end

  # The list's search and Lock filter, from the URL; the core's other filters and its
  # order are the workspace tab's, and left out here.
  defp query(params),
    do: %{Query.from_params(params) | values: nil, targets: nil, sort: :name}

  # The browser's title, the most specific first (`SettingsComponents.page_title/3`): a
  # page of a form is named by its act, the list by the section.
  defp titled(%{assigns: %{act: act}} = socket) when act in @pages,
    do:
      assign(
        socket,
        :page_title,
        SettingsComponents.page_title(socket.assigns.current_scope, :organisation, [
          form_title(socket.assigns)
        ])
      )

  defp titled(socket),
    do:
      assign(
        socket,
        :page_title,
        SettingsComponents.page_title(socket.assigns.current_scope, :organisation, [
          gettext("Variables"),
          SecretsAndVariables.title()
        ])
      )

  defp open(socket, :index, _params), do: socket

  defp open(socket, :new, _params) do
    if socket.assigns.may_edit,
      do:
        assign(socket,
          act: :new,
          form: variable_form(fresh(OrganisationVariables.change(%Variable{})))
        ),
      else: refused(socket)
  end

  defp open(socket, :change, %{"id" => id}) do
    with_variable(socket, id, fn socket, variable ->
      assign(socket,
        act: :change,
        variable: variable,
        form: variable_form(fresh(OrganisationVariables.change(variable)))
      )
    end)
  end

  defp open(socket, action, %{"id" => id}) when action in [:lock, :unlock] do
    with_variable(socket, id, fn socket, variable ->
      # Locked or unlocked already: the list says so, and there is nothing to confirm.
      if variable.locked == (action == :lock),
        do: push_patch(socket, to: list_path(socket.assigns.current_scope, socket.assigns.query)),
        else: assign(socket, act: action, variable: variable)
    end)
  end

  defp open(socket, :delete, %{"id" => id}) do
    with_variable(socket, id, fn socket, variable ->
      assign(socket, act: :delete, variable: variable)
    end)
  end

  # The organisation's variable of the path, for one who may change it.
  defp with_variable(socket, id, fun) do
    if socket.assigns.may_edit do
      case OrganisationVariables.get(socket.assigns.current_scope, id) do
        {:ok, variable} -> fun.(socket, variable)
        {:error, :forbidden} -> unauthorized(socket)
        {:error, _gone} -> back(socket, :error, gone(socket.assigns.current_scope))
      end
    else
      refused(socket)
    end
  end

  ## Events

  @impl true
  # The search is the URL's `q`, sent as the reader types.
  def handle_event("find", %{"q" => q}, socket) do
    query = %{socket.assigns.query | q: String.trim(q)}

    {:noreply,
     push_patch(socket, to: list_path(socket.assigns.current_scope, query), replace: true)}
  end

  def handle_event("validate_variable", %{"variable" => params}, socket) when is_map(params) do
    changeset =
      %Variable{}
      |> OrganisationVariables.change(params)
      |> Map.put(:action, :validate)

    # Only what was typed in shows its error, as the reader goes (`used_input?/1`).
    {:noreply, assign(socket, :form, to_form(changeset, as: "variable"))}
  end

  def handle_event("create_variable", %{"variable" => params}, %{assigns: %{act: :new}} = socket)
      when is_map(params) do
    scope = socket.assigns.current_scope

    case OrganisationVariables.create(scope, Map.take(params, ~w(name value locked))) do
      {:ok, variable} ->
        {:noreply, saved(socket, gettext("%{name} is saved.", name: variable.name))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, variable_form(changeset))}

      # Not found: no variable is gone, the organisation's variables are out of reach (the
      # feature turned off, the organisation marked for deletion).
      {:error, :not_found} ->
        {:noreply, refusal(socket, :not_found, unsaved(scope))}

      {:error, reason} ->
        {:noreply, refusal(socket, reason)}
    end
  end

  def handle_event(
        "change_variable",
        %{"variable" => params},
        %{assigns: %{act: :change}} = socket
      )
      when is_map(params) do
    %{current_scope: scope, variable: variable} = socket.assigns

    case OrganisationVariables.update(scope, variable, %{"value" => params["value"]}) do
      {:ok, variable} ->
        {:noreply, saved(socket, gettext("%{name} is changed.", name: variable.name))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, variable_form(changeset))}

      {:error, reason} ->
        {:noreply, refusal(socket, reason)}
    end
  end

  # The confirmation on a row acts on the variable its path named; the back end asks
  # again whether the reader still may.
  def handle_event(event, _params, %{assigns: %{act: act, variable: %Variable{}}} = socket)
      when {event, act} in [
             {"lock_variable", :lock},
             {"unlock_variable", :unlock},
             {"delete_variable", :delete}
           ] do
    %{current_scope: scope, variable: variable} = socket.assigns

    result =
      case act do
        :lock -> OrganisationVariables.lock(scope, variable)
        :unlock -> OrganisationVariables.unlock(scope, variable)
        :delete -> OrganisationVariables.delete(scope, variable)
      end

    case result do
      {:ok, done} ->
        shown = Query.variables(socket.assigns.variables, %{}, socket.assigns.query)
        socket = saved(socket, done(act, done.name))

        {:noreply, focus(socket, focus_after(act, variable, shown, socket.assigns))}

      # Refused on what the change would do below: the confirmation stays open, says why
      # under its question, and keeps the focus on its button; the list read again.
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> reload()
         |> assign(:refusal, reasons(variable, changeset))
         |> focus("variable-#{variable.id}-confirm-act")}

      {:error, reason} ->
        {:noreply, refusal(socket, reason)}
    end
  end

  # Cancel, or Escape, of a confirmation: back to the list, the focus on the row's menu
  # button, where the confirmation was opened from.
  def handle_event("cancel_confirm", _params, socket) do
    socket =
      case socket.assigns do
        %{act: act, variable: %Variable{id: id}} when act in @confirms ->
          focus(socket, "variable-#{id}-menu-button")

        _none ->
          socket
      end

    {:noreply,
     push_patch(socket, to: list_path(socket.assigns.current_scope, socket.assigns.query))}
  end

  # A change without its page or its confirmation open: a second click of a button whose
  # confirmation has gone, or an event the page offers no control for. One who may change
  # the variables is shown the list again; one who may not is refused, as a path the page
  # offers no button for is.
  def handle_event(event, _params, socket)
      when event in ~w(create_variable change_variable lock_variable unlock_variable delete_variable) do
    if socket.assigns.may_edit,
      do: {:noreply, reload(socket)},
      else: {:noreply, refused(socket)}
  end

  @impl true
  def handle_info(:switched, socket), do: {:noreply, assign(socket, :switched, true)}

  # Another person's change, or this page's: the list read again.
  def handle_info({:organisation_variables_changed, _change}, socket),
    do: {:noreply, reload(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  # Where the focus goes after a confirmation acted, among the rows shown before it: the
  # row's menu button, or, the row deleted, the next row's, else the one before, else New
  # variable, the list empty. A row a lock or an unlock takes out of the filter in force
  # gives it to New variable too.
  defp focus_after(:delete, %Variable{id: id}, shown, _assigns) do
    {before, rest} = Enum.split_while(shown, &(&1.id != id))

    case {List.last(before), Enum.drop(rest, 1)} do
      {_before, [next | _rest]} -> "variable-#{next.id}-menu-button"
      {%Variable{} = previous, []} -> "variable-#{previous.id}-menu-button"
      {nil, []} -> "new-variable"
    end
  end

  defp focus_after(_act, %Variable{id: id}, _shown, assigns) do
    if Enum.any?(Query.variables(assigns.variables, %{}, assigns.query), &(&1.id == id)),
      do: "variable-#{id}-menu-button",
      else: "new-variable"
  end

  defp done(:lock, name), do: gettext("%{name} is locked.", name: name)
  defp done(:unlock, name), do: gettext("%{name} is unlocked.", name: name)
  defp done(:delete, name), do: gettext("%{name} is deleted.", name: name)

  # The back end's reasons, said beside the variable they refuse a change of: each names
  # the act it refused (`cannot be unlocked while…`) or what the change would do
  # (`would raise…`), but one, about the variable's name, which reads under its field
  # and is given the variable as its subject here.
  defp reasons(variable, changeset),
    do: Enum.map_join(changeset.errors, " ", &reason(variable, &1))

  defp reason(variable, {_field, {"is %{name} in %{workspace}: use the same spelling", keys}}),
    do:
      gettext("%{name} is spelled %{other} in %{workspace}: use the same spelling",
        name: variable.name,
        other: keys[:name],
        workspace: keys[:workspace]
      )

  defp reason(_variable, {_field, error}), do: translate_error(error)

  ## After a change, and its refusals

  # The element the focus goes to once the server's answer is drawn (`focus_back/1`).
  defp focus(socket, id), do: assign(socket, :focus, {id, System.unique_integer([:positive])})

  # Saved: the list read again, back on it, the page or the confirmation gone.
  defp saved(socket, words), do: back(socket, :info, words)

  defp refusal(socket, :forbidden), do: unauthorized(socket)

  defp refusal(socket, :not_found),
    do: refusal(socket, :not_found, gone(socket.assigns.current_scope))

  defp refusal(socket, :not_found, words) do
    socket = reload_scope(socket)

    if socket.redirected,
      do: socket,
      else: back(socket, :error, words)
  end

  # A variable the path or the event names that the organisation does not have: deleted
  # meanwhile, or never one of the organisation's (another organisation's id).
  defp gone(scope),
    do: gettext("That variable is not in %{organisation}.", organisation: scope.organisation.name)

  defp unsaved(scope),
    do:
      gettext("The variable is not saved: %{organisation}'s variables cannot be changed now.",
        organisation: scope.organisation.name
      )

  # Back to the list, with a word, the list read again.
  defp back(socket, kind, words) do
    socket
    |> put_flash(kind, words)
    |> reload()
    |> then(fn socket ->
      if socket.redirected,
        do: socket,
        else:
          push_patch(socket,
            to: list_path(socket.assigns.current_scope, socket.assigns.query)
          )
    end)
  end

  # A path or an event for a change the reader may not make, which the page offers no
  # control for: a reader is told they read the organisation, a suspended organisation's
  # people that it is suspended, anyone else who changes the variables.
  defp refused(socket) do
    scope = socket.assigns.current_scope

    words =
      cond do
        Access.reader(scope) ->
          ApiaryWeb.Access.reads_only(scope)

        socket.assigns.suspended ->
          gettext("%{name} is suspended.", name: scope.organisation.name)

        true ->
          gettext("Only owners and admins of %{organisation} change its variables.",
            organisation: scope.organisation.name
          )
      end

    back(socket, :error, words)
  end

  # Refused on the membership as it is now: the page's scope is stale, and is read again,
  # with what the reader may. A membership that is gone sends the page to `/`.
  defp unauthorized(socket) do
    socket = reload_scope(socket)

    if socket.redirected,
      do: socket,
      else: socket |> mays() |> refused()
  end

  # The scope read again (`ApiaryWeb.UserAuth.reload_scope/1`). A membership that is gone
  # sends the page to `/`, and says why when the reload did not.
  defp reload_scope(socket) do
    socket = UserAuth.reload_scope(socket)

    if socket.redirected && !Phoenix.Flash.get(socket.assigns.flash, :error),
      do:
        put_flash(
          socket,
          :error,
          gettext("You are no longer a member of %{organisation}.",
            organisation: socket.assigns.current_scope.organisation.name
          )
        ),
      else: socket
  end

  ## Forms

  defp variable_form(%Ecto.Changeset{} = changeset), do: to_form(used(changeset), as: "variable")

  # A form as its page opens: nothing is typed yet, so nothing is wrong yet.
  defp fresh(%Ecto.Changeset{} = changeset), do: %{changeset | errors: [], valid?: true}

  # A field with an error is a used one, so the error shows under it, however the
  # changeset came to have it: the back end's check adds an error to a changeset that may
  # have no params for the field, nor an action.
  defp used(%Ecto.Changeset{errors: []} = changeset),
    do: %{changeset | params: changeset.params || %{}}

  defp used(%Ecto.Changeset{} = changeset) do
    params =
      Enum.reduce(changeset.errors, changeset.params || %{}, fn {field, _error}, params ->
        Map.put_new(params, to_string(field), "")
      end)

    %{changeset | params: params, action: changeset.action || :validate}
  end
end
