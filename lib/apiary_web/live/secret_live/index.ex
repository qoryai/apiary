defmodule ApiaryWeb.SecretLive.Index do
  @moduledoc """
  The workspace's Secrets and variables, a section of its settings
  (`ApiaryWeb.SettingsComponents`, the frame's second column) with the `secrets` feature:
  two tabs under the section's title (`ApiaryWeb.PageComponents.page_tabs/1`, links, each
  with its count), Secrets (`/:org/:workspace/settings/secrets`) and Variables
  (`…/settings/variables`). Each tab's panel holds its New and its list on the list pattern
  (a search, a Filter menu, Sort, the filters in force as tokens, all in the URL;
  `ApiaryWeb.SecretLive.Query`); one status line says a switch and what a search left.
  The second column marks the section as the page on Secrets, and as its parent
  (`aria-current="true"`) on Variables and on every page of a form, which shows no tabs.
  Nothing opens over the page: each act is at a path of its own, a form a page of its own
  (`ApiaryWeb.PageComponents.page_form/1`: its title, one sentence, the form, its button
  and Cancel back to the tab, the breadcrumb ending with the section and the page), and
  so is the list of a variable's targets; a deletion asks to confirm in place, on its row
  (`CoreComponents.inline_confirm/1`). Lock and Unlock act at once from the row's menu;
  their paths, which must not act as they open, ask on the row first. A confirmation the
  context refuses stays open and says why under its question.

  A run receives its security policy alone. Each tab, and each of its pages, says so
  once, near its top (`ApiaryWeb.PageComponents.not_on_runs/1`), and no line of the
  section says a run is given what it holds.

  - **Secrets** (`Apiary.Secrets`): a secret's name and note, its value ids, who changed
    each value and when, and what uses it; never a value. New secret, with one value or
    several, each with its value ID, saved at once (its rows added in the browser alone,
    by the `SecretValues` hook), then Edit name and note, Add value, Change value, Rename
    value and Delete value, and Delete secret. A value is written into a field and sent
    once: the page never renders it, nor keeps it in an assign, so the field is empty
    after a save and after a refused one, and the form the context hands back holds none
    (`Apiary.Secrets.change_secret/2`).
  - **Variables** (`Apiary.Variables`): the workspace's own, each with its value, which
    is plain configuration, its lock, and the targets that set their own value or whose
    value a lock sets aside, from their resolution
    (`Apiary.Variables.repository_overrides/1`). New variable, Change value, Lock and
    Unlock, Delete variable, and the targets of a variable. A name beginning
    `QORY_` is refused by the context; any other name on the runner's deny list is
    saved, and the page warns (`Apiary.Variables.Denied`).

  Every member reads both views; owners and admins change them (`secret.write`,
  `variable.edit`), and a reader who may not sees the page without its controls, and
  one line that says who changes it. What each may is asked of `Apiary.Access`, and the
  context functions ask again.
  """
  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :secrets
  on_mount {ApiaryWeb.Access, :"secret.read"}

  alias Apiary.{Access, Organisations, Secrets, Variables}
  alias Apiary.Secrets.{Secret, Value}
  alias Apiary.Variables.{Denied, Variable}
  alias ApiaryWeb.{People, SettingsComponents, UserAuth}
  alias ApiaryWeb.SecretLive.Query

  # The acts of each view, each at a path of its own.
  @secret_acts [
    :new_secret,
    :edit_secret,
    :add_value,
    :change_value,
    :rename_value,
    :delete_value,
    :delete_secret
  ]

  # The acts that are a page of the section: the forms, and the targets of a variable;
  # the rest are confirmations in place, on the row they act on.
  @pages [
    :new_secret,
    :edit_secret,
    :add_value,
    :change_value,
    :rename_value,
    :new_variable,
    :change_variable,
    :variable_targets
  ]

  # Past this many repositories, a variable's list of them has a search.
  @find_from 10

  @impl true
  # A form is a page of its own (`ApiaryWeb.PageComponents.page_form/1`): the section's
  # list beside it as the frame's second column, the breadcrumb ending with the section and
  # the page, its title, one sentence, the line that a run receives only its security
  # policy, the form, its button and Cancel back to the tab.
  def render(%{act: act} = assigns) when act in @pages do
    assigns = assign(assigns, :sentence, form_sentence(assigns))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:settings}
      sections={@sections}
      section={:secrets}
      section_path={list_path(@current_scope, @view, @query)}
      section_current="true"
    >
      <:crumb>{crumb_words(@act)}</:crumb>

      <.page_form
        id={if @view == :secrets, do: "secret-page", else: "variable-page"}
        title={form_title(assigns)}
        cancel={list_path(@current_scope, @view, @query)}
        cancel_by="patch"
      >
        <:description :if={@sentence}>{@sentence}</:description>
        <.not_on_runs>{not_on_runs_words(@view)}</.not_on_runs>
        <.form_page {assigns} />
      </.page_form>
    </Layouts.app>
    """
  end

  # The section: its title and sentence, then its two tabs, Secrets and Variables, each a
  # link with an address of its own (`page_tabs/1`, not an ARIA tablist) that wraps and
  # does not stick. Under them the panel of the tab: the line that a run receives only its
  # security policy, who changes them, its New beside its search, Filter and Sort, and its
  # list.
  # One status line, there from the start and outside both tabs' parts, says a switch
  # ("Variables, 7") and what a search left.
  def render(assigns) do
    assigns =
      assign(assigns,
        tokens: Query.tokens(assigns.query),
        shown:
          if(assigns.view == :secrets,
            do: Query.secrets(assigns.secrets, assigns.query),
            else: Query.variables(assigns.variables, assigns.targets, assigns.query)
          ),
        listed: if(assigns.view == :secrets, do: assigns.secrets, else: assigns.variables)
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:settings}
      sections={@sections}
      section={:secrets}
    >
      <.settings_page
        section={:secrets}
        measure="list"
        title={gettext("Secrets and variables")}
      >
        <:subtitle>
          {gettext("A secret is never shown again once it is saved; a variable is plain text.")}
        </:subtitle>

        <.page_tabs
          id="secrets-tabs"
          label={gettext("Secrets and variables")}
          current={@view}
          place="section"
        >
          <:tab
            key={:secrets}
            patch={list_path(@current_scope, :secrets, Query.for_secrets(@query))}
            count={length(@secrets)}
          >
            {gettext("Secrets")}
          </:tab>
          <:tab
            key={:variables}
            patch={list_path(@current_scope, :variables, Query.for_variables(@query))}
            count={length(@variables)}
          >
            {gettext("Variables")}
          </:tab>
        </.page_tabs>

        <div id="secrets-tabs-panel" class="grid gap-5">
          <div class="-mt-2 grid gap-1">
            <.not_on_runs>{not_on_runs_words(@view)}</.not_on_runs>
            <p
              :if={(@view == :secrets && !@may_write) || (@view == :variables && !@may_edit)}
              id="secrets-read-only"
              class="text-[13px]/5 text-muted"
            >
              {gettext("Only owners and admins change this.")}
            </p>
          </div>

          <.secrets_bar :if={@view == :secrets} {assigns} />
          <.variables_bar :if={@view == :variables} {assigns} />

          <%!-- Always there, so a screen reader hears the tab it switched to and what the
               search left. Out of sight unless a search narrowed the list. --%>
          <div
            id="secrets-and-variables-status"
            role="status"
            class={["q-status", !(Query.narrowed?(@query) && @listed != []) && "sr-only"]}
          >
            <span :if={@switched} class="sr-only">{switch_words(@view, length(@listed))}</span>
            <p :if={Query.narrowed?(@query) && @listed != []} class="text-[13px] text-muted">
              {match_words(@view, length(@shown))}
            </p>
          </div>

          <.secrets_list :if={@view == :secrets} {assigns} />
          <.variables_list :if={@view == :variables} {assigns} />
        </div>
      </.settings_page>
    </Layouts.app>
    """
  end

  # What the status line says after a switch: the tab, and how many it holds.
  defp switch_words(:secrets, number),
    do: gettext("Secrets, %{number}", number: Format.number(number))

  defp switch_words(:variables, number),
    do: gettext("Variables, %{number}", number: Format.number(number))

  # What it says while a search or a filter narrows the list.
  defp match_words(:secrets, number),
    do:
      ngettext("%{number} secret matches", "%{number} secrets match", number,
        number: Format.number(number)
      )

  defp match_words(:variables, number),
    do:
      ngettext("%{number} variable matches", "%{number} variables match", number,
        number: Format.number(number)
      )

  # The one line each tab, and each of its pages, says of what it holds: a run receives
  # its security policy alone (`/v1`).
  defp not_on_runs_words(_view), do: gettext("A run receives only its security policy.")

  ## The secrets

  # The tab's New, beside its search, Filter and Sort while it holds any, and the filters
  # in force.
  defp secrets_bar(assigns) do
    ~H"""
    <div :if={@may_write || @secrets != []} class="q-bar">
      <.button
        :if={@may_write}
        id="new-secret"
        variant="primary"
        patch={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/settings/secrets/new"}
      >
        <.icon name="hero-plus-micro" class="size-4" /> {gettext("New secret")}
      </.button>
      <.list_search
        :if={@secrets != []}
        id="secrets-search"
        value={@query.q}
        label={gettext("Find a secret")}
        placeholder={gettext("Find a secret by name or value ID")}
        change="find"
      />
      <.filter_menu :if={@secrets != []} id="secrets-filter" count={length(@tokens)}>
        <.menu_heading title={gettext("Values")} />
        <.menu_item
          :for={{values, words} <- [one: gettext("One value"), several: gettext("Several values")]}
          id={"secrets-filter-values-#{values}"}
          patch={list_path(@current_scope, :secrets, Query.toggle(@query, {:values, values}))}
          checked={@query.values == values}
        >
          {words}
        </.menu_item>
      </.filter_menu>
      <.sort_menu :if={@secrets != []} id="secrets-sort" current={sort_words(@query.sort)}>
        <.menu_item
          :for={sort <- [:name, :changed]}
          id={"secrets-sort-#{sort}"}
          patch={list_path(@current_scope, :secrets, %{@query | sort: sort})}
          checked={@query.sort == sort}
        >
          {sort_words(sort)}
        </.menu_item>
      </.sort_menu>
    </div>

    <.filter_tokens
      id="secrets-tokens"
      clear={list_path(@current_scope, :secrets, Query.clear(@query))}
    >
      <:token
        :for={token <- @tokens}
        id={"secrets-token-#{elem(token, 0)}"}
        patch={list_path(@current_scope, :secrets, Query.toggle(@query, token))}
        label={gettext("Remove the filter %{filter}", filter: token_words(token))}
      >
        {token_words(token)}
      </:token>
    </.filter_tokens>
    """
  end

  defp secrets_list(assigns) do
    ~H"""
    <div :if={@secrets == []} id="secrets-empty">
      <.empty_state
        icon="hero-lock-closed"
        tone="neutral"
        title={gettext("No secrets yet")}
      >
        {secret_sentence()}
        <:actions :if={@may_write}>
          <.button patch={
            ~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/settings/secrets/new"
          }>
            {gettext("New secret")}
          </.button>
        </:actions>
      </.empty_state>
    </div>

    <.empty_state
      :if={@secrets != [] && @shown == []}
      icon={nil}
      tone="neutral"
      title={gettext("No secret matches")}
    >
      <:actions>
        <.button patch={list_path(@current_scope, :secrets, Query.clear(@query))}>
          {gettext("Clear the search")}
        </.button>
      </:actions>
    </.empty_state>

    <.table
      :if={@shown != []}
      id="secrets"
      label={gettext("Secrets")}
      rows={secret_rows(@shown)}
      row_id={&row_id/1}
      confirming={secret_confirming(@act, @secret, @value)}
    >
      <:col :let={row} label={gettext("Name")} kind="title">
        <%= case row do %>
          <% {:secret, secret} -> %>
            <span class="q-nm">
              <span class="q-title font-mono">{secret.name}</span>
              <span :if={secret.note} class="q-side" title={secret.note}>{secret.note}</span>
            </span>
          <% {:value, _secret, value} -> %>
            <span class="flex items-center gap-1.5 pl-4 text-[12.5px] font-normal text-muted">
              <.icon name="hero-arrow-turn-down-right-micro" class="size-3.5 text-faint" />
              <span class="font-mono" id={"#{row_id(row)}-value-id"}>{value.value_id}</span>
            </span>
        <% end %>
      </:col>
      <:col :let={row} label={gettext("Values")}>
        <%= case row do %>
          <% {:secret, %{values: [%{value_id: nil}]}} -> %>
            {gettext("One value")}
          <% {:secret, secret} -> %>
            {ngettext("%{number} value", "%{number} values", length(secret.values),
              number: Format.number(length(secret.values))
            )}
          <% {:value, _secret, _value} -> %>
        <% end %>
      </:col>
      <:col :let={row} label={gettext("Changed")} from="sm">
        <.changed changed={changed_of(row)} people={@people} />
      </:col>
      <:col :let={row} label={gettext("Used by")} from="sm">
        <%= case row do %>
          <% {:secret, secret} -> %>
            <span :if={Map.get(@uses, secret.id, []) == []} class="q-faint">
              {gettext("Not used")}
            </span>
            <span :if={Map.get(@uses, secret.id, []) != []}>
              {@uses |> Map.get(secret.id) |> Enum.map(& &1.name) |> Enum.uniq() |> Enum.join(", ")}
            </span>
          <% {:value, _secret, _value} -> %>
        <% end %>
      </:col>
      <:action :let={row}>
        <.secret_menu :if={@may_write} row={row} scope={@current_scope} />
      </:action>
      <:confirm :let={row}>
        <.secret_confirm
          row={row}
          refusal={@refusal}
          cancel={list_path(@current_scope, :secrets, @query)}
        />
      </:confirm>
    </.table>
    """
  end

  # A secret is one row; a secret with several values, or one value with a value id, has
  # a line under it for each value, with the value's own acts.
  defp secret_rows(secrets) do
    Enum.flat_map(secrets, fn
      %Secret{values: [%Value{value_id: nil}]} = secret -> [{:secret, secret}]
      %Secret{} = secret -> [{:secret, secret} | Enum.map(secret.values, &{:value, secret, &1})]
    end)
  end

  defp row_id({:secret, secret}), do: "secret-#{secret.public_id}"
  defp row_id({:value, secret, value}), do: "secret-#{secret.public_id}-#{value.value_id}"

  # Who changed what the row shows last, and when: a value's own change, or for a secret
  # of one value that value's, else the secret's.
  defp changed_of({:value, _secret, value}), do: %{at: value.updated_at, by: value.updated_by_id}

  defp changed_of({:secret, %Secret{values: [%Value{value_id: nil} = value]}}),
    do: %{at: value.updated_at, by: value.updated_by_id}

  defp changed_of({:secret, secret}), do: %{at: secret.updated_at, by: secret.updated_by_id}

  attr :changed, :map, required: true, doc: "when, and by whose user id"
  attr :people, :map, required: true

  defp changed(assigns) do
    assigns =
      assign(assigns,
        at: assigns.changed.at,
        by: People.short(People.member(assigns.people, assigns.changed.by))
      )

    ~H"""
    <span class="tabular-nums">
      <%= if @by do %>
        <.rich text={rich_gettext("%{time} by %{person}", time: {:part, :time}, person: @by)}>
          <:part name={:time}><.time_ago at={@at} /></:part>
        </.rich>
      <% else %>
        <.time_ago at={@at} />
      <% end %>
    </span>
    """
  end

  attr :row, :any, required: true
  attr :scope, :any, required: true

  defp secret_menu(%{row: {:secret, secret}} = assigns) do
    assigns = assign(assigns, secret: secret, one: match?([%Value{value_id: nil}], secret.values))

    ~H"""
    <.row_menu
      id={"secret-#{@secret.public_id}-menu"}
      label={gettext("Actions for %{name}", name: @secret.name)}
    >
      <.menu_item
        :if={@one}
        id={"secret-#{@secret.public_id}-change"}
        patch={secret_path(@scope, @secret, :change_value)}
        aria-label={gettext("Change value of %{name}", name: @secret.name)}
      >
        {gettext("Change value…")}
      </.menu_item>
      <.menu_item
        id={"secret-#{@secret.public_id}-add"}
        patch={secret_path(@scope, @secret, :add_value)}
        aria-label={gettext("Add value to %{name}", name: @secret.name)}
      >
        {gettext("Add value…")}
      </.menu_item>
      <.menu_item
        id={"secret-#{@secret.public_id}-edit"}
        patch={secret_path(@scope, @secret, :edit)}
        aria-label={gettext("Edit name and note of %{name}", name: @secret.name)}
      >
        {gettext("Edit name and note…")}
      </.menu_item>
      <.menu_divider />
      <.menu_item
        id={"secret-#{@secret.public_id}-delete"}
        patch={secret_path(@scope, @secret, :delete)}
        aria-label={gettext("Delete secret %{name}", name: @secret.name)}
      >
        {gettext("Delete secret…")}
      </.menu_item>
    </.row_menu>
    """
  end

  defp secret_menu(%{row: {:value, secret, value}} = assigns) do
    assigns = assign(assigns, secret: secret, value: value, id: row_id(assigns.row))

    ~H"""
    <.row_menu
      id={"#{@id}-menu"}
      label={
        gettext("Actions for %{value_id} of %{name}", value_id: @value.value_id, name: @secret.name)
      }
    >
      <.menu_item
        id={"#{@id}-change"}
        patch={value_path(@scope, @secret, @value, :change)}
        aria-label={
          gettext("Change value %{value_id} of %{name}",
            value_id: @value.value_id,
            name: @secret.name
          )
        }
      >
        {gettext("Change value…")}
      </.menu_item>
      <.menu_item
        id={"#{@id}-rename"}
        patch={value_path(@scope, @secret, @value, :rename)}
        aria-label={
          gettext("Rename value %{value_id} of %{name}",
            value_id: @value.value_id,
            name: @secret.name
          )
        }
      >
        {gettext("Rename value…")}
      </.menu_item>
      <.menu_divider :if={length(@secret.values) > 1} />
      <.menu_item
        :if={length(@secret.values) > 1}
        id={"#{@id}-delete"}
        patch={value_path(@scope, @secret, @value, :delete)}
        aria-label={
          gettext("Delete value %{value_id} of %{name}",
            value_id: @value.value_id,
            name: @secret.name
          )
        }
      >
        {gettext("Delete value…")}
      </.menu_item>
    </.row_menu>
    """
  end

  ## The variables

  # The tab's New, beside its search, Filter and Sort while it holds any, and the filters
  # in force.
  defp variables_bar(assigns) do
    ~H"""
    <div :if={@may_edit || @variables != []} class="q-bar">
      <.button
        :if={@may_edit}
        id="new-variable"
        variant="primary"
        patch={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/settings/variables/new"}
      >
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
          patch={list_path(@current_scope, :variables, Query.toggle(@query, {:lock, lock}))}
          checked={@query.lock == lock}
        >
          {words}
        </.menu_item>
        <.menu_heading title={gettext("Targets")} />
        <.menu_item
          id="variables-filter-targets-own"
          patch={list_path(@current_scope, :variables, Query.toggle(@query, {:targets, :own}))}
          checked={@query.targets == :own}
          multiple
        >
          {gettext("Set by a target too")}
        </.menu_item>
      </.filter_menu>
      <.sort_menu :if={@variables != []} id="variables-sort" current={sort_words(@query.sort)}>
        <.menu_item
          :for={sort <- [:name, :changed]}
          id={"variables-sort-#{sort}"}
          patch={list_path(@current_scope, :variables, %{@query | sort: sort})}
          checked={@query.sort == sort}
        >
          {sort_words(sort)}
        </.menu_item>
      </.sort_menu>
    </div>

    <.filter_tokens
      id="variables-tokens"
      clear={list_path(@current_scope, :variables, Query.clear(@query))}
    >
      <:token
        :for={token <- @tokens}
        id={"variables-token-#{elem(token, 0)}"}
        patch={list_path(@current_scope, :variables, Query.toggle(@query, token))}
        label={gettext("Remove the filter %{filter}", filter: token_words(token))}
      >
        {token_words(token)}
      </:token>
    </.filter_tokens>
    """
  end

  defp variables_list(assigns) do
    ~H"""
    <div :if={@variables == []} id="variables-empty">
      <.empty_state
        icon="hero-variable"
        tone="neutral"
        title={gettext("No variables yet")}
      >
        {variable_sentence()}
        <:actions :if={@may_edit}>
          <.button patch={
            ~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/settings/variables/new"
          }>
            {gettext("New variable")}
          </.button>
        </:actions>
      </.empty_state>
    </div>

    <.empty_state
      :if={@variables != [] && @shown == []}
      icon={nil}
      tone="neutral"
      title={gettext("No variable matches")}
    >
      <:actions>
        <.button patch={list_path(@current_scope, :variables, Query.clear(@query))}>
          {gettext("Clear the search")}
        </.button>
      </:actions>
    </.empty_state>

    <.table
      :if={@shown != []}
      id="variables"
      label={gettext("Variables")}
      rows={@shown}
      row_id={&"variable-#{&1.id}"}
      confirming={variable_confirming(@act, @variable)}
    >
      <:col :let={variable} label={gettext("Name")} kind="title">
        <span class="q-nm">
          <span class="q-title font-mono">{variable.name}</span>
          <.state_word
            :if={warned?(variable.name)}
            id={"variable-#{variable.id}-denied"}
            hot
          >
            {gettext("On the runner's deny list")}
          </.state_word>
        </span>
      </:col>
      <:col :let={variable} label={gettext("Value")}>
        <span
          id={"variable-#{variable.id}-value"}
          class="block max-w-[28ch] truncate font-mono text-[12.5px]"
          title={variable.value}
        >
          {variable.value}
        </span>
      </:col>
      <:col :let={variable} label={gettext("Lock")}>
        <.lock_of
          id={"variable-#{variable.id}-lock"}
          variable={variable}
          entry={Variables.Resolution.entry(@resolution, variable.name)}
        />
      </:col>
      <:col :let={variable} label={gettext("Targets")} from="sm">
        <.targets_of
          id={"variable-#{variable.id}-targets"}
          variable={variable}
          targets={Map.get(@targets, String.downcase(variable.name), [])}
          path={variable_path(@current_scope, variable, :targets)}
        />
      </:col>
      <:col :let={variable} label={gettext("Changed")} from="md">
        <.changed
          changed={%{at: variable.updated_at, by: variable.updated_by_id}}
          people={@people}
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
          <%!-- A lock is undone by an unlock: each acts at once, and the flash says what
               it did to the targets. --%>
          <.menu_item
            :if={!variable.locked}
            id={"variable-#{variable.id}-lock-item"}
            phx-click="lock_variable"
            phx-value-id={variable.id}
            aria-label={gettext("Lock %{name}", name: variable.name)}
          >
            {gettext("Lock")}
          </.menu_item>
          <.menu_item
            :if={variable.locked}
            id={"variable-#{variable.id}-unlock-item"}
            phx-click="unlock_variable"
            phx-value-id={variable.id}
            aria-label={gettext("Unlock %{name}", name: variable.name)}
          >
            {gettext("Unlock")}
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
        <.variable_confirm
          act={@act}
          variable={variable}
          refusal={@refusal}
          targets={Map.get(@targets, String.downcase(variable.name), [])}
          cancel={list_path(@current_scope, :variables, @query)}
        />
      </:confirm>
    </.table>
    """
  end

  attr :id, :string, required: true
  attr :variable, Variable, required: true
  attr :entry, :map, default: nil

  # Said only when it is not the usual: the workspace's own lock, or a lock above the
  # workspace that sets the workspace's value aside.
  defp lock_of(assigns) do
    ~H"""
    <%= cond do %>
      <% @entry && :workspace in @entry.ignored -> %>
        <.state_word id={@id} hot>{gettext("Set aside: locked above the workspace")}</.state_word>
      <% @variable.locked -> %>
        <span id={@id} class="inline-flex items-center gap-1">
          <.icon name="hero-lock-closed-micro" class="size-3.5 text-faint" />{gettext("Locked")}
        </span>
      <% true -> %>
        <span id={@id} class="sr-only">{gettext("Not locked")}</span>
    <% end %>
    """
  end

  attr :id, :string, required: true
  attr :variable, Variable, required: true
  attr :targets, :list, required: true
  attr :path, :string, required: true

  defp targets_of(assigns) do
    assigns =
      assign(assigns,
        own: Enum.count(assigns.targets, &(&1.state == :own)),
        ignored: Enum.count(assigns.targets, &(&1.state == :ignored))
      )

    ~H"""
    <span :if={@targets == []} id={@id} class="q-faint">{gettext("None of their own")}</span>
    <.link :if={@targets != []} id={@id} patch={@path} class="hover:underline">
      <span :if={@own > 0}>
        {ngettext("%{number} target sets its own", "%{number} targets set their own", @own,
          number: Format.number(@own)
        )}
      </span>
      <span :if={@own > 0 && @ignored > 0} aria-hidden="true">·</span>
      <span :if={@ignored > 0}>
        {ngettext(
          "%{number} target set aside by the lock",
          "%{number} targets set aside by the lock",
          @ignored,
          number: Format.number(@ignored)
        )}
      </span>
    </.link>
    """
  end

  ## The pages of a form

  # New secret: its name, then the Values choice, one value or several, each with a value
  # ID. The choice shows the fields of one or of the other, and "Add another value" adds a
  # row, in the browser alone (the `SecretValues` hook, assets/js/hooks/secret_values.js):
  # nothing is sent before Save, and the fields of the choice not taken are not sent then.
  defp form_page(%{act: :new_secret} = assigns) do
    assigns =
      assign(assigns,
        several: assigns.values_kind == "several",
        full: length(assigns.value_rows) >= Secrets.max_values()
      )

    ~H"""
    <.form
      for={@form}
      id="secret-form"
      phx-submit="create_secret"
      phx-hook="SecretValues"
      data-refused-saves={@refused_saves}
      class="grid gap-4"
      novalidate
    >
      <.input
        field={@form[:name]}
        label={gettext("Name")}
        placeholder="FORGE_TOKEN"
        hint={gettext("Letters, digits and _, starting with a letter or _.")}
        autocomplete="off"
        spellcheck="false"
        class="font-mono"
        phx-mounted={JS.focus()}
      />
      <%!-- The choice, as `input/1` draws a radio group, described by the error on the
      values as a whole, which shows under their rows. --%>
      <fieldset
        id="secret_values_kind"
        class="fieldset"
        aria-invalid={@values_errors != [] && "true"}
        aria-describedby={values_error_ids(@values_errors)}
      >
        <legend class="mb-1 text-[13px]/[18px] font-medium">{gettext("Values")}</legend>
        <label
          :for={
            {{words, kind}, index} <-
              Enum.with_index([
                {gettext("One value"), "one"},
                {gettext("Several values, each with a value ID"), "several"}
              ])
          }
          for={"secret_values_kind-#{index}"}
          class="inline-flex w-fit cursor-pointer items-center gap-2 text-[13.5px]/5 max-md:min-h-10"
        >
          <input
            type="radio"
            id={"secret_values_kind-#{index}"}
            name="secret[values_kind]"
            value={kind}
            checked={@values_kind == kind}
            class="radio radio-sm radio-primary"
          />
          {words}
        </label>
      </fieldset>
      <div id="secret-one-value" class="grid gap-4" hidden={@several}>
        <.value_field form={@form} disabled={@several} />
      </div>
      <div
        id="secret-several-values"
        class="grid gap-4"
        hidden={!@several}
        data-max={Secrets.max_values()}
        data-legend={gettext("Value %{number}", number: "__NUMBER__")}
        data-remove={gettext("Remove value %{number}", number: "__NUMBER__")}
      >
        <ol id="secret-values" class="grid gap-4">
          <.value_row :for={row <- @value_rows} {row} disabled={!@several} />
        </ol>
        <template id="secret-value-template">
          <.value_row index="__INDEX__" number="__NUMBER__" removable template />
        </template>
        <p
          :for={{message, id} <- Enum.zip(@values_errors, values_error_id_list(@values_errors))}
          id={id}
          class="flex items-center gap-1.5 text-[12.5px]/[18px] text-error"
        >
          <.icon name="hero-exclamation-circle-micro" class="size-4 flex-none" />{message}
        </p>
        <div class="flex flex-wrap items-center gap-3">
          <.button id="secret-add-value" type="button" data-add-value disabled={@full}>
            <.icon name="hero-plus-micro" class="size-4" />{gettext("Add another value")}
          </.button>
          <p
            id="secret-values-full"
            class="text-[12.5px]/[18px] text-muted"
            hidden={!@full or @values_errors != []}
          >
            {gettext("A secret holds at most %{number} values.",
              number: Format.number(Secrets.max_values())
            )}
          </p>
        </div>
      </div>
      <.input field={@form[:note]} label={gettext("What it is for")} optional autocomplete="off" />
      <.page_form_foot
        id="secret-save"
        cancel={list_path(@current_scope, :secrets, @query)}
        cancel_by="patch"
      >
        <.button variant="primary" type="submit" loading_text={gettext("Saving")}>
          {gettext("Save secret")}
        </.button>
      </.page_form_foot>
    </.form>
    """
  end

  # A secret's name and what it is for: its values stay as they are.
  defp form_page(%{act: :edit_secret} = assigns) do
    ~H"""
    <.form for={@form} id="secret-form" phx-submit="update_secret" class="grid gap-4" novalidate>
      <.input
        field={@form[:name]}
        label={gettext("Name")}
        hint={gettext("Letters, digits and _, starting with a letter or _.")}
        autocomplete="off"
        spellcheck="false"
        class="font-mono"
        phx-mounted={JS.focus()}
      />
      <.input field={@form[:note]} label={gettext("What it is for")} optional autocomplete="off" />
      <.page_form_foot
        id="secret-save"
        cancel={list_path(@current_scope, :secrets, @query)}
        cancel_by="patch"
      >
        <.button variant="primary" type="submit" loading_text={gettext("Saving")}>
          {gettext("Save")}
        </.button>
      </.page_form_foot>
    </.form>
    """
  end

  defp form_page(%{act: :add_value} = assigns) do
    assigns =
      assign(assigns, :unnamed, Enum.any?(assigns.secret.values, &is_nil(&1.value_id)))

    ~H"""
    <.form for={@form} id="secret-form" phx-submit="add_value" class="grid gap-4" novalidate>
      <.input
        :if={@unnamed}
        field={@form[:first_value_id]}
        label={gettext("Value ID of the value it holds now")}
        placeholder="main-app"
        autocomplete="off"
        spellcheck="false"
        class="font-mono"
        phx-mounted={JS.focus()}
      />
      <.input
        field={@form[:value_id]}
        label={gettext("Value ID of the new value")}
        placeholder="bot-app"
        hint={gettext("Lowercase letters, digits, ., _ and -.")}
        autocomplete="off"
        spellcheck="false"
        class="font-mono"
        phx-mounted={!@unnamed && JS.focus()}
      />
      <.value_field form={@form} />
      <.page_form_foot
        id="secret-save"
        cancel={list_path(@current_scope, :secrets, @query)}
        cancel_by="patch"
      >
        <.button variant="primary" type="submit" loading_text={gettext("Saving")}>
          {gettext("Add value")}
        </.button>
      </.page_form_foot>
    </.form>
    """
  end

  defp form_page(%{act: :change_value} = assigns) do
    ~H"""
    <.form for={@form} id="secret-form" phx-submit="set_value" class="grid gap-4" novalidate>
      <.value_field form={@form} label={gettext("New value")} focus />
      <.page_form_foot
        id="secret-save"
        cancel={list_path(@current_scope, :secrets, @query)}
        cancel_by="patch"
      >
        <.button variant="primary" type="submit" loading_text={gettext("Saving")}>
          {gettext("Change value")}
        </.button>
      </.page_form_foot>
    </.form>
    """
  end

  defp form_page(%{act: :rename_value} = assigns) do
    ~H"""
    <.form for={@form} id="secret-form" phx-submit="rename_value" class="grid gap-4" novalidate>
      <.input
        field={@form[:value_id]}
        label={gettext("Value ID")}
        hint={gettext("Lowercase letters, digits, ., _ and -.")}
        autocomplete="off"
        spellcheck="false"
        class="font-mono"
        phx-mounted={JS.focus()}
      />
      <.page_form_foot
        id="secret-save"
        cancel={list_path(@current_scope, :secrets, @query)}
        cancel_by="patch"
      >
        <.button variant="primary" type="submit" loading_text={gettext("Saving")}>
          {gettext("Rename value")}
        </.button>
      </.page_form_foot>
    </.form>
    """
  end

  defp form_page(%{act: :new_variable} = assigns) do
    ~H"""
    <.form
      for={@form}
      id="variable-form"
      phx-change="validate_variable"
      phx-submit="create_variable"
      class="grid gap-4"
      novalidate
    >
      <%!-- The name's hint is drawn here, as the input draws one, so that the deny-list
           warning describes the field too while it shows: the input writes its own
           aria-describedby from a hint it is given, before one passed to it, and a browser
           keeps the first. While the field shows an error, the error describes it, and
           the hint goes, as in the input. --%>
      <div class="grid gap-1.5">
        <.input
          field={@form[:name]}
          label={gettext("Name")}
          placeholder="NPM_REGISTRY"
          aria-describedby={name_described(@form[:name], @warning)}
          autocomplete="off"
          spellcheck="false"
          class="font-mono"
          phx-mounted={JS.focus()}
        />
        <p
          :if={!errors_shown?(@form[:name])}
          id={"#{@form[:name].id}-hint"}
          class="text-[12.5px]/[18px] text-muted"
        >
          {gettext("Letters, digits and _, starting with a letter or _.")}
        </p>
      </div>
      <.notice :if={@warning} kind={:warning}>
        <span id="variable-warning">{@warning}</span>
      </.notice>
      <.input
        field={@form[:value]}
        label={gettext("Value")}
        placeholder="https://registry.example.com"
        hint={gettext("Plain text on one line, shown to every member.")}
        autocomplete="off"
        spellcheck="false"
        class="font-mono"
      />
      <.input
        field={@form[:locked]}
        type="checkbox"
        label={gettext("Locked: a target may not set its own value")}
      />
      <.page_form_foot
        id="variable-save"
        cancel={list_path(@current_scope, :variables, @query)}
        cancel_by="patch"
      >
        <.button variant="primary" type="submit" loading_text={gettext("Saving")}>
          {gettext("Save variable")}
        </.button>
      </.page_form_foot>
    </.form>
    """
  end

  defp form_page(%{act: :change_variable} = assigns) do
    ~H"""
    <.form for={@form} id="variable-form" phx-submit="change_variable" class="grid gap-4" novalidate>
      <.input
        field={@form[:value]}
        label={gettext("Value")}
        hint={gettext("Plain text on one line, shown to every member.")}
        autocomplete="off"
        spellcheck="false"
        class="font-mono"
        phx-mounted={JS.focus()}
      />
      <.page_form_foot
        id="variable-save"
        cancel={list_path(@current_scope, :variables, @query)}
        cancel_by="patch"
      >
        <.button variant="primary" type="submit" loading_text={gettext("Saving")}>
          {gettext("Change value")}
        </.button>
      </.page_form_foot>
    </.form>
    """
  end

  # The targets of a variable: a page of the section too, to read.
  defp form_page(%{act: :variable_targets} = assigns) do
    targets = Map.get(assigns.targets, String.downcase(assigns.variable.name), [])
    q = String.downcase(assigns.target_q)

    assigns =
      assign(assigns,
        all: targets,
        listed:
          Enum.filter(targets, &(q == "" or String.contains?(String.downcase(&1.target.path), q))),
        shared: shared_paths(assigns.targets)
      )

    ~H"""
    <.list_search
      :if={length(@all) > find_from()}
      id="variable-targets-search"
      value={@target_q}
      label={gettext("Find a target")}
      change="find_target"
    />
    <p :if={@all == []} class="text-muted">{gettext("No target sets its own value.")}</p>
    <.table
      :if={@all != []}
      id="variable-targets"
      label={gettext("Targets")}
      rows={@listed}
      row_id={&"variable-target-#{&1.target.id}"}
    >
      <:col :let={%{target: target}} label={gettext("Target")} kind="title">
        <.link
          navigate={
            ApiaryWeb.TargetComponents.target_path(
              @current_scope,
              target.system,
              target.path,
              [],
              @shared
            )
          }
          class="hover:underline"
        >
          <.target_name system={target.system} path={target.path} shared={@shared} />
        </.link>
      </:col>
      <:col :let={%{state: state}} label={gettext("Its value")}>
        {if state == :own,
          do: gettext("Its own value"),
          else: gettext("Its value set aside by the lock")}
      </:col>
    </.table>
    <SettingsComponents.save id="variable-targets-foot">
      <.button patch={list_path(@current_scope, :variables, @query)}>
        {gettext("Back to the variables")}
      </.button>
    </SettingsComponents.save>
    """
  end

  # The page's title, the act and what it acts on.
  defp form_title(%{act: :new_secret}), do: gettext("New secret")

  defp form_title(%{act: :edit_secret, secret: secret}),
    do: gettext("Edit the name and note of %{name}", name: secret.name)

  defp form_title(%{act: :add_value, secret: secret}),
    do: gettext("Add a value to %{name}", name: secret.name)

  defp form_title(%{act: :change_value, secret: secret, value: %Value{value_id: nil}}),
    do: gettext("Change the value of %{name}", name: secret.name)

  defp form_title(%{act: :change_value, secret: secret, value: value}),
    do: gettext("Change %{value_id} of %{name}", value_id: value.value_id, name: secret.name)

  defp form_title(%{act: :rename_value, secret: secret, value: value}),
    do: gettext("Rename %{value_id} of %{name}", value_id: value.value_id, name: secret.name)

  defp form_title(%{act: :new_variable}), do: gettext("New variable")

  defp form_title(%{act: :change_variable, variable: variable}),
    do: gettext("Change the value of %{name}", name: variable.name)

  defp form_title(%{act: :variable_targets, variable: variable}),
    do: gettext("Targets that set %{name}", name: variable.name)

  # The breadcrumb's last segment: the act alone.
  defp crumb_words(:new_secret), do: gettext("New secret")
  defp crumb_words(:edit_secret), do: gettext("Edit name and note")
  defp crumb_words(:add_value), do: gettext("Add value")
  defp crumb_words(:change_value), do: gettext("Change value")
  defp crumb_words(:rename_value), do: gettext("Rename value")
  defp crumb_words(:new_variable), do: gettext("New variable")
  defp crumb_words(:change_variable), do: gettext("Change value")
  defp crumb_words(:variable_targets), do: gettext("Targets")

  # The one sentence under the title: what the page does, where it says more than the
  # title. Nothing here says a run is given what the page holds: none is.
  defp form_sentence(%{act: :new_secret}), do: secret_sentence()

  defp form_sentence(%{act: :edit_secret}),
    do: gettext("Its values stay as they are; only its name and what it is for change.")

  defp form_sentence(%{act: :add_value}),
    do: gettext("A secret with several values names each one with a value ID.")

  defp form_sentence(%{act: :change_value}),
    do: gettext("The value it holds now is not shown.")

  defp form_sentence(%{act: :rename_value}),
    do: gettext("The value stays as it is; only its value ID changes.")

  defp form_sentence(%{act: :new_variable}), do: variable_sentence()

  defp form_sentence(%{act: :change_variable}), do: nil

  defp form_sentence(%{act: :variable_targets, variable: variable}),
    do:
      gettext(
        "The targets that set their own value of %{name}, and those whose own value its lock sets aside.",
        name: variable.name
      )

  # What a secret and a variable are, on the empty view and on the page that makes one.
  defp secret_sentence,
    do:
      gettext(
        "A secret holds one value, such as a token, or several under one name, such as one per app. Once a value is saved, nobody sees it again."
      )

  defp variable_sentence,
    do: gettext("A variable is a named plain value, such as the address of a package registry.")

  ## The confirmations in place

  # The row of the secrets that asks to confirm: a secret's, or one of its values'.
  defp secret_confirming(:delete_secret, %Secret{} = secret, _value),
    do: row_id({:secret, secret})

  defp secret_confirming(:delete_value, %Secret{} = secret, %Value{} = value),
    do: row_id({:value, secret, value})

  defp secret_confirming(_act, _secret, _value), do: nil

  attr :row, :any, required: true
  attr :refusal, :string, default: nil, doc: "why the context refused it, once it did"
  attr :cancel, :string, required: true

  defp secret_confirm(%{row: {:secret, secret}} = assigns) do
    assigns = assign(assigns, :secret, secret)

    ~H"""
    <.inline_confirm
      id={"secret-#{@secret.public_id}-confirm"}
      question={gettext("Delete %{name}?", name: @secret.name)}
      cancel={@cancel}
    >
      {ngettext(
        "The secret and its value are deleted. This cannot be undone.",
        "The secret and its %{number} values are deleted. This cannot be undone.",
        length(@secret.values),
        number: Format.number(length(@secret.values))
      )}
      <.refusal_line id="secret-refused" refusal={@refusal} />
      <:action>
        <.button
          variant="danger"
          size="xs"
          phx-click="delete_secret"
          loading_text={gettext("Deleting")}
        >
          {gettext("Yes, delete")}
        </.button>
      </:action>
    </.inline_confirm>
    """
  end

  defp secret_confirm(%{row: {:value, secret, value}} = assigns) do
    assigns = assign(assigns, secret: secret, value: value, id: row_id(assigns.row))

    ~H"""
    <.inline_confirm
      id={"#{@id}-confirm"}
      question={
        gettext("Delete %{value_id} of %{name}?", value_id: @value.value_id, name: @secret.name)
      }
      cancel={@cancel}
    >
      {gettext("The value is deleted, and the secret keeps its other values. This cannot be undone.")}
      <.refusal_line id="secret-refused" refusal={@refusal} />
      <:action>
        <.button
          variant="danger"
          size="xs"
          phx-click="delete_value"
          loading_text={gettext("Deleting")}
        >
          {gettext("Yes, delete")}
        </.button>
      </:action>
    </.inline_confirm>
    """
  end

  # The row of the variables that asks to confirm.
  defp variable_confirming(act, %Variable{} = variable)
       when act in [:delete_variable, :lock_variable, :unlock_variable],
       do: "variable-#{variable.id}"

  defp variable_confirming(_act, _variable), do: nil

  attr :act, :atom, required: true
  attr :variable, Variable, required: true
  attr :targets, :list, required: true, doc: "the targets that set the variable"
  attr :refusal, :string, default: nil, doc: "why the context refused it, once it did"
  attr :cancel, :string, required: true

  defp variable_confirm(%{act: :delete_variable} = assigns) do
    ~H"""
    <.inline_confirm
      id={"variable-#{@variable.id}-confirm"}
      question={gettext("Delete %{name}?", name: @variable.name)}
      cancel={@cancel}
    >
      {gettext(
        "The workspace's value of %{name} is deleted. A target that sets its own keeps it. This cannot be undone.",
        name: @variable.name
      )}
      <.refusal_line id="variable-refused" refusal={@refusal} />
      <:action>
        <.button
          variant="danger"
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

  # Lock and Unlock act at once from the row's menu; their paths, which must not act as
  # they open, ask first.
  defp variable_confirm(%{act: :lock_variable} = assigns) do
    assigns = assign(assigns, :own, Enum.count(assigns.targets, &(&1.state == :own)))

    ~H"""
    <.inline_confirm
      id={"variable-#{@variable.id}-confirm"}
      question={gettext("Lock %{name}?", name: @variable.name)}
      cancel={@cancel}
    >
      {gettext("While %{name} is locked, a target may not set its own value.",
        name: @variable.name
      )}
      <span :if={@own > 0} id="lock-targets">
        {ngettext(
          "%{number} target sets its own now: the lock sets it aside while it holds.",
          "%{number} targets set their own now: the lock sets them aside while it holds.",
          @own,
          number: Format.number(@own)
        )}
      </span>
      <.refusal_line id="variable-refused" refusal={@refusal} />
      <:action>
        <.button
          variant="primary"
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

  defp variable_confirm(%{act: :unlock_variable} = assigns) do
    assigns = assign(assigns, :ignored, Enum.count(assigns.targets, &(&1.state == :ignored)))

    ~H"""
    <.inline_confirm
      id={"variable-#{@variable.id}-confirm"}
      question={gettext("Unlock %{name}?", name: @variable.name)}
      cancel={@cancel}
    >
      {gettext("A target's own value of %{name} applies again.", name: @variable.name)}
      <span :if={@ignored > 0} id="unlock-targets">
        {ngettext(
          "%{number} target set its own: the lock no longer sets it aside.",
          "%{number} targets set their own: the lock no longer sets them aside.",
          @ignored,
          number: Format.number(@ignored)
        )}
      </span>
      <.refusal_line id="variable-refused" refusal={@refusal} />
      <:action>
        <.button
          variant="primary"
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

  attr :id, :string, required: true
  attr :refusal, :string, default: nil

  # Why the context refused what a confirmation asked, under its question, in the open
  # confirmation: said as it comes, and the focus left on the button that acted.
  defp refusal_line(assigns) do
    ~H"""
    <span
      :if={@refusal}
      id={@id}
      role="alert"
      class="block font-medium text-error-soft-content"
    >
      {@refusal}
    </span>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :label, :string, default: nil
  attr :focus, :boolean, default: false, doc: "whether the field takes the focus as it mounts"
  attr :disabled, :boolean, default: false, doc: "off while its choice is not taken"

  # The value of a secret: written, sent once, and never rendered back. The field's
  # value is always empty, whatever the form holds.
  defp value_field(assigns) do
    ~H"""
    <.input
      field={@form[:value]}
      type="textarea"
      value=""
      label={@label || gettext("Value")}
      rows="4"
      hint={gettext("Stored encrypted. Nobody sees it again once it is saved.")}
      autocomplete="off"
      spellcheck="false"
      class="font-mono"
      phx-mounted={@focus && JS.focus()}
      disabled={@disabled}
    />
    """
  end

  attr :index, :any, required: true, doc: "its index among the values the form sends"
  attr :number, :any, required: true, doc: "its place among the values, from 1"
  attr :value_id, :string, default: ""
  attr :value_id_errors, :list, default: []
  attr :value_errors, :list, default: []
  attr :removable, :boolean, default: false
  attr :template, :boolean, default: false, doc: "the row the hook copies, its fields off"
  attr :disabled, :boolean, default: false, doc: "off while Several values is not chosen"

  # One value of a new secret of several: its value ID and its value, a group named by
  # its place ("Value 3", for whoever hears it), and Remove past the first two. The value
  # is written, sent once and never rendered back, as `value_field/1`'s; its value ID is
  # no secret, and a refused save shows it again.
  defp value_row(assigns) do
    ~H"""
    <li id={"secret-value-#{@index}"} data-value-row data-index={@index}>
      <fieldset class="grid gap-3 sm:grid-cols-[minmax(0,16rem)_minmax(0,1fr)_auto] sm:items-start">
        <legend class="sr-only">{gettext("Value %{number}", number: @number)}</legend>
        <.input
          id={"secret_values_#{@index}_value_id"}
          name={"secret[values][#{@index}][value_id]"}
          value={@value_id}
          label={gettext("Value ID")}
          placeholder={value_id_placeholder(@number)}
          hint={gettext("Lowercase letters, digits, ., _ and -.")}
          errors={@value_id_errors}
          autocomplete="off"
          spellcheck="false"
          class="font-mono"
          disabled={@template or @disabled}
        />
        <.input
          id={"secret_values_#{@index}_value"}
          name={"secret[values][#{@index}][value]"}
          type="textarea"
          value=""
          label={gettext("Value")}
          rows="4"
          errors={@value_errors}
          autocomplete="off"
          spellcheck="false"
          class="font-mono"
          disabled={@template or @disabled}
        />
        <.button
          :if={@removable}
          id={"secret-value-#{@index}-remove"}
          type="button"
          size="xs"
          class="sm:mt-6"
          aria-label={gettext("Remove value %{number}", number: @number)}
          data-remove-value
        >
          {gettext("Remove")}
        </.button>
      </fieldset>
    </li>
    """
  end

  defp value_id_placeholder(1), do: "main-app"
  defp value_id_placeholder(2), do: "bot-app"
  defp value_id_placeholder(_number), do: nil

  # The rows of New secret's values: two to start; after a refused save, the values it
  # sent, each with its value ID and its errors, and never its value.
  defp value_rows(changeset \\ nil)

  defp value_rows(%Ecto.Changeset{changes: %{values: [_ | _] = values}}) do
    values
    |> Enum.with_index()
    |> Enum.map(fn {value, index} ->
      %{
        index: index,
        number: index + 1,
        value_id: text((value.params || %{})["value_id"]),
        value_id_errors: translate_errors(value.errors, :value_id),
        value_errors: translate_errors(value.errors, :value),
        removable: index >= 2
      }
    end)
    |> then(&(&1 ++ blank_rows(length(&1))))
  end

  defp value_rows(_changeset), do: blank_rows(0)

  # A value ID shown again as it was sent, when it was text; anything else a request
  # could carry is not.
  defp text(value) when is_binary(value), do: value
  defp text(_value), do: ""

  # The ids of the errors on the values as a whole, which describe the Values choice.
  defp values_error_id_list(errors) do
    errors
    |> Enum.with_index()
    |> Enum.map(fn
      {_error, 0} -> "secret-values-error"
      {_error, i} -> "secret-values-error-#{i + 1}"
    end)
  end

  defp values_error_ids([]), do: nil
  defp values_error_ids(errors), do: Enum.join(values_error_id_list(errors), " ")

  # Blank rows after `count`, up to two.
  defp blank_rows(count) when count >= 2, do: []

  defp blank_rows(count),
    do: for(index <- count..1//1, do: %{index: index, number: index + 1, removable: false})

  defp find_from, do: @find_from

  # The paths that are on more than one system among the repositories the page names.
  defp shared_paths(targets) do
    targets
    |> Map.values()
    |> List.flatten()
    |> Enum.map(& &1.target)
    |> Enum.uniq_by(& &1.id)
    |> Enum.group_by(& &1.path)
    |> Enum.filter(fn {_path, same} -> length(same) > 1 end)
    |> MapSet.new(&elem(&1, 0))
  end

  ## Words

  defp sort_words(:name), do: gettext("Name")
  defp sort_words(:changed), do: gettext("Recently changed")

  defp token_words({:values, :one}), do: gettext("One value")
  defp token_words({:values, :several}), do: gettext("Several values")
  defp token_words({:lock, :yes}), do: gettext("Locked")
  defp token_words({:lock, :no}), do: gettext("Not locked")
  defp token_words({:targets, :own}), do: gettext("Set by a target too")

  # A name on the runner's deny list, which the context saves: warned. No run receives a
  # variable, so the words say where the name is, and nothing of a run.
  defp warned?(name) when is_binary(name), do: Denied.denied?(name) and not Denied.refused?(name)
  defp warned?(_name), do: false

  defp warning(name) do
    if warned?(name), do: gettext("%{name} is on the runner's deny list.", name: name)
  end

  # What describes New variable's name field: its hint, and the warning while it shows;
  # nothing of ours while the field shows an error, which the input says is what describes
  # it.
  defp name_described(field, warning) do
    unless errors_shown?(field),
      do: Enum.join(["#{field.id}-hint" | List.wrap(warning && "variable-warning")], " ")
  end

  # Whether the input shows the field's errors (`CoreComponents.input/1`): once it is used.
  defp errors_shown?(field), do: field.errors != [] and Phoenix.Component.used_input?(field)

  ## Paths

  defp list_path(scope, view, %Query{} = query) do
    base =
      case view do
        :secrets -> ~p"/#{scope.organisation}/#{scope.workspace}/settings/secrets"
        :variables -> ~p"/#{scope.organisation}/#{scope.workspace}/settings/variables"
      end

    case Query.to_params(query) do
      [] -> base
      params -> base <> "?" <> URI.encode_query(params)
    end
  end

  defp secret_path(scope, secret, :change_value),
    do:
      ~p"/#{scope.organisation}/#{scope.workspace}/settings/secrets/#{secret.public_id}/change-value"

  defp secret_path(scope, secret, :edit),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/settings/secrets/#{secret.public_id}/edit"

  defp secret_path(scope, secret, :add_value),
    do:
      ~p"/#{scope.organisation}/#{scope.workspace}/settings/secrets/#{secret.public_id}/add-value"

  defp secret_path(scope, secret, :delete),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/settings/secrets/#{secret.public_id}/delete"

  defp value_path(scope, secret, value, :change),
    do:
      ~p"/#{scope.organisation}/#{scope.workspace}/settings/secrets/#{secret.public_id}/values/#{value.value_id}/change"

  defp value_path(scope, secret, value, :rename),
    do:
      ~p"/#{scope.organisation}/#{scope.workspace}/settings/secrets/#{secret.public_id}/values/#{value.value_id}/rename"

  defp value_path(scope, secret, value, :delete),
    do:
      ~p"/#{scope.organisation}/#{scope.workspace}/settings/secrets/#{secret.public_id}/values/#{value.value_id}/delete"

  defp variable_path(scope, variable, :targets),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/settings/variables/#{variable.id}/targets"

  defp variable_path(scope, variable, :change),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/settings/variables/#{variable.id}/change"

  defp variable_path(scope, variable, :delete),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/settings/variables/#{variable.id}/delete"

  ## Mount and the paths of the pages and the confirmations

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    socket =
      socket
      |> assign(
        page_title:
          SettingsComponents.page_title(scope, :workspace, [gettext("Secrets and variables")]),
        sections: SettingsComponents.sections(scope, :workspace),
        query: %Query{},
        switched: false,
        act: nil,
        secret: nil,
        value: nil,
        variable: nil,
        form: nil,
        warning: nil,
        refusal: nil,
        target_q: ""
      )
      |> mays()

    case read(scope) do
      {:ok, data} -> {:ok, assign(socket, data)}
      {:error, _reason} -> raise ApiaryWeb.NotFound
    end
  end

  defp mays(socket) do
    %{current_scope: scope} = socket.assigns

    assign(socket,
      may_write: Access.can?(scope, :"secret.write", scope.workspace),
      may_edit: Access.can?(scope, :"variable.edit", scope.workspace)
    )
  end

  # Everything the two views show, read again after every change.
  defp read(scope) do
    with {:ok, secrets} <- Secrets.list_secrets(scope),
         {:ok, uses} <- Secrets.list_uses(scope, secrets),
         {:ok, variables} <- Variables.list_variables(scope, :workspace),
         {:ok, resolution} <- Variables.resolve(scope, :workspace),
         {:ok, targets} <- Variables.repository_overrides(scope) do
      {:ok,
       %{
         secrets: secrets,
         uses: uses,
         variables: variables,
         resolution: resolution,
         targets: targets,
         people: people(scope)
       }}
    end
  end

  # user id => email, of the organisation's members: who changed a value or a variable.
  defp people(scope) do
    for %{user: user} <- Organisations.list_members(scope),
        email = People.email(user),
        into: %{},
        do: {user.id, email}
  end

  defp reload(socket) do
    case read(socket.assigns.current_scope) do
      {:ok, data} -> assign(socket, data)
      {:error, _reason} -> reload_scope(socket)
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    action = socket.assigns.live_action
    view = if(action in [:secrets | @secret_acts], do: :secrets, else: :variables)

    # A switch from one tab to the other, which the status line says; not a page's
    # first view, nor a return from a page of the same tab.
    switched =
      action in [:secrets, :variables] and socket.assigns[:view] not in [nil, view]

    socket =
      socket
      |> assign(view: view, switched: switched)
      |> assign(
        act: nil,
        secret: nil,
        value: nil,
        variable: nil,
        form: nil,
        warning: nil,
        refusal: nil
      )

    socket =
      if action in [:secrets, :variables],
        do: assign(socket, :query, Query.from_params(params)),
        else: socket

    {:noreply, socket |> open(action, params) |> titled()}
  end

  # The browser's title, the most specific first (`SettingsComponents.page_title/3`): a
  # page of a form is named by its act, the Secrets tab by the section, the Variables tab
  # by the tab and the section.
  defp titled(socket),
    do: assign(socket, :page_title, title_of(socket.assigns))

  defp title_of(%{act: act} = assigns) when act in @pages,
    do: SettingsComponents.page_title(assigns.current_scope, :workspace, [form_title(assigns)])

  defp title_of(%{view: :variables} = assigns),
    do:
      SettingsComponents.page_title(assigns.current_scope, :workspace, [
        gettext("Variables"),
        gettext("Secrets and variables")
      ])

  defp title_of(assigns),
    do:
      SettingsComponents.page_title(assigns.current_scope, :workspace, [
        gettext("Secrets and variables")
      ])

  defp open(socket, action, _params) when action in [:secrets, :variables], do: socket

  defp open(socket, :new_secret, _params) do
    if socket.assigns.may_write,
      do:
        assign(socket,
          act: :new_secret,
          form: secret_form(fresh(Secrets.change_secret(%Secret{}))),
          values_kind: "one",
          value_rows: value_rows(),
          values_errors: [],
          refused_saves: 0
        ),
      else: refused(socket)
  end

  defp open(socket, :edit_secret, %{"id" => id}) do
    with_secret(socket, id, nil, fn socket, secret, _value ->
      assign(socket,
        act: :edit_secret,
        secret: secret,
        form: secret_form(fresh(Secrets.change_secret(secret)))
      )
    end)
  end

  defp open(socket, :add_value, %{"id" => id}) do
    with_secret(socket, id, nil, fn socket, secret, _value ->
      assign(socket,
        act: :add_value,
        secret: secret,
        form: value_form(Ecto.Changeset.change(%Value{}))
      )
    end)
  end

  defp open(socket, :change_value, %{"id" => id} = params) do
    with_secret(socket, id, {:value, params["value_id"]}, fn socket, secret, value ->
      assign(socket,
        act: :change_value,
        secret: secret,
        value: value,
        form: value_form(Ecto.Changeset.change(%Value{}))
      )
    end)
  end

  defp open(socket, :rename_value, %{"id" => id, "value_id" => value_id}) do
    with_secret(socket, id, {:value, value_id}, fn socket, secret, value ->
      assign(socket,
        act: :rename_value,
        secret: secret,
        value: value,
        form: value_form(Ecto.Changeset.change(value))
      )
    end)
  end

  defp open(socket, :delete_value, %{"id" => id, "value_id" => value_id}) do
    with_secret(socket, id, {:value, value_id}, fn socket, secret, value ->
      if length(secret.values) > 1,
        do: assign(socket, act: :delete_value, secret: secret, value: value),
        else: back(socket, :error, last_value(secret))
    end)
  end

  defp open(socket, :delete_secret, %{"id" => id}) do
    with_secret(socket, id, nil, fn socket, secret, _value ->
      assign(socket, act: :delete_secret, secret: secret)
    end)
  end

  defp open(socket, :new_variable, _params) do
    if socket.assigns.may_edit,
      do:
        assign(socket,
          act: :new_variable,
          form: variable_form(fresh(Variables.change_variable(%Variable{})))
        ),
      else: refused(socket)
  end

  defp open(socket, :variable_targets, %{"id" => id}) do
    with_variable(socket, id, :read, fn socket, variable ->
      assign(socket, act: :variable_targets, variable: variable, target_q: "")
    end)
  end

  defp open(socket, :change_variable, %{"id" => id}) do
    with_variable(socket, id, :edit, fn socket, variable ->
      assign(socket,
        act: :change_variable,
        variable: variable,
        form: variable_form(fresh(Variables.change_variable(variable)))
      )
    end)
  end

  defp open(socket, action, %{"id" => id}) when action in [:lock_variable, :unlock_variable] do
    with_variable(socket, id, :edit, fn socket, variable ->
      # Locked or unlocked already: the list says so, and there is nothing to confirm.
      if variable.locked == (action == :lock_variable),
        do:
          push_patch(socket,
            to: list_path(socket.assigns.current_scope, :variables, socket.assigns.query)
          ),
        else: assign(socket, act: action, variable: variable)
    end)
  end

  defp open(socket, :delete_variable, %{"id" => id}) do
    with_variable(socket, id, :edit, fn socket, variable ->
      assign(socket, act: :delete_variable, variable: variable)
    end)
  end

  # The secret of the path, read as the reader sees it, and the value it names: `nil` for
  # none, `{:value, nil}` for the secret's one value without a value id.
  defp with_secret(socket, id, which, fun) do
    scope = socket.assigns.current_scope

    with {:ok, secret} <- Secrets.get_secret(scope, id),
         true <- Access.can?(scope, :"secret.write", secret) || :refused,
         {:ok, value} <- value_of(secret, which) do
      fun.(socket, secret, value)
    else
      :refused ->
        refused(socket)

      {:error, :no_value, secret} ->
        back(socket, :error, value_gone(secret))

      {:error, :forbidden} ->
        unauthorized(socket)

      {:error, _not_found} ->
        back(socket, :error, gettext("That secret is no longer in this workspace."))
    end
  end

  defp value_of(_secret, nil), do: {:ok, nil}

  defp value_of(secret, {:value, value_id}) do
    case Enum.find(secret.values, &(&1.value_id == value_id)) do
      %Value{} = value -> {:ok, value}
      nil -> {:error, :no_value, secret}
    end
  end

  # The workspace's own variable of the path. A repository's is not this page's, and is
  # answered as one that is gone.
  defp with_variable(socket, id, need, fun) do
    scope = socket.assigns.current_scope

    with {:ok, %Variable{target_id: nil} = variable} <- Variables.get_variable(scope, id),
         true <- need == :read || Access.can?(scope, :"variable.edit", variable) || :refused do
      fun.(socket, variable)
    else
      :refused ->
        refused(socket)

      {:error, :forbidden} ->
        unauthorized(socket)

      _gone ->
        back(socket, :error, gettext("That variable is no longer in this workspace."), :variables)
    end
  end

  ## Events

  @impl true
  # The search is the URL's `q`, sent as the reader types.
  def handle_event("find", %{"q" => q}, socket) do
    query = %{socket.assigns.query | q: String.trim(q)}

    {:noreply,
     push_patch(socket,
       to: list_path(socket.assigns.current_scope, socket.assigns.view, query),
       replace: true
     )}
  end

  def handle_event("find_target", %{"q" => q}, socket),
    do: {:noreply, assign(socket, :target_q, String.trim(q))}

  # One value, or several, each with its value ID: only the fields of the choice taken
  # are read, and a refused save shows the form again, its errors under their fields and
  # every value empty, to write again.
  def handle_event("create_secret", %{"secret" => params}, socket) when is_map(params) do
    scope = socket.assigns.current_scope
    kind = if params["values_kind"] == "several", do: "several", else: "one"

    attrs =
      if kind == "several",
        do: params |> Map.take(~w(name note)) |> Map.put("values", params["values"] || %{}),
        else: Map.take(params, ~w(name note value))

    case Secrets.create_secret(scope, attrs) do
      {:ok, secret} ->
        {:noreply, saved(socket, gettext("%{name} is saved.", name: secret.name))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket,
           form: secret_form(changeset),
           values_kind: kind,
           value_rows: if(kind == "several", do: value_rows(changeset), else: value_rows()),
           values_errors: translate_errors(changeset.errors, :values),
           refused_saves: (socket.assigns[:refused_saves] || 0) + 1
         )}

      {:error, reason} ->
        {:noreply, refusal(socket, reason)}
    end
  end

  def handle_event(
        "update_secret",
        %{"secret" => params},
        %{assigns: %{act: :edit_secret}} = socket
      )
      when is_map(params) do
    %{current_scope: scope, secret: secret} = socket.assigns

    case Secrets.update_secret(scope, secret, Map.take(params, ~w(name note))) do
      {:ok, secret} ->
        {:noreply, saved(socket, gettext("%{name} is saved.", name: secret.name))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, secret_form(changeset))}

      {:error, reason} ->
        {:noreply, refusal(socket, reason)}
    end
  end

  def handle_event(
        "add_value",
        %{"secret_value" => params},
        %{assigns: %{act: :add_value}} = socket
      )
      when is_map(params) do
    %{current_scope: scope, secret: secret} = socket.assigns
    params = Map.take(params, ~w(value_id value first_value_id))

    case Secrets.add_value(scope, secret, params) do
      {:ok, secret} ->
        {:noreply,
         saved(
           socket,
           gettext("%{value_id} is added to %{name}.",
             value_id: Value.normalise_value_id(params["value_id"]),
             name: secret.name
           )
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, value_form(changeset))}

      {:error, reason} ->
        {:noreply, refusal(socket, reason)}
    end
  end

  def handle_event(
        "set_value",
        %{"secret_value" => params},
        %{assigns: %{act: :change_value}} = socket
      )
      when is_map(params) do
    %{current_scope: scope, secret: secret, value: value} = socket.assigns

    case Secrets.set_value(scope, secret, value.value_id, params["value"]) do
      {:ok, secret} ->
        {:noreply,
         saved(
           socket,
           if(value.value_id,
             do:
               gettext("%{value_id} of %{name} is saved.",
                 value_id: value.value_id,
                 name: secret.name
               ),
             else: gettext("The value of %{name} is saved.", name: secret.name)
           )
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, value_form(changeset))}

      {:error, reason} ->
        {:noreply, refusal(socket, reason)}
    end
  end

  def handle_event(
        "rename_value",
        %{"secret_value" => params},
        %{assigns: %{act: :rename_value}} = socket
      )
      when is_map(params) do
    %{current_scope: scope, secret: secret, value: value} = socket.assigns

    case Secrets.rename_value(scope, secret, value.value_id, params["value_id"]) do
      {:ok, secret} ->
        {:noreply,
         saved(
           socket,
           gettext("%{value_id} of %{name} is now %{new}.",
             value_id: value.value_id,
             name: secret.name,
             new: Value.normalise_value_id(params["value_id"])
           )
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, value_form(changeset))}

      {:error, reason} ->
        {:noreply, refusal(socket, reason)}
    end
  end

  def handle_event("delete_value", _params, %{assigns: %{act: :delete_value}} = socket) do
    %{current_scope: scope, secret: secret, value: value} = socket.assigns

    case Secrets.delete_value(scope, secret, value.value_id) do
      {:ok, secret} ->
        {:noreply,
         saved(
           socket,
           gettext("%{value_id} is deleted from %{name}.",
             value_id: value.value_id,
             name: secret.name
           )
         )}

      {:error, reason} ->
        {:noreply, refusal(socket, reason)}
    end
  end

  def handle_event("delete_secret", _params, %{assigns: %{act: :delete_secret}} = socket) do
    %{current_scope: scope, secret: secret} = socket.assigns

    case Secrets.delete_secret(scope, secret) do
      {:ok, secret} ->
        {:noreply, saved(socket, gettext("%{name} is deleted.", name: secret.name))}

      {:error, reason} ->
        {:noreply, refusal(socket, reason)}
    end
  end

  def handle_event("validate_variable", %{"variable" => params}, socket) when is_map(params) do
    changeset =
      %Variable{}
      |> Variables.change_variable(params)
      |> Map.put(:action, :validate)

    # Only what was typed in shows its error, as the reader goes (`used_input?/1`).
    {:noreply,
     assign(socket, form: to_form(changeset, as: "variable"), warning: warning(params["name"]))}
  end

  def handle_event("create_variable", %{"variable" => params}, socket) when is_map(params) do
    scope = socket.assigns.current_scope

    case Variables.create_variable(scope, :workspace, Map.take(params, ~w(name value locked))) do
      {:ok, variable} ->
        {:noreply, saved(socket, gettext("%{name} is saved.", name: variable.name), :variables)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, form: variable_form(changeset), warning: warning(params["name"]))}

      {:error, reason} ->
        {:noreply, refusal(socket, reason, :variables)}
    end
  end

  def handle_event(
        "change_variable",
        %{"variable" => params},
        %{assigns: %{act: :change_variable}} = socket
      )
      when is_map(params) do
    %{current_scope: scope, variable: variable} = socket.assigns
    asked_at = DateTime.utc_now()

    case Variables.update_variable(scope, variable, %{"value" => params["value"]}) do
      {:ok, variable} ->
        {:noreply, saved(socket, value_saved(variable, asked_at), :variables)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, variable_form(changeset))}

      {:error, reason} ->
        {:noreply, refusal(socket, reason, :variables)}
    end
  end

  # The confirmation on a row acts on the variable its path named; the context asks again
  # whether the reader still may. A row's menu names its own variable (below).
  def handle_event(event, params, %{assigns: %{act: act}} = socket)
      when {event, act} in [
             {"lock_variable", :lock_variable},
             {"unlock_variable", :unlock_variable},
             {"delete_variable", :delete_variable}
           ] and not is_map_key(params, "id"),
      do: {:noreply, change_variable(socket, event, socket.assigns.variable)}

  # Lock and Unlock act at once from the row's menu, which names the variable.
  def handle_event(event, %{"id" => id}, socket)
      when event in ~w(lock_variable unlock_variable) do
    {:noreply, with_variable(socket, id, :edit, &change_variable(&1, event, &2))}
  end

  # A change without its page or its confirmation open: a second click of a button whose
  # confirmation has gone, or an event the page offers no control for. One who may change the view is shown the
  # list again; one who may not is refused, as a path the page offers no button for is.
  def handle_event(event, _params, socket)
      when event in ~w(update_secret add_value set_value rename_value delete_value delete_secret) do
    if socket.assigns.may_write,
      do: {:noreply, reload(socket)},
      else: {:noreply, refused(socket)}
  end

  def handle_event(event, _params, socket)
      when event in ~w(change_variable lock_variable unlock_variable delete_variable) do
    if socket.assigns.may_edit,
      do: {:noreply, reload(socket)},
      else: {:noreply, refused(socket)}
  end

  defp change_variable(socket, event, variable) do
    %{current_scope: scope, targets: targets} = socket.assigns
    targets = Map.get(targets, String.downcase(variable.name), [])

    result =
      case event do
        "lock_variable" -> Variables.lock_variable(scope, variable)
        "unlock_variable" -> Variables.unlock_variable(scope, variable)
        "delete_variable" -> Variables.delete_variable(scope, variable)
      end

    case result do
      {:ok, variable} ->
        saved(socket, variable_done(event, variable.name, targets), :variables)

      {:error, %Ecto.Changeset{} = changeset} ->
        not_done(socket, event, variable, changeset)

      {:error, reason} ->
        refusal(socket, reason, :variables)
    end
  end

  # A lock, an unlock or a deletion refused, on what it asks of the variable or on the
  # limits of the holders it reaches, which are checked where the change leaves them, so
  # a holder already over them refuses it too (a deletion that shrinks a holder already
  # over them, and grows none, is let through). The row's confirmation, when the change
  # came from it, stays open and says why; a lock or an unlock from the row's menu says
  # it in the flash. Either way the list is read again, and the row is as it was.
  defp not_done(socket, event, variable, changeset) do
    words = not_done_words(event, reasons(changeset))

    if confirming?(socket, event, variable),
      do: held(socket, words),
      else: back(socket, :error, words, :variables)
  end

  # The context's reason names no act, so the words say which did not happen.
  defp not_done_words("lock_variable", reason),
    do: gettext("Not locked: %{reason}", reason: reason)

  defp not_done_words("unlock_variable", reason),
    do: gettext("Not unlocked: %{reason}", reason: reason)

  defp not_done_words("delete_variable", reason),
    do: gettext("Not deleted: %{reason}", reason: reason)

  # Whether the change came from its confirmation, open on the variable's row.
  defp confirming?(socket, event, %Variable{id: id}) do
    %{act: act, variable: open} = socket.assigns

    match?(%Variable{id: ^id}, open) and
      {event, act} in [
        {"lock_variable", :lock_variable},
        {"unlock_variable", :unlock_variable},
        {"delete_variable", :delete_variable}
      ]
  end

  # What a change did, with what a lock or an unlock did to the targets that set the
  # variable too.
  defp variable_done("lock_variable", name, targets) do
    own = Enum.count(targets, &(&1.state == :own))

    if own > 0,
      do:
        ngettext(
          "%{name} is locked: %{number} target that sets its own is set aside by the lock.",
          "%{name} is locked: %{number} targets that set their own are set aside by the lock.",
          own,
          name: name,
          number: Format.number(own)
        ),
      else: gettext("%{name} is locked.", name: name)
  end

  defp variable_done("unlock_variable", name, targets) do
    ignored = Enum.count(targets, &(&1.state == :ignored))

    if ignored > 0,
      do:
        ngettext(
          "%{name} is unlocked: %{number} target that sets its own is no longer set aside.",
          "%{name} is unlocked: %{number} targets that set their own are no longer set aside.",
          ignored,
          name: name,
          number: Format.number(ignored)
        ),
      else: gettext("%{name} is unlocked.", name: name)
  end

  defp variable_done("delete_variable", name, _targets),
    do: gettext("%{name} is deleted.", name: name)

  # A value equal to the one the variable has is written nowhere and leaves no entry
  # (`Apiary.Variables.update_variable/3`): the variable comes back as it was, stamped
  # before this change was asked, and the flash says it has that value already.
  defp value_saved(%Variable{updated_at: updated_at, name: name}, asked_at) do
    if DateTime.before?(updated_at, asked_at),
      do: gettext("%{name} already has that value.", name: name),
      else: gettext("%{name} is changed.", name: name)
  end

  ## After a change, and its refusals

  # Saved: the list read again, back on the view, the page and its field gone.
  defp saved(socket, words, view \\ :secrets) do
    socket
    |> put_flash(:info, words)
    |> reload()
    |> then(fn socket ->
      if socket.redirected,
        do: socket,
        else:
          push_patch(socket,
            to: list_path(socket.assigns.current_scope, view, socket.assigns.query)
          )
    end)
  end

  defp refusal(socket, reason, view \\ :secrets)

  # A secret's deletion or a value's, refused while what it deletes stays: its
  # confirmation stays open and says why.
  defp refusal(socket, {:in_use, uses}, _view),
    do:
      held(
        socket,
        gettext("%{name} is used by %{uses}: unlink it there first.",
          name: socket.assigns.secret.name,
          uses: uses |> Enum.map(& &1.name) |> Enum.uniq() |> Enum.join(", ")
        )
      )

  defp refusal(socket, :last_value, _view), do: held(socket, last_value(socket.assigns.secret))

  defp refusal(socket, :too_many_values, view),
    do:
      back(
        socket,
        :error,
        gettext("A secret holds at most %{number} values.",
          number: Format.number(Secrets.max_values())
        ),
        view
      )

  defp refusal(socket, :key_unavailable, view),
    do:
      back(
        socket,
        :error,
        gettext(
          "The values of this workspace cannot be read: the instance's encryption secret is not the one they were stored under."
        ),
        view
      )

  defp refusal(socket, :not_found, view) do
    socket = reload_scope(socket)

    if socket.redirected,
      do: socket,
      else:
        back(
          socket,
          :error,
          if(view == :variables,
            do: gettext("That variable is no longer in this workspace."),
            else: gettext("That secret is no longer in this workspace.")
          ),
          view
        )
  end

  defp refusal(socket, :forbidden, _view), do: unauthorized(socket)

  # Any other refusal: a deletion's changeset (a form's is answered under its fields), or
  # a reason no clause above names. A deletion's confirmation stays open and says why; a
  # form's page goes back to the view and says it in the flash.
  defp refusal(socket, reason, view) do
    deleting? = socket.assigns.act in [:delete_secret, :delete_value]

    words =
      case reason do
        %Ecto.Changeset{} = changeset when deleting? ->
          gettext("Not deleted: %{reason}", reason: reasons(changeset))

        _other when deleting? ->
          gettext("Not deleted.")

        _other ->
          gettext("Not saved.")
      end

    if deleting?, do: held(socket, words), else: back(socket, :error, words, view)
  end

  defp reasons(changeset),
    do: Enum.map_join(changeset.errors, " ", fn {_field, error} -> translate_error(error) end)

  defp last_value(secret),
    do:
      gettext(
        "%{name} has one value, which goes only with the secret: delete the secret instead.",
        name: secret.name
      )

  defp value_gone(secret),
    do: gettext("That value is no longer in %{name}.", name: secret.name)

  # A change its confirmation asked for, refused while what it acts on stays: the list read
  # again, and the confirmation still open, saying why under its question
  # (`refusal_line/1`). Nothing mounts again, so the focus stays on the button that acted.
  defp held(socket, words), do: socket |> reload() |> assign(:refusal, words)

  # Back to the view, with a word, the list read again.
  defp back(socket, kind, words, view \\ nil) do
    view = view || socket.assigns.view

    socket
    |> put_flash(kind, words)
    |> reload()
    |> then(fn socket ->
      if socket.redirected,
        do: socket,
        else:
          push_patch(socket,
            to: list_path(socket.assigns.current_scope, view, socket.assigns.query)
          )
    end)
  end

  # A path or an event for a change the reader may not make, which the page offers no
  # control for.
  defp refused(socket), do: back(socket, :error, gettext("Only owners and admins change this."))

  # Refused on the membership as it is now: the page's scope is stale, and is read again,
  # with what the reader may. A membership that is gone sends the page to `/`; a reader
  # whom the edition lets read the organisation is told so.
  defp unauthorized(socket) do
    socket = reload_scope(socket)

    cond do
      socket.redirected ->
        socket

      Access.reader(socket.assigns.current_scope) ->
        socket
        |> mays()
        |> back(:error, ApiaryWeb.Access.reads_only(socket.assigns.current_scope))

      true ->
        socket |> mays() |> refused()
    end
  end

  # The scope read again (`ApiaryWeb.UserAuth.reload_scope/1`). A membership that is gone
  # sends the page to `/`, and says why when the reload did not.
  defp reload_scope(socket) do
    socket = UserAuth.reload_scope(socket)

    if socket.redirected && !Phoenix.Flash.get(socket.assigns.flash, :error),
      do: put_flash(socket, :error, gettext("You are no longer a member of this workspace.")),
      else: socket
  end

  ## Forms

  # A form of a secret or a value: the changeset the context handed back holds no value
  # (`Apiary.Secrets.change_secret/2`), and the field is marked as used, so an error on
  # the value shows under it, without the value.
  defp secret_form(changeset), do: changeset |> used_value() |> to_form(as: "secret")
  defp value_form(changeset), do: changeset |> used_value() |> to_form(as: "secret_value")

  defp used_value(%Ecto.Changeset{} = changeset) do
    changeset = used(changeset)
    params = Map.put(changeset.params, "value", "")
    %{changeset | params: params, changes: Map.delete(changeset.changes, :value)}
  end

  defp variable_form(%Ecto.Changeset{} = changeset), do: to_form(used(changeset), as: "variable")

  # A form as its page opens: nothing is typed yet, so nothing is wrong yet.
  defp fresh(%Ecto.Changeset{} = changeset), do: %{changeset | errors: [], valid?: true}

  # A field with an error is a used one, so the error shows under it, however the
  # changeset came to have it: a context's check adds an error to a changeset that may
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
