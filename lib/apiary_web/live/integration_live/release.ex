defmodule ApiaryWeb.IntegrationLive.Release do
  @moduledoc """
  A release of an integration the workspace asked for, before it is added
  (`/:org/:workspace/settings/integrations/releases/:release_id`), with the `secrets`
  feature: the second step of Add from a release, after `ApiaryWeb.IntegrationLive.Index`
  asked for it (`Apiary.Integrations.request_release/2`).

  While the release is pending, the page reads it again every few seconds
  (`Apiary.Integrations.get_release/2`): a job fetches it. Once it is ready, the page
  shows what its `description.json` says (`Apiary.Integrations.description/1`): its name,
  version, what it does, its roles, the secrets and plain settings it declares, and the
  file itself; then, to an owner or an
  admin, the form that adds it (`Apiary.Connections.create_integration/3`): its plain
  settings, its argument and where it applies. A failed release says why, by its code. A
  release whose source the instance no longer accepts (`Apiary.Integrations.accepted_source/1`)
  is shown and not offered.

  With `?for=<connection's public id>`, an integration of the same source, the release is
  another version of it, asked for from its Settings, and the page offers to move it there
  (`Apiary.Connections.change_release/3`) instead of adding it. The page says once that a
  run receives only its security policy.
  """
  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :secrets
  on_mount {ApiaryWeb.Access, :"connection.read"}

  alias Apiary.{Connections, Integrations}
  alias Apiary.Connections.Connection
  alias ApiaryWeb.IntegrationLive.Common
  alias ApiaryWeb.SettingsComponents

  # How often a pending release is read again, in milliseconds.
  @poll 2_000

  @impl true
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
      <:crumb :if={@moving} navigate={Common.connection_path(@current_scope, @moving)}>
        {elem(Common.names(@moving), 0)}
      </:crumb>
      <:crumb>{act(@moving)}</:crumb>

      <.settings_page
        section={:integrations}
        title={title(@release, @description)}
        measure="list"
      >
        <:subtitle>
          <span class="q-mono">{@release.source}</span>
          <span
            :if={@release.version || @release.requested_version}
            class="text-faint"
            aria-hidden="true"
          >
            ·
          </span>
          <span :if={@release.version || @release.requested_version} class="q-mono">
            {@release.version || @release.requested_version}
          </span>
        </:subtitle>

        <Common.not_on_runs />

        <%!-- What the poll finds, said once it changes: the release fetched, then read. A
             failure says itself, as an alert. --%>
        <p id="release-status" role="status" class="sr-only">
          <span :if={@release.state == "pending"}>{fetching()}</span>
          <span :if={@release.state == "ready"}>{gettext("The release is read.")}</span>
        </p>

        <div :if={@release.state == "pending"} id="release-pending" class="grid gap-2">
          <p class="inline-flex items-center gap-2 text-[13.5px]/5">
            <span class="loading loading-spinner loading-xs" aria-hidden="true"></span>
            {fetching()}
          </p>
          <p class="text-[13px]/5 text-muted">
            {gettext("This page shows what it says once it is read.")}
          </p>
        </div>

        <div :if={@release.state == "failed"} id="release-failed" class="grid gap-3">
          <.notice kind={:error}>{failure(@release.failure)}</.notice>
          <div :if={@may_write}>
            <.button
              id="ask-again"
              navigate={
                if @moving,
                  do: Common.connection_path(@current_scope, @moving, :version),
                  else: Common.add_path(@current_scope, ask_again(@release))
              }
            >
              {gettext("Ask for a release again")}
            </.button>
          </div>
        </div>

        <%= if @release.state == "ready" and @description do %>
          <.notice :if={!@accepted} kind={:warning}>
            {gettext(
              "This instance no longer accepts integrations from this source, so it can't be added."
            )}
          </.notice>

          <.found description={@description} release={@release} people={@people} />

          <.move_form
            :if={@moving && @may_write && @accepted}
            moving={@moving}
            release={@release}
          />
          <.add_form
            :if={!@moving && @may_write && @accepted}
            form={@form}
            description={@description}
            plain={@plain}
            patterns={@patterns}
            scope={@current_scope}
          />
          <p :if={!@may_write} id="release-readonly" class="text-[13px]/5 text-muted">
            {Common.only_admins(@current_scope)}
          </p>
        <% end %>
      </.settings_page>
    </Layouts.app>
    """
  end

  attr :description, :any, required: true
  attr :release, :any, required: true
  attr :people, :map, required: true

  defp found(assigns) do
    ~H"""
    <p :if={@description.about} id="release-about" class="max-w-[72ch] text-[13.5px]/5">
      {@description.about}
    </p>

    <SettingsComponents.part id="release-found" title={gettext("Found in its description.json")}>
      <dl class="grid grid-cols-[max-content_minmax(0,1fr)] gap-x-4 gap-y-2 text-[13px]/5">
        <dt class="text-faint">{gettext("Name")}</dt>
        <dd>
          {@description.title} <span class="q-mono text-muted">({@description.name})</span>
        </dd>
        <dt class="text-faint">{gettext("Version")}</dt>
        <dd class="q-mono">{@description.program_version}</dd>
        <dt :if={@description.domains} class="text-faint">{gettext("Domains")}</dt>
        <dd :if={@description.domains} class="q-mono">{Enum.join(@description.domains, ", ")}</dd>
        <dt class="text-faint">{gettext("Released on")}</dt>
        <dd>{Common.released_on(@release.forge_kind)}</dd>
        <dt class="text-faint">{gettext("Roles")}</dt>
        <dd id="release-roles" class="q-mono">{Enum.join(@description.roles, ", ")}</dd>
        <dt class="text-faint">{gettext("Secrets")}</dt>
        <dd :if={@description.secrets != []}>
          <span :for={secret <- @description.secrets} class="block">
            <span class="q-mono">{secret.name}</span>
            <span class="text-muted">· {secret.title}</span>
          </span>
        </dd>
        <dd :if={@description.secrets == []} class="text-muted">{gettext("None")}</dd>
        <dt class="text-faint">{gettext("Plain settings")}</dt>
        <dd :if={Common.plain_settings(@description) != []} class="q-mono">
          {Enum.map_join(Common.plain_settings(@description), ", ", & &1.name)}
        </dd>
        <dd :if={Common.plain_settings(@description) == []} class="text-muted">
          {gettext("None")}
        </dd>
        <dt class="text-faint">{gettext("Fetched")}</dt>
        <dd>
          <.time_ago :if={@release.fetched_at} at={@release.fetched_at} />
          <span :if={Common.who(@people, @release.requested_by_id)} class="text-muted">
            · {gettext("asked for by %{person}",
              person: Common.who(@people, @release.requested_by_id)
            )}
          </span>
        </dd>
        <dt class="text-faint">{gettext("Description digest")}</dt>
        <dd class="q-mono break-all">{@release.description_sha256}</dd>
      </dl>
      <p class="text-[12.5px]/[18px] text-faint">
        {gettext("The release is only read; nothing of it runs on Qory Apiary.")}
      </p>
    </SettingsComponents.part>

    <.code_block
      id="release-description"
      label="description.json"
      code={Jason.encode!(@description.document, pretty: true)}
    />
    """
  end

  attr :moving, :any, required: true
  attr :release, :any, required: true

  defp move_form(assigns) do
    ~H"""
    <SettingsComponents.part id="release-move" title={gettext("Change version")}>
      <p class="text-[13px]/5">
        <.rich text={
          rich_gettext("Move %{name} from %{from} to %{to}. Its settings and argument are kept.",
            name: {:part, :name},
            from: {:m, @moving.version},
            to: {:m, @release.version}
          )
        }>
          <:part name={:name}><Common.name names={@moving} /></:part>
        </.rich>
      </p>
      <div>
        <.button
          id="move-release"
          variant="primary"
          phx-click="move"
          loading_text={gettext("Saving")}
        >
          {gettext("Move to %{version}", version: @release.version)}
        </.button>
      </div>
    </SettingsComponents.part>
    """
  end

  attr :form, :any, required: true
  attr :description, :any, required: true
  attr :plain, :list, required: true
  attr :patterns, :list, required: true
  attr :scope, :any, required: true

  defp add_form(assigns) do
    ~H"""
    <SettingsComponents.part id="release-add" title={gettext("Add it")}>
      <.form for={@form} id="add-release-form" phx-change="validate" phx-submit="add" novalidate>
        <div class="grid gap-4">
          <%= for setting <- @plain do %>
            <div :if={setting.type == :boolean} class="grid gap-1.5">
              <.input
                id={"release-setting-#{setting.name}"}
                name={"integration[settings][#{setting.name}]"}
                type="checkbox"
                label={setting.title}
                value={@form.params["settings"][setting.name]}
                aria-describedby={setting.description && "release-setting-#{setting.name}-hint"}
              />
              <p
                :if={setting.description}
                id={"release-setting-#{setting.name}-hint"}
                class="text-[12.5px]/[18px] text-muted"
              >
                {setting.description}
              </p>
            </div>
            <.input
              :if={setting.type != :boolean}
              id={"release-setting-#{setting.name}"}
              name={"integration[settings][#{setting.name}]"}
              label={setting.title}
              hint={setting.description}
              value={@form.params["settings"][setting.name]}
              optional
              autocomplete="off"
            />
          <% end %>
          <.input
            :if={@patterns != []}
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
          <.input
            field={@form[:applies_to]}
            type="radio"
            label={Common.applies_label()}
            options={[{gettext("Every target"), "all"}, {gettext("Chosen targets"), "selected"}]}
            hint={gettext("You choose the targets on its page, once it is added.")}
          />
          <SettingsComponents.save
            id="add-release-save"
            cancel={Common.index_path(@scope)}
            cancel_by="navigate"
          >
            <.button type="submit" variant="primary" loading_text={gettext("Adding")}>
              {gettext("Add %{title}", title: @description.title)}
            </.button>
            <:note :if={@description.secrets != []}>
              {gettext("Qory Apiary links no stored secret to it.")}
            </:note>
          </SettingsComponents.save>
        </div>
      </.form>
    </SettingsComponents.part>
    """
  end

  defp title(%{state: "ready"}, %{title: title}), do: title
  defp title(release, _description), do: release.source

  defp fetching, do: gettext("Fetching the release's description.json and checksums.txt…")

  # The source and version a release was asked for with, for Add from a release to ask
  # again.
  defp ask_again(release) do
    for {key, value} <- [source: release.source, version: release.requested_version],
        is_binary(value),
        do: {key, value}
  end

  defp failure("integration_source_refused"),
    do: gettext("This instance doesn't accept integrations from this source.")

  defp failure("fetch_failed"),
    do:
      gettext(
        "The release's description.json and checksums.txt couldn't be fetched. Check the source and the version, and that the release is public."
      )

  defp failure("description_invalid"),
    do: gettext("The release's description.json is not a valid description of a program.")

  defp failure("integration_source_mismatch"),
    do:
      gettext(
        "What the release serves doesn't match its source: its checksums.txt, its version, or a description of the same version fetched before."
      )

  defp failure(_code), do: gettext("The release couldn't be read.")

  ## Mount, params and the poll

  @impl true
  def mount(%{"release_id" => id}, _session, socket) do
    scope = socket.assigns.current_scope

    case Integrations.get_release(scope, id) do
      {:ok, release} ->
        {:ok,
         socket
         |> assign(
           sections: SettingsComponents.sections(scope, :workspace),
           may_write: Common.may_write?(scope),
           people: Common.people(scope),
           moving: nil
         )
         |> assign_release(release)}

      {:error, _reason} ->
        raise ApiaryWeb.NotFound
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    source = socket.assigns.release.source

    # Only an integration of the release's own source moves to it; any other `for` is
    # not one, and the release is offered as it is.
    moving =
      with id when is_binary(id) <- params["for"],
           {:ok, %Connection{kind: "integration", source: ^source} = connection} <-
             Connections.get_connection(socket.assigns.current_scope, id) do
        connection
      else
        _ -> nil
      end

    {:noreply,
     assign(socket,
       moving: moving,
       page_title:
         SettingsComponents.page_title(socket.assigns.current_scope, :workspace, [act(moving)])
     )}
  end

  # The page's act, the breadcrumb's last segment and its title: another version of a
  # program, or one added from a release.
  defp act(nil), do: gettext("Add from a release")
  defp act(_moving), do: gettext("Change version")

  defp assign_release(socket, release) do
    description =
      case Integrations.description(release) do
        {:ok, description} -> description
        {:error, _} -> nil
      end

    if release.state == "pending" and connected?(socket),
      do: Process.send_after(self(), :poll, @poll)

    socket
    |> assign(
      release: release,
      description: description,
      accepted:
        release.state == "ready" and match?({:ok, _}, Integrations.accepted_source(release)),
      plain: if(description, do: Common.plain_settings(description), else: []),
      patterns: if(description, do: Common.argument_patterns(description), else: [])
    )
    |> assign_new(:form, fn ->
      to_form(%{"applies_to" => "all", "argument" => "", "settings" => %{}}, as: :integration)
    end)
  end

  @impl true
  def handle_info(:poll, socket) do
    case Integrations.get_release(socket.assigns.current_scope, socket.assigns.release.id) do
      {:ok, release} -> {:noreply, assign_release(socket, release)}
      {:error, _reason} -> {:noreply, socket}
    end
  end

  ## Events

  @impl true
  def handle_event("validate", %{"integration" => params}, socket) when is_map(params),
    do: {:noreply, assign(socket, :form, to_form(params, as: :integration))}

  def handle_event("add", %{"integration" => params}, socket) when is_map(params) do
    scope = socket.assigns.current_scope

    attrs = %{
      settings: Common.cast_settings(socket.assigns.plain, params["settings"]),
      argument: params["argument"] || "",
      applies_to: params["applies_to"]
    }

    case Connections.create_integration(scope, socket.assigns.release.id, attrs) do
      {:ok, connection} ->
        to =
          if connection.applies_to == "selected",
            do: Common.connection_path(scope, connection, :targets),
            else: Common.connection_path(scope, connection)

        {:noreply,
         socket
         |> put_flash(:info, gettext("%{name} is added.", name: Common.label(connection)))
         |> push_navigate(to: to)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, :form, to_form(params, as: :integration, errors: changeset.errors))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, refusal(scope, reason))}
    end
  end

  def handle_event("move", _params, %{assigns: %{moving: %Connection{}}} = socket) do
    %{current_scope: scope, moving: connection, release: release} = socket.assigns

    case Connections.change_release(scope, connection, release.id) do
      {:ok, connection} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("%{name} is at %{version}.",
             name: Common.label(connection),
             version: connection.version
           )
         )
         |> push_navigate(to: Common.connection_path(scope, connection, :settings))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, refusal(scope, reason))}
    end
  end

  # An event the page's controls do not send, or sent where they are not: nothing.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp refusal(scope, reason) do
    connections =
      case Connections.list_connections(scope) do
        {:ok, connections} -> connections
        {:error, _} -> []
      end

    Common.refusal(scope, reason, connections)
  end
end
