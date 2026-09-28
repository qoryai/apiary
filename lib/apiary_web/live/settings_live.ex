defmodule ApiaryWeb.SettingsLive do
  @moduledoc """
  Organisation and workspace settings, one page in two places: the organisation's,
  `/:org/settings` (`:organisation`), with its name, its slug, the owners and, for an
  owner, its workspaces and the deletion of a workspace or of the organisation; and the
  workspace's, `/:org/:workspace/settings` (`:workspace`), with its name, its slug and
  retention: how long the workspace keeps a run's events and log output, and what the
  nightly job last pruned. A slug is shown, not edited: renaming one is not decided yet.

  Deleting asks to type the slug, in a modal over the organisation's settings:
  `/:org/settings/delete` (`:delete_organisation`) and
  `/:org/settings/workspaces/:workspace_id/delete` (`:delete_workspace`). A workspace
  marked for deletion is a notice at the top of the organisation's settings, where an
  owner or an admin cancels it until it is purged (`Apiary.Deletion`).

  An edition adds tabs to the organisation's settings, each a page of its own
  (`ApiaryWeb.SettingsComponents`), and to each workspace of the organisation what its
  `:workspace_actions` slot renders (`ApiaryWeb.Extension`).

  The proof of the domain's words (`docs/lingo.md`): every sentence is a gettext call in
  engine words, and the software domain's catalogue says organisation and workspace.
  """
  use ApiaryWeb, :live_view

  alias Apiary.{Access, Deletion, Organisations, Retention}
  alias ApiaryWeb.{SettingsComponents, UserAuth}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={if @page == :organisation, do: :organisation, else: :settings}
      width="narrow"
    >
      <.header :if={@page == :organisation}>
        {gettext("Organisation settings")}
        <:subtitle>
          {gettext("The name of this organisation, where its pages are, and who owns it.")}
        </:subtitle>
      </.header>

      <SettingsComponents.settings_tabs
        :if={@page == :organisation}
        tabs={@tabs}
        current={:organisation}
        organisation={@current_scope.organisation}
      />

      <.header :if={@page == :workspace}>
        {gettext("Workspace settings")}
        <:subtitle>
          {gettext("The name of this workspace, where its pages are, and how long runs are kept.")}
        </:subtitle>
      </.header>

      <.notice
        :for={workspace <- @marked_workspaces}
        :if={@page == :organisation}
        kind={:warning}
        class="max-w-[80ch]"
      >
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

      <.notice :if={refused_for_level?(@current_scope, settings_action(@page))} kind={:info}>
        {gettext(
          "Only owners and admins can change these settings. Ask one of them if a name needs to change."
        )}
      </.notice>

      <.card :if={@page == :organisation}>
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

      <.card :if={@page == :workspace}>
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

      <.card :if={@page == :workspace}>
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

      <.card :if={@page == :workspace} padding={false}>
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

      <.card :if={@page == :organisation} padding={false}>
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

      <.card
        :if={@page == :organisation && may?(@current_scope, :"workspace.delete")}
        id="workspaces"
        padding={false}
      >
        <:title>{gettext("Workspaces")}</:title>
        <ul class="divide-y divide-line">
          <li
            :for={workspace <- @workspaces}
            id={"workspace-#{workspace.id}"}
            class="flex flex-wrap items-center gap-x-2.5 gap-y-1 px-5 py-2.5"
          >
            <span class="min-w-0 truncate font-medium">{workspace.name}</span>
            <.mono bare class="text-faint">{workspace.slug}</.mono>
            <span class="ml-auto flex flex-wrap items-center justify-end gap-x-2.5 gap-y-1">
              <ApiaryWeb.Extension.slot
                name={:workspace_actions}
                scope={@current_scope}
                workspace={workspace}
              />
              <.button
                :if={length(@workspaces) > 1}
                variant="danger-ghost"
                size="xs"
                patch={~p"/#{@current_scope.organisation}/settings/workspaces/#{workspace.id}/delete"}
                aria-label={gettext("Delete the workspace %{name}", name: workspace.name)}
              >
                {gettext("Delete")}
              </.button>
            </span>
          </li>
        </ul>
        <:footer>
          <span id="workspaces-note">
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
          </span>
        </:footer>
      </.card>

      <.card
        :if={@page == :organisation && may?(@current_scope, :"organisation.delete")}
        id="delete-organisation"
      >
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
          @page == :organisation && may?(@current_scope, :"organisation.rename") &&
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

      <.modal
        :if={@live_action == :delete_organisation}
        id="delete-organisation-modal"
        title={gettext("Delete %{name}", name: @current_scope.organisation.name)}
        on_cancel={JS.patch(~p"/#{@current_scope.organisation}/settings")}
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
          <.button patch={~p"/#{@current_scope.organisation}/settings"} data-autofocus>
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
        :if={@live_action == :delete_workspace && @deleting}
        id="delete-workspace-modal"
        title={gettext("Delete %{name}", name: @deleting.name)}
        on_cancel={JS.patch(~p"/#{@current_scope.organisation}/settings")}
      >
        <p class="text-muted">
          {gettext(
            "The workspace disappears at once, with its runs, policy and access keys, which stop working. Its members stay in the organisation. It is purged after %{days}; until then an owner or an admin can cancel the deletion on this page.",
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
          <.button patch={~p"/#{@current_scope.organisation}/settings"} data-autofocus>
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

  @impl true
  def mount(_params, _session, socket) do
    page = page(socket.assigns.live_action)

    {:ok,
     socket
     |> assign(page: page, page_title: page_title(page), deleting: nil)
     |> assign_forms()
     |> assign_confirm()
     |> load_owners()
     |> load_tabs()
     |> load_workspaces()
     |> load_retention_runs()
     |> follow_memberships()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :delete_organisation, _params) do
    if may?(socket.assigns.current_scope, :"organisation.delete"),
      do: socket |> assign(:deleting, nil) |> assign_confirm(),
      else: refused(socket)
  end

  defp apply_action(socket, :delete_workspace, %{"workspace_id" => id}) do
    scope = socket.assigns.current_scope

    case Enum.find(socket.assigns.workspaces, &(&1.id == id)) do
      %{} = workspace when length(socket.assigns.workspaces) > 1 ->
        if may?(scope, :"workspace.delete"),
          do: socket |> assign(:deleting, workspace) |> assign_confirm(),
          else: refused(socket)

      _gone_or_last ->
        socket
        |> put_flash(:error, gettext("That workspace cannot be deleted here."))
        |> push_patch(to: organisation_path(scope))
    end
  end

  defp apply_action(socket, _page, _params), do: assign(socket, :deleting, nil)

  defp refused(socket) do
    socket
    |> put_flash(:error, deletion_refused())
    |> push_patch(to: organisation_path(socket.assigns.current_scope))
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
             |> push_patch(to: organisation_path(scope))}

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

        # The workspace the page's scope holds: the page is loaded again, in another.
        if scope.workspace && deleted.id == scope.workspace.id,
          do: {:noreply, push_navigate(socket, to: organisation_path(scope))},
          else:
            {:noreply, socket |> load_workspaces() |> push_patch(to: organisation_path(scope))}

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
         |> push_patch(to: organisation_path(scope))}

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

  # What the page's forms change: the organisation's name on the organisation's page, the
  # workspace's name on the workspace's; retention is asked for on its own.
  defp settings_action(:organisation), do: :"organisation.rename"
  defp settings_action(:workspace), do: :"workspace.rename"

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

  defp page(:workspace), do: :workspace
  defp page(_organisation), do: :organisation

  defp page_title(:organisation), do: gettext("Organisation settings")
  defp page_title(:workspace), do: gettext("Workspace settings")

  defp organisation_path(scope), do: ~p"/#{scope.organisation}/settings"

  # The slug typed to confirm a deletion, and whether it was refused.
  defp assign_confirm(socket, params \\ %{}, refused \\ nil) do
    errors =
      case refused do
        :mismatch -> [slug: {dgettext_noop("errors", "is not the slug"), []}]
        nil -> []
      end

    assign(socket, :confirm_form, to_form(params, as: :confirm, errors: errors))
  end

  # The workspaces of the organisation in use, and those marked for deletion: an owner's.
  defp load_workspaces(socket) do
    scope = socket.assigns.current_scope

    if socket.assigns.page == :organisation and may?(scope, :"workspace.delete") do
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
    |> push_patch(to: organisation_path(socket.assigns.current_scope))
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

  # The tabs of the organisation's settings, the edition's among them, for its page.
  defp load_tabs(%{assigns: %{page: :organisation}} = socket),
    do: assign(socket, :tabs, SettingsComponents.list_tabs(socket.assigns.current_scope))

  defp load_tabs(socket), do: assign(socket, :tabs, [])

  # A change of the reader's membership, or of the people of the organisation, told to
  # the page (`ApiaryWeb.UserAuth.on_membership_change/2`), loads the scope again, and here
  # the forms, the owners and the tabs with it.
  defp follow_memberships(%{assigns: %{page: :organisation}} = socket) do
    UserAuth.on_membership_change(
      socket,
      &(&1 |> assign_forms() |> load_owners() |> load_tabs())
    )
  end

  defp follow_memberships(socket), do: socket

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
