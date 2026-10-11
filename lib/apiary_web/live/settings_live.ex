defmodule ApiaryWeb.SettingsLive do
  @moduledoc """
  The core's sections of the organisation's and the workspace's settings, one section a
  page, its title the page's h1, beside the list of its kind's sections
  (`ApiaryWeb.SettingsComponents`), under the scope's own sidebar, whose Organisation
  settings or Workspace settings is the current entry.

  - The organisation's: General, `/:org/settings` (`:organisation`), its name, its slug,
    its owners and, last, its danger zone, the deletion of the organisation; Workspaces,
    `/:org/settings/workspaces` (`:workspaces`), for whoever may rename or delete a
    workspace (`Apiary.Organisations.lists_workspaces?/1`), an owner or an admin in the
    core's edition, with the deletion of one and the cancelling of a deletion for whoever
    may take them.
  - The workspace's: General, `/:org/:workspace/settings` (`:workspace`), its name, its
    slug, its type (its domain, read only: "A software workspace") and, last, its danger
    zone, its deletion while it is one of several; Runs,
    `/:org/:workspace/settings/runs` (`:runs`), how long the workspace keeps runs, their
    events and their logs, and what the nightly job last pruned. Its path before,
    `/settings/retention`, sends on (`ApiaryWeb.MovedController`).

  A slug is shown, not edited. Deleting asks to type the
  slug, in place, never in a dialog, each at a path of its own: the organisation's and this
  workspace's in their danger zone's line, expanded on General
  (`SettingsComponents.danger_action/1`), the organisation's at `/:org/settings/danger`
  (`:danger`, and `/:org/settings/delete`, `:delete_organisation`), this workspace's at
  `/:org/:workspace/settings/danger` (`:workspace_danger`, and
  `/:org/:workspace/settings/delete`, `:delete_this_workspace`); any workspace's in its
  row of Workspaces (`SettingsComponents.workspace_list/1`), at
  `/:org/settings/workspaces/:workspace_id/delete` (`:delete_workspace`). The danger zones are no section of their own: nothing that
  cannot be undone is an entry of the settings' list. A workspace marked for deletion is a
  notice at the top of Workspaces, where an owner or an admin cancels it until it is
  purged (`Apiary.Deletion`).

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
    danger: {:organisation, :organisation},
    delete_organisation: {:organisation, :organisation},
    workspace: {:workspace, :general},
    runs: {:workspace, :runs},
    workspace_danger: {:workspace, :general},
    delete_this_workspace: {:workspace, :general}
  }

  # The pages that are General with a danger zone's confirmation expanded, the
  # organisation's and this workspace's deletion.
  @delete_organisation [:danger, :delete_organisation]
  @delete_this_workspace [:workspace_danger, :delete_this_workspace]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={if @page == :organisation, do: :organisation, else: :settings}
      sections={@sections}
      section={@section}
    >
      <SettingsComponents.layout
        scope={@current_scope}
        counts={@nav_counts}
        kind={@page}
        current={@section}
        measure={if @section == :workspaces, do: "list", else: "read"}
        title={section_title(@section)}
      >
        <:subtitle>{section_subtitle(@page, @section)}</:subtitle>
        <:actions :if={@section == :workspaces}>
          <ApiaryWeb.Extension.slot name={:workspaces_heading} scope={@current_scope} />
        </:actions>
        {section(assigns)}
      </SettingsComponents.layout>
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

    <SettingsComponents.part id="organisation-name">
      <.form
        for={@organisation_form}
        id="organisation-form"
        phx-change="validate_organisation"
        phx-submit="save_organisation"
        class="q-form"
        novalidate
      >
        <.input
          field={@organisation_form[:name]}
          type="text"
          label={gettext("Name")}
          hint={gettext("Shown in the breadcrumb, the switcher and invitations.")}
          debounce="200"
          autocomplete="off"
          disabled={!may?(@current_scope, :"organisation.rename")}
          required
        />
        <p id="organisation-slug" class="text-[13px]/[20px] text-muted">
          <.rich text={
            rich_gettext("Its pages are under %{path}. Renaming the organisation keeps it.",
              path: {:m, ~p"/#{@current_scope.organisation}"}
            )
          } />
        </p>
        <SettingsComponents.save :if={may?(@current_scope, :"organisation.rename")}>
          <.button
            type="submit"
            variant="primary"
            disabled={!@organisation_form.source.valid?}
            loading_text={gettext("Saving")}
          >
            {gettext("Save")}
          </.button>
          <:note>{gettext("Owners and admins can change these.")}</:note>
        </SettingsComponents.save>
      </.form>
    </SettingsComponents.part>

    <SettingsComponents.part id="owners-part" title={gettext("Owners")} count={length(@owners)}>
      <ul id="owners" class="q-plain-list">
        <li :for={owner <- @owners} id={"owner-#{owner.id}"}>
          <.avatar
            name={owner.user.email}
            kind={if owner.user_id == @current_scope.user.id, do: "self", else: "person"}
          />
          <span class="min-w-0 truncate font-medium">{owner.user.email}</span>
          <span :if={owner.user_id == @current_scope.user.id} class="text-[12.5px] text-faint">
            {gettext("you")}
          </span>
          <span class="ml-auto text-[12.5px]/[18px] tabular-nums text-faint">
            {gettext("since %{date}", date: Format.date(owner.inserted_at))}
          </span>
        </li>
      </ul>
      <p id="owners-note" class="q-foot-note">
        <span :if={only_owner_held?(@current_scope, @owners)}>
          {gettext("The only owner cannot be removed or demoted until another member is an owner.")}
        </span>
        <.link navigate={~p"/#{@current_scope.organisation}/settings/people"} class="link">
          {gettext("People changes who is an owner.")}
        </.link>
      </p>
    </SettingsComponents.part>

    <SettingsComponents.danger_zone :if={
      may?(@current_scope, :"organisation.delete") or organisation_kept?(@current_scope)
    }>
      <SettingsComponents.danger_action
        :if={may?(@current_scope, :"organisation.delete")}
        id="delete-organisation"
        title={gettext("Delete this organisation")}
        button={gettext("Delete organisation…")}
        open={@live_action in [:danger, :delete_organisation]}
        open_path={~p"/#{@current_scope.organisation}/settings/danger"}
        close_path={~p"/#{@current_scope.organisation}/settings"}
        question={gettext("Delete %{name}?", name: @current_scope.organisation.name)}
        form={@confirm_form}
        change="confirm"
        submit="delete_organisation"
        ready={@confirm_form[:slug].value == @current_scope.organisation.slug}
      >
        {gettext(
          "Its workspaces, runs, access keys, policy, members and activity go with it, for every member at once, and after the purge, %{days} later, nothing brings them back.",
          days: days(Deletion.grace_days())
        )}
        <:lost>
          <.rich text={
            rich_gettext(
              "The organisation, its workspaces and everything in them disappear for every member at once, and its access keys stop working. It is purged after %{days}; until then you can cancel the deletion from %{organisations}.",
              days: days(Deletion.grace_days()),
              organisations:
                {:link, ~p"/users/organisations", gettext("your organisations page"), "link"}
            )
          } />
        </:lost>
        <:field>
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
        </:field>
      </SettingsComponents.danger_action>
      <SettingsComponents.danger_action
        :if={!may?(@current_scope, :"organisation.delete")}
        id="delete-organisation-kept"
        title={gettext("Delete this organisation")}
      >
        {organisation_kept()}
      </SettingsComponents.danger_action>
    </SettingsComponents.danger_zone>
    """
  end

  # The organisation's Workspaces (`SettingsComponents.workspace_list/1`): each with the
  # edition's actions and its deletion, and the ones marked for deletion, whose deletion
  # an owner or an admin cancels. The edition's way of adding one is in the header's
  # actions (the `:workspaces_heading` slot).
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

    <SettingsComponents.workspace_list
      scope={@current_scope}
      workspaces={@workspaces}
      targets={@workspace_targets}
      may_delete={may?(@current_scope, :"workspace.delete")}
      confirming={@live_action == :delete_workspace && @deleting}
      confirm_form={@confirm_form}
    />
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

    <SettingsComponents.part id="workspace-name">
      <.form
        for={@workspace_form}
        id="workspace-form"
        phx-change="validate_workspace"
        phx-submit="save_workspace"
        class="q-form"
        novalidate
      >
        <.input
          field={@workspace_form[:name]}
          type="text"
          label={gettext("Name")}
          hint={gettext("Shown in the breadcrumb, the switcher and as the overview title.")}
          debounce="200"
          autocomplete="off"
          disabled={!may?(@current_scope, :"workspace.rename")}
          required
        />
        <p id="workspace-slug" class="text-[13px]/[20px] text-muted">
          <.rich text={
            rich_gettext("Its pages are under %{path}. Renaming the workspace keeps it.",
              path: {:m, ~p"/#{@current_scope.organisation}/#{@current_scope.workspace}"}
            )
          } />
        </p>
        <SettingsComponents.save :if={may?(@current_scope, :"workspace.rename")}>
          <.button
            type="submit"
            variant="primary"
            disabled={!@workspace_form.source.valid?}
            loading_text={gettext("Saving")}
          >
            {gettext("Save")}
          </.button>
          <:note>{gettext("Owners and admins can change these.")}</:note>
        </SettingsComponents.save>
      </.form>

      <%!-- The workspace's type, its domain, read only: set when it was created, and
           nothing changes it after. --%>
      <dl id="workspace-type" class="grid gap-1.5">
        <dt class="text-[13px]/[18px] font-medium">{gettext("Type")}</dt>
        <dd id="workspace-type-value" class="m-0">{workspace_type(@current_scope.workspace)}</dd>
        <dd class="m-0 text-[12.5px]/[18px] text-muted">
          {gettext("Set when the workspace was created. It decides the words its pages use.")}
        </dd>
      </dl>
    </SettingsComponents.part>

    <SettingsComponents.danger_zone :if={may?(@current_scope, :"workspace.delete")}>
      <SettingsComponents.danger_action
        id="delete-workspace"
        title={gettext("Delete this workspace")}
        button={if length(@workspaces) > 1, do: gettext("Delete workspace…")}
        open={@live_action in [:workspace_danger, :delete_this_workspace] && @deleting != nil}
        open_path={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/settings/danger"}
        close_path={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/settings"}
        question={gettext("Delete %{name}?", name: @current_scope.workspace.name)}
        form={@confirm_form}
        change="confirm"
        submit="delete_workspace"
        ready={@deleting != nil && @confirm_form[:slug].value == @deleting.slug}
      >
        {if length(@workspaces) > 1,
          do:
            gettext(
              "Its runs, policy and access keys go with it, and its keys stop working; its members stay in the organisation. After the purge, %{days} later, nothing brings it back.",
              days: days(Deletion.grace_days())
            ),
          else:
            gettext(
              "The organisation's only workspace is not deleted on its own: delete the organisation instead."
            )}
        <:lost>{SettingsComponents.workspace_lost()}</:lost>
        <:field>
          <.input
            field={@confirm_form[:slug]}
            type="text"
            label={
              gettext("Type the workspace's slug, %{slug}, to confirm",
                slug: @current_scope.workspace.slug
              )
            }
            autocomplete="off"
            spellcheck="false"
            debounce="0"
          />
        </:field>
      </SettingsComponents.danger_action>
    </SettingsComponents.danger_zone>
    """
  end

  # The workspace's Runs: how long a run's events and log output are kept, its retention,
  # and what the nightly job last pruned.
  defp section(%{section: :runs} = assigns) do
    ~H"""
    <SettingsComponents.part id="retention-keep">
      <.form
        for={@retention_form}
        id="retention-form"
        phx-change="validate_retention"
        phx-submit="save_retention"
        class="q-form"
        novalidate
      >
        <div class="q-form-two">
          <.input
            field={@retention_form[:events_retention_days]}
            type="text"
            aria-describedby={described_by(@retention_form[:events_retention_days], "retention-help")}
            label={gettext("Keep a run's events for")}
            placeholder={gettext("Forever")}
            inputmode="numeric"
            debounce="200"
            disabled={!may?(@current_scope, :"retention.edit")}
          />
          <.input
            field={@retention_form[:log_retention_days]}
            type="text"
            aria-describedby={described_by(@retention_form[:log_retention_days], "retention-help")}
            label={gettext("Keep a run's log output for")}
            placeholder={gettext("Forever")}
            inputmode="numeric"
            debounce="200"
            disabled={!may?(@current_scope, :"retention.edit")}
          />
        </div>
        <p id="retention-help" class="max-w-[72ch] text-[13px]/[20px] text-muted">
          {gettext(
            "In days; empty keeps everything. A run that ended is pruned whole, counted from its last event: first its log output, then its timeline. The run stays in the list with its state, its counts and its connections, and its page says what was pruned and when. Pruned data comes back only from a backup."
          )}
        </p>
        <SettingsComponents.save>
          <.button
            :if={may?(@current_scope, :"retention.edit")}
            type="submit"
            variant="primary"
            disabled={!@retention_form.source.valid?}
            loading_text={gettext("Saving")}
          >
            {gettext("Save")}
          </.button>
          <:note>
            <span id="retention-summary">{retention_summary(@current_scope.workspace)}</span>
          </:note>
        </SettingsComponents.save>
      </.form>
    </SettingsComponents.part>

    <SettingsComponents.part id="retention-pruned" title={gettext("Pruned")}>
      <p :if={@retention_runs == []} id="retention-runs-empty" class="text-muted">
        {if retention_set?(@current_scope.workspace),
          do: gettext("Nothing has been pruned yet. The pruning job runs every night."),
          else: gettext("Nothing is pruned: this workspace keeps everything.")}
      </p>
      <ul :if={@retention_runs != []} id="retention-runs" class="q-plain-list">
        <li :for={run <- @retention_runs} id={"retention-run-#{run.id}"} class="items-baseline">
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
      <p :if={@retention_runs != []} id="retention-runs-note" class="q-foot-note">
        {ngettext(
          "The pruning job's last pass. It is also a line in Qory Apiary's log.",
          "The pruning job's last %{number} passes. Each is also a line in Qory Apiary's log.",
          length(@retention_runs),
          number: Format.number(length(@retention_runs))
        )}
      </p>
    </SettingsComponents.part>
    """
  end

  # A workspace's domain, read as its type (`Apiary.Lingo.Domain`): the software domain,
  # the only one there is, is "A software workspace"; any other, a test's, is the name
  # the workspace stores, which no sentence around it would read right for every name.
  # The domain's module is matched, not asked its name: an edition's test domain need not
  # have one.
  defp workspace_type(workspace) do
    if Apiary.Lingo.Domain.for_workspace(workspace) == Apiary.Lingo.Domain.Software,
      do: gettext("A software workspace"),
      else: workspace.domain
  end

  defp section_title(:organisation), do: gettext("General")
  defp section_title(:general), do: gettext("General")
  defp section_title(:workspaces), do: gettext("Workspaces")
  defp section_title(:runs), do: gettext("Runs")

  defp section_subtitle(:organisation, :organisation),
    do: gettext("The name of this organisation, where its pages are, and who owns it.")

  defp section_subtitle(:organisation, :workspaces),
    do: gettext("The workspaces of this organisation, and the ones waiting to be purged.")

  defp section_subtitle(:workspace, :general),
    do: gettext("The name of this workspace, where its pages are, and its type.")

  defp section_subtitle(:workspace, :runs),
    do: gettext("How long this workspace keeps runs, their events and their logs.")

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

  # The section of the page's action: a confirmation is on its section, and a patch to another
  # section of the same settings shows that one.
  defp assign_section(socket) do
    {page, section} = Map.fetch!(@sections, socket.assigns.live_action)

    socket
    |> assign(page: page, section: section)
    |> assign(:page_title, page_title(socket.assigns.current_scope, page, section))
  end

  # The organisation's deletion, expanded on General, for whoever may; anyone else is sent
  # to General, which says why.
  defp apply_action(socket, action, _params) when action in @delete_organisation do
    scope = socket.assigns.current_scope

    if may?(scope, :"organisation.delete"),
      do: socket |> assign(:deleting, nil) |> assign_confirm(),
      else: refused(socket, general_path(scope, action))
  end

  # A section the reader may not open is not in their list; its path sends them to the
  # settings' General, and says why.
  defp apply_action(socket, :workspaces, _params) do
    if section?(socket.assigns),
      do: assign(socket, :deleting, nil),
      else: refused(socket, general_path(socket.assigns.current_scope, :workspaces))
  end

  defp apply_action(socket, :delete_workspace, %{"workspace_id" => id}),
    do: deleting(socket, Enum.find(socket.assigns.workspaces, &(&1.id == id)))

  defp apply_action(socket, action, _params) when action in @delete_this_workspace do
    scope = socket.assigns.current_scope

    if may?(scope, :"workspace.delete"),
      do: deleting(socket, Enum.find(socket.assigns.workspaces, &(&1.id == scope.workspace.id))),
      else: refused(socket, general_path(scope, action))
  end

  defp apply_action(socket, _page, _params), do: assign(socket, :deleting, nil)

  # The workspace the confirmation deletes, while it is one of several the reader may
  # delete.
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

    # The instance's organisation is deleted by nobody, which its danger zone says too.
    sentence =
      cond do
        action in @delete_organisation and organisation_kept?(scope) -> organisation_kept()
        action in @delete_organisation -> gettext("Only owners delete the organisation.")
        action == :workspaces -> gettext("Only owners and admins open the list of workspaces.")
        true -> gettext("Only owners and admins delete a workspace.")
      end

    socket
    |> put_flash(:error, sentence)
    |> push_patch(to: to)
  end

  # Whether the section of the page is one of the reader's (`SettingsComponents.sections/2`).
  defp section?(%{sections: sections, section: section}),
    do: Enum.any?(sections, &(&1.key == section))

  defp general_path(scope, action) do
    case Map.fetch!(@sections, action) do
      {:organisation, _section} -> ~p"/#{scope.organisation}/settings"
      {:workspace, _section} -> ~p"/#{scope.organisation}/#{scope.workspace}/settings"
    end
  end

  # An organisation no level may delete, the instance's own, whose danger zone says why to
  # whoever may rename it.
  defp organisation_kept?(scope),
    do:
      !may?(scope, :"organisation.delete") and may?(scope, :"organisation.rename") and
        Access.refused_on?(:"organisation.delete", scope.organisation)

  defp organisation_kept,
    do:
      gettext(
        "This is the instance's organisation, whose owners run the instance, so it cannot be deleted."
      )

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
         # The browser title names the organisation.
         |> assign_section()
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
         # The browser title names the workspace.
         |> assign_section()
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
        {:noreply, unauthorized(socket, gettext("Only owners delete the organisation."))}

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
        {:noreply, unauthorized(socket, gettext("Only owners and admins delete a workspace."))}

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
        {:noreply,
         unauthorized(
           socket,
           gettext("Only owners and admins cancel the deletion of a workspace.")
         )}

      {:error, _reason} ->
        {:noreply, load_workspaces(socket)}
    end
  end

  # Whether the organisation has one owner, whom the last-owner rule holds in place, and
  # the reader would otherwise change that owner's level: only to them does it say anything.
  defp only_owner_held?(scope, [owner]), do: Access.can?(scope, :"member.change_level", owner)
  defp only_owner_held?(_scope, _owners), do: false

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

  defp page_title(scope, page, section),
    do: SettingsComponents.page_title(scope, page, [section_title(section)])

  defp workspaces_path(scope), do: ~p"/#{scope.organisation}/settings/workspaces"

  # The section a confirmation is on, where the page goes back to once it is done.
  defp section_path(scope, action) when action in @delete_organisation,
    do: ~p"/#{scope.organisation}/settings"

  defp section_path(scope, action) when action in @delete_this_workspace,
    do: ~p"/#{scope.organisation}/#{scope.workspace}/settings"

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

  # The workspaces of the organisation in use, for whoever may rename or delete one, and
  # those marked for deletion, for whoever may delete one: Workspaces lists them, and a
  # workspace's danger zone asks whether it is the only one.
  defp load_workspaces(socket) do
    scope = socket.assigns.current_scope

    if Organisations.lists_workspaces?(scope) do
      assign(socket,
        workspaces: Organisations.list_workspaces(scope),
        workspace_targets: Apiary.Targets.count_by_workspace(scope),
        marked_workspaces:
          if(may?(scope, :"workspace.delete"),
            do: Deletion.list_marked_workspaces(scope),
            else: []
          )
      )
    else
      assign(socket, workspaces: [], workspace_targets: %{}, marked_workspaces: [])
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

  # The sections of the settings, the edition's among them, for the list beside the page.
  defp load_sections(socket),
    do:
      assign(
        socket,
        :sections,
        SettingsComponents.sections(socket.assigns.current_scope, socket.assigns.page)
      )

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

  # What describes a retention field: the line under the fields, unless the field shows an
  # error, which then describes it: `CoreComponents.input/1` writes its own
  # aria-describedby from its errors, before one passed to it, and a browser keeps the
  # first.
  defp described_by(field, id) do
    unless field.errors != [] and Phoenix.Component.used_input?(field), do: id
  end

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
