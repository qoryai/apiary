defmodule ApiaryWeb.SettingsLive do
  @moduledoc """
  The core's sections of the organisation's and the workspace's settings, one section a
  page, with every kind of settings the reader may change listed in the sidebar
  (`ApiaryWeb.SettingsComponents`).

  - The organisation's: General, `/:org/settings` (`:organisation`), its name, its slug and
    its owners; Workspaces, `/:org/settings/workspaces` (`:workspaces`), for an owner or an
    admin, with the deletion of one and the cancelling of a deletion; Danger zone,
    `/:org/settings/danger` (`:danger`), the deletion of the organisation.
  - The workspace's: General, `/:org/:workspace/settings` (`:workspace`), its name and its
    slug; Retention, `/:org/:workspace/settings/retention` (`:retention`), how long the
    workspace keeps a run's events and log output, and what the nightly job last pruned;
    Danger zone, `/:org/:workspace/settings/danger` (`:workspace_danger`), its deletion.

  A slug is shown, not edited: renaming one is not decided yet. Deleting asks to type the
  slug, in a modal over its section: `/:org/settings/delete` (`:delete_organisation`),
  `/:org/settings/workspaces/:workspace_id/delete` (`:delete_workspace`) and
  `/:org/:workspace/settings/delete` (`:delete_this_workspace`). A workspace marked for
  deletion is a notice at the top of Workspaces, where an owner or an admin cancels it
  until it is purged (`Apiary.Deletion`).

  An edition adds sections to the organisation's settings, each a page of its own
  (`ApiaryWeb.SettingsComponents`), and to each workspace's ⋯ menu in Workspaces the items
  its `:workspace_actions` slot renders (`ApiaryWeb.Extension`).

  The proof of the domain's words (`docs/lingo.md`): every sentence is a gettext call in
  engine words, and the software domain's catalogue says organisation and workspace.
  """
  use ApiaryWeb, :live_view

  alias Apiary.{Access, Deletion, Organisations, Retention}
  alias ApiaryWeb.{SettingsComponents, UserAuth}

  # Each page of this LiveView: the settings it is part of and its section's key.
  @sections %{
    organisation: {:organisation, :organisation},
    workspaces: {:organisation, :workspaces},
    delete_workspace: {:organisation, :workspaces},
    danger: {:organisation, :danger},
    delete_organisation: {:organisation, :danger},
    workspace: {:workspace, :general},
    retention: {:workspace, :retention},
    workspace_danger: {:workspace, :workspace_danger},
    delete_this_workspace: {:workspace, :workspace_danger}
  }

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={if @page == :organisation, do: :organisation, else: :settings}
      settings={@settings_nav}
      section={@section}
    >
      <SettingsComponents.layout
        scope={@current_scope}
        kind={@page}
        current={@section}
        title={section_title(@section)}
      >
        <:subtitle>{section_subtitle(@page, @section)}</:subtitle>
        {section(assigns)}
      </SettingsComponents.layout>

      <.modal
        :if={@live_action == :delete_organisation}
        id="delete-organisation-modal"
        title={gettext("Delete %{name}", name: @current_scope.organisation.name)}
        on_cancel={JS.patch(~p"/#{@current_scope.organisation}/settings/danger")}
      >
        <p class="text-muted">
          {gettext(
            "The organisation, its workspaces and everything in them disappear for every member at once, and its access keys stop working. It is purged after %{days}; until then you can cancel the deletion from your organisations page.",
            days: days(Deletion.grace_days())
          )}
        </p>
        <.form
          for={@confirm_form}
          id="delete-organisation-form"
          phx-change="confirm"
          phx-submit="delete_organisation"
          class="grid gap-4"
        >
          <.input
            field={@confirm_form[:slug]}
            type="text"
            label={
              gettext("Type the organisation's slug, %{slug}, to confirm",
                slug: @current_scope.organisation.slug
              )
            }
            autocomplete="off"
            spellcheck="false"
            debounce="0"
          />
        </.form>
        <:footer>
          <.button patch={~p"/#{@current_scope.organisation}/settings/danger"} data-autofocus>
            {gettext("Cancel")}
          </.button>
          <.button
            id="delete-organisation-confirm"
            variant="danger"
            type="submit"
            form="delete-organisation-form"
            disabled={@confirm_form[:slug].value != @current_scope.organisation.slug}
            loading_text={gettext("Deleting")}
          >
            {gettext("Delete organisation")}
          </.button>
        </:footer>
      </.modal>

      <.modal
        :if={@live_action in [:delete_workspace, :delete_this_workspace] && @deleting}
        id="delete-workspace-modal"
        title={gettext("Delete %{name}", name: @deleting.name)}
        on_cancel={JS.patch(section_path(@current_scope, @live_action))}
      >
        <p class="text-muted">
          {gettext(
            "The workspace disappears at once, with its runs, policy and access keys, which stop working. Its members stay in the organisation. It is purged after %{days}; until then an owner or an admin can cancel the deletion in the organisation's settings.",
            days: days(Deletion.grace_days())
          )}
        </p>
        <.form
          for={@confirm_form}
          id="delete-workspace-form"
          phx-change="confirm"
          phx-submit="delete_workspace"
          class="grid gap-4"
        >
          <.input
            field={@confirm_form[:slug]}
            type="text"
            label={gettext("Type the workspace's slug, %{slug}, to confirm", slug: @deleting.slug)}
            autocomplete="off"
            spellcheck="false"
            debounce="0"
          />
        </.form>
        <:footer>
          <.button patch={section_path(@current_scope, @live_action)} data-autofocus>
            {gettext("Cancel")}
          </.button>
          <.button
            id="delete-workspace-confirm"
            variant="danger"
            type="submit"
            form="delete-workspace-form"
            disabled={@confirm_form[:slug].value != @deleting.slug}
            loading_text={gettext("Deleting")}
          >
            {gettext("Delete workspace")}
          </.button>
        </:footer>
      </.modal>
    </Layouts.app>
    """
  end

  # The organisation's General: its name and its owners.
  defp section(%{section: :organisation} = assigns) do
    ~H"""
    <.notice :if={refused_for_level?(@current_scope, :"organisation.rename")} kind={:info}>
      {gettext(
        "Only owners and admins can change these settings. Ask one of them if a name needs to change."
      )}
    </.notice>

    <.card>
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
        <span>{gettext("Shown in the breadcrumb, the switcher and invitations.")}</span>
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

    <.card padding={false}>
      <:title>{gettext("Owners")}</:title>
      <:actions>
        <.button navigate={~p"/#{@current_scope.organisation}/settings/people"}>
          {gettext("Manage people")}
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
          <span :if={owner.user_id == @current_scope.user.id} class="text-[12.5px] text-faint">
            {gettext("you")}
          </span>
          <span class="ml-auto text-[13px]/[18px] tabular-nums text-faint">
            {gettext("since %{date}", date: Format.date(owner.inserted_at))}
          </span>
        </li>
      </ul>
      <:footer>
        <span>{gettext("The last owner cannot be removed or demoted.")}</span>
      </:footer>
    </.card>
    """
  end

  # The organisation's Workspaces: each with the edition's actions and its deletion, and
  # the ones marked for deletion, whose deletion an owner or an admin cancels.
  defp section(%{section: :workspaces} = assigns) do
    ~H"""
    <.notice :for={workspace <- @marked_workspaces} kind={:warning}>
      <div
        id={"marked-workspace-#{workspace.id}"}
        class="flex flex-wrap items-center justify-between gap-x-4 gap-y-2"
      >
        <span>
          <.rich text={
            rich_gettext(
              "The workspace %{name} is deleted and is purged on %{date}, with its runs and access keys. Until then an owner or an admin can cancel the deletion.",
              name: {:b, workspace.name},
              date: Format.date(workspace.purge_after)
            )
          } />
        </span>
        <.button
          :if={may?(@current_scope, :"workspace.restore")}
          id={"restore-workspace-#{workspace.id}"}
          size="xs"
          phx-click="restore_workspace"
          phx-value-id={workspace.id}
          aria-label={gettext("Cancel the deletion of %{name}", name: workspace.name)}
          loading_text={gettext("Cancelling")}
        >
          {gettext("Cancel deletion")}
        </.button>
      </div>
    </.notice>

    <.table
      id="workspaces"
      label={gettext("Workspaces")}
      rows={@workspaces}
      row_id={&"workspace-#{&1.id}"}
    >
      <:col :let={workspace} label={gettext("Workspace")} kind="title">
        <span class="q-nm">
          <.link
            navigate={~p"/#{@current_scope.organisation}/#{workspace}"}
            class="q-title hover:underline"
          >
            {workspace.name}
          </.link>
          <span class="q-side q-mono">{workspace.slug}</span>
        </span>
      </:col>
      <:col :let={workspace} label={gettext("Created")} from="sm">
        <span class="tabular-nums">{Format.day(workspace.inserted_at)}</span>
      </:col>
      <:action :let={workspace}>
        <.row_menu
          id={"workspace-#{workspace.id}-menu"}
          label={gettext("Actions for the workspace %{name}", name: workspace.name)}
        >
          <ApiaryWeb.Extension.slot
            name={:workspace_actions}
            scope={@current_scope}
            workspace={workspace}
          />
          <.menu_item
            :if={length(@workspaces) > 1}
            id={"workspace-#{workspace.id}-delete"}
            patch={~p"/#{@current_scope.organisation}/settings/workspaces/#{workspace.id}/delete"}
            aria-label={gettext("Delete the workspace %{name}", name: workspace.name)}
          >
            {gettext("Delete…")}
          </.menu_item>
        </.row_menu>
      </:action>
    </.table>
    <p id="workspaces-note" class="text-[12.5px]/[18px] text-faint">
      {if length(@workspaces) > 1,
        do:
          gettext(
            "A deleted workspace is purged after %{days}; until then an owner or an admin can cancel the deletion here.",
            days: days(Deletion.grace_days())
          ),
        else:
          gettext(
            "The organisation's only workspace is not deleted on its own: delete the organisation instead."
          )}
    </p>
    """
  end

  # The organisation's Danger zone: its deletion, or why it cannot be deleted.
  defp section(%{section: :danger} = assigns) do
    ~H"""
    <.card :if={may?(@current_scope, :"organisation.delete")} id="delete-organisation">
      <:title>{gettext("Delete organisation")}</:title>
      <p class="max-w-[60ch] text-muted">
        {gettext(
          "Everything in it is deleted with it: its workspaces, runs, access keys, policy, members and activity. It disappears for every member at once, and is purged after %{days}; until then its owners can cancel the deletion from their organisations page.",
          days: days(Deletion.grace_days())
        )}
      </p>
      <:footer>
        <span>{gettext("After the purge, nothing brings it back.")}</span>
        <.button
          id="delete-organisation-button"
          variant="danger"
          patch={~p"/#{@current_scope.organisation}/settings/delete"}
        >
          {gettext("Delete organisation")}
        </.button>
      </:footer>
    </.card>

    <.card
      :if={
        !may?(@current_scope, :"organisation.delete") &&
          Access.refused_on?(:"organisation.delete", @current_scope.organisation)
      }
      id="delete-organisation-kept"
    >
      <:title>{gettext("Delete organisation")}</:title>
      <p class="max-w-[60ch] text-muted">
        {gettext(
          "This is the instance's organisation, whose owners run the instance, so it cannot be deleted."
        )}
      </p>
    </.card>
    """
  end

  # The workspace's General: its name.
  defp section(%{section: :general} = assigns) do
    ~H"""
    <.notice :if={refused_for_level?(@current_scope, :"workspace.rename")} kind={:info}>
      {gettext(
        "Only owners and admins can change these settings. Ask one of them if a name needs to change."
      )}
    </.notice>

    <.card>
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
        <span>{gettext("Shown in the breadcrumb, the switcher and as the overview title.")}</span>
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
    """
  end

  # The workspace's Retention: how long a run's events and log output are kept, and what
  # the nightly job last pruned.
  defp section(%{section: :retention} = assigns) do
    ~H"""
    <.card>
      <:title>{gettext("Keep for")}</:title>
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

    <.card padding={false}>
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
          <span :if={run.trigger == "manual"} class="text-[12.5px] text-muted">
            {gettext("By hand")}
          </span>
          <.state_word :if={!run.complete} hot class="text-[12.5px]">
            {gettext("Not finished")}
          </.state_word>
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
    """
  end

  # The workspace's Danger zone: its deletion, unless it is the organisation's only one.
  defp section(%{section: :workspace_danger} = assigns) do
    ~H"""
    <.card id="delete-workspace">
      <:title>{gettext("Delete this workspace")}</:title>
      <p class="max-w-[60ch] text-muted">
        {if length(@workspaces) > 1,
          do:
            gettext(
              "Its runs, policy and access keys are deleted with it, and its keys stop working. Its members stay in the organisation. It is purged after %{days}; until then an owner or an admin can cancel the deletion in the organisation's settings.",
              days: days(Deletion.grace_days())
            ),
          else:
            gettext(
              "The organisation's only workspace is not deleted on its own: delete the organisation instead."
            )}
      </p>
      <:footer :if={length(@workspaces) > 1}>
        <span>{gettext("After the purge, nothing brings it back.")}</span>
        <.button
          id="delete-workspace-button"
          variant="danger"
          patch={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/settings/delete"}
        >
          {gettext("Delete workspace")}
        </.button>
      </:footer>
    </.card>
    """
  end

  defp section_title(:organisation), do: gettext("General")
  defp section_title(:general), do: gettext("General")
  defp section_title(:workspaces), do: gettext("Workspaces")
  defp section_title(:retention), do: gettext("Retention")

  defp section_title(danger) when danger in [:danger, :workspace_danger],
    do: gettext("Danger zone")

  defp section_subtitle(:organisation, :organisation),
    do: gettext("The name of this organisation, where its pages are, and who owns it.")

  defp section_subtitle(:organisation, :workspaces),
    do: gettext("The workspaces of this organisation, and the ones waiting to be purged.")

  defp section_subtitle(:organisation, :danger),
    do: gettext("What cannot be undone once the purge has run.")

  defp section_subtitle(:workspace, :general),
    do: gettext("The name of this workspace, and where its pages are.")

  defp section_subtitle(:workspace, :retention),
    do: gettext("How long this workspace keeps a run's events and log output.")

  defp section_subtitle(:workspace, :workspace_danger),
    do: gettext("What cannot be undone once the purge has run.")

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(deleting: nil)
     |> assign_section()
     |> assign_forms()
     |> assign_confirm()
     |> load_owners()
     |> load_sections()
     |> load_workspaces()
     |> load_retention_runs()
     |> follow_memberships()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign_section() |> apply_action(socket.assigns.live_action, params)}
  end

  # The section of the page's action: a modal is over its section, and a patch to another
  # section of the same settings shows that one.
  defp assign_section(socket) do
    {page, section} = Map.fetch!(@sections, socket.assigns.live_action)

    socket
    |> assign(page: page, section: section)
    |> assign(:page_title, page_title(page, section))
  end

  defp apply_action(socket, :delete_organisation, _params) do
    if may?(socket.assigns.current_scope, :"organisation.delete"),
      do: socket |> assign(:deleting, nil) |> assign_confirm(),
      else: refused(socket)
  end

  # A section the reader may not open is not in their list; its path sends them to the
  # settings' General, and says why.
  defp apply_action(socket, action, _params)
       when action in [:workspaces, :danger, :workspace_danger] do
    if section?(socket.assigns),
      do: assign(socket, :deleting, nil),
      else: refused(socket, general_path(socket.assigns.current_scope, action))
  end

  defp apply_action(socket, :delete_workspace, %{"workspace_id" => id}),
    do: deleting(socket, Enum.find(socket.assigns.workspaces, &(&1.id == id)))

  defp apply_action(socket, :delete_this_workspace, _params) do
    workspace = socket.assigns.current_scope.workspace
    deleting(socket, Enum.find(socket.assigns.workspaces, &(&1.id == workspace.id)))
  end

  defp apply_action(socket, _page, _params), do: assign(socket, :deleting, nil)

  # The workspace the modal deletes, while it is one of several the reader may delete.
  defp deleting(socket, workspace) do
    scope = socket.assigns.current_scope

    case workspace do
      %{} when length(socket.assigns.workspaces) > 1 ->
        if may?(scope, :"workspace.delete"),
          do: socket |> assign(:deleting, workspace) |> assign_confirm(),
          else: refused(socket)

      _gone_or_last ->
        socket
        |> put_flash(:error, gettext("That workspace cannot be deleted here."))
        |> push_patch(to: section_path(scope, socket.assigns.live_action))
    end
  end

  defp refused(socket, to \\ nil) do
    scope = socket.assigns.current_scope
    action = socket.assigns.live_action

    to =
      to ||
        if(section?(socket.assigns),
          do: section_path(scope, action),
          else: general_path(scope, action)
        )

    socket
    |> put_flash(:error, deletion_refused())
    |> push_patch(to: to)
  end

  # Whether the section of the page is one of the reader's (`SettingsComponents.nav/1`).
  defp section?(%{settings_nav: nav, section: section}),
    do: Enum.any?(nav, fn {_kind, entries} -> Enum.any?(entries, &(&1.key == section)) end)

  defp general_path(scope, action) do
    case Map.fetch!(@sections, action) do
      {:organisation, _section} -> ~p"/#{scope.organisation}/settings"
      {:workspace, _section} -> ~p"/#{scope.organisation}/#{scope.workspace}/settings"
    end
  end

  defp deletion_refused,
    do: gettext("Only owners and admins delete a workspace, and only owners the organisation.")

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

      {:error, reason} when reason in [:forbidden, :not_found] ->
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

      {:error, reason} when reason in [:forbidden, :not_found] ->
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

      {:error, reason} when reason in [:forbidden, :not_found] ->
        {:noreply, unauthorized(socket)}
    end
  end

  def handle_event("confirm", %{"confirm" => params}, socket) do
    {:noreply, assign_confirm(socket, params)}
  end

  def handle_event("delete_organisation", %{"confirm" => %{"slug" => slug}}, socket) do
    scope = socket.assigns.current_scope

    case Deletion.delete_organisation(scope, slug) do
      {:ok, organisation} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext(
             "%{name} is deleted and is purged on %{date}. Until then you can cancel the deletion on this page.",
             name: organisation.name,
             date: Format.date(organisation.purge_after)
           )
         )
         |> redirect(to: ~p"/users/organisations")}

      {:error, :confirmation} ->
        {:noreply, assign_confirm(socket, %{"slug" => slug}, :mismatch)}

      {:error, :forbidden} ->
        {:noreply, unauthorized(socket, deletion_refused())}

      # A refusal of the edition's is said in its words, where it has some.
      {:error, reason} ->
        case is_atom(reason) && ApiaryWeb.Edition.refusal_sentence(reason) do
          sentence when is_binary(sentence) ->
            {:noreply,
             socket
             |> put_flash(:error, sentence)
             |> push_patch(to: section_path(scope, :delete_organisation))}

          _none ->
            {:noreply, gone(socket)}
        end
    end
  end

  def handle_event("delete_workspace", %{"confirm" => %{"slug" => slug}}, socket) do
    %{current_scope: scope, deleting: workspace} = socket.assigns

    case workspace && Deletion.delete_workspace(scope, workspace.id, slug) do
      {:ok, deleted} ->
        socket =
          put_flash(
            socket,
            :info,
            gettext("%{name} is deleted and is purged on %{date}.",
              name: deleted.name,
              date: Format.date(deleted.purge_after)
            )
          )

        # The workspace the page's scope holds: the organisation's workspaces are loaded
        # again, in another.
        if scope.workspace && deleted.id == scope.workspace.id,
          do: {:noreply, push_navigate(socket, to: workspaces_path(scope))},
          else: {:noreply, socket |> load_workspaces() |> push_patch(to: workspaces_path(scope))}

      {:error, :confirmation} ->
        {:noreply, assign_confirm(socket, %{"slug" => slug}, :mismatch)}

      {:error, :last_workspace} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext(
             "The organisation's only workspace is not deleted on its own: delete the organisation instead."
           )
         )
         |> load_workspaces()
         |> push_patch(to: section_path(scope, socket.assigns.live_action))}

      {:error, :forbidden} ->
        {:noreply, unauthorized(socket, deletion_refused())}

      _not_found ->
        {:noreply, gone(socket)}
    end
  end

  def handle_event("restore_workspace", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Deletion.restore_workspace(scope, id) do
      {:ok, workspace} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("The deletion of %{name} is cancelled: it is back, with its access keys.",
             name: workspace.name
           )
         )
         |> load_workspaces()}

      {:error, :purge_started} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("It is being purged: the deletion can no longer be cancelled.")
         )
         |> load_workspaces()}

      {:error, :forbidden} ->
        {:noreply, unauthorized(socket, deletion_refused())}

      {:error, _reason} ->
        {:noreply, load_workspaces(socket)}
    end
  end

  # Whether the level of the reader's membership holds no `action`, which the notice says.
  # A reader with no membership, and a place read-only for everyone, say why in the
  # notices at the top of the page (`ApiaryWeb.Extension`).
  defp refused_for_level?(scope, action) do
    case Access.level(scope) do
      nil -> false
      level -> action not in Map.get(Access.roles(), level, [])
    end
  end

  # The organisation's actions are asked of the organisation, the workspace's of the
  # workspace. Deleting and restoring a workspace are the organisation's: an owner or an
  # admin deletes any workspace of it.
  defp may?(scope, action)
       when action in [
              :"organisation.rename",
              :"organisation.delete",
              :"workspace.delete",
              :"workspace.restore"
            ],
       do: Access.can?(scope, action, scope.organisation)

  defp may?(scope, action), do: Access.can?(scope, action, scope.workspace)

  defp page_title(page, section) do
    settings =
      if page == :organisation,
        do: gettext("Organisation settings"),
        else: gettext("Workspace settings")

    section_title(section) <> " · " <> settings
  end

  defp workspaces_path(scope), do: ~p"/#{scope.organisation}/settings/workspaces"

  # The section a modal is over, where the page goes back to once the modal is done.
  defp section_path(scope, action) when action in [:delete_organisation, :danger],
    do: ~p"/#{scope.organisation}/settings/danger"

  defp section_path(scope, action) when action in [:delete_this_workspace, :workspace_danger],
    do: ~p"/#{scope.organisation}/#{scope.workspace}/settings/danger"

  defp section_path(scope, _workspaces), do: workspaces_path(scope)

  # The slug typed to confirm a deletion, and whether it was refused.
  defp assign_confirm(socket, params \\ %{}, refused \\ nil) do
    errors =
      case refused do
        :mismatch -> [slug: {dgettext_noop("errors", "is not the slug"), []}]
        nil -> []
      end

    assign(socket, :confirm_form, to_form(params, as: :confirm, errors: errors))
  end

  # The workspaces of the organisation in use, and those marked for deletion, for whoever
  # may delete one: Workspaces lists them, and a workspace's danger zone asks whether it is
  # the only one.
  defp load_workspaces(socket) do
    scope = socket.assigns.current_scope

    if may?(scope, :"workspace.delete") do
      assign(socket,
        workspaces: Organisations.list_workspaces(scope),
        marked_workspaces: Deletion.list_marked_workspaces(scope)
      )
    else
      assign(socket, workspaces: [], marked_workspaces: [])
    end
  end

  # What the page offered is gone or no longer allowed: the page reads it again.
  defp gone(socket) do
    socket
    |> put_flash(:error, gettext("That is no longer there to delete."))
    |> load_workspaces()
    |> push_patch(to: section_path(socket.assigns.current_scope, socket.assigns.live_action))
  end

  # The organisation's page of a member who reaches no workspace yet has no workspace, and
  # shows none of its forms.
  defp assign_forms(%{assigns: %{current_scope: %{workspace: nil} = scope}} = socket) do
    assign(socket,
      organisation_form: to_form(Organisations.change_organisation(scope.organisation)),
      workspace_form: nil,
      retention_form: nil
    )
  end

  defp assign_forms(socket) do
    scope = socket.assigns.current_scope

    assign(socket,
      organisation_form: to_form(Organisations.change_organisation(scope.organisation)),
      workspace_form: to_form(Organisations.change_workspace(scope.workspace)),
      retention_form: to_form(Retention.change_retention(scope.workspace), as: :retention)
    )
  end

  # The owners, whom the Owners card lists.
  defp load_owners(socket) do
    owners =
      socket.assigns.current_scope
      |> Organisations.list_members()
      |> Enum.filter(&(&1.level == :owner))

    assign(socket, :owners, owners)
  end

  # The settings the reader may change, the edition's sections among them, for the sidebar.
  defp load_sections(socket),
    do: assign(socket, :settings_nav, SettingsComponents.nav(socket.assigns.current_scope))

  # A change of the reader's membership, or of the people of the organisation, told to
  # the page (`ApiaryWeb.UserAuth.on_membership_change/2`), loads the scope again, and here
  # the forms, the owners, the sections and the workspaces with it.
  defp follow_memberships(socket) do
    UserAuth.on_membership_change(
      socket,
      &(&1 |> assign_forms() |> load_owners() |> load_sections() |> load_workspaces())
    )
  end

  defp load_retention_runs(%{assigns: %{current_scope: %{workspace: nil}}} = socket),
    do: assign(socket, :retention_runs, [])

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
  # A person who no longer reaches the workspace, or is no longer a member, is sent to `/`;
  # anyone else is told `sentence`, what the refused change asks of a role.
  defp unauthorized(socket, sentence \\ nil) do
    socket = UserAuth.reload_scope(socket)

    if socket.redirected do
      put_flash(socket, :error, gettext("You no longer have access to this workspace."))
    else
      socket
      |> assign_forms()
      |> put_flash(
        :error,
        sentence || gettext("Only owners and admins can change these settings.")
      )
    end
  end
end
