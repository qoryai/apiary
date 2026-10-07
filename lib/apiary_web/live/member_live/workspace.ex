defmodule ApiaryWeb.MemberLive.Workspace do
  @moduledoc """
  The people who reach a workspace, and at what level: the People section of a
  workspace's settings (`ApiaryWeb.SettingsComponents`), `/:org/:workspace/settings/people`.
  Read only: a membership is the organisation's, and is managed in the organisation's
  People (`ApiaryWeb.MemberLive.Index`), which the section's one action leads to for whoever
  manages members there (`member.invite`, asked of `Apiary.Access`).

  The list is `Apiary.Organisations.list_workspace_members/1`: each membership in use at a
  level that reaches every workspace, or that the edition lets into this one. A suspended
  membership reaches nothing, and is not listed. Each person is one row on the row spec
  of the organisation's People (`docs/ui.md`, Lists): the email is the title, "you" beside
  the reader's own, the level plain text, and no menu. A person is found by their email,
  `?q=`.

  An edition says beside each member's name how they reach the workspace through the slot
  the organisation's People has there (`:member_access`, `ApiaryWeb.Extension`), given the
  workspace besides.
  """
  use ApiaryWeb, :live_view

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
      nav={:settings}
      sections={@sections}
      section={:people}
    >
      <SettingsComponents.layout
        scope={@current_scope}
        counts={@nav_counts}
        kind={:workspace}
        current={:people}
        measure="list"
        title={gettext("People")}
      >
        <:subtitle>
          {gettext(
            "The people who reach this workspace, and at what level; membership is managed in the organisation's People."
          )}
        </:subtitle>
        <:actions :if={manages?(@current_scope)}>
          <.button id="manage-people" navigate={~p"/#{@current_scope.organisation}/settings/people"}>
            {gettext("Manage people")}
          </.button>
        </:actions>

        <.list_search
          id="people-search"
          name="q"
          value={@q}
          label={gettext("Find a person")}
          placeholder={gettext("Find a person by email")}
          change="find"
          class="max-w-[28rem]"
        />
        <%!-- Always there, so a screen reader hears what the search left. --%>
        <div id="people-status" role="status" class="q-status">
          <p :if={@q != ""} id="people-summary" class="text-[13px] text-muted">
            {ngettext("%{number} person matches", "%{number} people match", length(@shown),
              number: Format.number(length(@shown))
            )}
          </p>
        </div>

        <p :if={@shown == [] and @q != ""} id="people-none" class="text-[13px] text-muted">
          {gettext("No member's email has %{text}.", text: @q)}
        </p>
        <p :if={@members == []} id="people-empty" class="text-[13px] text-muted">
          {gettext("Nobody reaches this workspace yet.")}
        </p>
        <.table
          :if={@shown != []}
          id="members"
          label={gettext("Members")}
          rows={@shown}
          row_id={&"member-#{&1.id}"}
        >
          <:col :let={m} label={gettext("Member")} kind="title">
            <span class="q-nm">
              <.avatar
                name={m.user.email}
                kind={if m.user_id == @current_scope.user.id, do: "self", else: "person"}
              />
              <span class="q-title">{m.user.email}</span>
              <span :if={m.user_id == @current_scope.user.id} class="q-side">{gettext("you")}</span>
              <ApiaryWeb.Extension.slot
                name={:member_access}
                scope={@current_scope}
                member={m}
                workspace={@current_scope.workspace}
              />
            </span>
          </:col>
          <:col :let={m} label={gettext("Level")}>
            <span id={"member-#{m.id}-level"}>{level_text(m.level)}</span>
          </:col>
          <:col :let={m} label={gettext("Joined")} from="sm">
            <span class="tabular-nums">{Format.day(m.inserted_at)}</span>
          </:col>
        </.table>
      </SettingsComponents.layout>
    </Layouts.app>
    """
  end

  defp level_text(:owner), do: gettext("Owner")
  defp level_text(:admin), do: gettext("Admin")
  defp level_text(:member), do: gettext("Member")

  # Whoever manages the organisation's members is led there: asked of the organisation,
  # whose membership it is.
  defp manages?(scope), do: Access.can?(scope, :"member.invite", scope.organisation)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("People") <> " · " <> gettext("Workspace settings"))
     |> load()
     |> UserAuth.on_membership_change(&load/1)}
  end

  @impl true
  def handle_params(params, _uri, socket), do: {:noreply, find(socket, params["q"])}

  @impl true
  # The search is the URL's `q`: a person is found by their email, whatever its case.
  def handle_event("find", %{"q" => q}, socket) do
    q = String.trim(q)
    scope = socket.assigns.current_scope
    path = ~p"/#{scope.organisation}/#{scope.workspace}/settings/people"

    {:noreply,
     push_patch(socket,
       to: if(q == "", do: path, else: path <> "?" <> URI.encode_query(q: q)),
       replace: true
     )}
  end

  # The members the search leaves, `shown`, in the list's order.
  defp find(socket, q) do
    q = String.trim(q || "")
    needle = String.downcase(q)

    shown =
      if needle == "",
        do: socket.assigns.members,
        else:
          Enum.filter(
            socket.assigns.members,
            &String.contains?(String.downcase(&1.user.email), needle)
          )

    assign(socket, q: q, shown: shown)
  end

  # The people, and the sections, which an edition's may change with the reader's
  # membership: read at mount and again when it changes.
  defp load(socket) do
    scope = socket.assigns.current_scope

    socket
    |> assign(:members, Organisations.list_workspace_members(scope))
    |> assign(:sections, SettingsComponents.sections(scope, :workspace))
    |> find(socket.assigns[:q])
  end
end
