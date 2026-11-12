defmodule ApiaryProWeb.SettingsLive.Secrets do
  @moduledoc """
  Organisation settings › Secrets and variables, its Secrets tab: the organisation's
  secrets by name, note and value ID; never a value. Among them, the keys of the model
  providers added for every workspace.
  """

  # The first tab of the organisation settings' Secrets and variables section, in the
  # frame's second column (`ApiaryWeb.SettingsComponents.sections/2`,
  # `ApiaryWeb.PageComponents.settings_page/1`), at `/:org/settings/secrets`; the
  # Variables tab is
  # `ApiaryProWeb.SettingsLive.Variables`
  # (`ApiaryProWeb.SettingsLive.SecretsAndVariables`). The core keeps the secrets
  # (`Apiary.Secrets`, the organisation's level) and asks the edition who may
  # (`ApiaryPro.OrganisationSecrets`); the page asks the same.
  #
  # **Two kinds of row, two features.** The organisation's secrets and the Variables tab
  # need the `organisation_variables` feature. The keys of the organisation's model providers
  # (`Apiary.Secrets.list_provider_keys/2`, `:organisation`) need the features `factory`
  # and `secrets`, and show without `organisation_variables`: then the page lists the keys
  # alone, with no Variables tab and no New secret; the search and the Filter menu stay over
  # the key rows. A key row shows its provider's name and "Model provider key", and a mask
  # on each value's line, never the key. Add value, Change value, Rename value and Delete
  # value write it as the provider's key (`Apiary.Connections.add_provider_key/3` to
  # `Apiary.Connections.delete_provider_key/3`), under `provider.write`; Delete secret is
  # refused while the provider links the secret, and Edit name and note is not offered. The
  # rows are for whoever reads the organisation's secrets, or changes the keys
  # (`provider.write`); a member has neither, and does not open the page.
  #
  # It is laid out as the core's workspace Secrets tab (`ApiaryWeb.SecretLive.Index`),
  # with the core's words but where the texts name the organisation: New secret beside a
  # search, a Filter menu (Values: One value, Several values) and Sort, the filters in
  # force as tokens, all in the URL (`ApiaryWeb.SecretLive.Query`); one status line that
  # says what a search left; then the table, each secret with its note, its value IDs, who
  # changed it and when, and what uses it; never a value. Nothing opens over the page:
  # each act is at a separate path, a form a separate page
  # (`ApiaryWeb.PageComponents.page_form/1`), and a deletion asks to confirm in place, on
  # its row (`CoreComponents.inline_confirm/1`). A confirmation the core refuses stays
  # open and says why under its question.
  #
  # A value is written into a field and sent once: the page never renders it, nor keeps it
  # in an assign, so the field is empty after a save and after a refused one.
  #
  # Owners and admins change them. A reader reads them: no control, and one line that says
  # who changes them; a suspended organisation's are read only, as the notice above the
  # page says. Where the organisation has neither the feature `organisation_variables` nor
  # the features `factory` and `secrets`, the page is not there.

  use ApiaryProWeb, :live_view
  use ApiaryWeb.Features, :secrets
  on_mount {ApiaryWeb.Access, :"connection.read"}

  alias Apiary.{Access, Connections, Secrets}
  alias Apiary.Connections.Connection
  alias Apiary.Secrets.{Secret, Value}
  alias ApiaryPro.{OrganisationSecrets, OrganisationVariables}
  alias ApiaryProWeb.SettingsLive.SecretsAndVariables
  alias ApiaryWeb.{People, SettingsComponents, UserAuth}
  alias ApiaryWeb.SecretLive.Query

  # The acts that are a page of the section; the deletions ask to confirm on their row.
  @pages [:new_secret, :edit_secret, :add_value, :change_value, :rename_value]

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
        id="secret-page"
        title={form_title(assigns)}
        cancel={list_path(@current_scope, @query)}
        cancel_by="patch"
      >
        <:description>
          {form_sentence(assigns)}
          <span :if={@act == :new_secret} id="secret-levels" class="block">
            {levels_sentence()}
          </span>
        </:description>
        <.not_on_runs id="secrets-not-in-runs">
          {gettext("A run receives only its security policy.")}
        </.not_on_runs>
        <.form_page {assigns} />
      </.page_form>
    </Layouts.app>
    """
  end

  # The section: its title and sentence, the line on the two levels, the line that a run
  # receives only its security policy, who changes them, New secret beside the search,
  # Filter and Sort, and the list, as the core's Secrets tab has them. One status line,
  # there from the start, says what a search or a filter left.
  def render(assigns) do
    assigns =
      assign(assigns,
        tokens: Query.tokens(assigns.query),
        shown: Query.secrets(assigns.secrets, assigns.query)
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
          :if={@variables_shown}
          organisation={@current_scope.organisation}
          current={:secrets}
          secrets={length(@secrets)}
          variables={@variables_count}
        />

        <div id="secrets-tabs-panel" class="grid gap-5">
          <div class="-mt-2 grid gap-1">
            <p id="secrets-levels" class="text-[13px]/5 text-muted">{levels_sentence()}</p>

            <.not_on_runs id="secrets-not-in-runs">
              {gettext("A run receives only its security policy.")}
            </.not_on_runs>

            <p
              :if={!@may_write && !@may_write_keys && !@suspended}
              id="secrets-read-only"
              class="text-[13px]/5 text-muted"
            >
              {only_admins_change(@current_scope)}
            </p>
          </div>

          <.secrets_bar {assigns} />

          <%!-- Always there, so a screen reader hears the tab it came to from
               Variables and what a search or a filter left. Out of sight unless one
               narrows the list. --%>
          <div
            id="secrets-status"
            role="status"
            class={["q-status", !(Query.narrowed?(@query) && @secrets != []) && "sr-only"]}
          >
            <span :if={@switched} class="sr-only">
              {SecretsAndVariables.switch_words(:secrets, length(@secrets))}
            </span>
            <p :if={Query.narrowed?(@query) && @secrets != []} class="text-[13px] text-muted">
              {ngettext("%{number} secret matches", "%{number} secrets match", length(@shown),
                number: Format.number(length(@shown))
              )}
            </p>
          </div>

          <.secrets_list {assigns} />
        </div>
      </.settings_page>
    </Layouts.app>
    """
  end

  # New secret, beside the search, the Filter and Sort while there are any, and the
  # filters in force under them: the core's Secrets tab's bar.
  defp secrets_bar(assigns) do
    ~H"""
    <div :if={@may_write || @secrets != []} class="q-bar">
      <.button :if={@may_write} id="new-secret" variant="primary" patch={new_path(@current_scope)}>
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
          patch={list_path(@current_scope, Query.toggle(@query, {:values, values}))}
          checked={@query.values == values}
        >
          {words}
        </.menu_item>
      </.filter_menu>
      <.sort_menu :if={@secrets != []} id="secrets-sort" current={sort_words(@query.sort)}>
        <.menu_item
          :for={sort <- [:name, :changed]}
          id={"secrets-sort-#{sort}"}
          patch={list_path(@current_scope, %{@query | sort: sort})}
          checked={@query.sort == sort}
        >
          {sort_words(sort)}
        </.menu_item>
      </.sort_menu>
    </div>

    <.filter_tokens id="secrets-tokens" clear={list_path(@current_scope, Query.clear(@query))}>
      <:token
        :for={token <- @tokens}
        id={"secrets-token-#{elem(token, 0)}"}
        patch={list_path(@current_scope, Query.toggle(@query, token))}
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
      <.empty_state icon="hero-lock-closed" tone="neutral" title={gettext("No secrets yet")}>
        {secret_sentence()}
        <:actions :if={@may_write}>
          <.button patch={new_path(@current_scope)}>{gettext("New secret")}</.button>
        </:actions>
      </.empty_state>
    </div>

    <div :if={@secrets != [] && @shown == []} id="secrets-no-match">
      <.empty_state icon={nil} tone="neutral" title={gettext("No secret matches")}>
        <:actions>
          <.button id="secrets-clear" patch={list_path(@current_scope, Query.clear(@query))}>
            {gettext("Clear the search")}
          </.button>
        </:actions>
      </.empty_state>
    </div>

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
              <span class="q-title font-mono" title={secret.name}>{secret.name}</span>
              <span :if={secret.note} class="q-side" title={secret.note}>{secret.note}</span>
              <span
                :if={@keys[secret.id]}
                id={"#{row_id(row)}-provider"}
                class="q-side"
                title={@keys[secret.id].name}
              >
                {@keys[secret.id].name}
              </span>
            </span>
          <% {:value, secret, value} -> %>
            <span class="flex items-center gap-1.5 pl-4 text-[12.5px] font-normal text-muted">
              <.icon name="hero-arrow-turn-down-right-micro" class="size-3.5 text-faint" />
              <span class="font-mono" id={"#{row_id(row)}-value-id"}>{value.value_id}</span>
              <span :if={@keys[secret.id]} class="font-mono text-faint" aria-hidden="true">
                ••••••••••••
              </span>
            </span>
        <% end %>
      </:col>
      <:col :let={row} label={gettext("Values")}>
        <%= case row do %>
          <% {:secret, secret} -> %>
            {values_words(secret, @keys)}
          <% {:value, _secret, _value} -> %>
        <% end %>
      </:col>
      <:col :let={row} label={gettext("Changed")} from="sm">
        <.changed
          changed={changed_of(row)}
          people={@people}
          reader={@current_scope.user.email}
        />
      </:col>
      <:col :let={row} label={gettext("Used by")} from="sm">
        <%= case row do %>
          <% {:secret, secret} -> %>
            <span
              :if={Map.get(@uses, secret.id, []) == []}
              id={"#{row_id(row)}-used-by"}
              class="q-faint"
            >
              {gettext("Not used")}
            </span>
            <span
              :if={Map.get(@uses, secret.id, []) != []}
              id={"#{row_id(row)}-used-by"}
              class="q-cut"
              title={used_by(@uses, secret)}
            >
              {used_by(@uses, secret)}
            </span>
          <% {:value, _secret, _value} -> %>
        <% end %>
      </:col>
      <:action :let={row}>
        <.secret_menu
          :if={if key_row?(row, @keys), do: @may_write_keys, else: @may_write}
          row={row}
          scope={@current_scope}
          key={key_row?(row, @keys)}
        />
      </:action>
      <:confirm :let={row}>
        <.secret_confirm row={row} refusal={@refusal} cancel={list_path(@current_scope, @query)} />
      </:confirm>
    </.table>
    """
  end

  # How many values a secret has; for a model provider's keys, after "Model provider key".
  defp values_words(%Secret{values: [%Value{value_id: nil}]}, _keys), do: gettext("One value")

  defp values_words(%Secret{} = secret, keys) do
    count =
      ngettext("%{number} value", "%{number} values", length(secret.values),
        number: Format.number(length(secret.values))
      )

    if Map.has_key?(keys, secret.id),
      do: Enum.join([gettext("Model provider key"), count], " · "),
      else: count
  end

  # Whether the row is of a model provider's keys, which `provider.write` changes.
  defp key_row?({:secret, secret}, keys), do: Map.has_key?(keys, secret.id)
  defp key_row?({:value, secret, _value}, keys), do: Map.has_key?(keys, secret.id)

  # A secret is one row; a secret with several values, or one value with a value id, has
  # a line under it for each value, with the value's acts.
  defp secret_rows(secrets) do
    Enum.flat_map(secrets, fn
      %Secret{values: [%Value{value_id: nil}]} = secret -> [{:secret, secret}]
      %Secret{} = secret -> [{:secret, secret} | Enum.map(secret.values, &{:value, secret, &1})]
    end)
  end

  defp row_id({:secret, secret}), do: "secret-#{secret.public_id}"
  defp row_id({:value, secret, value}), do: "secret-#{secret.public_id}-#{value.value_id}"

  # What uses the secret, each name once: its Used by cell, and that cell's title, which
  # holds the names whole where the cell cuts them.
  defp used_by(uses, secret),
    do: uses |> Map.get(secret.id) |> Enum.map(& &1.name) |> Enum.uniq() |> Enum.join(", ")

  # Who changed what the row shows last, and when: a value's change, or for a secret of
  # one value that value's, else the secret's.
  defp changed_of({:value, _secret, value}), do: %{at: value.updated_at, by: value.updated_by_id}

  defp changed_of({:secret, %Secret{values: [%Value{value_id: nil} = value]}}),
    do: %{at: value.updated_at, by: value.updated_by_id}

  defp changed_of({:secret, secret}), do: %{at: secret.updated_at, by: secret.updated_by_id}

  attr :changed, :map, required: true, doc: "when, and by whose user id"
  attr :people, :map, required: true
  attr :reader, :string, required: true, doc: "the reader's address"

  # The time, and who: the first letter of their account's address, with the address as
  # its tooltip, whether or not they are a member of the organisation, or "Former member"
  # for a deleted one; the time alone for no one.
  defp changed(assigns) do
    assigns =
      assign(assigns,
        at: assigns.changed.at,
        by: People.account(assigns.people, assigns.changed.by)
      )

    ~H"""
    <span class="tabular-nums">
      <%= if @by do %>
        <.rich text={
          rich_gettext("%{time} by %{person}",
            time: {:part, :time},
            person: letter(@by, @reader)
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

  attr :row, :any, required: true
  attr :scope, :any, required: true
  attr :key, :boolean, default: false, doc: "a model provider's keys, whose name stays"

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
        :if={!@key}
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

  ## The pages of a form

  # New secret: its name, then the Values choice, one value or several, each with a value
  # ID. The choice shows the fields of one or of the other, and "Add another value" adds a
  # row, in the browser alone (the core's `SecretValues` hook): nothing is sent before
  # Save, and the fields of the choice not taken are not sent then.
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
      <.page_form_foot id="secret-save" cancel={list_path(@current_scope, @query)} cancel_by="patch">
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
      <.page_form_foot id="secret-save" cancel={list_path(@current_scope, @query)} cancel_by="patch">
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
      <.page_form_foot id="secret-save" cancel={list_path(@current_scope, @query)} cancel_by="patch">
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
      <.page_form_foot id="secret-save" cancel={list_path(@current_scope, @query)} cancel_by="patch">
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
      <.page_form_foot id="secret-save" cancel={list_path(@current_scope, @query)} cancel_by="patch">
        <.button variant="primary" type="submit" loading_text={gettext("Saving")}>
          {gettext("Rename value")}
        </.button>
      </.page_form_foot>
    </.form>
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

  # The breadcrumb's last segment: the act alone.
  defp crumb_words(:new_secret), do: gettext("New secret")
  defp crumb_words(:edit_secret), do: gettext("Edit name and note")
  defp crumb_words(:add_value), do: gettext("Add value")
  defp crumb_words(:change_value), do: gettext("Change value")
  defp crumb_words(:rename_value), do: gettext("Rename value")

  # The one sentence under the title; New secret's is followed by the line on the two
  # levels (`render/1`).
  defp form_sentence(%{act: :new_secret}), do: secret_sentence()

  defp form_sentence(%{act: :edit_secret}),
    do: gettext("Its values stay as they are; only its name and what it is for change.")

  defp form_sentence(%{act: :add_value}),
    do: gettext("A secret with several values names each one with a value ID.")

  defp form_sentence(%{act: :change_value}),
    do: gettext("The value it holds now is not shown.")

  defp form_sentence(%{act: :rename_value}),
    do: gettext("The value stays as it is; only its value ID changes.")

  # What a secret is, on the empty view and on the page that makes one.
  defp secret_sentence,
    do:
      gettext(
        "A secret holds one value, such as a token, or several under one name, such as one per app. Once a value is saved, nobody sees it again."
      )

  # That a workspace's secret is another, whatever its name: nothing finds a secret by its
  # name across the two levels.
  defp levels_sentence,
    do:
      gettext(
        "A workspace's secret with the same name is a different secret: neither one replaces the other."
      )

  ## The confirmations in place

  # The row that asks to confirm: a secret's, or one of its values'.
  defp secret_confirming(:delete_secret, %Secret{} = secret, _value),
    do: row_id({:secret, secret})

  defp secret_confirming(:delete_value, %Secret{} = secret, %Value{} = value),
    do: row_id({:value, secret, value})

  defp secret_confirming(_act, _secret, _value), do: nil

  attr :row, :any, required: true
  attr :refusal, :string, default: nil, doc: "why the core refused it, once it did"
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

  attr :id, :string, required: true
  attr :refusal, :string, default: nil

  # Why the core refused what a confirmation asked, under its question, in the open
  # confirmation: said as it comes, and the focus left on the button that acted.
  defp refusal_line(assigns) do
    ~H"""
    <span :if={@refusal} id={@id} role="alert" class="block font-medium text-error-soft-content">
      {@refusal}
    </span>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :label, :string, default: nil
  attr :focus, :boolean, default: false, doc: "whether the field takes the focus as it mounts"
  attr :disabled, :boolean, default: false, doc: "off while its choice is not taken"

  # The value of a secret: written, sent once, and never rendered back. The field's value
  # is always empty, whatever the form holds.
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

  # A value ID shown again as it was sent, when it was text; anything else a request could
  # carry is not.
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

  ## Words

  defp sort_words(:name), do: gettext("Name")
  defp sort_words(:changed), do: gettext("Recently changed")

  defp token_words({:values, :one}), do: gettext("One value")
  defp token_words({:values, :several}), do: gettext("Several values")

  ## Paths

  # The list, with its search, its filter and its order in the URL
  # (`ApiaryWeb.SecretLive.Query`).
  defp list_path(scope, %Query{} = query) do
    base = ~p"/#{scope.organisation}/settings/secrets"

    case Query.to_params(query) do
      [] -> base
      params -> base <> "?" <> URI.encode_query(params)
    end
  end

  defp new_path(scope), do: ~p"/#{scope.organisation}/settings/secrets/new"

  defp secret_path(scope, secret, :change_value),
    do: ~p"/#{scope.organisation}/settings/secrets/#{secret.public_id}/change-value"

  defp secret_path(scope, secret, :edit),
    do: ~p"/#{scope.organisation}/settings/secrets/#{secret.public_id}/edit"

  defp secret_path(scope, secret, :add_value),
    do: ~p"/#{scope.organisation}/settings/secrets/#{secret.public_id}/add-value"

  defp secret_path(scope, secret, :delete),
    do: ~p"/#{scope.organisation}/settings/secrets/#{secret.public_id}/delete"

  defp value_path(scope, secret, value, :change),
    do:
      ~p"/#{scope.organisation}/settings/secrets/#{secret.public_id}/values/#{value.value_id}/change"

  defp value_path(scope, secret, value, :rename),
    do:
      ~p"/#{scope.organisation}/settings/secrets/#{secret.public_id}/values/#{value.value_id}/rename"

  defp value_path(scope, secret, value, :delete),
    do:
      ~p"/#{scope.organisation}/settings/secrets/#{secret.public_id}/values/#{value.value_id}/delete"

  ## Mount, and the paths of the pages and the confirmations

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    # The Variables tab's count follows every change of the variables.
    if connected?(socket), do: OrganisationVariables.subscribe(scope)

    socket =
      socket
      |> assign(
        query: %Query{},
        act: nil,
        secret: nil,
        provider: nil,
        value: nil,
        form: nil,
        refusal: nil,
        switched: false
      )
      |> mays()

    case read(scope) do
      {:ok, data} -> {:ok, socket |> assign(data) |> say_switch()}
      {:error, _reason} -> raise ApiaryWeb.NotFound
    end
  end

  # Come from the Variables tab, the status line says so once the page is up: said into
  # the line already there, a screen reader hears it.
  defp say_switch(socket) do
    if SecretsAndVariables.switched?(socket, :variables), do: send(self(), :switched)
    socket
  end

  defp mays(socket) do
    scope = socket.assigns.current_scope

    assign(socket,
      sections: SettingsComponents.sections(scope, :organisation),
      may_write: OrganisationSecrets.may(scope, :write) == :ok,
      may_write_keys: Access.can?(scope, :"provider.write", scope.organisation),
      secrets_open: OrganisationSecrets.shown?(scope),
      suspended: ApiaryPro.Access.suspended?(scope)
    )
  end

  # Everything the list shows, read again after every change. The secrets are the
  # organisation's, where the edition lets the person read them, then the keys of its model
  # providers, where the features `factory` and `secrets` are shown; `keys` has each
  # provider by its keys' secret's row id. A person who reads the secrets or changes the
  # keys gets the keys; one who does neither is refused.
  defp read(scope) do
    open? = OrganisationSecrets.shown?(scope)

    with {:ok, secrets} <- organisation_secrets(scope, open?),
         {:ok, keys} <- provider_keys(scope, open?),
         {:ok, uses} <- uses(scope, secrets),
         {:ok, variables} <- variables(scope, open?) do
      all = secrets ++ Enum.map(keys, & &1.secret)

      {:ok,
       %{
         secrets: all,
         keys: Map.new(keys, &{&1.secret.id, &1.provider}),
         uses: Map.merge(uses, Map.new(keys, &{&1.secret.id, [%{name: &1.provider.name}]})),
         people: people(all),
         variables_count: length(variables),
         variables_shown: open?
       }}
    end
  end

  defp organisation_secrets(scope, true), do: Secrets.list_organisation_secrets(scope)
  defp organisation_secrets(_scope, false), do: {:ok, []}

  # The keys of the model providers added for every workspace. Where the person reads the
  # organisation's secrets, none is the answer to a refusal; where they read nothing else, the
  # refusal is.
  defp provider_keys(scope, open?) do
    if open? or Access.can?(scope, :"provider.write", scope.organisation) do
      case Secrets.list_provider_keys(scope, :organisation) do
        {:ok, keys} -> {:ok, keys}
        {:error, _reason} when open? -> {:ok, []}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_found}
    end
  end

  # What uses the organisation's secrets, asked of the core for the secrets alone: the core
  # answers none for the keys of a model provider, which their provider uses, and the page
  # names it in their place.
  defp uses(_scope, []), do: {:ok, %{}}
  defp uses(scope, secrets), do: Secrets.list_uses(scope, secrets)

  defp variables(scope, true), do: OrganisationVariables.list(scope)
  defp variables(_scope, false), do: {:ok, []}

  # user id => email, of the accounts that changed a secret or a value, read in one query
  # (`ApiaryWeb.People.accounts/1`).
  defp people(secrets) do
    secrets
    |> Enum.flat_map(fn secret ->
      [secret.updated_by_id | Enum.map(secret.values, & &1.updated_by_id)]
    end)
    |> People.accounts()
  end

  # The list read again. Refused, the scope is read again with what the reader may: a
  # membership that is gone sends the page to `/`; one that may no longer read the
  # secrets (an admin made a member, or the feature taken away) is sent to the
  # organisation's settings, rather than kept on a list it no longer reads.
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
          gettext("The secrets of %{organisation} are no longer open to you.",
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
      |> assign(act: nil, secret: nil, provider: nil, value: nil, form: nil, refusal: nil)
      |> then(&if(action == :index, do: assign(&1, :query, query(params)), else: &1))
      |> open(action, params)

    {:noreply, titled(socket)}
  end

  # The list's search, Values filter and order, from the URL; the variables' filters are
  # the workspace tab's, and left out here.
  defp query(params), do: Query.for_secrets(Query.from_params(params))

  # The browser's title, the most specific first (`SettingsComponents.page_title/3`): a
  # page of a form is named by its title, the list, the section's first tab, by the
  # section.
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
          SecretsAndVariables.title()
        ])
      )

  defp open(socket, :index, _params), do: socket

  defp open(socket, :new_secret, _params) do
    unless socket.assigns.secrets_open, do: raise(ApiaryWeb.NotFound)

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

  # A model provider's keys keep their name: no edit of it.
  defp open(socket, :edit_secret, %{"id" => id}) do
    with_secret(
      socket,
      id,
      nil,
      fn socket, secret, _value ->
        assign(socket,
          act: :edit_secret,
          secret: secret,
          form: secret_form(fresh(Secrets.change_secret(secret)))
        )
      end,
      false
    )
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

  # The organisation's secret of the path, for one who may change it, and the value it
  # names: `nil` for none, `{:value, nil}` for the secret's one value without a value id.
  # With `keys`, a model provider's keys too, its provider assigned as `provider`, changed by
  # one who may `provider.write`.
  defp with_secret(socket, id, which, fun, keys \\ true) do
    with {:ok, secret, provider} <- secret_of(socket, id, keys),
         true <- may_change?(socket, provider) || {:refused, provider},
         {:ok, value} <- value_of(secret, which) do
      fun.(assign(socket, :provider, provider), secret, value)
    else
      {:refused, provider} -> refused(socket, provider)
      {:error, :no_value, secret} -> back(socket, :error, value_gone(secret))
      {:error, _closed} when not socket.assigns.secrets_open -> raise ApiaryWeb.NotFound
      {:error, :forbidden} -> unauthorized(socket)
      {:error, _not_found} -> refusal(socket, :not_found)
    end
  end

  # The organisation's secret `id`, with nil, or, with `keys`, a model provider's keys with
  # their provider.
  defp secret_of(socket, id, keys) do
    scope = socket.assigns.current_scope

    case Secrets.get_organisation_secret(scope, id) do
      {:ok, secret} ->
        {:ok, secret, nil}

      {:error, reason} when keys ->
        case Enum.find(provider_key_list(scope), &(&1.secret.public_id == id)) do
          %{secret: secret, provider: provider} -> {:ok, secret, provider}
          nil -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The keys of the organisation's model providers, for the page's readers; none for
  # anyone else, or where they are not shown.
  defp provider_key_list(scope) do
    case provider_keys(scope, OrganisationSecrets.shown?(scope)) do
      {:ok, keys} -> keys
      {:error, _reason} -> []
    end
  end

  defp may_change?(socket, nil), do: socket.assigns.may_write
  defp may_change?(socket, %Connection{}), do: socket.assigns.may_write_keys

  defp value_of(_secret, nil), do: {:ok, nil}

  defp value_of(secret, {:value, value_id}) do
    case Enum.find(secret.values, &(&1.value_id == value_id)) do
      %Value{} = value -> {:ok, value}
      nil -> {:error, :no_value, secret}
    end
  end

  @impl true
  def handle_info(:switched, socket), do: {:noreply, assign(socket, :switched, true)}

  def handle_info({:organisation_variables_changed, _change}, socket),
    do: {:noreply, reload(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  ## Events

  # An event the page's controls never send is refused in silence, before any clause
  # reads it (`sent?/2`): the page stays up, so no crash report prints the event, and a
  # secret's value in it with the rest of its terms.
  @impl true
  def handle_event(event, params, socket) do
    if sent?(event, params), do: handle(event, params, socket), else: {:noreply, socket}
  end

  # Whether an event and its parameters are what the page's controls send: a form's
  # fields, under the form's key, each a string; the search's `q`, a string; a
  # confirmation's button, nothing the page reads. So every clause below, and all it
  # calls, is given strings, as the forms give them. New secret's values are a map of rows
  # by index, each a map: a field of a row that is not text is refused under its field, as
  # `Apiary.Secrets.create_organisation_secret/2` casts it.
  defp sent?("find", %{"q" => q}), do: is_binary(q)

  defp sent?("create_secret", %{"secret" => %{} = fields}),
    do: strings?(Map.delete(fields, "values")) and rows?(fields["values"])

  defp sent?("update_secret", %{"secret" => fields}), do: strings?(fields)

  defp sent?(event, %{"secret_value" => fields})
       when event in ~w(add_value set_value rename_value),
       do: strings?(fields)

  defp sent?(event, _params) when event in ~w(delete_value delete_secret), do: true
  defp sent?(_event, _params), do: false

  defp strings?(%{} = fields), do: Enum.all?(fields, fn {_key, field} -> is_binary(field) end)
  defp strings?(_fields), do: false

  defp rows?(nil), do: true
  defp rows?(%{} = rows), do: Enum.all?(rows, fn {_index, row} -> is_map(row) end)
  defp rows?(_rows), do: false

  # The search is the URL's `q`, sent as the reader types.
  defp handle("find", %{"q" => q}, socket) do
    query = %{socket.assigns.query | q: String.trim(q)}

    {:noreply,
     push_patch(socket, to: list_path(socket.assigns.current_scope, query), replace: true)}
  end

  # One value, or several, each with its value ID: only the fields of the choice taken are
  # read, and a refused save shows the form again, its errors under their fields and every
  # value empty, to write again.
  defp handle(
         "create_secret",
         %{"secret" => params},
         %{assigns: %{act: :new_secret}} = socket
       )
       when is_map(params) do
    scope = socket.assigns.current_scope
    kind = if params["values_kind"] == "several", do: "several", else: "one"

    attrs =
      if kind == "several",
        do: params |> Map.take(~w(name note)) |> Map.put("values", params["values"] || %{}),
        else: Map.take(params, ~w(name note value))

    case Secrets.create_organisation_secret(scope, attrs) do
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

  defp handle(
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

  defp handle(
         "add_value",
         %{"secret_value" => params},
         %{assigns: %{act: :add_value}} = socket
       )
       when is_map(params) do
    %{current_scope: scope, secret: secret, provider: provider} = socket.assigns
    params = Map.take(params, ~w(value_id value first_value_id))

    added =
      if provider,
        do: Connections.add_provider_key(scope, provider, Map.delete(params, "first_value_id")),
        else: Secrets.add_value(scope, secret, params)

    case added do
      {:ok, _secret_or_provider} ->
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

  defp handle(
         "set_value",
         %{"secret_value" => params},
         %{assigns: %{act: :change_value}} = socket
       )
       when is_map(params) do
    %{current_scope: scope, secret: secret, value: value, provider: provider} = socket.assigns

    set =
      if provider,
        do: Connections.set_provider_key(scope, provider, value.value_id, params["value"]),
        else: Secrets.set_value(scope, secret, value.value_id, params["value"])

    case set do
      {:ok, _secret_or_provider} ->
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

  defp handle(
         "rename_value",
         %{"secret_value" => params},
         %{assigns: %{act: :rename_value}} = socket
       )
       when is_map(params) do
    %{current_scope: scope, secret: secret, value: value, provider: provider} = socket.assigns

    renamed =
      if provider,
        do: Connections.rename_provider_key(scope, provider, value.value_id, params["value_id"]),
        else: Secrets.rename_value(scope, secret, value.value_id, params["value_id"])

    case renamed do
      {:ok, _secret_or_provider} ->
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

  defp handle("delete_value", _params, %{assigns: %{act: :delete_value}} = socket) do
    %{current_scope: scope, secret: secret, value: value, provider: provider} = socket.assigns

    deleted =
      if provider,
        do: Connections.delete_provider_key(scope, provider, value.value_id),
        else: Secrets.delete_value(scope, secret, value.value_id)

    case deleted do
      {:ok, _secret_or_provider} ->
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

  # A model provider's keys go only with their provider: refused while it links them.
  defp handle("delete_secret", _params, %{assigns: %{act: :delete_secret}} = socket) do
    %{current_scope: scope, secret: secret, provider: provider} = socket.assigns

    if provider do
      {:noreply,
       held(
         socket,
         gettext(
           "Change or add a value instead. Model provider %{provider} uses this secret, so it cannot be deleted.",
           provider: provider.name
         )
       )}
    else
      case Secrets.delete_secret(scope, secret) do
        {:ok, secret} ->
          {:noreply, saved(socket, gettext("%{name} is deleted.", name: secret.name))}

        {:error, reason} ->
          {:noreply, refusal(socket, reason)}
      end
    end
  end

  # A change without its page or its confirmation open: a second click of a button whose
  # confirmation has gone, or an event the page offers no control for. One who may change
  # the secrets is shown the list again; one who may not is refused, as a path the page
  # offers no button for is.
  defp handle(event, _params, socket)
       when event in ~w(create_secret update_secret add_value set_value rename_value delete_value delete_secret) do
    if socket.assigns.may_write or socket.assigns.may_write_keys,
      do: {:noreply, reload(socket)},
      else: {:noreply, refused(socket)}
  end

  ## After a change, and its refusals

  # Saved: the list read again, back on it, the page and its field gone.
  defp saved(socket, words), do: back(socket, :info, words)

  # A secret's deletion or a value's, refused while what it deletes stays: its
  # confirmation stays open and says why.
  defp refusal(socket, {:in_use, uses}),
    do:
      held(
        socket,
        gettext("%{name} is used by %{uses}: unlink it there first.",
          name: socket.assigns.secret.name,
          uses: uses |> Enum.map(& &1.name) |> Enum.uniq() |> Enum.join(", ")
        )
      )

  defp refusal(socket, :last_value), do: held(socket, last_value(socket.assigns.secret))

  defp refusal(socket, :too_many_values),
    do:
      back(
        socket,
        :error,
        gettext("A secret holds at most %{number} values.",
          number: Format.number(Secrets.max_values())
        )
      )

  defp refusal(socket, :key_unavailable),
    do:
      back(
        socket,
        :error,
        gettext(
          "The values of %{organisation}'s secrets cannot be read. %{contact_support}.",
          organisation: socket.assigns.current_scope.organisation.name,
          contact_support: ApiaryWeb.Support.plain()
        )
      )

  # Not found: the secret is gone, or the organisation's secrets are out of reach (the
  # feature taken away, the organisation marked for deletion), which reading the list
  # again finds out.
  defp refusal(socket, :not_found) do
    socket = reload_scope(socket)

    if socket.redirected,
      do: socket,
      else:
        back(
          socket,
          :error,
          gettext("That secret is no longer in %{organisation}.",
            organisation: socket.assigns.current_scope.organisation.name
          )
        )
  end

  defp refusal(socket, :forbidden), do: unauthorized(socket)

  # Any other refusal: a deletion's changeset (a form's is answered under its fields), or
  # a reason no clause above names. A deletion's confirmation stays open and says why; a
  # form's page goes back to the list and says it in the flash.
  defp refusal(socket, reason) do
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

    if deleting?, do: held(socket, words), else: back(socket, :error, words)
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

  # A change its confirmation asked for, refused while what it acts on stays: the list
  # read again, and the confirmation still open, saying why under its question
  # (`refusal_line/1`). Nothing mounts again, so the focus stays on the button that acted.
  defp held(socket, words), do: socket |> reload() |> assign(:refusal, words)

  # Back to the list, with a word, the list read again.
  defp back(socket, kind, words) do
    socket
    |> put_flash(kind, words)
    |> reload()
    |> then(fn socket ->
      if socket.redirected,
        do: socket,
        else:
          push_patch(socket, to: list_path(socket.assigns.current_scope, socket.assigns.query))
    end)
  end

  # A path or an event for a change the reader may not make, which the page offers no
  # control for: a reader is told they read the organisation, a suspended organisation's
  # people that it is suspended, anyone else who changes the secrets.
  defp refused(socket, provider \\ nil) do
    scope = socket.assigns.current_scope

    words =
      cond do
        Access.reader(scope) ->
          ApiaryWeb.Access.reads_only(scope)

        socket.assigns.suspended ->
          gettext("%{name} is suspended.", name: scope.organisation.name)

        provider ->
          ApiaryWeb.Access.who_may(scope, :"provider.write", only_admins_change(scope))

        true ->
          only_admins_change(scope)
      end

    back(socket, :error, words)
  end

  defp only_admins_change(scope),
    do:
      gettext("Only owners and admins of %{organisation} change its secrets.",
        organisation: scope.organisation.name
      )

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

  # A form of a secret or a value: the changeset the core handed back holds no value
  # (`Apiary.Secrets.change_secret/2`), and the field is marked as used, so an error on
  # the value shows under it, without the value. A value's changeset loses its stored
  # nonce and ciphertext too, and the new ones a refused change made, so no ciphertext
  # stays in an assign.
  defp secret_form(changeset), do: changeset |> used_value() |> to_form(as: "secret")

  defp value_form(changeset),
    do: changeset |> as_value() |> used_value() |> to_form(as: "secret_value")

  # A refusal of a model provider's keys comes on the provider's changeset
  # (`Apiary.Connections`): its errors go on a value's, under the same fields.
  defp as_value(%Ecto.Changeset{data: %Connection{}} = changeset),
    do: %{Ecto.Changeset.change(%Value{}) | errors: changeset.errors, valid?: false}

  defp as_value(changeset), do: changeset

  defp used_value(%Ecto.Changeset{} = changeset) do
    changeset = used(changeset)
    params = Map.put(changeset.params, "value", "")
    changes = Map.drop(changeset.changes, [:value, :nonce, :ciphertext])
    %{changeset | params: params, changes: changes, data: without_ciphertext(changeset.data)}
  end

  defp without_ciphertext(%Value{} = value), do: %{value | nonce: nil, ciphertext: nil}
  defp without_ciphertext(data), do: data

  # A form as its page opens: nothing is typed yet, so nothing is wrong yet.
  defp fresh(%Ecto.Changeset{} = changeset), do: %{changeset | errors: [], valid?: true}

  # A field with an error is a used one, so the error shows under it, however the
  # changeset came to have it: the core's check adds an error to a changeset that may have
  # no params for the field, nor an action.
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
