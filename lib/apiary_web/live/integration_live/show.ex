defmodule ApiaryWeb.IntegrationLive.Show do
  @moduledoc """
  One runtime, integration or service of the workspace, under Workspace settings ›
  Integrations (`/:org/:workspace/settings/integrations/:id`, `:id` its public id,
  `con_…`), with the `security` feature. Three tabs, each an address:

    * **Overview** (`:overview`): what it is, its id, its source, version and publisher
      (an integration's), its definition (a service's) or its catalogue entry (a
      runtime's), where it applies, who added and changed it, the way it is used, the
      secrets it declares and an integration's plain settings;
    * **Targets** (`…/targets`): where it applies, every target or the chosen ones, with
      Add target (`…/targets/add`, a page) and the removal of one, confirmed on its row
      (`…/targets/:target_id/remove`);
    * **Settings** (`…/settings`): where it applies, a service's name, an integration's
      plain settings and argument, its version (`…/version`, a page that asks for another
      release of the same source, `ApiaryWeb.IntegrationLive.Release`), and last its
      danger zone, its deletion confirmed in place (`…/delete`).

  It reads and writes through `Apiary.Connections` (`get_connection/2`,
  `update_connection/3`, `put_target/4`, `remove_target/3`, `delete_connection/2`,
  `definition/1`, `description/1`) and asks
  `Apiary.Integrations.request_release/2` for another version. No run receives any of it
  yet, and the page says so once.
  """
  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :security
  on_mount {ApiaryWeb.Access, :"connection.read"}

  import Ecto.Query, only: [from: 2]

  alias Apiary.{Connections, Integrations, Repo, Targets}
  alias Apiary.Connections.Connection
  alias Apiary.Kinds.Runtimes
  alias Apiary.Runs.Target
  alias ApiaryWeb.IntegrationLive.Common
  alias ApiaryWeb.{RunComponents, SettingsComponents, TargetComponents}

  @tabs [:overview, :targets, :settings]
  @writes [:add_target, :remove_target, :version, :delete]

  @impl true
  def render(%{live_action: :add_target} = assigns) do
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
      <:crumb navigate={Common.connection_path(@current_scope, @connection)}>
        {@connection.name}
      </:crumb>
      <:crumb>{gettext("Add target")}</:crumb>

      <.page_form
        id="add-target-page"
        title={gettext("Add a target to %{name}", name: @connection.name)}
        cancel={Common.connection_path(@current_scope, @connection, :targets)}
      >
        <:description>
          {gettext("Choose a target of this workspace for it to apply to.")}
        </:description>
        <Common.not_yet />
        <.form for={@find} id="find-target-form" phx-change="find" phx-submit="find" novalidate>
          <.input
            field={@find[:text]}
            type="search"
            label={gettext("Find a target")}
            placeholder="acme/shop"
            debounce="200"
            autocomplete="off"
          />
        </.form>
        <.table
          :if={@candidates != []}
          id="target-candidates"
          label={gettext("Targets")}
          rows={@candidates}
          row_id={&"candidate-#{&1.target.id}"}
        >
          <:col :let={row} label={gettext("Target")} kind="title">
            <RunComponents.target_name
              system={row.target.system}
              path={row.target.path}
              shared={@candidates_shared}
            />
          </:col>
          <:action :let={row}>
            <.button
              id={"add-#{row.target.id}"}
              size="xs"
              phx-click="put_target"
              phx-value-id={row.target.id}
            >
              {gettext("Add")}
            </.button>
          </:action>
        </.table>
        <p :if={@candidates == []} id="target-candidates-empty" class="text-[13px]/5 text-muted">
          {gettext("No target found that it doesn't apply to already.")}
        </p>
        <div>
          <.button
            id="add-target-done"
            navigate={Common.connection_path(@current_scope, @connection, :targets)}
          >
            {gettext("Done")}
          </.button>
        </div>
      </.page_form>
    </Layouts.app>
    """
  end

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
      <:crumb navigate={Common.settings_path(@current_scope)}>{gettext("Settings")}</:crumb>
      <:crumb navigate={Common.index_path(@current_scope)}>{gettext("Integrations")}</:crumb>
      <:crumb navigate={Common.connection_path(@current_scope, @connection)}>
        {@connection.name}
      </:crumb>
      <:crumb>{gettext("Change version")}</:crumb>

      <.page_form
        id="version-page"
        title={gettext("Change the version of %{name}", name: @connection.name)}
        cancel={Common.connection_path(@current_scope, @connection, :settings)}
      >
        <:description>
          {gettext("It is at %{version}, from %{source}.",
            version: @connection.version,
            source: @connection.source
          )}
        </:description>
        <Common.not_yet />
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
                "An integration from an address has one release: what its address serves. Qory fetches it again, and you move to it from there."
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
      <:crumb navigate={Common.settings_path(@current_scope)}>{gettext("Settings")}</:crumb>
      <:crumb navigate={Common.index_path(@current_scope)}>{gettext("Integrations")}</:crumb>
      <:crumb>{@connection.name}</:crumb>

      <.settings_page
        heading={gettext("Workspace settings")}
        section={:integrations}
        title={@connection.name}
        measure="list"
      >
        <:subtitle>
          <span id="connection-kind">{Common.kind_word(@connection.kind)}</span>
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
            count={if @connection.applies_to == "selected", do: length(@connection.targets)}
          >
            {gettext("Targets")}
          </:tab>
          <:tab
            key={:settings}
            patch={Common.connection_path(@current_scope, @connection, :settings)}
            settings
          >
            {gettext("Settings")}
          </:tab>
        </.page_tabs>

        <Common.not_yet />
        <.notice :if={!@connection.intact} kind={:error}>
          {gettext("%{name} fails its integrity check: its record is not as Qory wrote it.",
            name: @connection.name
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
      <dl class="grid grid-cols-[max-content_minmax(0,1fr)] gap-x-4 gap-y-2 text-[13px]/5">
        <dt class="text-faint">{gettext("Kind")}</dt>
        <dd>{Common.kind_word(@connection.kind)}</dd>
        <dt class="text-faint">{gettext("Id")}</dt>
        <dd class="q-mono" id="connection-id">{@connection.public_id}</dd>
        <%= if @connection.kind == "runtime" do %>
          <dt class="text-faint">{gettext("Runtime")}</dt>
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
            {gettext("Credential files")}
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
          <dt :if={@description} class="text-faint">{gettext("Publisher")}</dt>
          <dd :if={@description} id="connection-publisher">
            {@description.publisher["name"]}
            <span class="text-muted">
              {gettext("(as its description says; the source is %{owner})",
                owner: Common.source_owner(@connection.source)
              )}
            </span>
          </dd>
          <dt class="text-faint">{gettext("Released on")}</dt>
          <dd>{Common.released_on(@connection.forge_kind)}</dd>
          <dt class="text-faint">{gettext("Description digest")}</dt>
          <dd class="q-mono break-all">{@connection.description_sha256}</dd>
        <% end %>
        <%= if @connection.kind == "service" do %>
          <dt class="text-faint">{gettext("Definition")}</dt>
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
          <dt :if={@definition} class="text-faint">{gettext("Definition digest")}</dt>
          <dd :if={@definition} class="q-mono break-all">
            {Apiary.Kinds.ServiceDefinition.digest(@definition)}
          </dd>
        <% end %>
        <dt class="text-faint">{pgettext("plain", "Applies to")}</dt>
        <dd>
          <.link
            patch={Common.connection_path(@current_scope, @connection, :targets)}
            class="text-accent hover:underline"
          >
            {Common.applies_word(@connection)}
          </.link>
        </dd>
        <dt class="text-faint">{gettext("Added")}</dt>
        <dd>
          {Common.who(@people, @connection.created_by_id)}
          <span class="text-muted">· <.time_ago at={@connection.inserted_at} /></span>
        </dd>
        <dt class="text-faint">{gettext("Last changed")}</dt>
        <dd>
          {Common.who(@people, @connection.updated_by_id)}
          <span class="text-muted">· <.time_ago at={@connection.updated_at} /></span>
        </dd>
      </dl>
    </SettingsComponents.part>

    <SettingsComponents.part
      :if={@connection.kind == "integration"}
      id="connection-ways"
      title={gettext("Its ways")}
    >
      <p :if={@description && "credential" in @description.ways} class="text-[13px]/5">
        {gettext("Calls its API: the one way Qory supports.")}
      </p>
      <p
        :if={@description && "tool" in @description.ways}
        id="connection-tool-way"
        class="text-[13px]/5 text-muted"
      >
        {gettext("Its description also offers it as a tool (MCP). Qory doesn't support that way yet.")}
      </p>
      <p
        :if={!@description || "credential" not in @description.ways}
        class="text-[13px]/5 text-muted"
      >
        {gettext("Its description offers no way Qory supports yet.")}
      </p>
    </SettingsComponents.part>

    <SettingsComponents.part
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
            {secret.title}
            <span :if={secret.variable} class="q-mono text-muted">· {secret.variable}</span>
          </dd>
        <% end %>
      </dl>
      <p :for={group <- @one_of} class="text-[13px]/5 text-muted">
        {gettext("It needs one of: %{ids}.", ids: Enum.join(group, ", "))}
      </p>
      <p :if={@secrets == []} class="text-[13px]/5 text-muted">
        {gettext("It declares no secret.")}
      </p>
      <p :if={@secrets != []} id="connection-secrets-unlinked" class="text-[13px]/5 text-muted">
        <.rich text={
          rich_gettext(
            "Qory can't link a stored secret to it yet. The workspace's secrets are in %{secrets}.",
            secrets: {:link, Common.secrets_path(@current_scope), gettext("Secrets and variables")}
          )
        } />
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
          <dt>{setting.title}</dt>
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
        {gettext("It applies to every target of this workspace.")}
      <% else %>
        {gettext("It applies to the chosen targets below, and to no other.")}
      <% end %>
    </p>
    <p :if={@connection.applies_to == "all" and @may_write} class="text-[13px]/5 text-muted">
      <.rich text={
        rich_gettext("To choose its targets, change where it applies under %{settings}.",
          settings:
            {:link, Common.connection_path(@current_scope, @connection, :settings),
             gettext("Settings")}
        )
      } />
    </p>

    <.table
      :if={@target_rows != []}
      id="connection-targets"
      label={gettext("Targets")}
      rows={@target_rows}
      row_id={&"target-#{&1.id}"}
      confirming={@confirming && "target-#{@confirming}"}
    >
      <:col :let={row} label={gettext("Target")} kind="title">
        <.link
          :if={row.target}
          navigate={TargetComponents.target_path(@current_scope, row.target.system, row.target.path)}
          class="hover:underline"
        >
          <RunComponents.target_name
            system={row.target.system}
            path={row.target.path}
            shared={@shared}
          />
        </.link>
      </:col>
      <:action :let={row}>
        <.button
          :if={@may_write}
          variant="link"
          patch={Common.remove_target_path(@current_scope, @connection, row.id)}
          aria-label={gettext("Remove %{target}", target: row.target && row.target.path)}
        >
          {gettext("Remove")}
        </.button>
      </:action>
      <:confirm :let={row}>
        <.inline_confirm
          id={"target-#{row.id}-confirm"}
          question={
            gettext("Remove %{target} from %{name}?",
              target: row.target && row.target.path,
              name: @connection.name
            )
          }
          cancel={Common.connection_path(@current_scope, @connection, :targets)}
        >
          {target_removal_sentence(@connection)}
          <:action>
            <.button
              id={"target-#{row.id}-remove"}
              variant="danger"
              size="xs"
              phx-click="remove_target"
              phx-value-id={row.id}
              loading_text={gettext("Removing")}
            >
              {gettext("Yes, remove")}
            </.button>
          </:action>
        </.inline_confirm>
      </:confirm>
    </.table>
    <p
      :if={@target_rows == [] and @connection.applies_to == "selected"}
      id="connection-targets-empty"
      class="text-[13px]/5 text-muted"
    >
      {gettext("No target is chosen yet, so it applies to none.")}
    </p>
    <div :if={@may_write and @connection.applies_to == "selected"}>
      <.button
        id="add-target"
        navigate={Common.connection_path(@current_scope, @connection, :add_target)}
      >
        <.icon name="hero-plus-micro" class="size-4" />{gettext("Add target")}
      </.button>
    </div>
    """
  end

  defp target_removal_sentence(%Connection{applies_to: "selected"}),
    do: gettext("It no longer applies to that target.")

  defp target_removal_sentence(_connection),
    do: gettext("It still applies there, since it applies to every target.")

  ## Settings

  defp settings(assigns) do
    ~H"""
    <p :if={!@may_write} id="connection-readonly" class="text-[13px]/5 text-muted">
      {Common.only_admins()}
    </p>

    <.form
      :if={@may_write}
      for={@form}
      id="connection-form"
      phx-change="validate"
      phx-submit="save"
      class="q-form"
      novalidate
    >
      <div class="grid gap-4">
        <.input
          field={@form[:applies_to]}
          type="radio"
          label={pgettext("plain", "Applies to")}
          options={[{gettext("Every target"), "all"}, {gettext("Chosen targets"), "selected"}]}
          hint={gettext("Chosen targets are listed under Targets.")}
        />
        <.input
          :if={@connection.kind == "service"}
          field={@form[:name]}
          label={gettext("Name")}
          autocomplete="off"
        />
        <%= for setting <- @plain do %>
          <.input
            :if={setting.type == :boolean}
            id={"connection-setting-#{setting.name}"}
            name={"connection[settings][#{setting.name}]"}
            type="checkbox"
            label={setting.title}
            value={@form.params["settings"][setting.name]}
          />
          <.input
            :if={setting.type != :boolean}
            id={"connection-setting-#{setting.name}"}
            name={"connection[settings][#{setting.name}]"}
            label={setting.title}
            hint={setting.description}
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
            gettext("What it is started with. It must match %{patterns}.",
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
      <div :if={@may_write}>
        <.button
          id="change-version"
          navigate={Common.connection_path(@current_scope, @connection, :version)}
        >
          {gettext("Change version")}
        </.button>
      </div>
    </SettingsComponents.part>

    <SettingsComponents.danger_zone :if={@may_write}>
      <SettingsComponents.danger_action
        id="delete-connection"
        title={delete_title(@connection)}
        button={gettext("Delete…")}
        open={@live_action == :delete}
        open_path={Common.connection_path(@current_scope, @connection, :delete)}
        close_path={Common.connection_path(@current_scope, @connection, :settings)}
        question={gettext("Delete %{name}?", name: @connection.name)}
        submit="delete"
      >
        {pgettext(
          "plain",
          "It is removed from this workspace with where it applies. This cannot be undone."
        )}
      </SettingsComponents.danger_action>
    </SettingsComponents.danger_zone>
    """
  end

  defp delete_title(%Connection{kind: "runtime"}), do: gettext("Delete this runtime")
  defp delete_title(%Connection{kind: "integration"}), do: gettext("Delete this integration")
  defp delete_title(%Connection{kind: "service"}), do: gettext("Delete this service")

  ## Mount and params

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(
       sections: SettingsComponents.sections(scope, :workspace),
       may_write: Common.may_write?(scope),
       people: Common.people(scope),
       confirming: nil,
       find: to_form(%{"text" => ""}, as: :find),
       candidates: [],
       candidates_shared: MapSet.new(),
       form: nil
     )
     |> load(id)}
  end

  defp load(socket, id) do
    scope = socket.assigns.current_scope

    case Connections.get_connection(scope, id) do
      {:ok, connection} -> assign_connection(socket, connection)
      {:error, _reason} -> raise ApiaryWeb.NotFound
    end
  end

  defp assign_connection(socket, %Connection{} = connection) do
    scope = socket.assigns.current_scope
    description = description(connection)
    definition = definition(connection)
    runtime = runtime(connection)
    ids = Enum.map(connection.targets, & &1.target_id)

    targets =
      Repo.all(
        from t in Target,
          where:
            t.organisation_id == ^scope.organisation.id and
              t.workspace_id == ^scope.workspace.id and t.id in ^ids
      )
      |> Map.new(&{&1.id, &1})

    target_rows =
      for row <- connection.targets do
        %{
          id: row.target_id,
          target: targets[row.target_id]
        }
      end
      |> Enum.sort_by(&((&1.target && &1.target.path) || ""))

    assign(socket,
      connection: connection,
      description: description,
      definition: definition,
      runtime: runtime,
      about: about(connection, description, definition),
      secrets: secrets(connection, description, definition, runtime),
      one_of: one_of(runtime),
      plain: if(description, do: Common.plain_settings(description), else: []),
      patterns: if(description, do: Common.argument_patterns(description), else: []),
      settings: Connection.settings_map(connection),
      target_rows: target_rows,
      shared: Apiary.Runs.shared_paths(scope, for(t <- Map.values(targets), do: t.path))
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

  # The secrets it declares, each `%{id:, title:, variable:}`: a runtime's declarations,
  # a service definition's, an integration description's secrets.
  defp secrets(%Connection{kind: "runtime"}, _description, _definition, %{} = runtime),
    do: for(d <- runtime.declares, do: %{id: d["id"], title: d["title"], variable: d["name"]})

  defp secrets(%Connection{kind: "service"}, _description, %{} = definition, _runtime),
    do:
      for(
        d <- definition["declares"],
        do: %{id: d["id"], title: d["title"], variable: d["name"]}
      )

  defp secrets(%Connection{kind: "integration"}, %{} = description, _definition, _runtime),
    do:
      for(
        s <- description.secrets,
        do: %{id: s.name, title: s.title, variable: s.secret_name}
      )

  defp secrets(_connection, _description, _definition, _runtime), do: []

  defp one_of(%{one_of: groups}),
    do: for(%{"required" => true, "of" => of} <- groups, do: of)

  defp one_of(_runtime), do: []

  @impl true
  def handle_params(params, _uri, socket) do
    action = socket.assigns.live_action
    scope = socket.assigns.current_scope

    if action in @writes and not socket.assigns.may_write do
      {:noreply,
       socket
       |> put_flash(:error, Common.only_admins())
       |> push_patch(to: Common.connection_path(scope, socket.assigns.connection))}
    else
      {:noreply,
       socket
       |> assign(tab: tab(action), confirming: nil)
       |> assign(:page_title, socket.assigns.connection.name <> " · " <> gettext("Integrations"))
       |> open(action, params)}
    end
  end

  defp tab(action) when action in @tabs, do: action
  defp tab(:remove_target), do: :targets
  defp tab(:add_target), do: :targets
  defp tab(:delete), do: :settings
  defp tab(:version), do: :settings

  defp open(socket, :settings, _params), do: assign(socket, :form, edit_form(socket.assigns))
  defp open(socket, :delete, _params), do: assign(socket, :form, edit_form(socket.assigns))

  defp open(socket, :remove_target, %{"target_id" => target_id}) do
    if Enum.any?(socket.assigns.target_rows, &(&1.id == target_id)),
      do: assign(socket, :confirming, target_id),
      else:
        push_patch(socket,
          to:
            Common.connection_path(
              socket.assigns.current_scope,
              socket.assigns.connection,
              :targets
            )
        )
  end

  defp open(socket, :add_target, _params) do
    if socket.assigns.connection.applies_to == "selected",
      do: find(socket, ""),
      else:
        push_patch(socket,
          to:
            Common.connection_path(
              socket.assigns.current_scope,
              socket.assigns.connection,
              :targets
            )
        )
  end

  defp open(socket, :version, _params),
    do: assign(socket, :form, to_form(%{"version" => ""}, as: :version))

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
        "applies_to" => connection.applies_to,
        "name" => connection.name,
        "argument" => connection.argument || "",
        "settings" => settings
      },
      as: :connection
    )
  end

  # The workspace's targets whose system/path holds `text`, by name, but those it applies
  # to already: the first page of the Targets index (`Apiary.Targets.page/3`).
  defp find(socket, text) do
    scope = socket.assigns.current_scope
    present = MapSet.new(socket.assigns.connection.targets, & &1.target_id)
    text = String.trim(text)

    rows =
      Targets.page(scope, %{text: if(text == "", do: nil, else: text), sort: :name}).rows
      |> Enum.reject(&MapSet.member?(present, &1.target.id))
      |> Enum.take(20)

    assign(socket,
      find: to_form(%{"text" => text}, as: :find),
      candidates: rows,
      candidates_shared: MapSet.new(for row <- rows, row.shared, do: row.target.path)
    )
  end

  ## Events

  @impl true
  def handle_event("find", %{"find" => %{"text" => text}}, socket),
    do: {:noreply, find(socket, text)}

  def handle_event("put_target", %{"id" => target_id}, socket) do
    %{current_scope: scope, connection: connection} = socket.assigns

    case Connections.put_target(scope, connection, target_id) do
      {:ok, connection} ->
        target = Enum.find(socket.assigns.candidates, &(&1.target.id == target_id))

        {:noreply,
         socket
         |> assign_connection(connection)
         |> find(socket.assigns.find.params["text"] || "")
         |> put_flash(
           :info,
           pgettext("plain", "%{name} now applies to %{target}.",
             name: connection.name,
             target: target && target.target.path
           )
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, refusal(socket, reason))}
    end
  end

  def handle_event("remove_target", %{"id" => target_id}, socket) do
    %{current_scope: scope, connection: connection} = socket.assigns

    case Connections.remove_target(scope, connection, target_id) do
      {:ok, connection} ->
        {:noreply,
         socket
         |> assign_connection(connection)
         |> put_flash(
           :info,
           gettext("The target is removed from %{name}.", name: connection.name)
         )
         |> push_patch(to: Common.connection_path(scope, connection, :targets))}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, refusal(socket, reason))
         |> push_patch(to: Common.connection_path(scope, connection, :targets))}
    end
  end

  def handle_event("validate", %{"connection" => params}, socket),
    do: {:noreply, assign(socket, :form, to_form(params, as: :connection))}

  def handle_event("save", %{"connection" => params}, socket) do
    %{current_scope: scope, connection: connection} = socket.assigns

    attrs =
      %{"applies_to" => params["applies_to"]}
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
        {:noreply,
         socket
         |> assign_connection(connection)
         |> put_flash(:info, gettext("%{name} is saved.", name: connection.name))
         |> push_patch(to: Common.connection_path(scope, connection, :settings))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, :form, to_form(params, as: :connection, errors: changeset.errors))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, refusal(socket, reason))}
    end
  end

  def handle_event("request_version", params, socket) do
    %{current_scope: scope, connection: connection} = socket.assigns

    attrs =
      if Common.url_source?(connection.source),
        do: %{"source" => connection.source},
        else: %{"source" => connection.source, "version" => params["version"]["version"]}

    case Integrations.request_release(scope, attrs) do
      {:ok, release} ->
        {:noreply,
         push_navigate(socket,
           to: Common.release_path(scope, release.id, connection.public_id)
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(
           socket,
           :form,
           to_form(params["version"] || %{}, as: :version, errors: changeset.errors)
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, refusal(socket, reason))}
    end
  end

  def handle_event("delete", _params, socket) do
    %{current_scope: scope, connection: connection} = socket.assigns

    case Connections.delete_connection(scope, connection) do
      {:ok, _deleted} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("%{name} is deleted.", name: connection.name))
         |> push_navigate(to: Common.index_path(scope))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, refusal(socket, reason))}
    end
  end

  defp refusal(socket, reason) do
    connections =
      case Connections.list_connections(socket.assigns.current_scope) do
        {:ok, connections} -> connections
        {:error, _} -> []
      end

    Common.refusal(reason, connections)
  end
end
