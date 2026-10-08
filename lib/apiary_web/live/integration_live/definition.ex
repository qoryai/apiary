defmodule ApiaryWeb.IntegrationLive.Definition do
  @moduledoc """
  The workspace's own custom APIs, its service definitions in `Apiary.Connections`' words,
  under Workspace settings › Integrations, with the `security` feature: New custom API
  (`…/definitions/new`), one custom API (`…/definitions/:id`, its public id `svc_…`) with
  where it is set up, the APIs set up from it, its edit (`…/edit`), a page, and its
  deletion (`…/delete`), confirmed in place in its danger zone and refused while an API is
  set up from it. "Service definition" is not a word of the page.

  A custom API is written as JSON, the shape `Apiary.Kinds.ServiceDefinition` checks: its
  key, title, description, hosts, paths, auth and declared secrets. The page calls
  `Apiary.Connections.get_service_definition/2`, `create_service_definition/2`,
  `update_service_definition/3`, `delete_service_definition/2` and `list_connections/1`.
  The page says once that a run receives only its security policy.
  """
  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :security
  on_mount {ApiaryWeb.Access, :"connection.read"}

  alias Apiary.Connections
  alias Apiary.Connections.ServiceDefinition
  alias ApiaryWeb.IntegrationLive.Common
  alias ApiaryWeb.SettingsComponents

  # The most bytes of JSON a definition's form takes; more is refused before it is read.
  @json_max 65_536

  @example """
  {
    "version": 1,
    "key": "status-api",
    "title": "Status API",
    "hosts": ["status.example.com"],
    "auth": {"scheme": "bearer", "secret": "key"},
    "declares": [{"id": "key", "title": "API key", "name": "STATUS_API_KEY"}]
  }
  """

  @impl true
  def render(%{live_action: action} = assigns) when action in [:new, :edit] do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:settings}
      sections={@sections}
      section={:integrations}
    >
      <:crumb :if={@definition} navigate={Common.definition_path(@current_scope, @definition)}>
        {@definition.title}
      </:crumb>
      <:crumb>{form_title(@live_action)}</:crumb>

      <.page_form
        id="definition-page"
        title={form_title(@live_action)}
        cancel={cancel_path(@current_scope, @definition)}
      >
        <:description>
          {gettext(
            "A custom API says which hosts it is, how its secret is sent and which secrets it needs."
          )}
        </:description>
        <Common.not_on_runs />
        <.form for={@form} id="definition-form" phx-submit="save" novalidate>
          <div class="grid gap-4">
            <%!-- What is wrong with the JSON is the field's error, which describes it and
                 takes the focus after a save. --%>
            <.input
              id="definition_json"
              name="definition[json]"
              value={@form.params["json"]}
              errors={@problems}
              type="textarea"
              label={gettext("Definition")}
              rows="14"
              class="font-mono"
              spellcheck="false"
              phx-hook="FocusOn"
              hint={
                gettext(
                  "JSON: version 1, a key of lowercase letters, digits and hyphens, a title, 1 to 16 hosts, optional paths, its auth (bearer, header or basic) and the secrets it declares."
                )
              }
            />
            <.page_form_foot id="definition-save" cancel={cancel_path(@current_scope, @definition)}>
              <.button type="submit" variant="primary" loading_text={gettext("Saving")}>
                {if @live_action == :new,
                  do: gettext("Create custom API"),
                  else: gettext("Save custom API")}
              </.button>
              <:note :if={@live_action == :edit and @users != []}>
                {gettext("Every API set up from it takes the new definition.")}
              </:note>
            </.page_form_foot>
          </div>
        </.form>
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
      nav={:settings}
      sections={@sections}
      section={:integrations}
    >
      <:crumb>{@definition.title}</:crumb>

      <.settings_page
        section={:integrations}
        title={@definition.title}
        measure="list"
      >
        <:subtitle>
          {gettext("A custom API of this workspace's own")}
          <span class="text-faint" aria-hidden="true">·</span>
          <span class="q-mono">{@definition.key}</span>
        </:subtitle>
        <:actions :if={@may_write}>
          <.button
            id="edit-definition"
            navigate={Common.definition_path(@current_scope, @definition, :edit)}
          >
            {gettext("Edit")}
          </.button>
        </:actions>

        <Common.not_on_runs />

        <p :if={@decoded["description"]} id="definition-about" class="max-w-[72ch] text-[13.5px]/5">
          {@decoded["description"]}
        </p>

        <SettingsComponents.part id="definition-facts" title={gettext("About")}>
          <dl class="grid grid-cols-[max-content_minmax(0,1fr)] gap-x-4 gap-y-2 text-[13px]/5">
            <dt class="text-faint">{gettext("Key")}</dt>
            <dd class="q-mono">{@definition.key}</dd>
            <dt class="text-faint">{gettext("Id")}</dt>
            <dd class="q-mono">{@definition.public_id}</dd>
            <dt class="text-faint">{gettext("Hosts")}</dt>
            <dd class="q-mono">{Enum.join(@decoded["hosts"], ", ")}</dd>
            <dt :if={@decoded["paths"]} class="text-faint">{gettext("Paths")}</dt>
            <dd :if={@decoded["paths"]} class="q-mono">{Enum.join(@decoded["paths"], ", ")}</dd>
            <dt class="text-faint">{gettext("Auth")}</dt>
            <dd class="q-mono">
              {@decoded["auth"]["scheme"]}<span :if={@decoded["auth"]["header"]}> · {@decoded["auth"][
                "header"
              ]}</span>
            </dd>
            <dt class="text-faint">{gettext("Secrets it declares")}</dt>
            <dd>
              <span :for={declared <- @decoded["declares"]} class="block">
                <span class="q-mono">{declared["id"]}</span>
                <span class="text-muted">· {declared["title"]}</span>
                <span :if={declared["name"]} class="q-mono text-muted">· {declared["name"]}</span>
              </span>
            </dd>
            <dt class="text-faint">{gettext("Digest")}</dt>
            <dd class="q-mono break-all">{@definition.digest}</dd>
            <dt class="text-faint">{gettext("Added")}</dt>
            <dd>
              {Common.who(@people, @definition.created_by_id)}
              <span class="text-muted">· <.time_ago at={@definition.inserted_at} /></span>
            </dd>
            <dt class="text-faint">{gettext("Last changed")}</dt>
            <dd>
              {Common.who(@people, @definition.updated_by_id)}
              <span class="text-muted">· <.time_ago at={@definition.updated_at} /></span>
            </dd>
          </dl>
        </SettingsComponents.part>

        <SettingsComponents.part
          id="definition-users"
          title={gettext("Where it is set up")}
          count={length(@users)}
        >
          <ul :if={@users != []} class="q-plain-list">
            <li :for={service <- @users} id={"definition-user-#{service.public_id}"}>
              <.link
                navigate={Common.connection_path(@current_scope, service)}
                class="text-accent hover:underline"
              >
                {service.name}
              </.link>
            </li>
          </ul>
          <p :if={@users == []} class="text-[13px]/5 text-muted">
            {gettext("It isn't set up yet.")}
          </p>
        </SettingsComponents.part>

        <.code_block id="definition-json" label="definition.json" code={pretty(@definition)} />

        <SettingsComponents.danger_zone :if={@may_write}>
          <SettingsComponents.danger_action
            id="delete-definition"
            title={gettext("Delete this custom API")}
            button={gettext("Delete custom API…")}
            disabled={@users != []}
            open={@live_action == :delete}
            open_path={Common.definition_path(@current_scope, @definition, :delete)}
            close_path={Common.definition_path(@current_scope, @definition)}
            question={gettext("Delete %{title}?", title: @definition.title)}
            submit="delete"
          >
            <%= if @users == [] do %>
              {gettext("It is removed from this workspace. This cannot be undone.")}
            <% else %>
              {gettext("APIs are set up from it: remove them first.")}
            <% end %>
          </SettingsComponents.danger_action>
        </SettingsComponents.danger_zone>
      </.settings_page>
    </Layouts.app>
    """
  end

  defp form_title(:new), do: gettext("New custom API")
  defp form_title(:edit), do: gettext("Edit custom API")

  defp cancel_path(scope, nil), do: Common.index_path(scope)
  defp cancel_path(scope, definition), do: Common.definition_path(scope, definition)

  defp pretty(%ServiceDefinition{} = definition),
    do: definition |> ServiceDefinition.decoded() |> Jason.encode!(pretty: true)

  ## Mount and params

  @impl true
  def mount(params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(
       sections: SettingsComponents.sections(scope, :workspace),
       may_write: Common.may_write?(scope),
       people: Common.people(scope),
       problems: [],
       definition: nil,
       decoded: nil,
       users: [],
       form: nil
     )
     |> load(params["id"])}
  end

  defp load(socket, nil), do: socket

  defp load(socket, id) do
    scope = socket.assigns.current_scope

    with {:ok, definition} <- Connections.get_service_definition(scope, id),
         {:ok, connections} <- Connections.list_connections(scope) do
      assign(socket,
        definition: definition,
        decoded: ServiceDefinition.decoded(definition),
        users: Enum.filter(connections, &(&1.service_definition_id == definition.id))
      )
    else
      {:error, _reason} -> raise ApiaryWeb.NotFound
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    action = socket.assigns.live_action
    scope = socket.assigns.current_scope

    cond do
      action == :show ->
        {:noreply, assign(socket, page_title: title(scope, socket.assigns.definition.title))}

      not socket.assigns.may_write ->
        {:noreply,
         socket
         |> put_flash(:error, Common.only_admins(scope))
         |> push_navigate(to: cancel_path(scope, socket.assigns.definition))}

      action == :new ->
        {:noreply,
         assign(socket,
           form: to_form(%{"json" => @example}, as: :definition),
           problems: [],
           page_title: title(scope, form_title(:new))
         )}

      action == :edit ->
        {:noreply,
         assign(socket,
           form: to_form(%{"json" => pretty(socket.assigns.definition)}, as: :definition),
           problems: [],
           page_title: title(scope, form_title(:edit))
         )}

      action == :delete ->
        {:noreply, assign(socket, page_title: title(scope, socket.assigns.definition.title))}
    end
  end

  defp title(scope, words),
    do: SettingsComponents.page_title(scope, :workspace, [words, gettext("Integrations")])

  ## Events

  @impl true
  def handle_event(
        "save",
        %{"definition" => %{"json" => json} = params},
        %{assigns: %{live_action: action}} = socket
      )
      when action in [:new, :edit] and is_binary(json) and byte_size(json) > @json_max do
    {:noreply,
     refused(socket, params, [
       gettext("The definition is too long: it takes at most 64 KiB of JSON.")
     ])}
  end

  def handle_event(
        "save",
        %{"definition" => %{"json" => json} = params},
        %{assigns: %{live_action: action}} = socket
      )
      when action in [:new, :edit] and is_binary(json) do
    scope = socket.assigns.current_scope

    result =
      case action do
        :new -> Connections.create_service_definition(scope, json)
        :edit -> Connections.update_service_definition(scope, socket.assigns.definition, json)
      end

    case result do
      {:ok, definition} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("%{title} is saved.", title: definition.title))
         |> push_navigate(to: Common.definition_path(scope, definition))}

      {:error, {:definition_invalid, problems}} ->
        {:noreply, refused(socket, params, Common.definition_problems(problems))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         refused(
           socket,
           params,
           for {_field, error} <- changeset.errors do
             gettext("Its key %{error}.", error: translate_error(error))
           end
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Common.refusal(scope, reason))}
    end
  end

  def handle_event("delete", _params, %{assigns: %{definition: %ServiceDefinition{}}} = socket) do
    scope = socket.assigns.current_scope
    definition = socket.assigns.definition

    case Connections.delete_service_definition(scope, definition) do
      {:ok, _deleted} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("%{title} is deleted.", title: definition.title))
         |> push_navigate(to: Common.index_path(scope))}

      {:error, reason} ->
        connections =
          case Connections.list_connections(scope) do
            {:ok, connections} -> connections
            {:error, _} -> []
          end

        {:noreply, put_flash(socket, :error, Common.refusal(scope, reason, connections))}
    end
  end

  # An event the page's controls do not send, or sent where they are not: nothing.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # The form again, as it was sent, with what is wrong with it as the JSON field's error,
  # which takes the focus.
  defp refused(socket, params, problems) do
    socket
    |> assign(form: to_form(params, as: :definition), problems: problems)
    |> push_event("run:focus", %{id: "definition_json"})
  end
end
