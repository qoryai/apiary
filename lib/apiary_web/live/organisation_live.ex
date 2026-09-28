defmodule ApiaryWeb.OrganisationLive do
  @moduledoc """
  An organisation's own path, `/:org`. It names no page of its own: it sends the person on
  to their workspace in the organisation, the one they opened last while they reach it,
  else the first they reach, which the path scope has loaded
  (`Apiary.Organisations.resolve_scope/4`).

  A member who reaches no workspace yet, where the edition says which workspaces their
  level reaches (`c:Apiary.Edition.reaches_workspace?/3`), stays here: the page says so,
  and leads to the Members page, where the owners and admins are listed. Once they reach
  one while the page is open, the member's scope is loaded again (`ApiaryWeb.UserAuth`),
  and the page offers the workspace.
  """
  use ApiaryWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      notices
    >
      <div :if={is_nil(@current_scope.workspace)} id="not-added">
        <.empty_state
          icon="hero-squares-2x2"
          title={gettext("You have not been added to a workspace yet")}
          heading="h1"
          class="mx-auto mt-6 w-full max-w-[480px] md:mt-16"
        >
          <p>
            <.rich text={
              rich_gettext(
                "You are a member of %{organisation}, but of none of its workspaces yet. An owner or an admin of the organisation adds you to one; once they have, you open it from here.",
                organisation: organisation_name(@current_scope.organisation.name)
              )
            } />
          </p>
          <:actions>
            <.button id="not-added-members" navigate={~p"/#{@current_scope.organisation}/members"}>
              {gettext("See the owners and admins")}
            </.button>
          </:actions>
        </.empty_state>
      </div>
      <%!-- A workspace reached while the page was open: the scope reloaded with it. --%>
      <div :if={@current_scope.workspace} id="added">
        <.empty_state
          icon="hero-squares-2x2"
          title={gettext("You have been added to a workspace")}
          heading="h1"
          class="mx-auto mt-6 w-full max-w-[480px] md:mt-16"
        >
          <p>
            {gettext("An owner or an admin of the organisation added you to %{workspace}.",
              workspace: @current_scope.workspace.name
            )}
          </p>
          <:actions>
            <.button
              id="added-open"
              variant="primary"
              href={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}"}
            >
              {gettext("Open %{workspace}", workspace: @current_scope.workspace.name)}
            </.button>
          </:actions>
        </.empty_state>
      </div>
    </Layouts.app>
    """
  end

  defp organisation_name(name) do
    assigns = %{name: name}

    ~H"""
    <strong class="font-medium text-base-content">{@name}</strong>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    case socket.assigns.current_scope do
      %{organisation: organisation, workspace: %{} = workspace} ->
        {:ok, redirect(socket, to: ~p"/#{organisation}/#{workspace}")}

      _no_workspace ->
        {:ok, assign(socket, page_title: gettext("No workspace yet"))}
    end
  end
end
