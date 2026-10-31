defmodule ApiaryWeb.DeadEnd do
  @moduledoc """
  DeadEnd is the `404` page, inside the app's layout, of a path under an organisation the
  person reaches that leads nowhere for them:

    * `:workspace`, a workspace address that matches no workspace they reach in the
      organisation (`ApiaryWeb.UserAuth.fetch_path_scope/2`): "No workspace has this
      address in One Co. The workspace's name may have changed.", then the organisation's workspaces
      they reach, as links.
    * `:new_workspace`, New workspace (`/:org/workspaces/new`) for a person whom
      `workspace.create` does not allow (`ApiaryWeb.NotFound`'s `page`, rendered by
      `ApiaryWeb.ErrorHTML`): its heading, with no kind cards, and one line. Where the
      organisation has as many workspaces as the edition allows, nobody creates another,
      so the line is the limit's, in the information notice the owner sees there too
      (`ApiaryWeb.SetUpComponents.limit_line/1`); else who creates workspaces.

  The list contains only the workspaces the person reaches, the ones the switcher lists
  (`Apiary.Organisations.list_places/1`); a workspace they do not reach gets the same page
  as an address that matches none. An organisation they do not reach gets the plain
  `404`, which lists nothing.
  """
  use ApiaryWeb, :html

  alias Apiary.Accounts.Scope
  alias Apiary.Organisations

  @type page :: :workspace | :new_workspace

  @doc """
  document/2 is the whole HTML document of `page` for the request whose assigns are
  `assigns`: its `current_scope`, with the organisation, its `flash` and its `csp_nonce`.
  Nil where the scope has no person or no organisation: such a request gets the plain
  `404`.
  """
  @spec document(map, page) :: Phoenix.LiveView.Rendered.t() | nil
  def document(
        %{current_scope: %Scope{user: %{} = user, organisation: %{}} = scope} = assigns,
        page
      )
      when page in [:workspace, :new_workspace] do
    memberships = Organisations.list_places(user)
    nonce = assigns[:csp_nonce]

    assigns = %{
      page: page,
      current_scope: scope,
      flash: assigns[:flash] || %{},
      memberships: memberships,
      counts: ApiaryWeb.UserAuth.nav_counts(scope),
      workspaces: reached(memberships, scope),
      page_title: title(page)
    }

    ApiaryWeb.Layouts.root(%{
      csp_nonce: nonce,
      page_title: assigns.page_title,
      inner_content: content(assigns)
    })
  end

  def document(_assigns, _page), do: nil

  defp title(:workspace), do: gettext("Workspace not found")
  defp title(:new_workspace), do: gettext("New workspace")

  # The workspaces of the organisation the person reaches, as the switcher lists them.
  defp reached(memberships, %Scope{organisation: organisation}) do
    case Enum.find(memberships, &(&1.organisation.id == organisation.id)) do
      %{workspaces: workspaces} when is_list(workspaces) -> workspaces
      _none -> []
    end
  end

  defp content(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@counts}
      place={:organisation}
      width="read"
    >
      <:crumb>{@page_title}</:crumb>
      <.page_header title={@page_title} />
      <.body page={@page} current_scope={@current_scope} workspaces={@workspaces} />
    </Layouts.app>
    """
  end

  attr :page, :atom, required: true
  attr :current_scope, Scope, required: true
  attr :workspaces, :list, required: true

  defp body(%{page: :workspace} = assigns) do
    ~H"""
    <p id="dead-end-line" class="text-sm/5 text-muted">
      {gettext(
        "No workspace has this address in %{organisation}. The workspace's name may have changed.",
        organisation: @current_scope.organisation.name
      )}
    </p>
    <section :if={@workspaces != []} class="mt-6" aria-labelledby="dead-end-workspaces-title">
      <h2 id="dead-end-workspaces-title" class="text-sm/5 font-medium">
        {gettext("Workspaces you can open")}
      </h2>
      <ul id="dead-end-workspaces" role="list" class="mt-2 grid gap-1.5">
        <li :for={workspace <- @workspaces} id={"dead-end-workspace-#{workspace.id}"}>
          <.link navigate={~p"/#{@current_scope.organisation}/#{workspace}"} class="q-link">
            {workspace.name}
          </.link>
          <span class="q-mono text-[12.5px]/[18px] text-muted">
            {~p"/#{@current_scope.organisation}/#{workspace}"}
          </span>
        </li>
      </ul>
    </section>
    """
  end

  defp body(%{page: :new_workspace} = assigns) do
    assigns =
      assign(assigns,
        limit:
          if(ApiaryWeb.SetUpComponents.at_limit?(assigns.current_scope),
            do: ApiaryWeb.SetUpComponents.limit_line(assigns.current_scope.organisation)
          )
      )

    ~H"""
    <.notice :if={@limit} kind={:info}>
      <span id="set-up-limit">{@limit}</span>
    </.notice>
    <p :if={!@limit} id="dead-end-line" class="text-sm/5 text-muted">
      {who_creates(@current_scope)}
    </p>
    """
  end

  # Who creates a workspace: for the organisation's first, the edition's waiting line, as
  # the overview shows it; for a further one, who `workspace.create` allows.
  defp who_creates(scope) do
    if Organisations.list_workspaces(scope) == [],
      do: Apiary.Edition.first_workspace_waiting_line(scope.organisation),
      else:
        ApiaryWeb.Access.who_may(
          scope,
          :"workspace.create",
          gettext("Only owners of %{organisation} create workspaces.",
            organisation: scope.organisation.name
          )
        )
  end
end
