defmodule ApiaryWeb.IntegrationLive.Index do
  @moduledoc """
  Workspace settings › Integrations (`/:org/:workspace/settings/integrations`), with the
  `security` feature, in two parts:

    * **Set up in this workspace**: one list of what the runs of the workspace use,
      which `Apiary.Connections` calls connections, in the order of the groups below,
      each row its name, its kind (Agent, API, or Program, one added from a release), a
      program's version and where it applies (For runs in), every target or the chosen
      ones, leading to its page (`ApiaryWeb.IntegrationLive.Show`);
    * **Add an integration** (`add_cards/1`): a card for each thing it can add, by name,
      in three groups, each a heading, one sentence of what a run gets from it and its
      own list: Agent, the runtimes of the runner's catalogue (`Apiary.Kinds.Runtimes`);
      APIs the agent may call, the built-in APIs (`Apiary.Kinds.Services`), the
      workspace's own custom APIs (`ApiaryWeb.IntegrationLive.Definition`) and Custom
      API…; Programs, the named releases (`ApiaryWeb.IntegrationLive.Named`) and From a
      release….

  It is all for the runs, none of it for Qory Apiary itself, and the page says so in its
  subtitle. No run uses any of it yet, and the page says so once, at its top.

  The forms are pages of the section, at paths of their own, never a dialog: Add from a
  release (`…/add`), which asks for a release and leads to it
  (`ApiaryWeb.IntegrationLive.Release`), Set up an agent (`…/new-runtime`) and Set up an
  API (`…/new-service`), each opened by a card with its item chosen (`?runtime=`,
  `?definition=builtin:…` or `own:…`; one that is not there opens the form as it starts).
  Every member reads the section; owners and admins change it (`connection.write`), and
  a reader who may not sees the list, no card, and one line saying who does. The context
  functions ask again.
  """
  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :security
  on_mount {ApiaryWeb.Access, :"connection.read"}

  alias Apiary.{Connections, Integrations}
  alias Apiary.Integrations.Source
  alias Apiary.Kinds.{Runtimes, Services}
  alias ApiaryWeb.IntegrationLive.{Common, Named}
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
        section={:integrations}
        title={gettext("Integrations")}
        measure="list"
      >
        <:subtitle>
          {gettext(
            "What the runs in this workspace use: the coding agent a run starts, and the outside APIs and programs it may reach. Not Qory's own settings. Each applies to every target or to the ones you choose."
          )}
        </:subtitle>

        <Common.not_yet />
        <p :if={!@may_write} id="integrations-readonly" class="text-[13px]/5 text-muted">
          {Common.only_admins(@current_scope)}
        </p>

        <SettingsComponents.part
          id="set-up-part"
          title={gettext("Set up in this workspace")}
          count={length(@connections)}
        >
          <.table
            :if={@connections != []}
            id="connections"
            label={gettext("Set up in this workspace")}
            rows={@connections}
            row_id={&"connection-#{&1.public_id}"}
          >
            <:col :let={connection} label={gettext("Name")} kind="title">
              <span class="grid">
                <.name_cell connection={connection} scope={@current_scope} />
                <span
                  :if={connection.source}
                  class="q-mono text-[12.5px]/[18px] font-normal text-muted"
                >
                  {connection.source}
                </span>
              </span>
            </:col>
            <:col :let={connection} label={gettext("Kind")}>
              {Common.kind_word(connection.kind)}
            </:col>
            <:col :let={connection} label={gettext("Version")} from="sm">
              <span :if={connection.version} class="q-mono">{connection.version}</span>
            </:col>
            <:col :let={connection} label={Common.applies_label()}>
              {Common.applies_word(connection)}
            </:col>
          </.table>
          <p :if={@connections == []} id="connections-empty" class="text-[13px]/5 text-faint">
            {gettext("Nothing is set up in this workspace yet.")}
          </p>
        </SettingsComponents.part>

        <.add_cards
          :if={@may_write}
          scope={@current_scope}
          definitions={@definitions}
          url_sources={@url_sources}
        />
      </.settings_page>
    </Layouts.app>
    """
  end

  @doc """
  add_cards/1 is the part "Add an integration": a card for each thing the workspace can
  add, by name, each its kind as a small word, one line about what a run gets from it and
  the act that adds it. The cards are in three groups, each an `<h3>`, one sentence and a
  list of its own, labelled by its heading:

    * **Agent** (`#add-group-agent`): the runtimes of the runner's catalogue
      (`Apiary.Kinds.Runtimes`);
    * **APIs the agent may call** (`#add-group-apis`): the built-in APIs
      (`Apiary.Kinds.Services`), the workspace's own custom APIs, each its name leading to
      its page, then Custom API…;
    * **Programs** (`#add-group-programs`): the named releases
      (`ApiaryWeb.IntegrationLive.Named`), then From a release….

  A card's act opens the form with its item chosen; an agent or an API may be set up more
  than once, so a card stays as it is once it is set up. The runner's design that the
  agent never holds a token is said for APIs and programs, never for the agent, whose
  model credential the runner may give it.
  """
  attr :scope, :any, required: true
  attr :definitions, :list, required: true, doc: "the workspace's own service definitions"
  attr :url_sources, :boolean, required: true

  attr :named, :list,
    default: nil,
    doc: "the named releases; `ApiaryWeb.IntegrationLive.Named.list/0` where none is given"

  def add_cards(assigns) do
    assigns = assign(assigns, :named, assigns.named || Named.list())

    ~H"""
    <SettingsComponents.part id="add-part" title={gettext("Add an integration")}>
      <div id="add-cards" class="grid gap-6">
        <.add_group
          id="add-group-agent"
          title={gettext("Agent")}
          about={gettext("The coding agent a run starts in the targets it applies to.")}
        >
          <.add_card
            :for={runtime <- Runtimes.list()}
            id={"add-card-runtime-#{runtime.name}"}
            title={runtime.title}
            kind={gettext("Agent")}
            about={runtime_line(runtime)}
            act={gettext("Set up")}
            navigate={Common.new_runtime_path(@scope, runtime.name)}
          />
        </.add_group>
        <.add_group
          id="add-group-apis"
          title={gettext("APIs the agent may call")}
          about={
            gettext(
              "Outside APIs the agent reaches while it works. The runner adds the API's token to the agent's requests, so the agent never holds it."
            )
          }
        >
          <.add_card
            :for={definition <- Services.list()}
            id={"add-card-api-#{definition["key"]}"}
            title={definition["title"]}
            kind={gettext("API")}
            about={api_line(definition)}
            act={gettext("Set up")}
            navigate={Common.new_service_path(@scope, "builtin:" <> definition["key"])}
          />
          <.add_card
            :for={definition <- @definitions}
            id={"add-card-own-#{definition.public_id}"}
            title={definition.title}
            title_navigate={Common.definition_path(@scope, definition)}
            kind={gettext("Custom API")}
            about={own_line(definition)}
            act={gettext("Set up")}
            navigate={Common.new_service_path(@scope, "own:" <> definition.public_id)}
          />
          <.add_card
            id="add-card-custom-api"
            title={gettext("Custom API…")}
            about={
              gettext("Describe another API the agent may call: its hosts and how its token is sent.")
            }
            act={gettext("New custom API")}
            act_id="new-definition"
            navigate={Common.definition_path(@scope, :new)}
          />
        </.add_group>
        <.add_group
          id="add-group-programs"
          title={gettext("Programs")}
          about={
            gettext(
              "Programs their publishers release. The runner starts one outside the agent to get the run a short-lived token, such as GitHub's for the run's targets."
            )
          }
        >
          <.add_card
            :for={named <- @named}
            id={"add-card-named-#{slug(named.source)}"}
            title={named.name}
            source={named.source}
            kind={gettext("Program")}
            about={named.about}
            act={gettext("Set up")}
            navigate={Common.add_path(@scope, source: named.source)}
          />
          <.add_card
            id="add-card-release"
            title={gettext("From a release…")}
            about={
              if @url_sources,
                do:
                  gettext(
                    "Add a program its publisher releases on github.com, gitlab.com or codeberg.org, or at an https address."
                  ),
                else:
                  gettext(
                    "Add a program its publisher releases on github.com, gitlab.com or codeberg.org."
                  )
            }
            act={gettext("Add from a release")}
            act_id="add-integration"
            navigate={Common.add_path(@scope)}
          />
        </.add_group>
      </div>
    </SettingsComponents.part>
    """
  end

  # One group of cards: its heading, one sentence of what a run gets from it, and its
  # cards as a list of their own, which its heading names.
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :about, :string, required: true
  slot :inner_block, required: true

  defp add_group(assigns) do
    ~H"""
    <div id={@id} class="grid min-w-0 gap-2">
      <div class="grid gap-0.5">
        <h3 id={"#{@id}-title"} class="text-[13px]/5 font-semibold">{@title}</h3>
        <p id={"#{@id}-about"} class="max-w-[72ch] text-[13px]/5 text-muted">{@about}</p>
      </div>
      <ul
        id={"#{@id}-cards"}
        role="list"
        aria-labelledby={"#{@id}-title"}
        class="grid grid-cols-[repeat(auto-fill,minmax(min(100%,14rem),1fr))] gap-3"
      >
        {render_slot(@inner_block)}
      </ul>
    </div>
    """
  end

  # One card: its name (a link to its page where it has one), its source in mono beneath
  # where it has one, its kind, one line about it and its act. An act named for every card
  # alike, Set up, says the card's name to a screen reader.
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :title_navigate, :string, default: nil
  attr :source, :string, default: nil
  attr :kind, :string, default: nil
  attr :about, :string, default: nil
  attr :act, :string, required: true
  attr :act_id, :string, default: nil
  attr :navigate, :string, required: true

  defp add_card(assigns) do
    ~H"""
    <li id={@id} class="card card-border min-w-0 gap-2 bg-base-100 p-4 shadow-xs">
      <div class="grid gap-0.5">
        <h4 id={"#{@id}-title"} class="text-[14px]/5 font-semibold break-words">
          <.link :if={@title_navigate} navigate={@title_navigate} class="hover:underline">
            {@title}
          </.link>
          <span :if={!@title_navigate}>{@title}</span>
        </h4>
        <span :if={@source} class="q-mono text-[12.5px]/[18px] break-all text-muted">
          {@source}
        </span>
        <span :if={@kind} id={"#{@id}-kind"} class="text-[12px]/4 text-muted">{@kind}</span>
      </div>
      <p :if={@about} class="text-[13px]/5 text-muted">{@about}</p>
      <div class="mt-auto pt-1">
        <.button id={@act_id || "#{@id}-act"} size="xs" navigate={@navigate}>
          {@act}<span :if={@kind} class="sr-only">{" " <> @title}</span>
        </.button>
      </div>
    </li>
    """
  end

  # The line under an agent's name: the catalogue has no description, so the console
  # says what a run gets from each of its runtimes; one it doesn't know yet, what it is.
  defp runtime_line(%{name: "claude"}),
    do:
      gettext(
        "Runs start Anthropic's coding agent, with an Anthropic API key or a Claude OAuth credential."
      )

  defp runtime_line(_runtime), do: gettext("A coding agent the runner can start.")

  # The line under a built-in API's name: what the agent may do with it, said by the
  # console; one it doesn't know yet, its definition's description, which its page keeps
  # as its About.
  defp api_line(%{"key" => "sentry"}),
    do: gettext("The agent may call Sentry's API on sentry.io, such as to read issues.")

  defp api_line(%{"key" => "npm"}),
    do: gettext("The agent may install and publish packages on registry.npmjs.org.")

  defp api_line(definition), do: definition["description"]

  # The line under a custom API's name: its description, else its hosts.
  defp own_line(definition) do
    decoded = Apiary.Connections.ServiceDefinition.decoded(definition)

    decoded["description"] ||
      gettext("Its hosts: %{hosts}.", hosts: Enum.join(decoded["hosts"], ", "))
  end

  # A named release's source as part of an id: `github.com/acme/tracker` is
  # `github-com-acme-tracker`.
  defp slug(source), do: source |> String.replace(~r/[^A-Za-z0-9]+/, "-") |> String.trim("-")

  attr :connection, :any, required: true
  attr :scope, :any, required: true

  defp name_cell(assigns) do
    ~H"""
    <span class="inline-flex flex-wrap items-baseline gap-x-2">
      <.link navigate={Common.connection_path(@scope, @connection)} class="q-title hover:underline">
        <Common.name names={@connection} />
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
        <%= if @form[:where].value == "url" and @url_sources do %>
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
            prefix={forge(@form[:where].value) <> "/"}
            placeholder={
              if @form[:where].value == "gitlab.com", do: "group/project", else: "owner/repo"
            }
            hint={
              if @form[:where].value == "gitlab.com",
                do: gettext("The project's full path, its groups included."),
                else: gettext("Its owner and name, such as acme/shop-integration.")
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
              "Only its description.json and checksums.txt are read, and nothing of it runs on the server. You add it once they are read."
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
          label={gettext("Agent")}
          options={for runtime <- Runtimes.list(), do: {runtime.title, runtime.name}}
          aria-describedby="runtime-catalogue"
        />
        <div :if={@runtime} id="runtime-catalogue" class="grid gap-1 text-[13px]/5 text-muted">
          <p>
            {gettext("It declares these secrets: %{names}.",
              names: Enum.map_join(@runtime.declares, ", ", &"#{&1["title"]} (#{&1["name"]})")
            )}
          </p>
          <p :if={Runtimes.hosts(@runtime) != []}>
            {gettext("Its hosts: %{hosts}.", hosts: Enum.join(Runtimes.hosts(@runtime), ", "))}
          </p>
        </div>
        <.applies_input form={@form} />
        <.page_form_foot id="new-runtime-save" cancel={Common.index_path(@current_scope)}>
          <.button type="submit" variant="primary" loading_text={gettext("Saving")}>
            {gettext("Set up agent")}
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
          label={gettext("API")}
          options={definition_options(@definitions)}
          aria-describedby="service-definition-about"
        />
        <div :if={@chosen} id="service-definition-about" class="grid gap-1 text-[13px]/5 text-muted">
          <p :if={@chosen["description"]}>{@chosen["description"]}</p>
          <p>{gettext("Its hosts: %{hosts}.", hosts: Enum.join(@chosen["hosts"], ", "))}</p>
        </div>
        <.input
          field={@form[:name]}
          label={gettext("Name")}
          optional
          hint={gettext("The API's title, unless you give it another.")}
          autocomplete="off"
        />
        <.applies_input form={@form} />
        <.page_form_foot id="new-service-save" cancel={Common.index_path(@current_scope)}>
          <.button type="submit" variant="primary" loading_text={gettext("Saving")}>
            {gettext("Set up API")}
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
      label={Common.applies_label()}
      options={[{gettext("Every target"), "all"}, {gettext("Chosen targets"), "selected"}]}
      hint={gettext("You choose the targets on its page, once it is set up.")}
    />
    """
  end

  # The forge a path is on: the one chosen, or github.com where none of them is.
  defp forge(where) when where in @forges, do: where
  defp forge(_where), do: "github.com"

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

  defp form_title(:add_integration), do: gettext("Add from a release")
  defp form_title(:new_runtime), do: gettext("Set up an agent")
  defp form_title(:new_service), do: gettext("Set up an API")

  defp form_sentence(:add_integration),
    do:
      gettext(
        "Name the release of a program: its description is fetched, and you add it from there."
      )

  defp form_sentence(:new_runtime), do: gettext("Choose the coding agent runs start.")

  defp form_sentence(:new_service),
    do: gettext("Choose an outside API the agent may call while it works.")

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
        connections: Enum.sort_by(connections, &Common.kind_order(&1.kind)),
        definitions: definitions
      )
    else
      {:error, _reason} -> raise ApiaryWeb.NotFound
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    action = socket.assigns.live_action

    cond do
      action == :index ->
        {:noreply, assign(socket, form: nil, page_title: title(socket, gettext("Integrations")))}

      socket.assigns.may_write ->
        {:noreply,
         assign(socket,
           form: fresh_form(action, params, socket.assigns),
           page_title: title(socket, form_title(action))
         )}

      true ->
        {:noreply,
         socket
         |> put_flash(:error, Common.only_admins(socket.assigns.current_scope))
         |> push_patch(to: Common.index_path(socket.assigns.current_scope))}
    end
  end

  defp title(socket, words),
    do: SettingsComponents.page_title(socket.assigns.current_scope, :workspace, [words])

  # Add from a release, empty or with the `source` and `version` of a release asked for
  # again or a named release's card: a forge path on the forge it names, an address where
  # the instance accepts one.
  defp fresh_form(:add_integration, params, %{url_sources: url_sources?}) do
    empty = %{"where" => "github.com", "path" => "", "version" => "", "url" => ""}
    source = if is_binary(params["source"]), do: String.trim(params["source"]), else: ""
    version = if is_binary(params["version"]), do: String.trim(params["version"]), else: ""

    fields =
      cond do
        Common.url_source?(source) and url_sources? ->
          %{empty | "where" => "url", "url" => source}

        Common.url_source?(source) ->
          empty

        true ->
          case String.split(source, "/", parts: 2) do
            [host, path] when host in @forges ->
              %{empty | "where" => host, "path" => path, "version" => version}

            _other ->
              empty
          end
      end

    to_form(fields, as: :release)
  end

  # Set up an agent, its runtime the one a card chose (`?runtime=`) where the catalogue
  # has it, else the catalogue's first.
  defp fresh_form(:new_runtime, params, _assigns) do
    runtime =
      if chosen_runtime(params["runtime"]),
        do: params["runtime"],
        else: hd(Runtimes.list()).name

    to_form(%{"runtime" => runtime, "applies_to" => "all"}, as: :connection)
  end

  # Set up an API, its API the one a card chose (`?definition=builtin:<key>` or
  # `own:<public id>`) where it is built in or the workspace's own, else the first built-in
  # one.
  defp fresh_form(:new_service, params, assigns) do
    definition =
      if chosen_definition(params["definition"], assigns),
        do: params["definition"],
        else: "builtin:" <> hd(Services.list())["key"]

    to_form(%{"definition" => definition, "name" => "", "applies_to" => "all"}, as: :connection)
  end

  @impl true
  def handle_event("validate", %{"release" => params}, socket),
    do: {:noreply, assign(socket, :form, to_form(params, as: :release))}

  def handle_event("validate", %{"connection" => params}, socket),
    do: {:noreply, assign(socket, :form, to_form(params, as: :connection))}

  def handle_event("request", %{"release" => params}, socket) do
    scope = socket.assigns.current_scope
    url? = params["where"] == "url"

    if params["where"] in Enum.map(where_options(socket.assigns.url_sources), &elem(&1, 1)),
      do: request(socket, scope, params, url?),
      else:
        {:noreply,
         assign(socket, :form, to_form(params, as: :release, errors: [where: {"is invalid", []}]))}
  end

  def handle_event(
        "create",
        %{"connection" => params},
        %{assigns: %{live_action: action}} = socket
      )
      when action in [:new_runtime, :new_service] do
    create(socket, action, params)
  end

  # An event the page's controls do not send, or sent where they are not: nothing.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp request(socket, scope, params, url?) do
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
        {:noreply, put_flash(socket, :error, Common.refusal(scope, reason))}
    end
  end

  defp create(socket, action, params) do
    scope = socket.assigns.current_scope

    result =
      case action do
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
         |> put_flash(:info, gettext("%{name} is set up.", name: Common.label(connection)))
         |> push_navigate(to: to)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, :form, to_form(params, as: :connection, errors: changeset.errors))}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, Common.refusal(scope, reason, socket.assigns.connections))}
    end
  end

  defp definition_attrs("builtin:" <> key), do: %{service: key}
  defp definition_attrs("own:" <> id), do: %{definition_id: id}
  defp definition_attrs(_value), do: %{}
end
