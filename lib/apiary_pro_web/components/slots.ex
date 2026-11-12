defmodule ApiaryProWeb.Slots do
  @moduledoc """
  What the edition renders in the named places of the core's pages (`ApiaryWeb.Extension`), but
  the notices at their top (`ApiaryProWeb.Notices`): links to the edition's pages, and what they
  need beside them to be read. Nothing here handles an event; the pages it links to do.

  - `workspaces_heading/1`, the Workspaces section's actions in the organisation's
    settings, and the organisation's overview's (`:organisation_heading`): New workspace,
    for a person `workspace.create` allows, once the organisation has a workspace; it leads
    to the core's type cards, `/:org/workspaces/new`. An organisation with none shows the
    cards on its overview, and no button beside them.
  - `members_heading/1`, the People page's title: which workspaces each level reaches,
    and the operator of a client, for every one of its people.
  - `member_access/1`, each member on the People page, beside their name, in muted words
    on the row's one line: the workspaces they reach, of those the reader reaches, which
    the membership carries (`Apiary.Organisations.list_members/1`).
  - `member_actions/1`, each member's ⋯ menu on the People page: their Workspaces page
    (`ApiaryProWeb.MemberLive.Workspaces`), where an owner or an admin adds them to a
    workspace or removes them from one.
  - `policy_notices/1`, a workspace's policy page: the policy requests of a client's
    operator that wait for an answer, and the way to them
    (`ApiaryProWeb.PolicyRequestLive.Index`).

  A slot reads what it shows when it renders. LiveView renders it again only when what
  the page passes it changes, its scope or its row, so it reads as often as the page
  would have at mount.
  """
  use ApiaryProWeb, :html

  alias Apiary.{Access, Organisations}
  alias ApiaryPro.{Operators, PolicyRequests}

  @doc """
  workspaces_heading/1 renders, for a person `workspace.create` allows in the organisation
  of `scope`, once the organisation has a workspace in use, the one primary button of
  Workspaces, New workspace, which leads to the core's type cards; nothing for anyone else,
  and nothing while the organisation has no workspace, whose overview shows the cards.
  """
  attr :scope, :any, required: true

  @spec workspaces_heading(map) :: Phoenix.LiveView.Rendered.t()
  def workspaces_heading(assigns) do
    assigns =
      assign(
        assigns,
        :owner?,
        Organisations.has_workspace?(assigns.scope.organisation) and
          Access.can?(assigns.scope, :"workspace.create", assigns.scope.organisation)
      )

    ~H"""
    <.button
      :if={@owner?}
      id="new-workspace"
      variant="primary"
      navigate={~p"/#{@scope.organisation}/workspaces/new"}
    >
      <.icon name="hero-plus-micro" class="size-4" /> {gettext("New workspace")}
    </.button>
    """
  end

  @doc """
  members_heading/1 renders which workspaces each level reaches, a sentence that goes on
  from the People section's subtitle, and the operator of the organisation of `scope`,
  when it is a client: "Operated by" its name, on a separate line.
  """
  attr :scope, :any, required: true

  @spec members_heading(map) :: Phoenix.LiveView.Rendered.t()
  def members_heading(assigns) do
    assigns = assign(assigns, :operator, Operators.operator_of(assigns.scope))

    ~H"""
    <%!-- The subtitle's next sentence, in its paragraph; the operator on a separate
         line. --%>
    <span id="workspace-reach">
      {gettext("Owners and admins reach every workspace; members, the workspaces they are added to.")}
    </span>
    <span :if={@operator} id="operated-by" class="mt-1 block">
      {operated_by(@operator)}
    </span>
    """
  end

  # While the operator owns its clients (`ApiaryPro.Flags.operator_infrastructure?/0`), it
  # is their owner.
  defp operated_by(operator) do
    if ApiaryPro.Flags.operator_infrastructure?(),
      do: gettext("Owned by %{operator}", operator: operator.name),
      else: gettext("Operated by %{operator}", operator: operator.name)
  end

  @doc """
  member_access/1 renders the workspaces `member` reaches, of those the reader of `scope`
  reaches, as muted words beside their name (under it, where the table is narrow, so the
  Level and the menu keep their place): every one, for a level that reaches them all; none yet, where the reader would see them all, or it is the reader's row; none
  the reader can see, otherwise.
  """
  attr :scope, :any, required: true
  attr :member, :any, required: true

  @spec member_access(map) :: Phoenix.LiveView.Rendered.t()
  def member_access(assigns) do
    ~H"""
    <span
      id={"member-#{@member.id}-workspaces"}
      class="q-member-access text-[12.5px] font-normal text-muted"
      title={gettext("The workspaces they reach")}
    >
      <%= cond do %>
        <% Access.reaches_every_workspace?(@member.level) -> %>
          {gettext("Every workspace")}
        <% @member.workspaces == [] and
            (Access.reaches_every_workspace_in?(@scope) or @member.user_id == @scope.user.id) -> %>
          <span class="text-faint">{gettext("No workspace yet")}</span>
          <%!-- A reader who reaches some workspaces is shown only those. --%>
        <% @member.workspaces == [] -> %>
          <span class="text-faint">{gettext("None you can see")}</span>
        <% true -> %>
          {Enum.map_join(@member.workspaces, ", ", & &1.name)}
      <% end %>
    </span>
    """
  end

  @doc """
  member_actions/1 renders the item of `member`'s menu that leads to their Workspaces
  page, for a reader of `scope` who may add them to a workspace; nothing for a member
  whose level reaches every workspace already.
  """
  attr :scope, :any, required: true
  attr :member, :any, required: true

  @spec member_actions(map) :: Phoenix.LiveView.Rendered.t()
  def member_actions(assigns) do
    ~H"""
    <.menu_item
      :if={
        not Access.reaches_every_workspace?(@member.level) and
          Access.can?(@scope, :"workspace_access.add", @member)
      }
      id={"member-#{@member.id}-manage-workspaces"}
      navigate={~p"/#{@scope.organisation}/settings/people/#{@member.id}/workspaces"}
      aria-label={gettext("Workspaces of %{email}", email: @member.user.email)}
    >
      {gettext("Workspaces…")}
    </.menu_item>
    """
  end

  @doc """
  policy_notices/1 renders how many policy requests of the operator of the organisation
  of `scope` wait for its answer, with the way to them; nothing while none waits.
  """
  attr :scope, :any, required: true

  @spec policy_notices(map) :: Phoenix.LiveView.Rendered.t()
  def policy_notices(assigns) do
    assigns = assign(assigns, :pending, PolicyRequests.pending_count(assigns.scope))

    ~H"""
    <.notice :if={@pending > 0} class="max-w-[80ch]">
      <span id="policy-requests-pending">
        <.rich text={
          rich_ngettext(
            "A policy request of the organisation's operator waits for an answer: %{link}.",
            "%{number} policy requests of the organisation's operator wait for an answer: %{link}.",
            @pending,
            number: Format.number(@pending),
            link: {:link, ~p"/#{@scope.organisation}/policy-requests", gettext("see the requests")}
          )
        } />
      </span>
    </.notice>
    """
  end
end
