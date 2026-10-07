defmodule ApiaryWeb.IntegrationLive.Index do
  @moduledoc """
  Workspace settings › Integrations (`/:org/:workspace/settings/integrations`), with the
  `security` feature: what the workspace sets up for its runs, which `Apiary.Connections`
  calls connections, in four parts, each a list whose row leads to its page
  (`ApiaryWeb.IntegrationLive.Show`, `ApiaryWeb.IntegrationLive.Definition`):

    * **Runtimes**, from Apiary's catalogue (`Apiary.Kinds.Runtimes`);
    * **Integrations**, each added from a release on github.com, gitlab.com or
      codeberg.org, or at an https address while the instance accepts one
      (`Apiary.Integrations.Source`);
    * **Services**, each naming a service definition, built in (`Apiary.Kinds.Services`)
      or the workspace's own;
    * **Service definitions**, the workspace's own.

  Each says where it applies: every target, or the chosen ones. No run receives any of
  this yet, and the page says so once, at its top.

  The forms are pages of the section, at paths of their own, never a dialog: Add
  integration (`…/add`), which asks for a release and leads to it
  (`ApiaryWeb.IntegrationLive.Release`), New runtime (`…/new-runtime`) and New service
  (`…/new-service`). Every member reads the section; owners and admins change it
  (`connection.write`), and a reader who may not sees no control and one line saying who
  does. The context functions ask again.
  """
  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :security
  on_mount {ApiaryWeb.Access, :"connection.read"}

  alias Apiary.{Connections, Integrations}
  alias Apiary.Integrations.Source
  alias Apiary.Kinds.{Runtimes, Services}
  alias ApiaryWeb.IntegrationLive.Common
  alias ApiaryWeb.SettingsComponents

  @forms [:add_integration, :new_runtime, :new_service]
  @forges ~w(github.com gitlab.com codeberg.org)

  @impl true
  def render(%{live_action: action} = assigns) when action in @forms do
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
      <:crumb navigate={Common.settings_path(@current_scope)}>{gettext("Settings")}</:crumb>
      <:crumb navigate={Common.index_path(@current_scope)}>{gettext("Integrations")}</:crumb>
      <:crumb>{form_title(@live_action)}</:crumb>

      <.page_form
        id={form_id(@live_action)}
        title={form_title(@live_action)}
        cancel={Common.index_path(@current_scope)}
      >
        <:description>{form_sentence(@live_action)}</:description>
        <Common.not_yet />
        <.form_body {assigns} />
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
      <.settings_page
        heading={gettext("Workspace settings")}
        section={:integrations}
        title={gettext("Integrations")}
        measure="list"
      >
        <:subtitle>
          {gettext(
            "The runtimes, integrations and services set up in this workspace, and where each applies."
          )}
        </:subtitle>
        <:actions :if={@may_write}>
          <.button id="add-integration" variant="primary" navigate={Common.add_path(@current_scope)}>
            <.icon name="hero-plus-micro" class="size-4" />{gettext("Add integration")}
          </.button>
        </:actions>

        <Common.not_yet />
        <p :if={!@may_write} id="integrations-readonly" class="text-[13px]/5 text-muted">
          {Common.only_admins()}
        </p>

        <SettingsComponents.part
          id="runtimes-part"
          title={gettext("Runtimes")}
          count={length(@runtimes)}
        >
          <p class="text-[13px]/5 text-muted">
            {gettext("The agents a run can start, from Apiary's catalogue.")}
          </p>
          <.table
            :if={@runtimes != []}
            id="runtimes"
            label={gettext("Runtimes")}
            rows={@runtimes}
            row_id={&"connection-#{&1.public_id}"}
          >
            <:col :let={connection} label={gettext("Runtime")} kind="title">
              <.name_cell connection={connection} scope={@current_scope} />
            </:col>
            <:col :let={connection} label={gettext("Applies to")}>
              {Common.applies_word(connection)}
            </:col>
          </.table>
          <p :if={@runtimes == []} id="runtimes-empty" class="text-[13px]/5 text-faint">
            {gettext("No runtime is set up.")}
          </p>
          <div :if={@may_write}>
            <.button id="new-runtime" size="xs" navigate={Common.new_runtime_path(@current_scope)}>
              {gettext("New runtime")}
            </.button>
          </div>
        </SettingsComponents.part>

        <SettingsComponents.part
          id="integrations-part"
          title={gettext("Integrations")}
          count={length(@integrations)}
        >
          <p class="text-[13px]/5 text-muted">
            {gettext(
              "Programs their publishers release on github.com, gitlab.com or codeberg.org, or at an https address."
            )}
          </p>
          <.table
            :if={@integrations != []}
            id="integrations"
            label={gettext("Integrations")}
            rows={@integrations}
            row_id={&"connection-#{&1.public_id}"}
          >
            <:col :let={connection} label={gettext("Integration")} kind="title">
              <span class="grid">
                <.name_cell connection={connection} scope={@current_scope} />
                <span class="q-mono text-[12.5px]/[18px] font-normal text-muted">
                  {connection.source}
                </span>
              </span>
            </:col>
            <:col :let={connection} label={gettext("Version")} from="sm">
              <span class="q-mono">{connection.version}</span>
            </:col>
            <:col :let={connection} label={gettext("Applies to")}>
              {Common.applies_word(connection)}
            </:col>
          </.table>
          <p :if={@integrations == []} id="integrations-empty" class="text-[13px]/5 text-faint">
            {gettext("No integration is added.")}
          </p>
        </SettingsComponents.part>

        <SettingsComponents.part
          id="services-part"
          title={gettext("Services")}
          count={length(@services)}
        >
          <p class="text-[13px]/5 text-muted">
            {gettext(
              "APIs a run may call with a stored secret, each set up from a service definition."
            )}
          </p>
          <.table
            :if={@services != []}
            id="services"
            label={gettext("Services")}
            rows={@services}
            row_id={&"connection-#{&1.public_id}"}
          >
            <:col :let={connection} label={gettext("Service")} kind="title">
              <.name_cell connection={connection} scope={@current_scope} />
            </:col>
            <:col :let={connection} label={gettext("Definition")} from="sm">
              <.definition_word connection={connection} definitions={@definitions} />
            </:col>
            <:col :let={connection} label={gettext("Applies to")}>
              {Common.applies_word(connection)}
            </:col>
          </.table>
          <p :if={@services == []} id="services-empty" class="text-[13px]/5 text-faint">
            {gettext("No service is set up.")}
          </p>
          <div :if={@may_write}>
            <.button id="new-service" size="xs" navigate={Common.new_service_path(@current_scope)}>
              {gettext("New service")}
            </.button>
          </div>
        </SettingsComponents.part>

        <SettingsComponents.part
          id="definitions-part"
          title={gettext("Service definitions")}
          count={length(@definitions)}
        >
          <p class="text-[13px]/5 text-muted">
            {gettext(
              "This workspace's own service definitions, beside the %{count} built into Apiary: %{names}.",
              count: length(Services.list()),
              names: Enum.map_join(Services.list(), ", ", & &1["title"])
            )}
          </p>
          <.table
            :if={@definitions != []}
            id="definitions"
            label={gettext("Service definitions")}
            rows={@definitions}
            row_id={&"definition-#{&1.public_id}"}
          >
            <:col :let={definition} label={gettext("Definition")} kind="title">
              <span class="grid">
                <.link
                  navigate={Common.definition_path(@current_scope, definition)}
                  class="q-title hover:underline"
                >
                  {definition.title}
                </.link>
                <span class="q-mono text-[12.5px]/[18px] font-normal text-muted">
                  {definition.key}
                </span>
              </span>
            </:col>
            <:col :let={definition} label={gettext("Hosts")} from="sm">
              <span class="q-mono">
                {Enum.join(Apiary.Connections.ServiceDefinition.decoded(definition)["hosts"], ", ")}
              </span>
            </:col>
          </.table>
          <p :if={@definitions == []} id="definitions-empty" class="text-[13px]/5 text-faint">
            {gettext("This workspace has no service definition of its own.")}
          </p>
          <div :if={@may_write}>
            <.button
              id="new-definition"
              size="xs"
              navigate={Common.definition_path(@current_scope, :new)}
            >
              {gettext("New service definition")}
            </.button>
          </div>
        </SettingsComponents.part>
      </.settings_page>
    </Layouts.app>
    """
  end

  attr :connection, :any, required: true
  attr :scope, :any, required: true

  defp name_cell(assigns) do
    ~H"""
    <span class="inline-flex flex-wrap items-baseline gap-x-2">
      <.link navigate={Common.connection_path(@scope, @connection)} class="q-title hover:underline">
        {@connection.name}
      </.link>
      <.state_word
        :if={!@connection.intact}
        id={"connection-#{@connection.public_id}-intact"}
        hot
        tone="error"
      >
        {gettext("Fails its integrity check")}
      </.state_word>
    </span>
    """
  end

  attr :connection, :any, required: true
  attr :definitions, :list, required: true

  defp definition_word(%{connection: %{service_builtin: key}} = assigns) when is_binary(key) do
    assigns =
      assign(assigns,
        title:
          case Services.fetch(key) do
            {:ok, definition} -> definition["title"]
            :error -> key
          end
      )

    ~H"""
    {@title} <span class="text-faint">· {gettext("built in")}</span>
    """
  end

  defp definition_word(assigns) do
    assigns =
      assign(
        assigns,
        :definition,
        Enum.find(assigns.definitions, &(&1.id == assigns.connection.service_definition_id))
      )

    ~H"""
    <span :if={@definition}>{@definition.title}</span>
    """
  end

  ## The forms

  defp form_body(%{live_action: :add_integration} = assigns) do
    ~H"""
    <.form for={@form} id="add-integration-form" phx-change="validate" phx-submit="request" novalidate>
      <div class="grid gap-4">
        <.input
          field={@form[:where]}
          type="radio"
          label={gettext("Where it is released")}
          options={where_options(@url_sources)}
        />
        <%= if @form[:where].value == "url" do %>
          <.input
            field={@form[:url]}
            type="url"
            label={gettext("Address of its description.json")}
            placeholder="https://"
            hint={
              gettext(
                "An https address, such as https://example.com/shop/description.json. The release's other files are beside it."
              )
            }
            autocomplete="off"
          />
        <% else %>
          <.input
            field={@form[:path]}
            label={
              if @form[:where].value == "gitlab.com",
                do: gettext("Project path"),
                else: gettext("Repository")
            }
            prefix={(@form[:where].value || "github.com") <> "/"}
            placeholder={
              if @form[:where].value == "gitlab.com", do: "group/project", else: "owner/repo"
            }
            hint={
              if @form[:where].value == "gitlab.com",
                do: gettext("The project's full path, its groups included."),
                else: nil
            }
            autocomplete="off"
          />
          <.input
            field={@form[:version]}
            label={gettext("Version")}
            placeholder="1.4.0"
            hint={gettext("The version of a release, such as 1.4.0.")}
            autocomplete="off"
          />
        <% end %>
        <.page_form_foot id="add-integration-save" cancel={Common.index_path(@current_scope)}>
          <.button type="submit" variant="primary" loading_text={gettext("Asking")}>
            {gettext("Fetch the release")}
          </.button>
          <:note>
            {gettext(
              "Apiary reads the release's description.json and checksums.txt, and runs nothing of it. You add it once it is read."
            )}
          </:note>
        </.page_form_foot>
      </div>
    </.form>
    """
  end

  defp form_body(%{live_action: :new_runtime} = assigns) do
    assigns = assign(assigns, :runtime, chosen_runtime(assigns.form[:runtime].value))

    ~H"""
    <.form for={@form} id="new-runtime-form" phx-change="validate" phx-submit="create" novalidate>
      <div class="grid gap-4">
        <.input
          field={@form[:runtime]}
          type="select"
          label={gettext("Runtime")}
          options={for runtime <- Runtimes.list(), do: {runtime.title, runtime.name}}
        />
        <div :if={@runtime} id="runtime-catalogue" class="grid gap-1 text-[13px]/5 text-muted">
          <p>
            {gettext("It declares these secrets: %{names}.",
              names: Enum.map_join(@runtime.declares, ", ", &"#{&1["title"]} (#{&1["name"]})")
            )}
          </p>
          <p :if={Runtimes.hosts(@runtime) != []}>
            {gettext("It sets them on %{hosts}.", hosts: Enum.join(Runtimes.hosts(@runtime), ", "))}
          </p>
        </div>
        <.applies_input form={@form} />
        <.page_form_foot id="new-runtime-save" cancel={Common.index_path(@current_scope)}>
          <.button type="submit" variant="primary" loading_text={gettext("Saving")}>
            {gettext("Set up runtime")}
          </.button>
        </.page_form_foot>
      </div>
    </.form>
    """
  end

  defp form_body(%{live_action: :new_service} = assigns) do
    assigns =
      assign(assigns, :chosen, chosen_definition(assigns.form[:definition].value, assigns))

    ~H"""
    <.form for={@form} id="new-service-form" phx-change="validate" phx-submit="create" novalidate>
      <div class="grid gap-4">
        <.input
          field={@form[:definition]}
          type="select"
          label={gettext("Service definition")}
          options={definition_options(@definitions)}
        />
        <div :if={@chosen} id="service-definition-about" class="grid gap-1 text-[13px]/5 text-muted">
          <p :if={@chosen["description"]}>{@chosen["description"]}</p>
          <p>{gettext("It reaches %{hosts}.", hosts: Enum.join(@chosen["hosts"], ", "))}</p>
        </div>
        <.input
          field={@form[:name]}
          label={gettext("Name")}
          optional
          hint={gettext("The definition's title, unless you give it another.")}
          autocomplete="off"
        />
        <.applies_input form={@form} />
        <.page_form_foot id="new-service-save" cancel={Common.index_path(@current_scope)}>
          <.button type="submit" variant="primary" loading_text={gettext("Saving")}>
            {gettext("Set up service")}
          </.button>
        </.page_form_foot>
      </div>
    </.form>
    """
  end

  attr :form, :any, required: true

  defp applies_input(assigns) do
    ~H"""
    <.input
      field={@form[:applies_to]}
      type="radio"
      label={gettext("Applies to")}
      options={[{gettext("Every target"), "all"}, {gettext("Chosen targets"), "selected"}]}
      hint={gettext("You choose the targets on its page, once it is set up.")}
    />
    """
  end

  defp where_options(url_sources?) do
    forges = for host <- @forges, do: {host, host}
    if url_sources?, do: forges ++ [{gettext("An https address"), "url"}], else: forges
  end

  defp definition_options(definitions) do
    built_in =
      for definition <- Services.list(),
          do:
            {gettext("%{title} (built in)", title: definition["title"]),
             "builtin:" <> definition["key"]}

    own = for definition <- definitions, do: {definition.title, "own:" <> definition.public_id}
    built_in ++ own
  end

  defp chosen_runtime(name) do
    case Runtimes.fetch(name) do
      {:ok, runtime} -> runtime
      :error -> nil
    end
  end

  defp chosen_definition("builtin:" <> key, _assigns) do
    case Services.fetch(key) do
      {:ok, definition} -> definition
      :error -> nil
    end
  end

  defp chosen_definition("own:" <> id, assigns) do
    case Enum.find(assigns.definitions, &(&1.public_id == id)) do
      nil -> nil
      definition -> Apiary.Connections.ServiceDefinition.decoded(definition)
    end
  end

  defp chosen_definition(_value, _assigns), do: nil

  defp form_id(:add_integration), do: "add-integration-page"
  defp form_id(:new_runtime), do: "new-runtime-page"
  defp form_id(:new_service), do: "new-service-page"

  defp form_title(:add_integration), do: gettext("Add integration")
  defp form_title(:new_runtime), do: gettext("New runtime")
  defp form_title(:new_service), do: gettext("New service")

  defp form_sentence(:add_integration),
    do:
      gettext(
        "Name the release of an integration: Apiary fetches its description, and you add it from there."
      )

  defp form_sentence(:new_runtime), do: gettext("Set up a runtime of Apiary's catalogue.")

  defp form_sentence(:new_service),
    do: gettext("Set up a service from a built-in definition or one of this workspace's own.")

  ## Mount, the list and the forms

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(
       sections: SettingsComponents.sections(scope, :workspace),
       may_write: Common.may_write?(scope),
       url_sources: Source.url_sources?(),
       form: nil
     )
     |> load()}
  end

  defp load(socket) do
    scope = socket.assigns.current_scope

    with {:ok, connections} <- Connections.list_connections(scope),
         {:ok, definitions} <- Connections.list_service_definitions(scope) do
      assign(socket,
        connections: connections,
        runtimes: Enum.filter(connections, &(&1.kind == "runtime")),
        integrations: Enum.filter(connections, &(&1.kind == "integration")),
        services: Enum.filter(connections, &(&1.kind == "service")),
        definitions: definitions
      )
    else
      {:error, _reason} -> raise ApiaryWeb.NotFound
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    action = socket.assigns.live_action

    cond do
      action == :index ->
        {:noreply, assign(socket, form: nil, page_title: title(gettext("Integrations")))}

      socket.assigns.may_write ->
        {:noreply,
         assign(socket, form: fresh_form(action), page_title: title(form_title(action)))}

      true ->
        {:noreply,
         socket
         |> put_flash(:error, Common.only_admins())
         |> push_patch(to: Common.index_path(socket.assigns.current_scope))}
    end
  end

  defp title(words), do: words <> " · " <> gettext("Workspace settings")

  defp fresh_form(:add_integration),
    do:
      to_form(%{"where" => "github.com", "path" => "", "version" => "", "url" => ""},
        as: :release
      )

  defp fresh_form(:new_runtime),
    do: to_form(%{"runtime" => hd(Runtimes.list()).name, "applies_to" => "all"}, as: :connection)

  defp fresh_form(:new_service),
    do:
      to_form(
        %{
          "definition" => "builtin:" <> hd(Services.list())["key"],
          "name" => "",
          "applies_to" => "all"
        },
        as: :connection
      )

  @impl true
  def handle_event("validate", %{"release" => params}, socket),
    do: {:noreply, assign(socket, :form, to_form(params, as: :release))}

  def handle_event("validate", %{"connection" => params}, socket),
    do: {:noreply, assign(socket, :form, to_form(params, as: :connection))}

  def handle_event("request", %{"release" => params}, socket) do
    scope = socket.assigns.current_scope
    url? = params["where"] == "url"

    attrs =
      if url?,
        do: %{"source" => params["url"] || ""},
        else: %{
          "source" => "#{params["where"]}/#{String.trim(params["path"] || "")}",
          "version" => params["version"]
        }

    case Integrations.request_release(scope, attrs) do
      {:ok, release} ->
        {:noreply, push_navigate(socket, to: Common.release_path(scope, release.id))}

      {:error, %Ecto.Changeset{} = changeset} ->
        source_field = if url?, do: :url, else: :path

        errors =
          for {field, error} <- changeset.errors do
            {if(field == :source, do: source_field, else: field), error}
          end

        {:noreply, assign(socket, :form, to_form(params, as: :release, errors: errors))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Common.refusal(reason))}
    end
  end

  def handle_event("create", %{"connection" => params}, socket) do
    scope = socket.assigns.current_scope

    result =
      case socket.assigns.live_action do
        :new_runtime ->
          Connections.create_runtime(scope, %{
            runtime: params["runtime"],
            applies_to: params["applies_to"]
          })

        :new_service ->
          Connections.create_service(
            scope,
            Map.merge(definition_attrs(params["definition"]), %{
              name: params["name"],
              applies_to: params["applies_to"]
            })
          )
      end

    case result do
      {:ok, connection} ->
        to =
          if connection.applies_to == "selected",
            do: Common.connection_path(scope, connection, :targets),
            else: Common.connection_path(scope, connection)

        {:noreply,
         socket
         |> put_flash(:info, gettext("%{name} is set up.", name: connection.name))
         |> push_navigate(to: to)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, :form, to_form(params, as: :connection, errors: changeset.errors))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Common.refusal(reason, socket.assigns.connections))}
    end
  end

  defp definition_attrs("builtin:" <> key), do: %{service: key}
  defp definition_attrs("own:" <> id), do: %{definition_id: id}
  defp definition_attrs(_value), do: %{}
end
