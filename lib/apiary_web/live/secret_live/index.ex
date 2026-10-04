defmodule ApiaryWeb.SecretLive.Index do
  @moduledoc """
  The workspace's Secrets and variables, a section of its settings
  (`ApiaryWeb.SettingsComponents`) with the `security` feature: two views of one page,
  Secrets (`/:org/:workspace/settings/secrets`) and Variables (`…/settings/variables`),
  each a list on the list pattern (a search, a Filter menu, Sort, the filters in force as
  tokens, all in the URL; `ApiaryWeb.SecretLive.Query`). Each change is at a path of its
  own: a form is a page of the section, as Add integration is (its title, one sentence,
  the form in the section's column, its button and Cancel back to the view, the
  breadcrumb ending with the section and the page); a confirmation (a deletion, a lock,
  an unlock) is a small dialog over its view, and so is the list of a variable's
  targets.

  - **Secrets** (`Apiary.Secrets`): a secret's name, its value ids, who changed each
    value and when, and what uses it; never a value. New secret, then Add value, Change
    value, Rename value and Delete value, and Delete secret. A value is written into a
    field and sent once: the page never renders it, nor keeps it in an assign, so the
    field is empty after a save and after a refused one, and the form the context hands
    back holds none (`Apiary.Secrets.change_secret/2`).
  - **Variables** (`Apiary.Variables`): the workspace's own, each with its value, which
    is plain configuration, its lock, and the repositories that set their own value or
    whose value a lock sets aside, from their resolution
    (`Apiary.Variables.repository_overrides/1`). New variable, Change value, Lock and
    Unlock, Delete variable, and the repositories of a variable. A name beginning
    `QORY_` is refused by the context; any other name on the runner's deny list is
    saved, and the page warns (`Apiary.Variables.Denied`).

  Every member reads both views; owners and admins change them (`secret.write`,
  `variable.edit`), and a reader who may not sees the page without its controls, and
  one line that says who changes it. What each may is asked of `Apiary.Access`, and the
  context functions ask again.
  """
  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :security
  on_mount {ApiaryWeb.Access, :"secret.read"}

  alias Apiary.{Access, Organisations, Secrets, Variables}
  alias Apiary.Secrets.{Secret, Value}
  alias Apiary.Variables.{Denied, Variable}
  alias ApiaryWeb.{People, SettingsComponents, UserAuth}
  alias ApiaryWeb.SecretLive.Query

  @secret_dialogs [
    :new_secret,
    :add_value,
    :change_value,
    :rename_value,
    :delete_value,
    :delete_secret
  ]
  @variable_dialogs [
    :new_variable,
    :change_variable,
    :lock_variable,
    :unlock_variable,
    :delete_variable,
    :variable_targets
  ]

  # The changes that are a form, each a page of the section; the rest are confirmations,
  # small dialogs over their view.
  @pages [:new_secret, :add_value, :change_value, :rename_value, :new_variable, :change_variable]

  # Past this many repositories, a variable's list of them has a search.
  @find_from 10

  @impl true
  # A form is a page of the section, as Add integration is: the section's list beside it,
  # the breadcrumb ending with the section and the page, its title, one sentence, the
  # form in the section's column, its button and Cancel back to the view.
  def render(%{dialog: dialog} = assigns) when dialog in @pages do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:settings}
    >
      <:crumb navigate={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/settings"}>
        {gettext("Settings")}
      </:crumb>
      <:crumb navigate={list_path(@current_scope, @view, @query)}>
        {gettext("Secrets and variables")}
      </:crumb>
      <:crumb>{crumb_words(@dialog)}</:crumb>

      <SettingsComponents.layout
        scope={@current_scope}
        counts={@nav_counts}
        kind={:workspace}
        sections={@sections}
        current={:secrets}
        title={form_title(assigns)}
      >
        <:subtitle>{form_sentence(assigns)}</:subtitle>
        <.form_page {assigns} />
      </SettingsComponents.layout>
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
      nav={:settings}
    >
      <SettingsComponents.layout
        scope={@current_scope}
        counts={@nav_counts}
        kind={:workspace}
        sections={@sections}
        current={:secrets}
        measure="list"
        title={gettext("Secrets and variables")}
      >
        <:subtitle>
          {gettext("Values the runs of this workspace are given.")}
          {gettext("A secret is never shown again once it is saved; a variable is plain text.")}
        </:subtitle>
        <:actions :if={@view == :secrets && @may_write}>
          <.button
            id="new-secret"
            variant="primary"
            patch={
              ~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/settings/secrets/new"
            }
          >
            <.icon name="hero-plus-micro" class="size-4" /> {gettext("New secret")}
          </.button>
        </:actions>
        <:actions :if={@view == :variables && @may_edit}>
          <.button
            id="new-variable"
            variant="primary"
            patch={
              ~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/settings/variables/new"
            }
          >
            <.icon name="hero-plus-micro" class="size-4" /> {gettext("New variable")}
          </.button>
        </:actions>

        <p
          :if={(@view == :secrets && !@may_write) || (@view == :variables && !@may_edit)}
          id="secrets-read-only"
          class="-mt-2 text-[13px]/5 text-muted"
        >
          {gettext("Only owners and admins change this.")}
        </p>

        <.views id="secrets-views" label={gettext("Secrets and variables")}>
          <:view
            id="secrets-view-secrets"
            patch={list_path(@current_scope, :secrets, Query.for_secrets(@query))}
            current={@view == :secrets}
            count={Format.number(length(@secrets))}
          >
            {gettext("Secrets")}
          </:view>
          <:view
            id="secrets-view-variables"
            patch={list_path(@current_scope, :variables, Query.for_variables(@query))}
            current={@view == :variables}
            count={Format.number(length(@variables))}
          >
            {gettext("Variables")}
          </:view>
        </.views>

        <.secrets_view :if={@view == :secrets} {assigns} />
        <.variables_view :if={@view == :variables} {assigns} />
      </SettingsComponents.layout>

      <.secret_dialog :if={secret_dialog?(@dialog)} {assigns} />
      <.variable_dialog :if={variable_dialog?(@dialog)} {assigns} />
    </Layouts.app>
    """
  end

  defp secret_dialog?(dialog), do: dialog in @secret_dialogs
  defp variable_dialog?(dialog), do: dialog in @variable_dialogs

  ## The secrets

  defp secrets_view(assigns) do
    assigns =
      assign(assigns,
        shown: Query.secrets(assigns.secrets, assigns.query),
        tokens: Query.tokens(assigns.query)
      )

    ~H"""
    <div :if={@secrets != []} class="q-bar">
      <.list_search
        id="secrets-search"
        value={@query.q}
        label={gettext("Find a secret")}
        placeholder={gettext("Find a secret by name or value ID")}
        change="find"
      />
      <.filter_menu id="secrets-filter" count={length(@tokens)}>
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
      <.sort_menu id="secrets-sort" current={sort_words(@query.sort)}>
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

    <%!-- Always there, so a screen reader hears what the search left. --%>
    <div id="secrets-status" role="status" class="q-status">
      <p :if={Query.narrowed?(@query) && @secrets != []} class="text-[13px] text-muted">
        {ngettext("%{number} secret matches", "%{number} secrets match", length(@shown),
          number: Format.number(length(@shown))
        )}
      </p>
    </div>

    <div :if={@secrets == []} id="secrets-empty">
      <.empty_state
        icon="hero-lock-closed"
        tone="neutral"
        title={gettext("No secrets yet")}
      >
        {gettext(
          "A secret holds a value the runs are given, such as a token for a system. Once it is saved, nobody sees it again."
        )}
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
              {gettext("Not used yet")}
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
        aria-label={gettext("Change the value of %{name}", name: @secret.name)}
      >
        {gettext("Change value…")}
      </.menu_item>
      <.menu_item
        id={"secret-#{@secret.public_id}-add"}
        patch={secret_path(@scope, @secret, :add_value)}
        aria-label={gettext("Add a value to %{name}", name: @secret.name)}
      >
        {gettext("Add value…")}
      </.menu_item>
      <.menu_divider />
      <.menu_item
        id={"secret-#{@secret.public_id}-delete"}
        patch={secret_path(@scope, @secret, :delete)}
        aria-label={gettext("Delete %{name}", name: @secret.name)}
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
          gettext("Change %{value_id} of %{name}", value_id: @value.value_id, name: @secret.name)
        }
      >
        {gettext("Change value…")}
      </.menu_item>
      <.menu_item
        id={"#{@id}-rename"}
        patch={value_path(@scope, @secret, @value, :rename)}
        aria-label={
          gettext("Rename %{value_id} of %{name}", value_id: @value.value_id, name: @secret.name)
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
          gettext("Delete %{value_id} of %{name}", value_id: @value.value_id, name: @secret.name)
        }
      >
        {gettext("Delete value…")}
      </.menu_item>
    </.row_menu>
    """
  end

  ## The variables

  defp variables_view(assigns) do
    assigns =
      assign(assigns,
        shown: Query.variables(assigns.variables, assigns.targets, assigns.query),
        tokens: Query.tokens(assigns.query),
        shared: shared_paths(assigns.targets)
      )

    ~H"""
    <div :if={@variables != []} class="q-bar">
      <.list_search
        id="variables-search"
        value={@query.q}
        label={gettext("Find a variable")}
        placeholder={gettext("Find a variable by name or value")}
        change="find"
      />
      <.filter_menu id="variables-filter" count={length(@tokens)}>
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
      <.sort_menu id="variables-sort" current={sort_words(@query.sort)}>
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

    <div id="variables-status" role="status" class="q-status">
      <p :if={Query.narrowed?(@query) && @variables != []} class="text-[13px] text-muted">
        {ngettext("%{number} variable matches", "%{number} variables match", length(@shown),
          number: Format.number(length(@shown))
        )}
      </p>
    </div>

    <div :if={@variables == []} id="variables-empty">
      <.empty_state
        icon="hero-variable"
        tone="neutral"
        title={gettext("No variables yet")}
      >
        {gettext(
          "A variable is a plain value a run's process is given, such as the address of a package registry."
        )}
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
    >
      <:col :let={variable} label={gettext("Name")} kind="title">
        <span class="q-nm">
          <span class="q-title font-mono">{variable.name}</span>
          <.state_word
            :if={warned?(variable.name)}
            id={"variable-#{variable.id}-denied"}
            hot
          >
            {gettext("Left out by the runner")}
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
            aria-label={gettext("Change the value of %{name}", name: variable.name)}
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
            aria-label={gettext("Delete %{name}", name: variable.name)}
          >
            {gettext("Delete variable…")}
          </.menu_item>
        </.row_menu>
      </:action>
    </.table>

    <p id="variables-note" class="max-w-[72ch] text-[12.5px]/[18px] text-faint">
      {gettext("A node cannot change a variable set here; it can only add its own.")}
      {gettext("A run without a wall receives these only on nodes whose runner file turns that on.")}
    </p>
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

  defp form_page(%{dialog: :new_secret} = assigns) do
    ~H"""
    <.form for={@form} id="secret-form" phx-submit="create_secret" class="grid gap-4" novalidate>
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
      <.value_field form={@form} />
      <.input
        field={@form[:value_id]}
        label={gettext("Value ID")}
        optional
        placeholder="main-app"
        hint={
          gettext("Only for a secret that will hold several values: a lowercase name for this one.")
        }
        autocomplete="off"
        spellcheck="false"
        class="font-mono"
      />
      <.input field={@form[:note]} label={gettext("What it is for")} optional autocomplete="off" />
      <SettingsComponents.save id="secret-save" cancel={list_path(@current_scope, :secrets, @query)}>
        <.button variant="primary" type="submit" loading_text={gettext("Saving")}>
          {gettext("Save secret")}
        </.button>
      </SettingsComponents.save>
    </.form>
    """
  end

  defp form_page(%{dialog: :add_value} = assigns) do
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
      <SettingsComponents.save id="secret-save" cancel={list_path(@current_scope, :secrets, @query)}>
        <.button variant="primary" type="submit" loading_text={gettext("Saving")}>
          {gettext("Add value")}
        </.button>
      </SettingsComponents.save>
    </.form>
    """
  end

  defp form_page(%{dialog: :change_value} = assigns) do
    ~H"""
    <.form for={@form} id="secret-form" phx-submit="set_value" class="grid gap-4" novalidate>
      <.value_field form={@form} label={gettext("New value")} focus />
      <SettingsComponents.save id="secret-save" cancel={list_path(@current_scope, :secrets, @query)}>
        <.button variant="primary" type="submit" loading_text={gettext("Saving")}>
          {gettext("Change value")}
        </.button>
      </SettingsComponents.save>
    </.form>
    """
  end

  defp form_page(%{dialog: :rename_value} = assigns) do
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
      <SettingsComponents.save id="secret-save" cancel={list_path(@current_scope, :secrets, @query)}>
        <.button variant="primary" type="submit" loading_text={gettext("Saving")}>
          {gettext("Rename value")}
        </.button>
      </SettingsComponents.save>
    </.form>
    """
  end

  defp form_page(%{dialog: :new_variable} = assigns) do
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
      <SettingsComponents.save
        id="variable-save"
        cancel={list_path(@current_scope, :variables, @query)}
      >
        <.button variant="primary" type="submit" loading_text={gettext("Saving")}>
          {gettext("Save variable")}
        </.button>
      </SettingsComponents.save>
    </.form>
    """
  end

  defp form_page(%{dialog: :change_variable} = assigns) do
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
      <SettingsComponents.save
        id="variable-save"
        cancel={list_path(@current_scope, :variables, @query)}
      >
        <.button variant="primary" type="submit" loading_text={gettext("Saving")}>
          {gettext("Change value")}
        </.button>
      </SettingsComponents.save>
    </.form>
    """
  end

  # The page's title, the act and what it acts on.
  defp form_title(%{dialog: :new_secret}), do: gettext("New secret")

  defp form_title(%{dialog: :add_value, secret: secret}),
    do: gettext("Add a value to %{name}", name: secret.name)

  defp form_title(%{dialog: :change_value, secret: secret, value: %Value{value_id: nil}}),
    do: gettext("Change the value of %{name}", name: secret.name)

  defp form_title(%{dialog: :change_value, secret: secret, value: value}),
    do: gettext("Change %{value_id} of %{name}", value_id: value.value_id, name: secret.name)

  defp form_title(%{dialog: :rename_value, secret: secret, value: value}),
    do: gettext("Rename %{value_id} of %{name}", value_id: value.value_id, name: secret.name)

  defp form_title(%{dialog: :new_variable}), do: gettext("New variable")

  defp form_title(%{dialog: :change_variable, variable: variable}),
    do: gettext("Change the value of %{name}", name: variable.name)

  # The breadcrumb's last segment: the act alone.
  defp crumb_words(:new_secret), do: gettext("New secret")
  defp crumb_words(:add_value), do: gettext("Add value")
  defp crumb_words(:change_value), do: gettext("Change value")
  defp crumb_words(:rename_value), do: gettext("Rename value")
  defp crumb_words(:new_variable), do: gettext("New variable")
  defp crumb_words(:change_variable), do: gettext("Change value")

  # The one sentence under the title: what the page does.
  defp form_sentence(%{dialog: :new_secret}),
    do:
      gettext(
        "A secret holds a value the runs are given, such as a token for a system. Once it is saved, nobody sees it again."
      )

  defp form_sentence(%{dialog: :add_value}),
    do:
      gettext(
        "A secret with several values names each one with a value ID, and what uses the secret chooses one of them."
      )

  defp form_sentence(%{dialog: :change_value}),
    do:
      gettext(
        "The value it holds now is not shown. Runs are given the new one from their next start."
      )

  defp form_sentence(%{dialog: :rename_value}),
    do: gettext("The value stays as it is; only its value ID changes.")

  defp form_sentence(%{dialog: :new_variable}),
    do:
      gettext(
        "A variable is a plain value a run's process is given, such as the address of a package registry."
      )

  defp form_sentence(%{dialog: :change_variable}),
    do: gettext("Runs are given the new value from their next start.")

  ## The secrets' dialogs: confirmations

  defp secret_dialog(%{dialog: :delete_value} = assigns) do
    ~H"""
    <.modal
      id="secret-dialog"
      title={gettext("Delete %{value_id} of %{name}", value_id: @value.value_id, name: @secret.name)}
      on_cancel={JS.patch(list_path(@current_scope, :secrets, @query))}
    >
      <p class="text-muted">
        {gettext(
          "The value is deleted, and the secret keeps its other values. This cannot be undone."
        )}
      </p>
      <:footer>
        <.button patch={list_path(@current_scope, :secrets, @query)} data-autofocus>
          {gettext("Cancel")}
        </.button>
        <.button variant="danger" phx-click="delete_value" loading_text={gettext("Deleting")}>
          {gettext("Delete value")}
        </.button>
      </:footer>
    </.modal>
    """
  end

  defp secret_dialog(%{dialog: :delete_secret} = assigns) do
    ~H"""
    <.modal
      id="secret-dialog"
      title={gettext("Delete %{name}", name: @secret.name)}
      on_cancel={JS.patch(list_path(@current_scope, :secrets, @query))}
    >
      <p class="text-muted">
        {ngettext(
          "The secret and its value are deleted. This cannot be undone.",
          "The secret and its %{number} values are deleted. This cannot be undone.",
          length(@secret.values),
          number: Format.number(length(@secret.values))
        )}
      </p>
      <:footer>
        <.button patch={list_path(@current_scope, :secrets, @query)} data-autofocus>
          {gettext("Cancel")}
        </.button>
        <.button variant="danger" phx-click="delete_secret" loading_text={gettext("Deleting")}>
          {gettext("Delete secret")}
        </.button>
      </:footer>
    </.modal>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :label, :string, default: nil
  attr :focus, :boolean, default: false, doc: "whether the field takes the focus as it mounts"

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
    />
    """
  end

  ## The variables' dialogs: confirmations, and the list of a variable's targets

  defp variable_dialog(%{dialog: :lock_variable} = assigns) do
    assigns = assign(assigns, :own, count_targets(assigns, :own))

    ~H"""
    <.modal
      id="variable-dialog"
      title={gettext("Lock %{name}", name: @variable.name)}
      on_cancel={JS.patch(list_path(@current_scope, :variables, @query))}
    >
      <p class="text-muted">
        {gettext("While %{name} is locked, a target may not set its own value.",
          name: @variable.name
        )}
      </p>
      <p :if={@own > 0} id="lock-targets" class="text-muted">
        {ngettext(
          "%{number} target sets its own now: while the lock holds, its runs are given the workspace's value.",
          "%{number} targets set their own now: while the lock holds, their runs are given the workspace's value.",
          @own,
          number: Format.number(@own)
        )}
      </p>
      <:footer>
        <.button patch={list_path(@current_scope, :variables, @query)}>{gettext("Cancel")}</.button>
        <.button variant="primary" phx-click="lock_variable" loading_text={gettext("Locking")}>
          {gettext("Lock variable")}
        </.button>
      </:footer>
    </.modal>
    """
  end

  defp variable_dialog(%{dialog: :unlock_variable} = assigns) do
    assigns = assign(assigns, :ignored, count_targets(assigns, :ignored))

    ~H"""
    <.modal
      id="variable-dialog"
      title={gettext("Unlock %{name}", name: @variable.name)}
      on_cancel={JS.patch(list_path(@current_scope, :variables, @query))}
    >
      <p class="text-muted">
        {gettext("A target may set its own value of %{name} again.", name: @variable.name)}
      </p>
      <p :if={@ignored > 0} id="unlock-targets" class="text-muted">
        {ngettext(
          "%{number} target set its own: its runs are given it again.",
          "%{number} targets set their own: their runs are given them again.",
          @ignored,
          number: Format.number(@ignored)
        )}
      </p>
      <:footer>
        <.button patch={list_path(@current_scope, :variables, @query)}>{gettext("Cancel")}</.button>
        <.button variant="primary" phx-click="unlock_variable" loading_text={gettext("Unlocking")}>
          {gettext("Unlock variable")}
        </.button>
      </:footer>
    </.modal>
    """
  end

  defp variable_dialog(%{dialog: :delete_variable} = assigns) do
    ~H"""
    <.modal
      id="variable-dialog"
      title={gettext("Delete %{name}", name: @variable.name)}
      on_cancel={JS.patch(list_path(@current_scope, :variables, @query))}
    >
      <p class="text-muted">
        {gettext(
          "Runs are no longer given the workspace's value of %{name}. A target that sets its own keeps it. This cannot be undone.",
          name: @variable.name
        )}
      </p>
      <:footer>
        <.button patch={list_path(@current_scope, :variables, @query)} data-autofocus>
          {gettext("Cancel")}
        </.button>
        <.button variant="danger" phx-click="delete_variable" loading_text={gettext("Deleting")}>
          {gettext("Delete variable")}
        </.button>
      </:footer>
    </.modal>
    """
  end

  defp variable_dialog(%{dialog: :variable_targets} = assigns) do
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
    <.modal
      id="variable-dialog"
      title={gettext("Targets that set %{name}", name: @variable.name)}
      on_cancel={JS.patch(list_path(@current_scope, :variables, @query))}
      size="lg"
    >
      <.list_search
        :if={length(@all) > find_from()}
        id="variable-targets-search"
        value={@target_q}
        label={gettext("Find a target")}
        change="find_target"
        class="w-full"
      />
      <p :if={@all == []} class="text-muted">{gettext("No target sets its own value.")}</p>
      <ul id="variable-targets" class="grid gap-1.5">
        <li
          :for={%{target: target, state: state} <- @listed}
          id={"variable-target-#{target.id}"}
          class="flex flex-wrap items-baseline justify-between gap-x-4"
        >
          <.link
            navigate={
              ApiaryWeb.TargetComponents.target_path(@current_scope, target.system, target.path)
            }
            class="min-w-0 hover:underline"
          >
            <.target_name system={target.system} path={target.path} shared={@shared} />
          </.link>
          <span class="text-[12.5px] text-muted">
            {if state == :own,
              do: gettext("Its own value"),
              else: gettext("Its value set aside by the lock")}
          </span>
        </li>
      </ul>
      <:footer>
        <.button patch={list_path(@current_scope, :variables, @query)} data-autofocus>
          {gettext("Close")}
        </.button>
      </:footer>
    </.modal>
    """
  end

  defp find_from, do: @find_from

  defp count_targets(assigns, state) do
    assigns.targets
    |> Map.get(String.downcase(assigns.variable.name), [])
    |> Enum.count(&(&1.state == state))
  end

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

  # A name the runner leaves out of what a run is given, which the context saves: warned.
  defp warned?(name) when is_binary(name), do: Denied.denied?(name) and not Denied.refused?(name)
  defp warned?(_name), do: false

  defp warning(name) do
    if warned?(name),
      do:
        gettext(
          "Runs are not given %{name}: the runner leaves the names on its deny list out of what a run is given.",
          name: name
        )
  end

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

  defp variable_path(scope, variable, :lock),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/settings/variables/#{variable.id}/lock"

  defp variable_path(scope, variable, :unlock),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/settings/variables/#{variable.id}/unlock"

  defp variable_path(scope, variable, :delete),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/settings/variables/#{variable.id}/delete"

  ## Mount and the paths of the pages and the dialogs

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    socket =
      socket
      |> assign(
        page_title: gettext("Secrets and variables") <> " · " <> gettext("Workspace settings"),
        sections: SettingsComponents.sections(scope, :workspace),
        query: %Query{},
        dialog: nil,
        secret: nil,
        value: nil,
        variable: nil,
        form: nil,
        warning: nil,
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

    socket =
      socket
      |> assign(view: if(action in [:secrets | @secret_dialogs], do: :secrets, else: :variables))
      |> assign(dialog: nil, secret: nil, value: nil, variable: nil, form: nil, warning: nil)

    socket =
      if action in [:secrets, :variables],
        do: assign(socket, :query, Query.from_params(params)),
        else: socket

    {:noreply, socket |> open(action, params) |> titled()}
  end

  # The browser's title: a page of a form is named by its act, the views by the section.
  defp titled(%{assigns: %{dialog: dialog}} = socket) when dialog in @pages,
    do:
      assign(
        socket,
        :page_title,
        form_title(socket.assigns) <> " · " <> gettext("Workspace settings")
      )

  defp titled(socket),
    do:
      assign(
        socket,
        :page_title,
        gettext("Secrets and variables") <> " · " <> gettext("Workspace settings")
      )

  defp open(socket, action, _params) when action in [:secrets, :variables], do: socket

  defp open(socket, :new_secret, _params) do
    if socket.assigns.may_write,
      do:
        assign(socket,
          dialog: :new_secret,
          form: secret_form(fresh(Secrets.change_secret(%Secret{})))
        ),
      else: refused(socket)
  end

  defp open(socket, :add_value, %{"id" => id}) do
    with_secret(socket, id, nil, fn socket, secret, _value ->
      assign(socket,
        dialog: :add_value,
        secret: secret,
        form: value_form(Ecto.Changeset.change(%Value{}))
      )
    end)
  end

  defp open(socket, :change_value, %{"id" => id} = params) do
    with_secret(socket, id, {:value, params["value_id"]}, fn socket, secret, value ->
      assign(socket,
        dialog: :change_value,
        secret: secret,
        value: value,
        form: value_form(Ecto.Changeset.change(%Value{}))
      )
    end)
  end

  defp open(socket, :rename_value, %{"id" => id, "value_id" => value_id}) do
    with_secret(socket, id, {:value, value_id}, fn socket, secret, value ->
      assign(socket,
        dialog: :rename_value,
        secret: secret,
        value: value,
        form: value_form(Ecto.Changeset.change(value))
      )
    end)
  end

  defp open(socket, :delete_value, %{"id" => id, "value_id" => value_id}) do
    with_secret(socket, id, {:value, value_id}, fn socket, secret, value ->
      if length(secret.values) > 1,
        do: assign(socket, dialog: :delete_value, secret: secret, value: value),
        else: back(socket, :error, last_value(secret))
    end)
  end

  defp open(socket, :delete_secret, %{"id" => id}) do
    with_secret(socket, id, nil, fn socket, secret, _value ->
      assign(socket, dialog: :delete_secret, secret: secret)
    end)
  end

  defp open(socket, :new_variable, _params) do
    if socket.assigns.may_edit,
      do:
        assign(socket,
          dialog: :new_variable,
          form: variable_form(fresh(Variables.change_variable(%Variable{})))
        ),
      else: refused(socket)
  end

  defp open(socket, :variable_targets, %{"id" => id}) do
    with_variable(socket, id, :read, fn socket, variable ->
      assign(socket, dialog: :variable_targets, variable: variable, target_q: "")
    end)
  end

  defp open(socket, :change_variable, %{"id" => id}) do
    with_variable(socket, id, :edit, fn socket, variable ->
      assign(socket,
        dialog: :change_variable,
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
        else: assign(socket, dialog: action, variable: variable)
    end)
  end

  defp open(socket, :delete_variable, %{"id" => id}) do
    with_variable(socket, id, :edit, fn socket, variable ->
      assign(socket, dialog: :delete_variable, variable: variable)
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

  def handle_event("create_secret", %{"secret" => params}, socket) when is_map(params) do
    scope = socket.assigns.current_scope

    case Secrets.create_secret(scope, Map.take(params, ~w(name note value value_id))) do
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
        %{assigns: %{dialog: :add_value}} = socket
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
        %{assigns: %{dialog: :change_value}} = socket
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
               gettext("%{value_id} of %{name} is changed.",
                 value_id: value.value_id,
                 name: secret.name
               ),
             else: gettext("The value of %{name} is changed.", name: secret.name)
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
        %{assigns: %{dialog: :rename_value}} = socket
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

  def handle_event("delete_value", _params, %{assigns: %{dialog: :delete_value}} = socket) do
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

  def handle_event("delete_secret", _params, %{assigns: %{dialog: :delete_secret}} = socket) do
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
        %{assigns: %{dialog: :change_variable}} = socket
      )
      when is_map(params) do
    %{current_scope: scope, variable: variable} = socket.assigns

    case Variables.update_variable(scope, variable, %{"value" => params["value"]}) do
      {:ok, variable} ->
        {:noreply, saved(socket, gettext("%{name} is changed.", name: variable.name), :variables)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, variable_form(changeset))}

      {:error, reason} ->
        {:noreply, refusal(socket, reason, :variables)}
    end
  end

  def handle_event(event, _params, %{assigns: %{dialog: dialog}} = socket)
      when {event, dialog} in [
             {"lock_variable", :lock_variable},
             {"unlock_variable", :unlock_variable},
             {"delete_variable", :delete_variable}
           ] do
    %{current_scope: scope, variable: variable} = socket.assigns

    result =
      case event do
        "lock_variable" -> Variables.lock_variable(scope, variable)
        "unlock_variable" -> Variables.unlock_variable(scope, variable)
        "delete_variable" -> Variables.delete_variable(scope, variable)
      end

    case result do
      {:ok, variable} ->
        {:noreply, saved(socket, variable_done(event, variable.name), :variables)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, refusal(socket, changeset, :variables)}

      {:error, reason} ->
        {:noreply, refusal(socket, reason, :variables)}
    end
  end

  # A change without its dialog open: a second click of a button whose dialog has closed,
  # or an event the page offers no control for. One who may change the view is shown the
  # list again; one who may not is refused, as a path the page offers no button for is.
  def handle_event(event, _params, socket)
      when event in ~w(add_value set_value rename_value delete_value delete_secret) do
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

  defp variable_done("lock_variable", name), do: gettext("%{name} is locked.", name: name)
  defp variable_done("unlock_variable", name), do: gettext("%{name} is unlocked.", name: name)
  defp variable_done("delete_variable", name), do: gettext("%{name} is deleted.", name: name)

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

  defp refusal(socket, {:in_use, uses}, view),
    do:
      back(
        socket,
        :error,
        gettext("%{name} is used by %{uses}: unlink it there first.",
          name: socket.assigns.secret.name,
          uses: uses |> Enum.map(& &1.name) |> Enum.uniq() |> Enum.join(", ")
        ),
        view
      )

  defp refusal(socket, :last_value, view),
    do: back(socket, :error, last_value(socket.assigns.secret), view)

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

  # A lock or an unlock refused on what the lock asks: said, the list read again.
  defp refusal(socket, %Ecto.Changeset{} = changeset, view) do
    message =
      Enum.map_join(changeset.errors, " ", fn {_field, error} -> translate_error(error) end)

    back(socket, :error, gettext("Not saved: %{reason}", reason: message), view)
  end

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

  defp last_value(secret),
    do:
      gettext(
        "%{name} has one value, which goes only with the secret: delete the secret instead.",
        name: secret.name
      )

  defp value_gone(secret),
    do: gettext("That value is no longer in %{name}.", name: secret.name)

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
