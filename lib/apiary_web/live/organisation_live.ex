defmodule ApiaryWeb.OrganisationLive do
  @moduledoc """
  An organisation's overview, `/:org`, where the breadcrumb's organisation leads: the
  workspaces the person reaches in it, each with what it is doing (alive runs, its runs
  and denials of the last seven days, runs a day over fourteen, its last run and, where
  the workspace has `security`, its policy's mode), and beside them its people and what
  the organisation is.

  A member who reaches no workspace yet, where the edition says which workspaces their
  level reaches (`c:Apiary.Edition.reaches_workspace?/3`), is told so, and led to the
  People section of the settings, where the owners and admins are listed. Once they reach
  one while the page is open, the member's scope is loaded again (`ApiaryWeb.UserAuth`),
  and the page offers the workspace.

  The workspaces' facts are read off the first paint (`assign_async`), in three reads
  whatever their number (`Apiary.Runs.workspace_facts/3`).
  """
  use ApiaryWeb, :live_view

  alias Apiary.{Access, Organisations, Policy, Runs}
  alias ApiaryWeb.UserAuth

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:organisation_overview}
    >
      <div :if={is_nil(@current_scope.workspace)} id="not-added">
        <.empty_state
          icon="hero-squares-2x2"
          title={gettext("You have not been added to a workspace yet")}
          heading="h1"
          class="mt-6 w-full max-w-[480px] md:mt-16"
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
            <.button
              id="not-added-members"
              navigate={~p"/#{@current_scope.organisation}/settings/people"}
            >
              {gettext("See the owners and admins")}
            </.button>
          </:actions>
        </.empty_state>
      </div>

      <div :if={@current_scope.workspace} id="organisation-overview" class="q-org">
        <div class="q-org-top">
          <.header>
            {@current_scope.organisation.name}
            <:subtitle>{gettext("The organisation's workspaces and its people.")}</:subtitle>
          </.header>
        </div>

        <section class="q-org-main" aria-labelledby="workspaces-title">
          <div class="q-org-head">
            <h2 id="workspaces-title" class="q-org-title">
              {gettext("Workspaces")}
              <span class="q-org-count">{Format.number(length(@workspaces))}</span>
            </h2>
            <.link
              :if={Access.can?(@current_scope, :"workspace.delete", @current_scope.organisation)}
              id="manage-workspaces"
              navigate={~p"/#{@current_scope.organisation}/settings/workspaces"}
              class="link text-[13px]"
            >
              {gettext("Manage workspaces")}
            </.link>
          </div>
          <ul id="workspaces" class="q-org-grid">
            <li :for={workspace <- @workspaces} id={"workspace-#{workspace.id}"}>
              <.workspace_card
                scope={@current_scope}
                workspace={workspace}
                facts={@facts.ok? && @facts.result[workspace.id]}
                mode={@modes[workspace.id]}
              />
            </li>
          </ul>
          <p :if={@facts.failed} id="workspaces-error" class="text-muted">
            {gettext("What the workspaces are doing could not be read. Reload the page to try again.")}
          </p>
        </section>

        <aside class="q-org-rail" aria-label={gettext("About the organisation")}>
          <.card id="people">
            <:title>{gettext("People")}</:title>
            <:actions>
              <.link
                id="people-open"
                navigate={~p"/#{@current_scope.organisation}/settings/people"}
                class="link text-[13px]"
              >
                {gettext("See everyone")}
              </.link>
            </:actions>
            <p class="flex items-baseline gap-2">
              <span class="text-[26px]/8 font-semibold tabular-nums">
                {Format.number(length(@people.active))}
              </span>
              <span class="text-muted">
                {ngettext("person", "people", length(@people.active))}
              </span>
            </p>
            <dl class="q-org-levels">
              <div :for={{level, label} <- levels()}>
                <dt>{label}</dt>
                <dd class="tabular-nums">{Format.number(Map.get(@people.levels, level, 0))}</dd>
              </div>
            </dl>
            <p :if={@people.invitations > 0} id="people-invitations" class="text-[13px] text-muted">
              {ngettext(
                "%{number} invitation pending",
                "%{number} invitations pending",
                @people.invitations,
                number: Format.number(@people.invitations)
              )}
            </p>
            <p :if={@people.suspended > 0} id="people-suspended" class="text-[13px] text-muted">
              {ngettext("%{number} suspended", "%{number} suspended", @people.suspended,
                number: Format.number(@people.suspended)
              )}
            </p>
            <:footer :if={Access.can?(@current_scope, :"member.invite", @current_scope.workspace)}>
              <span></span>
              <.button
                id="people-invite"
                size="sm"
                navigate={~p"/#{@current_scope.organisation}/settings/people/invite"}
              >
                <.icon name="hero-user-plus-micro" class="size-4" /> {gettext("Invite people")}
              </.button>
            </:footer>
          </.card>

          <.card id="about">
            <:title>{gettext("Details")}</:title>
            <:actions>
              <.link
                id="about-settings"
                navigate={~p"/#{@current_scope.organisation}/settings"}
                class="link text-[13px]"
              >
                {gettext("Settings")}
              </.link>
            </:actions>
            <dl class="q-org-details">
              <dt>{gettext("Slug")}</dt>
              <dd>
                <.mono bare>{@current_scope.organisation.slug}</.mono>
              </dd>
              <dt>{gettext("Owners")}</dt>
              <dd class="grid min-w-0 gap-0.5">
                <span :for={owner <- @people.owners} class="truncate">{owner.user.email}</span>
              </dd>
              <dt>{gettext("Created")}</dt>
              <dd class="tabular-nums">{Format.date(@current_scope.organisation.inserted_at)}</dd>
            </dl>
          </.card>
        </aside>
      </div>
    </Layouts.app>
    """
  end

  attr :scope, :any, required: true
  attr :workspace, :any, required: true
  attr :facts, :any, required: true, doc: "the workspace's facts, nil while they load"
  attr :mode, :string, default: nil

  defp workspace_card(assigns) do
    ~H"""
    <article class="q-ws-card" aria-labelledby={"workspace-#{@workspace.id}-name"}>
      <header class="q-ws-card-head">
        <.link
          id={"workspace-#{@workspace.id}-name"}
          navigate={~p"/#{@scope.organisation}/#{@workspace}"}
          class="q-ws-card-name"
        >
          {@workspace.name}
        </.link>
        <span :if={@mode} class="q-ws-card-mode" title={gettext("The policy's default mode")}>
          {@mode}
        </span>
      </header>

      <dl :if={@facts} class="q-ws-card-stats">
        <div>
          <dt>{gettext("Alive now")}</dt>
          <dd class="flex items-center gap-1.5">
            <span :if={@facts.alive > 0} class="q-dot q-ripple !size-1.5" aria-hidden="true"></span>
            {Format.number(@facts.alive)}
          </dd>
        </div>
        <div>
          <dt>{gettext("Runs, 7 days")}</dt>
          <dd>{Format.number(@facts.runs)}</dd>
        </div>
        <div>
          <dt>{gettext("Denied, 7 days")}</dt>
          <dd class={@facts.denied > 0 && "text-error"}>{Format.number(@facts.denied)}</dd>
        </div>
      </dl>
      <div :if={!@facts} class="q-ws-card-stats" aria-busy="true">
        <span class="skeleton q-skel h-10 w-full"></span>
      </div>

      <.spark :if={@facts} days={@facts.days} />

      <p class="q-ws-card-foot">
        <%= cond do %>
          <% !@facts -> %>
            <span class="skeleton q-skel w-40"></span>
          <% @facts.last_at -> %>
            <span class="text-faint">{gettext("Last run")}</span>
            <.time_ago at={@facts.last_at} class="tabular-nums" />
          <% true -> %>
            <span class="text-faint">{gettext("No run yet")}</span>
        <% end %>
      </p>
    </article>
    """
  end

  # Runs a day over the last fourteen, today last and in ink: a shape, not a chart to read
  # values from; the numbers beside it say how many.
  attr :days, :list, required: true

  defp spark(assigns) do
    max = Enum.max([1 | assigns.days])
    count = length(assigns.days)

    bars =
      assigns.days
      |> Enum.with_index()
      |> Enum.map(fn {runs, i} ->
        height = if runs == 0, do: 1, else: max(2, round(runs / max * 32))
        %{x: i * 10, h: height, today: i == count - 1}
      end)

    assigns = assign(assigns, bars: bars, width: count * 10 - 2)

    ~H"""
    <svg
      class="q-ws-card-spark"
      viewBox={"0 0 #{@width} 32"}
      preserveAspectRatio="none"
      aria-hidden="true"
    >
      <rect
        :for={bar <- @bars}
        x={bar.x}
        y={32 - bar.h}
        width="8"
        height={bar.h}
        rx="1"
        class={if bar.today, do: "fill-base-content", else: "fill-base-content/25"}
      />
    </svg>
    """
  end

  defp levels,
    do: [owner: gettext("Owners"), admin: gettext("Admins"), member: gettext("Members")]

  defp organisation_name(name) do
    assigns = %{name: name}

    ~H"""
    <strong class="font-medium text-base-content">{@name}</strong>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> load() |> UserAuth.on_membership_change(&load/1)}
  end

  # What the page shows, read again when the reader's membership changes: a member added
  # to a workspace while the page was open sees the organisation's workspaces then.
  defp load(%{assigns: %{current_scope: %{workspace: nil}}} = socket),
    do: assign(socket, page_title: gettext("No workspace yet"), workspaces: [], modes: %{})

  defp load(socket) do
    scope = socket.assigns.current_scope
    workspaces = reached(socket.assigns.memberships, scope)

    socket
    |> assign(:page_title, scope.organisation.name)
    |> assign(:workspaces, workspaces)
    |> assign(:modes, modes(scope, workspaces))
    |> assign(:people, people(scope))
    |> assign_async(:facts, fn -> {:ok, %{facts: Runs.workspace_facts(scope, workspaces)}} end)
  end

  # The workspaces of the organisation the person reaches, as the switcher lists them: the
  # place of the organisation among theirs (`Apiary.Organisations.list_places/1`), which the
  # edition narrows; the scope's own workspace for a reader with no place of it.
  defp reached(memberships, %{organisation: organisation, workspace: workspace}) do
    case Enum.find(memberships, &(&1.organisation.id == organisation.id)) do
      %{workspaces: [_ | _] = workspaces} -> workspaces
      _none -> [workspace]
    end
  end

  # The policy's default mode of each workspace whose policy the reader may read, where the
  # workspace has one of Qory's: a word, as the sidebar says it.
  defp modes(scope, workspaces) do
    for workspace <- workspaces,
        here = %{scope | workspace: workspace},
        Access.can?(here, :"security_policy.read", workspace),
        %{managed?: true, mode: mode} <- [Policy.mode_summary(here)],
        into: %{},
        do: {workspace.id, mode}
  end

  # The organisation's people: in use by level, suspended, the owners by name, and the
  # invitations pending for a reader who may see them.
  defp people(scope) do
    members = Organisations.list_members(scope)
    {suspended, active} = Enum.split_with(members, & &1.suspended_at)

    invitations =
      if Access.can?(scope, :"member.invite", scope.workspace),
        do: length(Organisations.list_invitations(scope)),
        else: 0

    %{
      active: active,
      levels: Enum.frequencies_by(active, & &1.level),
      owners: Enum.filter(active, &(&1.level == :owner)),
      suspended: length(suspended),
      invitations: invitations
    }
  end
end
