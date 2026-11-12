defmodule ApiaryProWeb.MemberLive.Workspaces do
  @moduledoc """
  The workspaces of one member of the organisation, a page of People in its settings,
  `/:org/settings/people/:id/workspaces`: every workspace of the organisation, by name
  and slug, with whether the member is added to it, and the change, one workspace at a
  time and at once (`ApiaryPro.WorkspaceAccess`), with one button a row whose words follow
  the reach, so focus stays on it. A page of People on the form pages' pattern
  (`ApiaryWeb.PageComponents.page_form/1`): People the current section in the second
  column, the breadcrumb ending People / Workspaces, whose People leads back, and the
  page's title. A member reaches the workspaces they are added to, and no other; owners and admins reach every workspace, and have none
  to change.

  Owners add to and remove from workspaces anyone below the owner level, admins members
  only (`workspace_access.add`, `workspace_access.remove`). People leads here
  from each member (`ApiaryProWeb.Slots.member_actions/1`); anyone else, a member whose
  level reaches every workspace and a member who is gone are sent back there with a
  sentence that says why.
  """
  use ApiaryProWeb, :live_view

  alias Apiary.{Access, Organisations}
  alias ApiaryWeb.{SettingsComponents, UserAuth}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:members}
      sections={@sections}
      section={:people}
    >
      <:crumb>{gettext("Workspaces")}</:crumb>

      <.page_form
        id="member-workspaces-page"
        title={gettext("Workspaces of %{email}", email: @member.user.email)}
        cancel={members_path(@current_scope)}
      >
        <:description>
          {gettext(
            "A member reaches the workspaces they are added to, and no other. Removing them from one leaves them in the organisation."
          )}
        </:description>

        <.table
          id="member-workspaces-list"
          label={gettext("Workspaces of %{email}", email: @member.user.email)}
          rows={@workspaces}
          row_id={&"member-workspace-#{&1.id}"}
        >
          <:col :let={w} label={gettext("Workspace")} kind="title">
            <span class="q-nm">
              <span class="q-title">{w.name}</span>
              <span class="q-side q-mono">{w.slug}</span>
            </span>
          </:col>
          <:col :let={w} label={gettext("Reach")}>
            <span :if={added?(@member, w)} id={"member-workspace-#{w.id}-reach"}>
              {gettext("Added")}
            </span>
            <span :if={!added?(@member, w)} id={"member-workspace-#{w.id}-reach"} class="text-faint">
              {gettext("Not added")}
            </span>
          </:col>
          <:action :let={w}>
            <%!-- One button a row, whose words and event follow the reach: focus stays on it
                 once it acts. --%>
            <.button
              id={"member-workspace-#{w.id}-act"}
              variant="link"
              phx-click={if added?(@member, w), do: "remove_workspace", else: "add_workspace"}
              phx-value-workspace={w.id}
              aria-label={
                if added?(@member, w),
                  do:
                    gettext("Remove %{email} from %{workspace}",
                      email: @member.user.email,
                      workspace: w.name
                    ),
                  else:
                    gettext("Add %{email} to %{workspace}",
                      email: @member.user.email,
                      workspace: w.name
                    )
              }
            >
              {if added?(@member, w), do: gettext("Remove"), else: gettext("Add")}
            </.button>
          </:action>
        </.table>
      </.page_form>
    </Layouts.app>
    """
  end

  defp added?(member, workspace), do: Enum.any?(member.workspaces, &(&1.id == workspace.id))

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope

    case Enum.find(Organisations.list_members(scope), &(&1.id == id)) do
      nil ->
        {:ok, back(socket, gone())}

      member ->
        cond do
          not Access.can?(scope, :"workspace_access.add", member) ->
            {:ok, back(socket, refused())}

          Access.reaches_every_workspace?(member.level) ->
            {:ok,
             back(
               socket,
               gettext("%{email} reaches every workspace as an owner or an admin.",
                 email: member.user.email
               ),
               :info
             )}

          true ->
            {:ok,
             socket
             |> assign(
               page_title:
                 SettingsComponents.page_title(scope, :organisation, [
                   gettext("Workspaces of %{email}", email: member.user.email)
                 ]),
               member: member
             )
             |> assign(:sections, SettingsComponents.sections(scope, :organisation))
             |> assign(:workspaces, Organisations.list_workspaces(scope))}
        end
    end
  end

  @impl true
  def handle_event("add_workspace", %{"workspace" => workspace_id}, socket) do
    change(socket, workspace_id, &ApiaryPro.WorkspaceAccess.add/3, fn email, workspace ->
      gettext("%{email} is added to %{workspace}.", email: email, workspace: workspace)
    end)
  end

  def handle_event("remove_workspace", %{"workspace" => workspace_id}, socket) do
    change(socket, workspace_id, &ApiaryPro.WorkspaceAccess.remove/3, fn email, workspace ->
      gettext("%{email} is removed from %{workspace}.", email: email, workspace: workspace)
    end)
  end

  # Adds the member to a workspace, or removes them from one, and says so; the member, as
  # the database has them now, follows.
  defp change(socket, workspace_id, fun, said) do
    %{current_scope: scope, member: member} = socket.assigns
    workspace = Enum.find(socket.assigns.workspaces, &(&1.id == workspace_id))

    case fun.(scope, member.id, workspace_id) do
      {:ok, _access} ->
        case Enum.find(Organisations.list_members(scope), &(&1.id == member.id)) do
          nil ->
            {:noreply, back(socket, gone())}

          member ->
            {:noreply,
             socket
             |> put_flash(:info, said.(member.user.email, workspace && workspace.name))
             |> assign(:member, member)}
        end

      {:error, :forbidden} ->
        {:noreply, unauthorized(socket)}

      {:error, :not_found} ->
        {:noreply, back(socket, gone())}
    end
  end

  # Refused on the membership as it is now: the scope is read again, and the person is
  # sent back to the members, told why; one who is no longer a member has been sent to `/`
  # by then.
  defp unauthorized(socket) do
    socket = UserAuth.reload_scope(socket)
    if socket.redirected, do: socket, else: back(socket, refused())
  end

  # Back to the members, saying why.
  defp back(socket, sentence, kind \\ :error) do
    socket
    |> put_flash(kind, sentence)
    |> push_navigate(to: members_path(socket.assigns.current_scope))
  end

  defp members_path(scope), do: ~p"/#{scope.organisation}/settings/people"

  defp gone, do: gettext("That member is no longer in the organisation.")

  defp refused,
    do:
      gettext(
        "Only owners and admins manage members, and only owners change a level or manage an owner or an admin."
      )
end
