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
      danger zone, its removal confirmed in place (`…/delete`).

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

  alias Apiary.{Connections, Integrations, Repo}
  alias Apiary.Connections.Connection
  alias Apiary.Integrations.Release
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
        {elem(@names, 0)}
      </:crumb>
      <:crumb>{gettext("Add target")}</:crumb>

      <.page_form
        id="add-target-page"
        title={gettext("Add a target to %{name}", name: Common.label(@names))}
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
            phx-hook="FocusOn"
          />
        </.form>
        <p id="target-candidates-status" role="status" class="text-[13px]/5 text-muted">
          <span :if={@candidates == []} id="target-candidates-empty">
            {gettext("No target found that it doesn't apply to already.")}
          </span>
          <span :if={@candidates != [] and !@candidates_more} id="target-candidates-count">
            {ngettext("%{number} target found.", "%{number} targets found.", length(@candidates),
              number: Format.number(length(@candidates))
            )}
          </span>
          <span :if={@candidates_more} id="target-candidates-more">
            {gettext("The first %{number} by name: type to find another.",
              number: Format.number(@candidates_limit)
            )}
          </span>
        </p>
        <.table
          :if={@candidates != []}
          id="target-candidates"
          label={gettext("Targets")}
          rows={@candidates}
          row_id={&"candidate-#{&1.id}"}
        >
          <:col :let={target} label={gettext("Target")} kind="title">
            <RunComponents.target_name
              system={target.system}
              path={target.path}
              shared={@candidates_shared}
            />
          </:col>
          <:action :let={target}>
            <.button
              id={"add-#{target.id}"}
              size="xs"
              phx-click="put_target"
              phx-value-id={target.id}
              phx-hook="FocusOn"
              aria-label={gettext("Add %{target}", target: shown_name(target, @candidates_shared))}
            >
              {gettext("Add")}
            </.button>
          </:action>
        </.table>
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
        <Common.not_yet />
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
                "An integration from an address has one release: what its address serves. It is fetched again, and you move to it from there."
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
      <:crumb>{elem(@names, 0)}</:crumb>

      <.settings_page
        heading={gettext("Workspace settings")}
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
          <dt :if={@description} class="text-faint">{gettext("Roles")}</dt>
          <dd :if={@description} id="connection-roles" class="q-mono">
            {Enum.join(@description.roles, ", ")}
          </dd>
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
        <dt class="text-faint">{pgettext("plain", "Applies to")}</dt>
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
        {gettext("Calls its API.")}
      </p>
      <p
        :if={@description && "tool" in @description.ways}
        id="connection-tool-way"
        class="text-[13px]/5 text-muted"
      >
        {gettext("Its description also offers it as a tool (MCP), which no runner runs yet.")}
      </p>
      <p
        :if={!@description || "credential" not in @description.ways}
        class="text-[13px]/5 text-muted"
      >
        {gettext("Its description offers no way a runner runs yet.")}
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
            "A stored secret can't be linked to it yet. The workspace's secrets are in %{secrets}.",
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
      :if={@target_rows != [] and @connection.applies_to == "selected"}
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
          id={"remove-target-#{row.id}"}
          variant="link"
          patch={Common.remove_target_path(@current_scope, @connection, row.id)}
          phx-hook="FocusOn"
          aria-label={
            gettext("Remove %{target}", target: row.target && shown_name(row.target, @shared))
          }
        >
          {gettext("Remove")}
        </.button>
      </:action>
      <:confirm :let={row}>
        <.inline_confirm
          id={"target-#{row.id}-confirm"}
          question={
            gettext("Remove %{target} from %{name}?",
              target: row.target && shown_name(row.target, @shared),
              name: Common.label(@names)
            )
          }
          cancel={Common.connection_path(@current_scope, @connection, :targets)}
        >
          {gettext("It no longer applies to that target.")}
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
        phx-hook="FocusOn"
      >
        <.icon name="hero-plus-micro" class="size-4" />{gettext("Add target")}
      </.button>
    </div>
    """
  end

  # A target as the page names it in words: its path, with its system before it only where
  # the path is on more than one system of the workspace (`RunComponents.target_name/1`).
  defp shown_name(%Target{system: system, path: path}, shared),
    do: if(MapSet.member?(shared, path), do: "#{system}/#{path}", else: path)

  ## Settings

  defp settings(assigns) do
    ~H"""
    <p :if={!@may_write} id="connection-readonly" class="text-[13px]/5 text-muted">
      {Common.only_admins(@current_scope)}
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
          <div :if={setting.type == :boolean} class="grid gap-1.5">
            <.input
              id={"connection-setting-#{setting.name}"}
              name={"connection[settings][#{setting.name}]"}
              type="checkbox"
              label={setting.title}
              value={@form.params["settings"][setting.name]}
              aria-describedby={setting.description && "connection-setting-#{setting.name}-hint"}
            />
            <p
              :if={setting.description}
              id={"connection-setting-#{setting.name}-hint"}
              class="text-[12.5px]/[18px] text-muted"
            >
              {setting.description}
            </p>
          </div>
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
        {gettext("It is removed from this workspace. This cannot be undone.")}
      </.removal>
    </SettingsComponents.danger_zone>
    """
  end

  defp removal_title(%Connection{kind: "runtime"}), do: gettext("Remove this runtime")
  defp removal_title(%Connection{kind: "integration"}), do: gettext("Remove this integration")
  defp removal_title(%Connection{kind: "service"}), do: gettext("Remove this service")

  defp removal_button(%Connection{kind: "runtime"}), do: gettext("Remove runtime…")
  defp removal_button(%Connection{kind: "integration"}), do: gettext("Remove integration…")
  defp removal_button(%Connection{kind: "service"}), do: gettext("Remove service…")

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

  # How many targets Add target lists at once, by name.
  @candidates_limit 20

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
       candidates_more: false,
       candidates_limit: @candidates_limit,
       candidates_shared: MapSet.new(),
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
      names: Common.names(connection),
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
       |> put_flash(:error, Common.only_admins(scope))
       |> push_patch(to: Common.connection_path(scope, socket.assigns.connection))}
    else
      left = socket.assigns.confirming

      {:noreply,
       socket
       |> assign(tab: tab(action), confirming: nil, version_problems: [])
       |> assign(:page_title, elem(socket.assigns.names, 0) <> " · " <> gettext("Integrations"))
       |> open(action, params)
       |> focus_after_confirm(left)}
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
    %{connection: connection, target_rows: rows} = socket.assigns

    if connection.applies_to == "selected" and Enum.any?(rows, &(&1.id == target_id)),
      do: assign(socket, :confirming, target_id),
      else: push_patch(socket, to: targets_path(socket))
  end

  defp open(socket, :add_target, _params) do
    if socket.assigns.connection.applies_to == "selected",
      do: find(socket, ""),
      else: push_patch(socket, to: targets_path(socket))
  end

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

  defp targets_path(socket),
    do: Common.connection_path(socket.assigns.current_scope, socket.assigns.connection, :targets)

  # Once a row's removal is no longer asked, by Cancel, Escape or its answer, the focus
  # goes back to the row's Remove, or, where the row is gone, to Add target; never to the
  # page's body.
  defp focus_after_confirm(socket, nil), do: socket

  defp focus_after_confirm(%{assigns: %{confirming: nil, live_action: :targets}} = socket, id) do
    if Enum.any?(socket.assigns.target_rows, &(&1.id == id)),
      do: push_event(socket, "run:focus", %{id: "remove-target-#{id}"}),
      else: push_event(socket, "run:focus", %{id: "add-target"})
  end

  defp focus_after_confirm(socket, _id), do: socket

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

  # The workspace's targets the connection does not apply to yet whose system/path holds
  # `text`, by name: the first `@candidates_limit` of them, and whether there are more.
  defp find(socket, text) do
    scope = socket.assigns.current_scope
    present = Enum.map(socket.assigns.connection.targets, & &1.target_id)
    text = String.trim(text)

    query =
      from t in Target,
        where:
          t.organisation_id == ^scope.organisation.id and
            t.workspace_id == ^scope.workspace.id and t.id not in ^present,
        order_by: [asc: t.path, asc: t.system],
        limit: ^(@candidates_limit + 1)

    query =
      case Apiary.Runs.like(text) do
        nil ->
          query

        pattern ->
          from t in query, where: ilike(fragment("? || '/' || ?", t.system, t.path), ^pattern)
      end

    found = Repo.all(query)
    targets = Enum.take(found, @candidates_limit)

    assign(socket,
      find: to_form(%{"text" => text}, as: :find),
      candidates: targets,
      candidates_more: length(found) > @candidates_limit,
      candidates_shared: Apiary.Runs.shared_paths(scope, Enum.map(targets, & &1.path))
    )
  end

  # Where the focus goes once a target is added from its row, which leaves the list: the
  # next row's Add, or the one before where it was the last, or else the search field.
  defp next_focus(before, target_id, now) do
    present = MapSet.new(now, & &1.id)
    {above, [_added | below]} = Enum.split_while(before, &(&1.id != target_id))

    case Enum.find(below, &MapSet.member?(present, &1.id)) ||
           Enum.find(Enum.reverse(above), &MapSet.member?(present, &1.id)) || List.first(now) do
      nil -> "find_text"
      target -> "add-#{target.id}"
    end
  end

  ## Events

  @impl true
  def handle_event("find", %{"find" => %{"text" => text}}, socket) when is_binary(text),
    do: {:noreply, find(socket, text)}

  def handle_event("put_target", %{"id" => target_id}, socket) when is_binary(target_id) do
    %{current_scope: scope, connection: connection, candidates: before} = socket.assigns

    case Connections.put_target(scope, connection, target_id) do
      {:ok, connection} ->
        socket =
          socket
          |> assign_connection(connection)
          |> find(socket.assigns.find.params["text"] || "")

        row = Enum.find(socket.assigns.target_rows, &(&1.id == target_id))

        focus =
          if Enum.any?(before, &(&1.id == target_id)),
            do: next_focus(before, target_id, socket.assigns.candidates),
            else: "find_text"

        {:noreply,
         socket
         |> put_flash(
           :info,
           pgettext("plain", "%{name} now applies to %{target}.",
             name: Common.label(socket.assigns.names),
             target: row && row.target && shown_name(row.target, socket.assigns.shared)
           )
         )
         |> push_event("run:focus", %{id: focus})}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, refusal(socket, reason))}
    end
  end

  def handle_event("remove_target", %{"id" => target_id}, socket) when is_binary(target_id) do
    %{current_scope: scope, connection: connection} = socket.assigns

    case Connections.remove_target(scope, connection, target_id) do
      {:ok, connection} ->
        socket = assign_connection(socket, connection)

        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("The target is removed from %{name}.",
             name: Common.label(socket.assigns.names)
           )
         )
         |> push_patch(to: Common.connection_path(scope, connection, :targets))}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, refusal(socket, reason))
         |> push_patch(to: Common.connection_path(scope, connection, :targets))}
    end
  end

  def handle_event("validate", %{"connection" => params}, socket) when is_map(params),
    do: {:noreply, assign(socket, :form, to_form(params, as: :connection))}

  def handle_event("save", %{"connection" => params}, socket) when is_map(params) do
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

    Common.refusal(scope, reason, connections)
  end
end
