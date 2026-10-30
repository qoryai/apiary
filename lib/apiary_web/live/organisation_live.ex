defmodule ApiaryWeb.OrganisationLive do
  @moduledoc """
  An organisation's overview, `/:org`, where the breadcrumb's organisation leads: the
  workspaces the person reaches in it, one line each (its targets and, where the workspace
  has `security`, its policy's mode, what is alive, its runs a day over fourteen with their
  count, its denied attempts and its last run), at most six and a link to all of them;
  beside them its people and its details, as lines, not boxes (`docs/ui.md`, Lists).

  A workspace whose set-up is not finished shows "Set-up: 3 of 7 steps" under its name,
  and its line leads to its overview, which lists the set-up's steps
  (`ApiaryWeb.SetUpComponents.workspace_set_up/1`).

  An organisation with no workspace in use yet shows, in place of its workspaces, the kind
  cards (`ApiaryWeb.SetUpComponents.kind_cards/1`) to a person `workspace.create` allows
  there, whose Choose creates the first workspace and opens its Name step, and to anyone
  else one line on who creates it (`c:Apiary.Edition.first_workspace_waiting_line/1`).
  The page shows that organisation's people and details as for any other. A member who reaches no workspace yet, where the edition says
  which workspaces their level reaches (`c:Apiary.Edition.reaches_workspace?/3`), is told
  so, and led to the People section of the settings, where the owners and admins are listed. Once they reach
  one while the page is open, the member's scope is loaded again (`ApiaryWeb.UserAuth`),
  and the page offers the workspace.

  The workspaces' facts are read off the first paint (`assign_async`), in four reads
  whatever their number (`Apiary.Runs.workspace_facts/3`).
  """
  use ApiaryWeb, :live_view

  alias Apiary.{Access, Edition, Organisations, Policy, Runs}
  alias ApiaryWeb.{SetUpComponents, UserAuth}

  # The workspaces shown; beyond them, the link to all of them.
  @shown 6

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
      <:crumb>{gettext("Overview")}</:crumb>

      <div :if={@empty} id="organisation-overview" class="q-org">
        <div class="q-org-top">
          <.page_header title={@current_scope.organisation.name}>
            <:description>{gettext("The organisation's workspaces and its people.")}</:description>
            <:actions>
              <ApiaryWeb.Extension.slot name={:organisation_heading} scope={@current_scope} />
            </:actions>
          </.page_header>
        </div>

        <div class="q-org-main">
          <section id="first-workspace" class="q-blk">
            <SetUpComponents.kind_cards
              :if={@creates}
              title={gettext("Choose what your first workspace does")}
              heading="h2"
            />
            <p :if={!@creates} id="first-workspace-waiting" class="text-sm/5 text-muted">
              {Edition.first_workspace_waiting_line(@current_scope.organisation)}
            </p>
          </section>
        </div>

        <.side current_scope={@current_scope} people={@people} />
      </div>

      <div :if={is_nil(@current_scope.workspace) and !@empty} id="not-added">
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
          <.page_header title={@current_scope.organisation.name}>
            <:description>{gettext("The organisation's workspaces and its people.")}</:description>
            <:actions>
              <ApiaryWeb.Extension.slot name={:organisation_heading} scope={@current_scope} />
            </:actions>
          </.page_header>
        </div>

        <.notice :if={@added} kind={:info} class="q-org-top">
          <div id="added" class="flex flex-wrap items-center justify-between gap-x-4 gap-y-2">
            <span>
              {gettext("An owner or an admin of the organisation added you to %{workspace}.",
                workspace: @current_scope.workspace.name
              )}
            </span>
            <.button
              id="added-open"
              size="xs"
              variant="primary"
              href={Layouts.workspace_landing(@current_scope)}
            >
              {gettext("Open %{workspace}", workspace: @current_scope.workspace.name)}
            </.button>
          </div>
        </.notice>

        <div class="q-org-main">
          <section class="q-blk" aria-labelledby="workspaces-title">
            <div class="q-band">
              <h2 id="workspaces-title">{gettext("Workspaces")}</h2>
              <span class="q-band-n">{Format.number(length(@workspaces))}</span>
              <span class="q-band-hint">{gettext("14 days")}</span>
            </div>
            <ul id="workspaces" class="q-rows">
              <li :for={workspace <- Enum.take(@workspaces, @shown)} id={"workspace-#{workspace.id}"}>
                <.workspace_row
                  workspace={workspace}
                  landing={@landings[workspace.id]}
                  set_up={@set_ups[workspace.id]}
                  facts={@facts.ok? && @facts.result[workspace.id]}
                  mode={@modes[workspace.id]}
                />
              </li>
            </ul>
            <p :if={@facts.failed} id="workspaces-error" class="q-blk-none">
              {gettext(
                "What the workspaces are doing could not be read. Reload the page to try again."
              )}
            </p>
            <.link
              :if={length(@workspaces) > @shown}
              id="workspaces-all"
              navigate={~p"/#{@current_scope.organisation}/settings/workspaces"}
              class="q-more"
            >
              {ngettext("All %{number} workspace", "All %{number} workspaces", length(@workspaces),
                number: Format.number(length(@workspaces))
              )}
              <.icon name="hero-arrow-right-micro" class="size-3.5" />
            </.link>
          </section>
        </div>

        <.side current_scope={@current_scope} people={@people} />
      </div>
    </Layouts.app>
    """
  end

  attr :current_scope, :any, required: true
  attr :people, :map, required: true

  # Beside the workspaces: the organisation's people and its details.
  defp side(assigns) do
    ~H"""
    <aside class="q-org-side" aria-label={gettext("About the organisation")}>
      <section id="people" class="q-blk" aria-labelledby="people-title">
        <div class="q-band">
          <h2 id="people-title">{gettext("People")}</h2>
          <span class="q-band-n">{Format.number(length(@people.active))}</span>
          <span class="q-grow"></span>
          <.link
            :if={may_invite?(@current_scope)}
            id="people-invite"
            navigate={~p"/#{@current_scope.organisation}/settings/people/invite"}
            class="q-band-do"
          >
            {gettext("Invite")}
          </.link>
        </div>
        <div class="q-ppl">
          <div class="q-avs" aria-hidden="true">
            <.avatar :for={member <- Enum.take(@people.active, 6)} name={member.user.email} />
            <span :if={length(@people.active) > 6} class="q-avs-n">
              {ngettext("and %{number} more", "and %{number} more", length(@people.active) - 6,
                number: Format.number(length(@people.active) - 6)
              )}
            </span>
          </div>
          <span id="people-levels">{levels_line(@people)}</span>
          <span :if={@people.suspended > 0} id="people-suspended">
            {ngettext("%{number} suspended", "%{number} suspended", @people.suspended,
              number: Format.number(@people.suspended)
            )}
          </span>
          <span :if={@people.invitations > 0} id="people-invitations" class="q-hot">
            {ngettext(
              "%{number} invitation pending",
              "%{number} invitations pending",
              @people.invitations,
              number: Format.number(@people.invitations)
            )}
          </span>
        </div>
        <.link
          id="people-open"
          navigate={~p"/#{@current_scope.organisation}/settings/people"}
          class="q-more"
        >
          {gettext("All people")}<.icon name="hero-arrow-right-micro" class="size-3.5" />
        </.link>
      </section>

      <section id="about" class="q-blk" aria-labelledby="about-title">
        <div class="q-band">
          <h2 id="about-title">{gettext("Details")}</h2>
        </div>
        <dl class="q-kvl">
          <dt>{gettext("Slug")}</dt>
          <dd class="q-mono">{@current_scope.organisation.slug}</dd>
          <dt>{gettext("Owners")}</dt>
          <dd class="truncate" title={Enum.map_join(@people.owners, ", ", & &1.user.email)}>
            {Enum.map_join(@people.owners, ", ", & &1.user.email)}
          </dd>
          <dt>{gettext("Created")}</dt>
          <dd class="q-muted tabular-nums">
            {Format.date(@current_scope.organisation.inserted_at)}
          </dd>
        </dl>
      </section>
    </aside>
    """
  end

  attr :workspace, :any, required: true
  attr :landing, :string, required: true, doc: "where the workspace's link leads"

  attr :set_up, :map,
    default: nil,
    doc: "its set-up while it is not finished (`ApiaryWeb.SetUpComponents.workspace_set_up/1`)"

  attr :facts, :any, required: true, doc: "the workspace's facts, nil while they load"
  attr :mode, :string, default: nil

  # A workspace, one line: its name (the title), how many targets and its policy's mode in
  # faint words, how many steps of its set-up are done while it is not finished, what is
  # alive, its runs a day with their count, its denied attempts and its last run.
  defp workspace_row(assigns) do
    ~H"""
    <.link
      id={"workspace-#{@workspace.id}-name"}
      navigate={@landing}
      class="q-wr"
    >
      <span class="q-wr-nm">
        <b>{@workspace.name}</b>
        <span :if={@set_up} id={"workspace-#{@workspace.id}-set-up"} class="q-wr-su">
          {ngettext(
            "Set-up: %{done} of %{total} step",
            "Set-up: %{done} of %{total} steps",
            @set_up.total,
            done: @set_up.done,
            total: @set_up.total
          )}
        </span>
        <span :if={@facts}>{workspace_note(@facts, @mode)}</span>
      </span>
      <%= if @facts do %>
        <span class={["q-wr-al", @facts.alive == 0 && "q-none-alive"]}>
          {if @facts.alive == 0,
            do: gettext("none alive"),
            else: gettext("%{number} alive", number: Format.number(@facts.alive))}
        </span>
        <span class="q-wr-sp">
          <.sparkline values={@facts.days} />
          {ngettext("%{number} run", "%{number} runs", @facts.runs,
            number: Format.number(@facts.runs)
          )}
        </span>
        <span class="q-wr-den">
          <span :if={@facts.denied > 0} class="inline-flex items-center gap-1">
            <.icon name="hero-no-symbol-micro" class="size-3 text-error" />
            {ngettext("%{number} denied", "%{number} denied", @facts.denied,
              number: Format.number(@facts.denied)
            )}
          </span>
        </span>
        <span class="q-wr-when">
          <.time_ago :if={@facts.last_at} at={@facts.last_at} />
          <span :if={!@facts.last_at} class="q-faint">{gettext("No run yet")}</span>
        </span>
      <% else %>
        <span class="skeleton q-skel-line w-16"></span>
        <span class="skeleton q-skel-line w-32"></span>
        <span></span>
        <span class="skeleton q-skel-line w-20"></span>
      <% end %>
    </.link>
    """
  end

  # The faint words beside a workspace's name: its targets, and its policy's mode.
  defp workspace_note(facts, nil),
    do:
      ngettext("%{number} target", "%{number} targets", facts.targets,
        number: Format.number(facts.targets)
      )

  defp workspace_note(facts, mode),
    do:
      gettext("%{targets} · %{mode}",
        targets:
          ngettext("%{number} target", "%{number} targets", facts.targets,
            number: Format.number(facts.targets)
          ),
        mode: mode
      )

  # The people in use, by level, in one line.
  defp levels_line(people) do
    [:owner, :admin, :member]
    |> Enum.map(&{&1, Map.get(people.levels, &1, 0)})
    |> Enum.reject(fn {_level, n} -> n == 0 end)
    |> Enum.map_join(", ", fn {level, n} -> level_count(level, n) end)
  end

  defp level_count(:owner, n),
    do: ngettext("%{number} owner", "%{number} owners", n, number: Format.number(n))

  defp level_count(:admin, n),
    do: ngettext("%{number} admin", "%{number} admins", n, number: Format.number(n))

  defp level_count(:member, n),
    do: ngettext("%{number} member", "%{number} members", n, number: Format.number(n))

  defp organisation_name(name) do
    assigns = %{name: name}

    ~H"""
    <strong class="font-medium text-base-content">{@name}</strong>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    organisation = socket.assigns.current_scope.organisation

    # An organisation with no workspace yet has the kind cards in place of its workspaces.
    # Once someone creates the first, the page opens again with it.
    if is_nil(socket.assigns.current_scope.workspace) and
         not Organisations.has_workspace?(organisation) do
      if connected?(socket), do: Organisations.subscribe_workspaces(socket.assigns.current_scope)
      {:ok, load_empty(socket)}
    else
      {:ok, socket |> load() |> UserAuth.on_membership_change(&load/1)}
    end
  end

  @impl true
  # The page that creates the first workspace opens its Name step, not the overview again:
  # it stops listening while it creates, and listens again where nothing was created.
  def handle_event("choose_kind", %{"type" => type}, %{assigns: %{empty: true}} = socket) do
    scope = socket.assigns.current_scope

    Phoenix.PubSub.unsubscribe(
      Apiary.PubSub,
      Organisations.workspaces_topic(scope.organisation.id)
    )

    socket = SetUpComponents.choose_kind(socket, type, :first)
    if is_nil(socket.redirected), do: Organisations.subscribe_workspaces(scope)
    {:noreply, socket}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:workspace_created, _ids}, %{assigns: %{empty: true}} = socket),
    do: {:noreply, push_navigate(socket, to: ~p"/#{socket.assigns.current_scope.organisation}")}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp load_empty(socket) do
    scope = socket.assigns.current_scope

    assign(socket,
      empty: true,
      page_title: scope.organisation.name,
      creates: Access.can?(scope, :"workspace.create", scope.organisation),
      people: people(scope)
    )
  end

  # What the page shows, read again when the reader's membership changes: a member added
  # to a workspace while the page was open sees the organisation's workspaces then.
  defp load(%{assigns: %{current_scope: %{workspace: nil}}} = socket),
    do:
      assign(socket,
        empty: false,
        page_title: gettext("No workspace yet"),
        workspaces: [],
        landings: %{},
        set_ups: %{},
        modes: %{},
        waiting: true,
        added: false
      )

  defp load(socket) do
    scope = socket.assigns.current_scope
    workspaces = reached(socket.assigns.memberships, scope)

    socket
    |> assign(:empty, false)
    # A member who waited on this page for a workspace is told they have one, and offered it.
    |> assign(:added, Map.get(socket.assigns, :waiting, false))
    |> assign(:shown, @shown)
    |> assign(:waiting, false)
    |> assign(:page_title, scope.organisation.name)
    |> assign(:workspaces, workspaces)
    |> assign_landings(scope, workspaces)
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

  # Where each workspace's link leads, and its set-up while it is not finished
  # (`ApiaryWeb.SetUpComponents.workspace_set_up/1`), asked with the scope the reader would have
  # in it (`Apiary.Organisations.workspace_scopes/1`), one read for them all: with the
  # `factory` feature, its overview while its set-up is not finished; else the first page
  # its sidebar shows the reader there (`ApiaryWeb.Layouts.workspace_landing/1`). The
  # page's workspace with the page's scope, and a workspace that read did not find at its
  # overview, with no set-up, as before.
  defp assign_landings(socket, scope, workspaces) do
    scopes = Map.put(Organisations.workspace_scopes(scope), scope.workspace.id, scope)

    found =
      for workspace <- workspaces, into: %{} do
        case Map.fetch(scopes, workspace.id) do
          {:ok, here} ->
            case SetUpComponents.workspace_set_up(here) do
              nil -> {workspace.id, {Layouts.workspace_landing(here), nil}}
              set_up -> {workspace.id, {~p"/#{scope.organisation}/#{workspace}", set_up}}
            end

          :error ->
            {workspace.id, {~p"/#{scope.organisation}/#{workspace}", nil}}
        end
      end

    assign(socket,
      landings: Map.new(found, fn {id, {landing, _set_up}} -> {id, landing} end),
      set_ups: for({id, {_landing, %{} = set_up}} <- found, into: %{}, do: {id, set_up})
    )
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
      if may_invite?(scope),
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

  # Asked of the organisation where there is no workspace: an invitation sent while it has
  # none is to the organisation (`Apiary.Organisations.invite_member/3`).
  defp may_invite?(scope),
    do: Access.can?(scope, :"member.invite", scope.workspace || scope.organisation)
end
