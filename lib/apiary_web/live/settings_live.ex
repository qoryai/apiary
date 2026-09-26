defmodule ApiaryWeb.SettingsLive do
  @moduledoc """
  Organisation and workspace settings, one page in two places: the organisation's,
  `/:org/settings` (`:organisation`), with its name, its slug and the owners; and the
  workspace's, `/:org/:workspace/settings` (`:workspace`), with its name, its slug and
  retention: how long the workspace keeps a run's events and log output, and what the
  nightly job last pruned. A slug is shown, not edited: renaming one is not decided yet.

  The proof of the domain's words (`docs/lingo.md`): every sentence is a gettext call in
  engine words, and the software domain's catalogue says organisation and workspace.
  """
  use ApiaryWeb, :live_view

  alias Apiary.{Access, Organisations, Retention}
  alias ApiaryWeb.UserAuth

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={if @live_action == :organisation, do: :organisation, else: :settings}
      width="narrow"
    >
      <.header :if={@live_action == :organisation}>
        {gettext("Organisation settings")}
        <:subtitle>
          {gettext("The name of this organisation, where its pages are, and who owns it.")}
        </:subtitle>
      </.header>

      <.header :if={@live_action == :workspace}>
        {gettext("Workspace settings")}
        <:subtitle>
          {gettext("The name of this workspace, where its pages are, and how long runs are kept.")}
        </:subtitle>
      </.header>

      <.notice :if={!may?(@current_scope, settings_action(@live_action))} kind={:info}>
        {gettext("Only owners can change these settings. Ask an owner if a name needs to change.")}
      </.notice>

      <.card :if={@live_action == :organisation}>
        <:title>{gettext("Organisation name")}</:title>
        <.form
          for={@organisation_form}
          id="organisation-form"
          phx-change="validate_organisation"
          phx-submit="save_organisation"
          class="grid max-w-[420px] gap-4"
        >
          <.input
            field={@organisation_form[:name]}
            type="text"
            label={gettext("Name")}
            debounce="200"
            autocomplete="off"
            disabled={!may?(@current_scope, :"organisation.rename")}
            required
          />
        </.form>
        <p id="organisation-slug" class="text-[13px]/[20px] text-muted">
          <.rich text={
            rich_gettext("Its pages are under %{path}. Renaming the organisation keeps it.",
              path: {:m, ~p"/#{@current_scope.organisation}"}
            )
          } />
        </p>
        <:footer>
          <span>{gettext("Shown in the sidebar and in invitations.")}</span>
          <.button
            :if={may?(@current_scope, :"organisation.rename")}
            type="submit"
            form="organisation-form"
            disabled={!@organisation_form.source.valid?}
            loading_text={gettext("Saving")}
          >
            {gettext("Save")}
          </.button>
        </:footer>
      </.card>

      <.card :if={@live_action == :workspace}>
        <:title>{gettext("Workspace name")}</:title>
        <.form
          for={@workspace_form}
          id="workspace-form"
          phx-change="validate_workspace"
          phx-submit="save_workspace"
          class="grid max-w-[420px] gap-4"
        >
          <.input
            field={@workspace_form[:name]}
            type="text"
            label={gettext("Name")}
            debounce="200"
            autocomplete="off"
            disabled={!may?(@current_scope, :"workspace.rename")}
            required
          />
        </.form>
        <p id="workspace-slug" class="text-[13px]/[20px] text-muted">
          <.rich text={
            rich_gettext("Its pages are under %{path}. Renaming the workspace keeps it.",
              path: {:m, ~p"/#{@current_scope.organisation}/#{@current_scope.workspace}"}
            )
          } />
        </p>
        <:footer>
          <span>{gettext("Shown in the sidebar and as the overview title.")}</span>
          <.button
            :if={may?(@current_scope, :"workspace.rename")}
            type="submit"
            form="workspace-form"
            disabled={!@workspace_form.source.valid?}
            loading_text={gettext("Saving")}
          >
            {gettext("Save")}
          </.button>
        </:footer>
      </.card>

      <.card :if={@live_action == :workspace}>
        <:title>{gettext("Retention")}</:title>
        <.form
          for={@retention_form}
          id="retention-form"
          phx-change="validate_retention"
          phx-submit="save_retention"
          class="grid max-w-[420px] gap-4"
        >
          <.input
            field={@retention_form[:events_retention_days]}
            type="number"
            label={gettext("Keep a run's events for")}
            placeholder={gettext("Forever")}
            min="1"
            max="3650"
            step="1"
            inputmode="numeric"
            debounce="200"
            disabled={!may?(@current_scope, :"retention.edit")}
          />
          <.input
            field={@retention_form[:log_retention_days]}
            type="number"
            label={gettext("Keep a run's log output for")}
            placeholder={gettext("Forever")}
            min="1"
            max="3650"
            step="1"
            inputmode="numeric"
            debounce="200"
            disabled={!may?(@current_scope, :"retention.edit")}
          />
        </.form>
        <p class="max-w-[60ch] text-[13px]/[20px] text-muted">
          {gettext(
            "In days; empty keeps everything. A run that ended is pruned whole, counted from its last event: first its log output, then its timeline. The run stays in the list with its state, its counts and its connections, and its page says what was pruned and when. Pruned data comes back only from a backup."
          )}
        </p>
        <:footer>
          <span id="retention-summary">{retention_summary(@current_scope.workspace)}</span>
          <.button
            :if={may?(@current_scope, :"retention.edit")}
            type="submit"
            form="retention-form"
            disabled={!@retention_form.source.valid?}
            loading_text={gettext("Saving")}
          >
            {gettext("Save")}
          </.button>
        </:footer>
      </.card>

      <.card :if={@live_action == :workspace} padding={false}>
        <:title>{gettext("Pruned")}</:title>
        <p :if={@retention_runs == []} id="retention-runs-empty" class="px-5 py-4 text-muted">
          {if retention_set?(@current_scope.workspace),
            do: gettext("Nothing has been pruned yet. The job runs every night."),
            else: gettext("Nothing is pruned: this workspace keeps everything.")}
        </p>
        <ul :if={@retention_runs != []} id="retention-runs" class="divide-y divide-line">
          <li
            :for={run <- @retention_runs}
            id={"retention-run-#{run.id}"}
            class="flex flex-wrap items-baseline gap-x-2.5 gap-y-0.5 px-5 py-2.5"
          >
            <span class="font-medium tabular-nums">{Format.datetime(run.started_at, zone: true)}</span>
            <.badge :if={run.trigger == "manual"}>{gettext("By hand")}</.badge>
            <.badge :if={!run.complete} color="warning">{gettext("Not finished")}</.badge>
            <span class="w-full text-[13px]/[20px] text-muted">{pruned_sentence(run)}</span>
          </li>
        </ul>
        <:footer>
          <span>
            {ngettext(
              "The last run of the nightly job. It is also a line in the server's log.",
              "The last %{number} runs of the nightly job. Each is also a line in the server's log.",
              length(@retention_runs),
              number: Format.number(length(@retention_runs))
            )}
          </span>
        </:footer>
      </.card>

      <.card :if={@live_action == :organisation} padding={false}>
        <:title>{gettext("Owners")}</:title>
        <:actions>
          <.button navigate={~p"/#{@current_scope.organisation}/members"}>
            {gettext("Manage members")}
          </.button>
        </:actions>
        <ul id="owners" class="divide-y divide-line">
          <li
            :for={owner <- @owners}
            id={"owner-#{owner.id}"}
            class="flex flex-wrap items-center gap-x-2.5 gap-y-1 px-5 py-2.5"
          >
            <.avatar
              name={owner.user.email}
              kind={if owner.user_id == @current_scope.user.id, do: "self", else: "person"}
            />
            <span class="min-w-0 truncate font-medium">{owner.user.email}</span>
            <.badge :if={owner.user_id == @current_scope.user.id}>{gettext("You")}</.badge>
            <span class="ml-auto text-[13px]/[18px] tabular-nums text-faint">
              {gettext("since %{date}", date: Format.date(owner.inserted_at))}
            </span>
          </li>
        </ul>
        <:footer>
          <span>{gettext("The last owner cannot be removed or demoted.")}</span>
        </:footer>
      </.card>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: page_title(socket.assigns.live_action))
     |> assign_forms()
     |> load_owners()
     |> load_retention_runs()}
  end

  @impl true
  def handle_event("validate_organisation", %{"organisation" => params}, socket) do
    changeset =
      socket.assigns.current_scope.organisation
      |> Organisations.change_organisation(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :organisation_form, to_form(changeset))}
  end

  def handle_event("save_organisation", %{"organisation" => params}, socket) do
    scope = socket.assigns.current_scope

    case Organisations.update_organisation(scope, params) do
      {:ok, organisation} ->
        {:noreply,
         socket
         |> assign(:current_scope, %{scope | organisation: organisation})
         |> assign_forms()
         |> put_flash(:info, gettext("Organisation renamed to %{name}.", name: organisation.name))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :organisation_form, to_form(changeset))}

      {:error, :forbidden} ->
        {:noreply, unauthorized(socket)}
    end
  end

  def handle_event("validate_workspace", %{"workspace" => params}, socket) do
    changeset =
      socket.assigns.current_scope.workspace
      |> Organisations.change_workspace(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :workspace_form, to_form(changeset))}
  end

  def handle_event("save_workspace", %{"workspace" => params}, socket) do
    scope = socket.assigns.current_scope

    case Organisations.update_workspace(scope, params) do
      {:ok, workspace} ->
        {:noreply,
         socket
         |> assign(:current_scope, %{scope | workspace: workspace})
         |> assign_forms()
         |> put_flash(:info, gettext("Workspace renamed to %{name}.", name: workspace.name))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :workspace_form, to_form(changeset))}

      {:error, :forbidden} ->
        {:noreply, unauthorized(socket)}
    end
  end

  def handle_event("validate_retention", %{"retention" => params}, socket) do
    changeset =
      socket.assigns.current_scope.workspace
      |> Retention.change_retention(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :retention_form, to_form(changeset, as: :retention))}
  end

  def handle_event("save_retention", %{"retention" => params}, socket) do
    scope = socket.assigns.current_scope

    case Retention.update_retention(scope, params) do
      {:ok, workspace} ->
        {:noreply,
         socket
         |> assign(:current_scope, %{scope | workspace: workspace})
         |> assign_forms()
         |> put_flash(:info, gettext("Retention saved.") <> " " <> retention_summary(workspace))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :retention_form, to_form(changeset, as: :retention))}

      {:error, :forbidden} ->
        {:noreply, unauthorized(socket)}
    end
  end

  # What the page's forms change: the organisation's name on the organisation's page, the
  # workspace's name on the workspace's; retention is asked for on its own.
  defp settings_action(:organisation), do: :"organisation.rename"
  defp settings_action(:workspace), do: :"workspace.rename"

  # The organisation's actions are asked of the organisation, the workspace's of the
  # workspace.
  defp may?(scope, :"organisation.rename" = action),
    do: Access.can?(scope, action, scope.organisation)

  defp may?(scope, action), do: Access.can?(scope, action, scope.workspace)

  defp page_title(:organisation), do: gettext("Organisation settings")
  defp page_title(:workspace), do: gettext("Workspace settings")

  defp assign_forms(socket) do
    scope = socket.assigns.current_scope

    assign(socket,
      organisation_form: to_form(Organisations.change_organisation(scope.organisation)),
      workspace_form: to_form(Organisations.change_workspace(scope.workspace)),
      retention_form: to_form(Retention.change_retention(scope.workspace), as: :retention)
    )
  end

  defp load_owners(socket) do
    owners =
      socket.assigns.current_scope
      |> Organisations.list_members()
      |> Enum.filter(&(&1.level == :owner))

    assign(socket, :owners, owners)
  end

  defp load_retention_runs(socket) do
    assign(
      socket,
      :retention_runs,
      Retention.list_retention_runs(socket.assigns.current_scope, 5)
    )
  end

  defp retention_set?(workspace),
    do: is_integer(workspace.events_retention_days) or is_integer(workspace.log_retention_days)

  defp retention_summary(%{events_retention_days: nil, log_retention_days: nil}),
    do: gettext("This workspace keeps everything.")

  defp retention_summary(%{events_retention_days: events, log_retention_days: nil}),
    do: gettext("Events and log output are pruned after %{days}.", days: days(events))

  defp retention_summary(%{events_retention_days: nil, log_retention_days: log}),
    do: gettext("Log output is pruned after %{days}; events are kept.", days: days(log))

  defp retention_summary(%{events_retention_days: events, log_retention_days: log}) do
    gettext("Log output is pruned after %{log_days}, events after %{events_days}.",
      log_days: days(log),
      events_days: days(events)
    )
  end

  defp days(n), do: ngettext("%{number} day", "%{number} days", n, number: Format.number(n))

  defp pruned_sentence(%{runs_pruned: 0}), do: gettext("Nothing was old enough to prune.")

  defp pruned_sentence(run) do
    pruned =
      gettext("%{runs}: %{events} and %{bytes} of log output in %{chunks}.",
        runs:
          ngettext("%{number} run", "%{number} runs", run.runs_pruned,
            number: Format.number(run.runs_pruned)
          ),
        events:
          ngettext("%{number} event", "%{number} events", run.events_deleted,
            number: Format.number(run.events_deleted)
          ),
        bytes: Format.bytes(run.log_bytes_deleted),
        chunks:
          ngettext("%{number} chunk", "%{number} chunks", run.log_chunks_deleted,
            number: Format.number(run.log_chunks_deleted)
          )
      )

    Enum.join([pruned | cutoffs(run)], " ")
  end

  defp cutoffs(%{log_cutoff: nil, events_cutoff: nil}), do: []

  defp cutoffs(%{log_cutoff: log, events_cutoff: nil}),
    do: [gettext("Pruned log output from before %{date}.", date: Format.date(log))]

  defp cutoffs(%{log_cutoff: nil, events_cutoff: events}),
    do: [gettext("Pruned events from before %{date}.", date: Format.date(events))]

  defp cutoffs(%{log_cutoff: log, events_cutoff: events}) do
    [
      gettext("Pruned log output from before %{log_date}, events from before %{events_date}.",
        log_date: Format.date(log),
        events_date: Format.date(events)
      )
    ]
  end

  # Refused on the membership as it is now: the page's scope is stale, and is loaded again.
  defp unauthorized(socket) do
    socket
    |> UserAuth.reload_scope()
    |> assign_forms()
    |> put_flash(:error, gettext("Only owners can change these settings."))
  end
end
