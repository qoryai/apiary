defmodule ApiaryWeb.IntegrationLive.Show do
  @moduledoc """
  One agent (a runtime), API (a service) or program (an integration added from a release)
  of the organisation, under Workspace settings › Integrations
  (`/:org/:workspace/settings/integrations/:id`, `:id` its public id, `con_…`), with the
  `secrets` feature. Under its title, its kind. Three tabs, each an address:

    * **Overview** (`:overview`): what it is, its id, its source, version and roles (a
      program's), the API it is set up from, built in or a custom API (an API's), or its
      catalogue entry (an agent's), where it applies, who added and changed it, the
      secrets it declares (an API's and a program's) and a program's plain settings;
    * **Workspaces** (`…/targets`): where it applies, every workspace of the organisation
      or the chosen ones. Where it applies is set when it is added, and never changed
      after (`Apiary.Connections.reach_at_add/3`);
    * **Settings** (`…/settings`): a service's name, an integration's
      plain settings and argument, its version (`…/version`, a page that asks for another
      release of the same source, `ApiaryWeb.IntegrationLive.Release`), and last its
      danger zone, its removal confirmed in place (`…/delete`).

  It reads and writes through `Apiary.Connections` (`get_connection/2`,
  `update_connection/3`, `delete_connection/2`, `definition/1`, `description/1`) and asks
  `Apiary.Integrations.request_release/2` for another version. The page says once that a
  run receives only its security policy.
  """
  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :secrets
  on_mount {ApiaryWeb.Access, :"connection.read"}

  import Ecto.Query, only: [from: 2]

  alias Apiary.{Connections, Integrations, Repo}
  alias Apiary.Connections.Connection
  alias Apiary.Integrations.Release
  alias Apiary.Kinds.Runtimes
  alias Apiary.Organisations.Workspace
  alias ApiaryWeb.IntegrationLive.Common
  alias ApiaryWeb.SettingsComponents

  @tabs [:overview, :targets, :settings]
  @writes [:version, :delete]

  @impl true
  def render(%{live_action: :version} = assigns) do
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
      <:crumb navigate={Common.connection_path(@current_scope, @connection)} title={elem(@names, 0)}>
        {elem(@names, 0)}
      </:crumb>
      <:crumb>{gettext("Change version")}</:crumb>

      <.page_form
        id="version-page"
        title={gettext("Change the version of %{name}", name: Common.label(@names))}
        cancel={Common.connection_path(@current_scope, @connection, :settings)}
      >
        <:description>
          {gettext("It is at %{version}, from %{source}.",
            version: @connection.version,
            source: @connection.source
          )}
        </:description>
        <Common.not_on_runs />
        <div :if={@version_problems != []} id="version-problems">
          <.notice kind={:error}>
            <p :for={problem <- @version_problems}>{problem}</p>
          </.notice>
        </div>
        <.form for={@form} id="version-form" phx-submit="request_version" novalidate>
          <div class="grid gap-4">
            <.input
              :if={!Common.url_source?(@connection.source)}
              field={@form[:version]}
              label={gettext("Version")}
              placeholder="1.4.0"
              hint={gettext("The version of a release of the same source, such as 1.4.0.")}
              autocomplete="off"
            />
            <p :if={Common.url_source?(@connection.source)} class="text-[13px]/5 text-muted">
              {gettext(
                "A program from an address has one release: what its address serves. It is fetched again, and you move to it from there."
              )}
            </p>
            <.page_form_foot
              id="version-save"
              cancel={Common.connection_path(@current_scope, @connection, :settings)}
            >
              <.button type="submit" variant="primary" loading_text={gettext("Asking")}>
                {gettext("Fetch the release")}
              </.button>
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
      <:crumb
        patch={@tab != :overview && Common.connection_path(@current_scope, @connection)}
        title={elem(@names, 0)}
      >
        {elem(@names, 0)}
      </:crumb>

      <.settings_page
        section={:integrations}
        title={elem(@names, 0)}
        measure="list"
      >
        <:subtitle>
          <span id="connection-kind">{Common.kind_word(@connection.kind)}</span>
          <span :if={elem(@names, 1)} class="text-faint" aria-hidden="true">·</span>
          <span :if={elem(@names, 1)} id="connection-name" class="q-mono">{elem(@names, 1)}</span>
          <span :if={@connection.source} class="text-faint" aria-hidden="true">·</span>
          <span :if={@connection.source} class="q-mono">{@connection.source}</span>
          <span :if={@connection.version} class="text-faint" aria-hidden="true">·</span>
          <span :if={@connection.version} class="q-mono">{@connection.version}</span>
        </:subtitle>

        <.page_tabs id="connection-tabs" label={Common.kind_word(@connection.kind)} current={@tab}>
          <:tab key={:overview} patch={Common.connection_path(@current_scope, @connection)}>
            {gettext("Overview")}
          </:tab>
          <:tab
            key={:targets}
            patch={Common.connection_path(@current_scope, @connection, :targets)}
            count={if @connection.applies_to == "selected", do: length(@connection.workspaces)}
          >
            {gettext("Workspaces")}
          </:tab>
          <:tab
            key={:settings}
            patch={Common.connection_path(@current_scope, @connection, :settings)}
            settings
          >
            {gettext("Settings")}
          </:tab>
        </.page_tabs>

        <Common.not_on_runs />
        <.notice :if={!@connection.intact} kind={:error}>
          {gettext("%{name} fails its integrity check: its record is not as it was saved.",
            name: Common.label(@names)
          )}
        </.notice>

        <.overview :if={@tab == :overview} {assigns} />
        <.targets :if={@tab == :targets} {assigns} />
        <.settings :if={@tab == :settings} {assigns} />
      </.settings_page>
    </Layouts.app>
    """
  end

  ## Overview

  defp overview(assigns) do
    ~H"""
    <p :if={@about} id="connection-about" class="max-w-[72ch] text-[13.5px]/5">{@about}</p>

    <SettingsComponents.part id="connection-facts" title={gettext("About")}>
      <dl class="grid grid-cols-[max-content_minmax(0,1fr)] gap-x-4 gap-y-2 text-[13px]/5 break-words">
        <dt class="text-faint">{gettext("Kind")}</dt>
        <dd>{Common.kind_word(@connection.kind)}</dd>
        <dt class="text-faint">{gettext("Id")}</dt>
        <dd class="q-mono" id="connection-id">{@connection.public_id}</dd>
        <%= if @connection.kind == "runtime" do %>
          <dt class="text-faint">{gettext("Agent")}</dt>
          <dd>
            {(@runtime && @runtime.title) || @connection.name}
            <span class="q-mono text-muted">({@connection.name})</span>
          </dd>
          <dt :if={@runtime} class="text-faint">{gettext("Hosts")}</dt>
          <dd :if={@runtime} class="q-mono">{Enum.join(Runtimes.hosts(@runtime), ", ")}</dd>
          <dt :if={@runtime && @runtime.reserves != []} class="text-faint">
            {gettext("Reserved variables")}
          </dt>
          <dd :if={@runtime && @runtime.reserves != []} class="q-mono">
            {Enum.join(@runtime.reserves, ", ")}
          </dd>
          <dt :if={@runtime && @runtime.denies != []} class="text-faint">
            {gettext("Denied variables")}
          </dt>
          <dd :if={@runtime && @runtime.denies != []} class="q-mono">
            {Enum.join(@runtime.denies, ", ")}
          </dd>
          <dt :if={@runtime && @runtime.credential_files != []} class="text-faint">
            {gettext("Secret files")}
          </dt>
          <dd :if={@runtime && @runtime.credential_files != []} class="q-mono">
            {Enum.join(@runtime.credential_files, ", ")}
          </dd>
        <% end %>
        <%= if @connection.kind == "integration" do %>
          <dt class="text-faint">{gettext("Source")}</dt>
          <dd class="q-mono">{@connection.source}</dd>
          <dt class="text-faint">{gettext("Version")}</dt>
          <dd class="q-mono">{@connection.version}</dd>
          <dt class="text-faint">{gettext("Released on")}</dt>
          <dd>{Common.released_on(@connection.forge_kind)}</dd>
          <dt :if={@description} class="text-faint">{gettext("Roles")}</dt>
          <dd :if={@description} id="connection-roles" class="q-mono">
            {Enum.join(@description.roles, ", ")}
          </dd>
          <dt class="text-faint">{gettext("Description digest")}</dt>
          <dd class="q-mono break-all">{@connection.description_sha256}</dd>
        <% end %>
        <%= if @connection.kind == "service" do %>
          <dt class="text-faint">{gettext("Set up from")}</dt>
          <dd id="connection-definition">
            <span :if={@connection.service_builtin}>
              {(@definition && @definition["title"]) || @connection.service_builtin}
              <span class="text-muted">{gettext("built in")}</span>
            </span>
            <.link
              :if={@connection.service_definition}
              navigate={Common.definition_path(@current_scope, @connection.service_definition)}
              class="text-accent hover:underline"
            >
              {@connection.service_definition.title}
            </.link>
          </dd>
          <dt :if={@definition} class="text-faint">{gettext("Hosts")}</dt>
          <dd :if={@definition} class="q-mono">{Enum.join(@definition["hosts"], ", ")}</dd>
          <dt :if={@definition && @definition["paths"]} class="text-faint">{gettext("Paths")}</dt>
          <dd :if={@definition && @definition["paths"]} class="q-mono">
            {Enum.join(@definition["paths"], ", ")}
          </dd>
          <dt :if={@definition} class="text-faint">{gettext("Auth")}</dt>
          <dd :if={@definition} class="q-mono">
            {@definition["auth"]["scheme"]}<span :if={@definition["auth"]["header"]}> · {@definition[
              "auth"
            ]["header"]}</span>
          </dd>
          <dt :if={@definition} class="text-faint">{gettext("Definition digest")}</dt>
          <dd :if={@definition} class="q-mono break-all">
            {Apiary.Kinds.ServiceDefinition.digest(@definition)}
          </dd>
        <% end %>
        <dt class="text-faint">{Common.applies_label()}</dt>
        <dd>
          <.link
            id="connection-applies-link"
            patch={Common.connection_path(@current_scope, @connection, :targets)}
            phx-click={JS.focus(to: "#connection-tabs-targets")}
            class="text-accent hover:underline"
          >
            {Common.applies_word(@connection)}
          </.link>
        </dd>
        <dt class="text-faint">{gettext("Added")}</dt>
        <dd>
          <.avatar
            email={Common.who(@people, @connection.created_by_id)}
            reader={@current_scope.user.email}
            size="xs"
          />
          <span class="text-muted">· <.time_ago at={@connection.inserted_at} /></span>
        </dd>
        <dt class="text-faint">{gettext("Last changed")}</dt>
        <dd>
          <.avatar
            email={Common.who(@people, @connection.updated_by_id)}
            reader={@current_scope.user.email}
            size="xs"
          />
          <span class="text-muted">· <.time_ago at={@connection.updated_at} /></span>
        </dd>
      </dl>
    </SettingsComponents.part>

    <%!-- A runtime connection offers none of its runtime's declarations
         (`Apiary.Kinds.Runtimes`), so its page has no part for them. --%>
    <SettingsComponents.part
      :if={@connection.kind != "runtime"}
      id="connection-secrets"
      title={gettext("Secrets it declares")}
      count={length(@secrets)}
    >
      <dl
        :if={@secrets != []}
        class="grid grid-cols-[max-content_minmax(0,1fr)] gap-x-4 gap-y-2 text-[13px]/5"
      >
        <%= for secret <- @secrets do %>
          <dt class="q-mono">{secret.id}</dt>
          <dd>
            <.external_text text={secret.title} />
            <span :if={secret.variable} class="q-mono text-muted">· {secret.variable}</span>
          </dd>
        <% end %>
      </dl>
      <p :if={@secrets == []} class="text-[13px]/5 text-muted">
        {gettext("It declares no secret.")}
      </p>
      <p :if={@secrets != []} id="connection-secrets-unlinked" class="text-[13px]/5 text-muted">
        {gettext("Qory Apiary links no stored secret to it.")}
      </p>
    </SettingsComponents.part>

    <SettingsComponents.part
      :if={@connection.kind == "integration"}
      id="connection-plain-settings"
      title={gettext("Its settings")}
    >
      <dl
        :if={@plain != [] or @connection.argument}
        class="grid grid-cols-[max-content_minmax(0,1fr)] gap-x-4 gap-y-2 text-[13px]/5"
      >
        <%= for setting <- @plain do %>
          <dt><.external_text text={setting.title} /></dt>
          <dd :if={Map.has_key?(@settings, setting.name)} class="q-mono">
            {Common.setting_value(@settings[setting.name])}
          </dd>
          <dd :if={!Map.has_key?(@settings, setting.name)} class="text-faint">
            {gettext("Not set")}
          </dd>
        <% end %>
        <dt :if={@connection.argument}>{gettext("Argument")}</dt>
        <dd :if={@connection.argument} class="q-mono">{@connection.argument}</dd>
      </dl>
      <p :if={@plain == [] and !@connection.argument} class="text-[13px]/5 text-muted">
        {gettext("It declares no plain setting.")}
      </p>
    </SettingsComponents.part>
    """
  end

  ## Targets

  defp targets(assigns) do
    ~H"""
    <p id="connection-applies" class="text-[13px]/5">
      <%= if @connection.applies_to == "all" do %>
        {pgettext("plain", "It applies to every workspace of this organisation.")}
      <% else %>
        {pgettext("plain", "It applies to the chosen workspaces below, and to no other.")}
      <% end %>
    </p>

    <.table
      :if={@target_rows != [] and @connection.applies_to == "selected"}
      id="connection-targets"
      label={gettext("Workspaces")}
      rows={@target_rows}
      row_id={&"target-#{&1.id}"}
    >
      <:col :let={row} label={gettext("Workspace")} kind="title">
        <.link
          :if={row.workspace}
          navigate={~p"/#{@current_scope.organisation}/#{row.workspace}"}
          class="q-cut hover:underline"
          title={row.workspace.name}
        >
          {row.workspace.name}
        </.link>
      </:col>
    </.table>
    <p
      :if={@target_rows == [] and @connection.applies_to == "selected"}
      id="connection-targets-empty"
      class="text-[13px]/5 text-muted"
    >
      {pgettext("plain", "It applies to no workspace.")}
    </p>
    """
  end

  ## Settings

  # Whether the form has a field: a service's name, an integration's plain settings or
  # its argument. A runtime has none, and where a connection applies is set at its add.
  defp editable?(%Connection{kind: "service"}, _plain, _patterns), do: true

  defp editable?(%Connection{kind: "integration"}, plain, patterns),
    do: plain != [] or patterns != []

  defp editable?(%Connection{}, _plain, _patterns), do: false

  defp settings(assigns) do
    ~H"""
    <p :if={!@may_write} id="connection-readonly" class="text-[13px]/5 text-muted">
      {Common.only_admins(@current_scope, Connections.write_action(@connection))}
    </p>

    <.form
      :if={@may_write and editable?(@connection, @plain, @patterns)}
      for={@form}
      id="connection-form"
      phx-change="validate"
      phx-submit="save"
      class="q-form"
      novalidate
    >
      <div class="grid gap-4">
        <.input
          :if={@connection.kind == "service"}
          field={@form[:name]}
          label={gettext("Name")}
          autocomplete="off"
        />
        <%= for setting <- @plain do %>
          <div :if={setting.type == :boolean} class="grid gap-1.5">
            <.input
              id={"connection-setting-#{setting.name}"}
              name={"connection[settings][#{setting.name}]"}
              type="checkbox"
              label={Apiary.ExternalText.line(setting.title)}
              value={@form.params["settings"][setting.name]}
              aria-describedby={Common.hint(setting) && "connection-setting-#{setting.name}-hint"}
            />
            <p
              :if={Common.hint(setting)}
              id={"connection-setting-#{setting.name}-hint"}
              class="text-[12.5px]/[18px] text-muted"
            >
              <.external_text text={Common.hint(setting)} />
            </p>
          </div>
          <.input
            :if={setting.type != :boolean}
            id={"connection-setting-#{setting.name}"}
            name={"connection[settings][#{setting.name}]"}
            label={Apiary.ExternalText.line(setting.title)}
            hint={Common.hint(setting)}
            value={@form.params["settings"][setting.name]}
            optional
            autocomplete="off"
          />
        <% end %>
        <.input
          :if={@connection.kind == "integration" and @patterns != []}
          field={@form[:argument]}
          label={gettext("Argument")}
          optional
          hint={
            gettext("It must match %{patterns}.",
              patterns: Enum.join(@patterns, ", ")
            )
          }
          autocomplete="off"
        />
        <SettingsComponents.save id="connection-save">
          <.button type="submit" variant="primary" loading_text={gettext("Saving")}>
            {gettext("Save changes")}
          </.button>
        </SettingsComponents.save>
      </div>
    </.form>

    <SettingsComponents.part
      :if={@connection.kind == "integration"}
      id="connection-version"
      title={gettext("Version")}
    >
      <p class="text-[13px]/5">
        {gettext("It is at %{version}, from %{source}.",
          version: @connection.version,
          source: @connection.source
        )}
      </p>
      <p :if={!@accepted} id="connection-version-refused" class="text-[13px]/5 text-muted">
        {gettext(
          "This instance no longer accepts integrations from this source, so its version can't be changed."
        )}
      </p>
      <div :if={@may_write and @accepted}>
        <.button
          id="change-version"
          navigate={Common.connection_path(@current_scope, @connection, :version)}
        >
          {gettext("Change version")}
        </.button>
      </div>
    </SettingsComponents.part>

    <SettingsComponents.danger_zone :if={@may_write}>
      <.removal
        id="delete-connection"
        title={removal_title(@connection)}
        button={removal_button(@connection)}
        open={@live_action == :delete}
        open_path={Common.connection_path(@current_scope, @connection, :delete)}
        close_path={Common.connection_path(@current_scope, @connection, :settings)}
        question={gettext("Remove %{name}?", name: Common.label(@names))}
      >
        {gettext("It is removed from this organisation. This cannot be undone.")}
      </.removal>
    </SettingsComponents.danger_zone>
    """
  end

  defp removal_title(%Connection{kind: "runtime"}), do: gettext("Remove this runtime")
  defp removal_title(%Connection{kind: "integration"}), do: gettext("Remove this program")
  defp removal_title(%Connection{kind: "service"}), do: gettext("Remove this API")

  defp removal_button(%Connection{kind: "runtime"}), do: gettext("Remove runtime…")
  defp removal_button(%Connection{kind: "integration"}), do: gettext("Remove program…")
  defp removal_button(%Connection{kind: "service"}), do: gettext("Remove API…")

  # The danger zone's line that removes the connection: `SettingsComponents.danger_action/1`
  # as it is drawn, with the same ids, its confirmation in place, but its red button "Yes,
  # remove", which the shared one, a deletion's "Yes, delete", does not take.
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :button, :string, required: true
  attr :open, :boolean, required: true
  attr :open_path, :string, required: true
  attr :close_path, :string, required: true
  attr :question, :string, required: true
  slot :inner_block, required: true

  defp removal(assigns) do
    ~H"""
    <div id={@id} class={["q-danger-line", @open && "q-danger-line-open"]}>
      <div class="q-danger-what">
        <h3 id={"#{@id}-title"} class="q-danger-name">{@title}</h3>
        <p class="q-danger-sub">{render_slot(@inner_block)}</p>
      </div>
      <div class="q-danger-act">
        <.button
          id={"#{@id}-button"}
          patch={if @open, do: @close_path, else: @open_path}
          aria-expanded={to_string(@open)}
          aria-controls={@open && "#{@id}-form"}
        >
          {@button}
        </.button>
      </div>
      <.form
        :if={@open}
        for={%{}}
        as={:confirm}
        id={"#{@id}-form"}
        class="q-danger-confirm"
        phx-submit="delete"
        novalidate
      >
        <.inline_confirm
          id={"#{@id}-confirming"}
          question={@question}
          cancel={JS.patch(@close_path) |> JS.focus(to: "##{@id}-button")}
        >
          <:action>
            <.button
              id={"#{@id}-confirm"}
              variant="danger"
              size="xs"
              type="submit"
              loading_text={gettext("Removing")}
            >
              {gettext("Yes, remove")}
            </.button>
          </:action>
        </.inline_confirm>
      </.form>
    </div>
    """
  end

  ## Mount and params

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(
       sections: SettingsComponents.sections(scope, :workspace),
       version_problems: [],
       form: nil
     )
     |> load(id)
     |> assign_accepted()}
  end

  defp load(socket, id) do
    scope = socket.assigns.current_scope

    case Connections.get_connection(scope, id) do
      {:ok, connection} -> assign_connection(socket, connection)
      {:error, _reason} -> raise ApiaryWeb.NotFound
    end
  end

  # Whether the instance still accepts the source of the integration's release, which
  # another version must come from (`Apiary.Integrations.accepted_source/1`): read once,
  # when the page mounts, since a refusal is logged.
  defp assign_accepted(%{assigns: %{connection: %Connection{kind: "integration"} = c}} = socket) do
    accepted =
      case c.release do
        %Release{} = release -> match?({:ok, _source}, Integrations.accepted_source(release))
        _none -> false
      end

    assign(socket, :accepted, accepted)
  end

  defp assign_accepted(socket), do: assign(socket, :accepted, false)

  defp assign_connection(socket, %Connection{} = connection) do
    scope = socket.assigns.current_scope
    description = description(connection)
    definition = definition(connection)
    runtime = runtime(connection)
    ids = Connections.workspace_ids_of(connection)

    workspaces =
      Repo.all(
        from w in Workspace,
          where: w.organisation_id == ^scope.organisation.id and w.id in ^ids
      )
      |> Map.new(&{&1.id, &1})

    target_rows =
      for id <- ids do
        %{id: id, workspace: workspaces[id]}
      end
      |> Enum.sort_by(&{(&1.workspace && &1.workspace.name) || "", &1.id})

    assign(socket,
      connection: connection,
      may_write: Common.may_write?(scope, connection),
      names: Common.names(connection),
      description: description,
      definition: definition,
      runtime: runtime,
      about: about(connection, description, definition),
      secrets: secrets(connection, description, definition),
      plain: if(description, do: Common.plain_settings(description), else: []),
      patterns: if(description, do: Common.argument_patterns(description), else: []),
      settings: Connection.settings_map(connection),
      target_rows: target_rows,
      people: Common.people([connection.created_by_id, connection.updated_by_id])
    )
  end

  defp description(%Connection{kind: "integration"} = connection) do
    case Connections.description(connection) do
      {:ok, description} -> description
      {:error, _} -> nil
    end
  end

  defp description(_connection), do: nil

  defp definition(%Connection{kind: "service"} = connection) do
    case Connections.definition(connection) do
      {:ok, definition} -> definition
      :error -> nil
    end
  end

  defp definition(_connection), do: nil

  defp runtime(%Connection{kind: "runtime", name: name}) do
    case Runtimes.fetch(name) do
      {:ok, runtime} -> runtime
      :error -> nil
    end
  end

  defp runtime(_connection), do: nil

  defp about(%Connection{kind: "integration"}, %{about: about}, _definition), do: about
  defp about(%Connection{kind: "service"}, _description, %{} = d), do: d["description"]
  defp about(_connection, _description, _definition), do: nil

  # The secrets it declares, each `%{id:, title:, variable:}`: a service definition's, an
  # integration description's secrets, which name no variable.
  defp secrets(%Connection{kind: "service"}, _description, %{} = definition),
    do:
      for(
        d <- definition["declares"],
        do: %{id: d["id"], title: d["title"], variable: d["name"]}
      )

  defp secrets(%Connection{kind: "integration"}, %{} = description, _definition),
    do:
      for(
        s <- description.secrets,
        do: %{id: s.name, title: s.title, variable: nil}
      )

  defp secrets(_connection, _description, _definition), do: []

  @impl true
  def handle_params(params, _uri, socket) do
    action = socket.assigns.live_action
    scope = socket.assigns.current_scope

    if action in @writes and not socket.assigns.may_write do
      {:noreply,
       socket
       |> put_flash(
         :error,
         Common.only_admins(scope, Connections.write_action(socket.assigns.connection))
       )
       |> push_patch(to: Common.connection_path(scope, socket.assigns.connection))}
    else
      {:noreply,
       socket
       |> assign(tab: tab(action), version_problems: [])
       |> assign(
         :page_title,
         SettingsComponents.page_title(scope, :workspace, [
           elem(socket.assigns.names, 0),
           gettext("Integrations")
         ])
       )
       |> open(action, params)}
    end
  end

  defp tab(action) when action in @tabs, do: action
  defp tab(:delete), do: :settings
  defp tab(:version), do: :settings

  defp open(socket, :settings, _params), do: assign(socket, :form, edit_form(socket.assigns))
  defp open(socket, :delete, _params), do: assign(socket, :form, edit_form(socket.assigns))

  # Another version is an integration's, from a source the instance still accepts;
  # anything else goes back to its Settings, which say why.
  defp open(socket, :version, _params) do
    socket = assign(socket, :form, to_form(%{"version" => ""}, as: :version))

    if socket.assigns.connection.kind == "integration" and socket.assigns.accepted,
      do: socket,
      else:
        push_patch(socket,
          to:
            Common.connection_path(
              socket.assigns.current_scope,
              socket.assigns.connection,
              :settings
            )
        )
  end

  defp open(socket, _action, _params), do: socket

  defp edit_form(assigns) do
    connection = assigns.connection

    settings =
      for setting <- assigns.plain,
          Map.has_key?(assigns.settings, setting.name),
          into: %{},
          do: {setting.name, Common.setting_value(assigns.settings[setting.name])}

    to_form(
      %{
        "name" => connection.name,
        "argument" => connection.argument || "",
        "settings" => settings
      },
      as: :connection
    )
  end

  ## Events

  @impl true
  def handle_event("validate", %{"connection" => params}, socket) when is_map(params),
    do: {:noreply, assign(socket, :form, to_form(params, as: :connection))}

  def handle_event("save", %{"connection" => params}, socket) when is_map(params) do
    %{current_scope: scope, connection: connection} = socket.assigns

    attrs =
      %{}
      |> then(
        &if(connection.kind == "service", do: Map.put(&1, "name", params["name"]), else: &1)
      )
      |> then(fn attrs ->
        if connection.kind == "integration",
          do:
            attrs
            |> Map.put("settings", Common.cast_settings(socket.assigns.plain, params["settings"]))
            |> Map.put("argument", params["argument"] || ""),
          else: attrs
      end)

    case Connections.update_connection(scope, connection, attrs) do
      {:ok, connection} ->
        socket = assign_connection(socket, connection)

        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("%{name} is saved.", name: Common.label(socket.assigns.names))
         )
         |> push_patch(to: Common.connection_path(scope, connection, :settings))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, :form, to_form(params, as: :connection, errors: changeset.errors))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, refusal(socket, reason))}
    end
  end

  def handle_event(
        "request_version",
        params,
        %{assigns: %{connection: %Connection{kind: "integration"}, accepted: true}} = socket
      ) do
    %{current_scope: scope, connection: connection} = socket.assigns
    fields = if is_map(params["version"]), do: params["version"], else: %{}
    url? = Common.url_source?(connection.source)

    attrs =
      if url?,
        do: %{"source" => connection.source},
        else: %{"source" => connection.source, "version" => fields["version"]}

    case Integrations.request_release(scope, attrs) do
      {:ok, release} ->
        {:noreply,
         push_navigate(socket,
           to: Common.release_path(scope, release.id, connection.public_id)
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        # The form shows a version's errors under its field; any other, such as the
        # source's, which it has no field for, above the form.
        shown = if url?, do: [], else: [:version]
        {on_fields, others} = Enum.split_with(changeset.errors, &(elem(&1, 0) in shown))

        {:noreply,
         assign(socket,
           form: to_form(fields, as: :version, errors: on_fields),
           version_problems: for({field, error} <- others, do: version_problem(field, error))
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, refusal(socket, reason))}
    end
  end

  def handle_event("delete", _params, socket) do
    %{current_scope: scope, connection: connection, names: names} = socket.assigns

    case Connections.delete_connection(scope, connection) do
      {:ok, _deleted} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("%{name} is removed.", name: Common.label(names)))
         |> push_navigate(to: Common.index_path(scope))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, refusal(socket, reason))}
    end
  end

  # An event the page's controls do not send, or sent where they are not: nothing.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp version_problem(:source, error),
    do: gettext("Its source %{error}.", error: translate_error(error))

  defp version_problem(_field, error),
    do: gettext("Its version %{error}.", error: translate_error(error))

  defp refusal(socket, reason) do
    scope = socket.assigns.current_scope

    connections =
      case Connections.list_connections(scope) do
        {:ok, connections} -> connections
        {:error, _} -> []
      end

    Common.refusal(
      scope,
      reason,
      connections,
      Connections.write_action(socket.assigns.connection)
    )
  end
end
