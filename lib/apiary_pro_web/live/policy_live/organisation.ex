defmodule ApiaryProWeb.PolicyLive.Organisation do
  @moduledoc """
  The organisation's policy, an organisation's page: `/:org/policy`, for a reader who may
  `organisation_policy.read` (owners, admins and readers), where `organisation_policy` is
  on. The rules every workspace of the organisation follows, which a workspace or a
  target may narrow and never widen (`ApiaryPro.OrganisationPolicy`), in the workspace's
  policy page's language (`ApiaryWeb.PolicyLive.Common`, `ApiaryWeb.PolicyComponents`).

  - **The mode**, a card above the tabs on every tab, drawn as the core's mode card
    (`ApiaryWeb.PolicyComponents.mode_card/1`, whose classes and ids it takes, so the
    `PolicyPage` hook's Escape closes it): the floor, "Enforce required" or
    "Set per workspace". Change mode, for an owner, opens the two choices in the card, each
    a native radio; a pick only selects (`mode_pick`), and one button that names the pick
    saves it (`mode_set`), after the question and what it changes in every workspace.
    Cancel and Escape (`mode_cancel`) close it. A refusal keeps it open, its reason under
    the question.
  - **Rules**: the switch (workspaces may allow more hosts) as a line, which an
    owner turns after a confirm, since it renders every workspace again; then Network
    access on the list pattern (`ApiaryWeb.PolicyLive.RuleList`): All, Allowed and Denied, no
    Locked, each rule's use counted over every workspace; Add rule, the section's primary
    button, for an owner, and each rule's menu: Edit, Change to deny or allow, Remove. The
    page reads `?rule=` (the host a link points at) with `?back=`, the workspace's page
    the link came from, which the page offers the way back to. An admin or a reader is
    told that only owners change any of it.
  - **New rule** (`/:org/policy/rules/new`) and **Edit rule**
    (`/:org/policy/rules/:id/edit`), pages of the policy: the core's rule form
    (`ApiaryWeb.PolicyComponents.rule_form/1`) for the scope `:organisation`, which reads
    a rule back as holding for every workspace, under the breadcrumb Policy › New rule or
    Edit rule, with no mode card and no tabs. New rule takes the host from the address
    (`?host=`, from Network access and the overview where only the organisation's allows
    grant) and `?back=`. A rule written there is marked and scrolled to in the list, as a
    `?rule=` link's is. Only an owner opens them (`may_change`); someone else who reads
    the policy is sent back to the list, told why, and anyone who doesn't finds no page.
  - The question of the mode and the switch's confirm, each in place, never over the
    page, say what each changes in every workspace: the workspaces and targets that
    enforce from now on or observe again, the allows left out of force or put back.
  - **Workspaces**: each workspace in use, one line: its mode in force, its workspace rules,
    how many of its allows are not in force, and the way to its policy.
  - **History**: the organisation's changes, one line each, who and what, with the
    workspaces it rendered again and the versions they were left at.

  The page follows the policy's topic (`ApiaryPro.OrganisationPolicy.subscribe/1`) and reads
  everything again on a change.
  """
  use ApiaryProWeb, :live_view
  use ApiaryWeb.Features, :organisation_policy
  on_mount {ApiaryWeb.Access, :"organisation_policy.read"}

  import ApiaryWeb.PolicyComponents, only: [rule_list: 1, rule_form: 1]
  import ApiaryWeb.PolicyLive.Views, only: [confirm_panel: 1, page_skeleton: 1]
  import ApiaryWeb.RichText, only: [rich: 1]

  alias Apiary.{Access, Accounts, Organisations, Targets}
  alias Apiary.Runs.Filters
  alias Apiary.Policy.{Effective, Resolution}
  alias ApiaryPro.OrganisationPolicy
  alias ApiaryProWeb.PolicyLive.Words
  alias ApiaryWeb.{Format, People, RunComponents}
  alias ApiaryWeb.PolicyLive.{Common, RuleList}

  # The mode card's two choices (`mode/1`).
  @modes ~w(own enforce)

  # The live actions of the rule form, a page of the policy.
  @forms [:new_rule, :edit_rule]

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    base = ~p"/#{scope.organisation}/policy"

    socket =
      socket
      |> Common.mount(nil,
        writer: writer(),
        base: base,
        form: "policy-rule",
        scope: :organisation,
        may_change: &owner?/1
      )
      |> assign(
        reload: &load/1,
        list_query: %RuleList{},
        ruled_host: nil,
        params: %{},
        back: nil,
        shown: nil
      )
      |> assign(
        version: nil,
        locks: %{},
        history: nil,
        mode_pick: nil,
        mode_error: nil,
        page_title: gettext("Policy")
      )
      |> assign(:summary, Phoenix.LiveView.AsyncResult.loading())
      |> assign(:activity, Phoenix.LiveView.AsyncResult.loading())

    socket =
      if connected?(socket) do
        OrganisationPolicy.subscribe(scope)
        socket |> load() |> assign(:loaded, true)
      else
        assign(socket, loaded: false)
      end

    {:ok, socket}
  end

  # What the page writes rules with: the organisation's policy, through its context.
  defp writer do
    %{
      allow: fn scope, _holder, attrs -> raced(OrganisationPolicy.allow(scope, attrs)) end,
      deny: fn scope, _holder, attrs -> raced(OrganisationPolicy.deny(scope, attrs)) end,
      remove: fn scope, rule -> raced(OrganisationPolicy.remove_rule(scope, rule)) end,
      get: &OrganisationPolicy.get_rule/2,
      written: fn
        "allow", host -> gettext("%{host} is allowed for every workspace.", host: host)
        "deny", host -> gettext("%{host} is denied for every workspace.", host: host)
      end
    }
  end

  # A workspace removed while a write took the locks of every workspace in use: the lock
  # answers a bare `:not_found` (`Apiary.Policy.lock_workspaces/2`), said as a write that
  # met another, so the page shows it as it shows any refusal (`Common.refused/2`).
  defp raced({:error, :not_found}),
    do:
      {:error,
       Apiary.Policy.Error.new(
         :conflict,
         gettext("Someone changed this at the same moment, so nothing was changed. Try again.")
       )}

  defp raced(result), do: result

  # Whether the reader may change the organisation's rules (`organisation_policy.edit`),
  # the question the writer asks again under its locks.
  defp owner?(scope), do: Access.can?(scope, :"organisation_policy.edit", scope.organisation)

  # Everything the page shows, read again after a write and on a change from elsewhere.
  defp load(socket) do
    scope = socket.assigns.current_scope

    {policy, rules} =
      case OrganisationPolicy.get(scope) do
        {:ok, %{policy: policy, rules: rules}} -> {policy || %OrganisationPolicy.Policy{}, rules}
        {:error, _refused} -> {%OrganisationPolicy.Policy{}, []}
      end

    effective =
      case Resolution.resolve("enforce", rules) do
        {:ok, effective} -> effective
        {:error, _error} -> %Effective{}
      end

    workspaces = Organisations.list_workspaces(scope)

    history_total =
      case OrganisationPolicy.list_changes(scope, 1) do
        {:ok, %{total: total}} -> total
        _refused -> 0
      end

    socket
    |> assign(
      policy: policy,
      own: rules,
      effective: effective,
      workspaces: workspaces,
      workspace_names: Map.new(workspaces, &{&1.id, &1.name}),
      history_total: history_total,
      owner?: owner?(scope),
      operator: OrganisationPolicy.owning_operator(scope),
      reload_pending: false,
      now: DateTime.utc_now()
    )
    |> Common.assign_authors()
    |> then(&assign(&1, :rows, rows(rules, effective, &1)))
    |> load_record()
  end

  # The organisation's rules, one row each (`ApiaryWeb.PolicyComponents.rule_line/1`):
  # each one the organisation's, changed here by an owner; one that a `*.` deny of the
  # organisation covers says why.
  defp rows(rules, effective, socket) do
    scope = socket.assigns.current_scope
    organisation = scope.organisation
    entries = Map.new(effective.entries, &{&1.rule.id, &1})
    source = %{key: organisation.slug, label: organisation.name, rank: 0}

    for rule <- rules do
      entry = entries[rule.id]

      %{
        id: rule.id,
        action: rule.action,
        host: rule.host,
        paths: rule.paths,
        locked: false,
        source: source,
        own: true,
        in_force: entry == nil or entry.in_force,
        off: entry && Common.off_words(entry, organisation.name, organisation.name),
        by: Common.author(socket, rule.created_by_id),
        at: rule.inserted_at,
        locked_tip: nil,
        can_change: socket.assigns.owner?,
        act: :remove,
        view: nil
      }
    end
  end

  # What is read over every workspace, bounded reads that may answer :unavailable: each
  # rule's use over 14 days, and each workspace's summary under the policy.
  defp load_record(socket) do
    scope = socket.assigns.current_scope

    socket
    |> assign_async(:activity, fn ->
      {:ok, %{activity: unwrap(OrganisationPolicy.rule_activity(scope, Common.use_since()))}}
    end)
    |> assign_async(:summary, fn ->
      case OrganisationPolicy.workspaces_summary(scope) do
        {:ok, summary} -> {:ok, %{summary: summary}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp unwrap({:ok, value}), do: value
  defp unwrap(_unavailable), do: :unavailable

  @impl true
  def handle_params(_params, _uri, %{assigns: %{loaded: false}} = socket), do: {:noreply, socket}

  def handle_params(params, _uri, socket) do
    action = socket.assigns.live_action
    socket = assign(socket, params: params, now: DateTime.utc_now())

    # A refusal said on the rule form stays there: Cancel leaves it.
    socket =
      if socket.assigns.shown in @forms and action not in @forms,
        do: assign(socket, :write_error, nil),
        else: socket

    {:noreply, socket |> apply_action(action, params) |> assign(:shown, action)}
  end

  # The list's query is the URL's (`RuleList`), written back without what it does not
  # know; `?rule=` lands on the page of the list that holds the rule.
  defp apply_action(socket, :rules, params) do
    if RuleList.canonical?(params) do
      ruled_host = Common.rule_param(params["rule"])

      query =
        RuleList.landing(
          RuleList.parse(params),
          socket.assigns.rows,
          Common.async_value(socket.assigns.activity),
          ruled_host
        )

      socket
      |> assign(list_query: query, ruled_host: ruled_host, page_title: gettext("Policy"))
      |> assign_back(params["back"])
      |> then(&if(ruled_host, do: push_event(&1, "policy:rule", %{host: ruled_host}), else: &1))
    else
      push_patch(socket,
        to: Common.list_path(socket, RuleList.parse(params), Map.take(params, ~w(rule back))),
        replace: true
      )
    end
  end

  # The rule form, a page of the policy reached by a patch from the list, which it goes
  # back to as it was left; New rule from a workspace's page keeps the way back to it. A
  # reader who may not change the rules is sent back to the list, told why.
  defp apply_action(socket, :new_rule, params) do
    socket
    |> assign(:page_title, form_title(socket, :new_rule))
    |> assign_back(params["back"])
    |> Common.new_rule(params)
  end

  defp apply_action(socket, :edit_rule, %{"id" => id}) do
    socket
    |> assign(:page_title, form_title(socket, :edit_rule))
    |> Common.edit_rule(id)
  end

  defp apply_action(socket, :workspaces, _params),
    do: assign(socket, page_title: gettext("Workspaces · Policy"))

  defp apply_action(socket, :history, params) do
    page = Common.page_param(params["page"])

    history =
      case OrganisationPolicy.list_changes(socket.assigns.current_scope, page) do
        {:ok, history} -> %{history | items: with_changed_by(history.items)}
        {:error, _refused} -> %{items: [], page: 1, pages: 1, total: 0}
      end

    assign(socket, history: history, page_title: gettext("History · Policy"))
  end

  # The changes, each with the account of the person who made it (`changed_by`), read in
  # one read for the page, a deleted account included: History names them by it (`who/1`).
  defp with_changed_by(changes) do
    accounts =
      changes
      |> Enum.map(& &1.changed_by_id)
      |> Accounts.list_users_by_id()
      |> Map.new(&{&1.id, &1})

    Enum.map(changes, &Map.put(&1, :changed_by, accounts[&1.changed_by_id]))
  end

  # The form's browser title, the organisation after the policy.
  defp form_title(socket, :new_rule),
    do:
      gettext("New rule · Policy · %{organisation}",
        organisation: socket.assigns.current_scope.organisation.name
      )

  defp form_title(socket, :edit_rule),
    do:
      gettext("Edit rule · Policy · %{organisation}",
        organisation: socket.assigns.current_scope.organisation.name
      )

  # `?back=` the workspace's page a link to allow a host came from
  # (`c:ApiaryWeb.Edition.above_policy_link/1`), named for the way back: a page of a
  # workspace of this organisation, its overview or its Network access, the whole list or
  # narrowed to one target the workspace has (`?target=tg_…`). Any other path is not
  # offered. The way back is that page's address, built again here, never the link's
  # text, so nothing the link carries beside the page (the list's other filters, a
  # fragment) rides along. Kept while the page is open, as the rule list's patches drop it
  # from the address.
  defp assign_back(socket, path) when is_binary(path) do
    case back(path, socket.assigns.current_scope, socket.assigns.workspaces) do
      nil -> socket
      back -> assign(socket, :back, back)
    end
  end

  defp assign_back(socket, _none), do: socket

  defp back(path, scope, workspaces) do
    org_slug = scope.organisation.slug

    with %URI{scheme: nil, host: nil, path: "/" <> rest, query: query} <- URI.parse(path),
         [^org_slug, slug | segments] <- String.split(rest, "/"),
         %{} = workspace <- Enum.find(workspaces, &(&1.slug == slug)),
         {[_ | _] = names, to} <- page(segments, query, %{scope | workspace: workspace}) do
      %{path: to, label: Enum.join([workspace.name | names], " › ")}
    else
      _other -> nil
    end
  end

  # The names of the page for the way back, and its address as the core writes it.
  defp page([], _query, %{organisation: organisation, workspace: workspace}),
    do: {[gettext("Overview")], ~p"/#{organisation}/#{workspace}"}

  # Network access, narrowed to a target where the address names one: the target read as
  # the page reads it (`Apiary.Runs.Filters.parse/2`, then the target of the workspace
  # with that id, `Apiary.Targets.get_by_public_id/2`), and its address written as the
  # console's links write it (`Apiary.Runs.Filters.target_params/1`), so this page never
  # makes up a target or the shape of its address. An address whose target the parse
  # drops (a `system`, or a path where the id goes), one that names no target of the
  # workspace, several targets, the runs with none, or a typed name (`{:name, text}`) is
  # not offered.
  defp page(["network"], query, workspace_scope) do
    %{organisation: organisation, workspace: workspace} = workspace_scope
    network = ~p"/#{organisation}/#{workspace}/network"
    filters = Filters.parse(URI.decode_query(query || ""), :connections)

    case if("target" in filters.dropped, do: :dropped, else: filters.target) do
      nil ->
        {[gettext("Network access")], network}

      [id] ->
        case Targets.get_by_public_id(workspace_scope, id) do
          %{} = target ->
            params = Filters.target_params([target.public_id])
            {[target.path, gettext("Network access")], network <> "?" <> URI.encode_query(params)}

          nil ->
            nil
        end

      _dropped_several_none_or_name ->
        nil
    end
  end

  defp page(_segments, _query, _workspace_scope), do: nil

  ## Events

  @impl true
  def handle_event(event, params, socket) do
    case Common.handle_event(event, params, socket) do
      {:halt, socket} -> {:noreply, socket}
      :cont -> {:noreply, event(event, params, socket)}
    end
  end

  # The mode's choices, as the core's mode card has them: opened by Change mode, a pick
  # only selects, and one button saves the pick; Cancel and Escape close them.
  # `mode_pick` alone says the choices are open, and what is picked: "own" (each
  # workspace chooses) or "enforce" (enforce in every workspace).
  defp event("mode_open", params, socket) do
    if socket.assigns.owner? do
      pick =
        case params do
          %{"mode" => mode} when mode in @modes -> mode
          _current -> mode(socket.assigns.policy)
        end

      socket
      |> assign(mode_pick: pick, mode_error: nil)
      |> Common.focus("policy-mode-opt-#{pick}")
    else
      only_owners(socket)
    end
  end

  defp event("mode_pick", %{"mode" => mode}, socket) when mode in @modes do
    cond do
      is_nil(socket.assigns.mode_pick) -> socket
      not socket.assigns.owner? -> only_owners(socket)
      true -> assign(socket, mode_pick: mode, mode_error: nil)
    end
  end

  defp event("mode_set", _params, socket) do
    pick = socket.assigns.mode_pick

    cond do
      not socket.assigns.owner? -> only_owners(socket)
      is_nil(pick) -> socket
      pick == mode(socket.assigns.policy) -> close_mode(socket)
      true -> set_mode(socket, pick == "enforce")
    end
  end

  defp event("mode_cancel", _params, socket), do: close_mode(socket)

  # The switch turned: the confirm says what it does to every workspace.
  defp event("switch_ask", _params, socket) do
    if socket.assigns.owner?,
      do: assign(socket, :dialog, {:switch, not socket.assigns.policy.own_allows}),
      else: only_owners(socket)
  end

  defp event("setting_confirm", _params, %{assigns: %{dialog: {:switch, to}}} = socket) do
    socket = assign(socket, :dialog, nil)

    case OrganisationPolicy.set_switch(socket.assigns.current_scope, to) do
      {:ok, _policy} ->
        socket
        |> Common.wrote(
          nil,
          Words.setting_sentence(:switch, to),
          Words.setting_announce(:switch, to)
        )
        |> Common.focus("policy-switch-switch")

      {:error, error} ->
        Common.refused(socket, error)
    end
  end

  defp event(_event, _params, socket), do: socket

  defp only_owners(socket) do
    sentence =
      Words.only_owners(socket.assigns.operator, socket.assigns.current_scope.organisation.name)

    assign(socket, :write_error, sentence)
  end

  # The floor as the card's choices name it.
  defp mode(%{enforce_everywhere: true}), do: "enforce"
  defp mode(_policy), do: "own"

  # The pick saved: the card closes, says the new mode, and the focus goes back to Change
  # mode. A refusal keeps the card open on the pick, its reason under the question, and
  # the focus on the button that names the pick.
  defp set_mode(socket, to) do
    case OrganisationPolicy.set_floor(socket.assigns.current_scope, to) do
      {:ok, _policy} ->
        socket
        |> assign(mode_pick: nil, mode_error: nil)
        |> Common.wrote(
          nil,
          Words.setting_sentence(:floor, to),
          Words.setting_announce(:floor, to)
        )
        |> Common.focus("policy-mode-change")

      {:error, %{message: message}} ->
        socket.assigns.reload.(socket)
        |> assign(:mode_error, message)
        |> Common.focus("policy-mode-set")
    end
  end

  # The choices close, nothing saved; the focus goes back to Change mode.
  defp close_mode(socket) do
    socket |> assign(mode_pick: nil, mode_error: nil) |> Common.focus("policy-mode-change")
  end

  ## Messages

  @impl true
  def handle_info({:organisation_policy_changed, _change}, socket) do
    socket = load(socket)

    socket =
      case socket.assigns.live_action do
        :history -> apply_action(socket, :history, socket.assigns.params)
        _other -> socket
      end

    socket =
      if socket.assigns.composer_params["host"] != "", do: Common.read(socket, %{}), else: socket

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  ## Render

  @impl true
  def render(%{loaded: false} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:organisation_policy}
      width="list"
    >
      <:crumb>{gettext("Policy")}</:crumb>
      <.page_skeleton title={gettext("Policy")} />
    </Layouts.app>
    """
  end

  # The New rule and Edit rule pages: the form, under the breadcrumb that leads back to the
  # list as it was left, with no mode card and no tabs. The page's root and its hook are
  # the list's, so the focus a save sends lands once the list is drawn again.
  def render(%{live_action: action} = assigns) when action in @forms do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:organisation_policy}
      width="list"
    >
      <:crumb patch={Common.cancel_path(assigns)}>{gettext("Policy")}</:crumb>
      <:crumb>
        {if @live_action == :new_rule, do: gettext("New rule"), else: gettext("Edit rule")}
      </:crumb>

      <div
        id="organisation-policy"
        class="q-policy grid grid-cols-[minmax(0,1fr)]"
        phx-hook="PolicyPage"
      >
        <div id="policy-announce" class="sr-only" role="status" aria-live="polite">{@announce}</div>
        <.rule_form
          id="policy-rule"
          title={
            if @rule_edit,
              do: gettext("Edit the rule for %{host}", host: @rule_edit.host),
              else: gettext("New rule")
          }
          form={@composer}
          scope={:organisation}
          reading={@reading}
          queued={length(@queue)}
          editing={@rule_edit && @rule_edit.host}
          error={@write_error}
          cancel={Common.cancel_path(assigns)}
          paths={Apiary.Features.on?(:path_rules)}
        >
          <:description>
            {if @rule_edit,
              do:
                gettext(
                  "Change what the runs of every workspace of %{organisation} may do with %{host}. The host stays; to rule on another host, add a new rule.",
                  organisation: @current_scope.organisation.name,
                  host: @rule_edit.host
                ),
              else:
                gettext(
                  "Let the runs of every workspace of %{organisation} reach a host, or stop them reaching it. A deny here holds in every workspace and target; an allow reaches every workspace, and a workspace or a target may still deny it.",
                  organisation: @current_scope.organisation.name
                )}
          </:description>
        </.rule_form>
      </div>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:organisation_policy}
      width="list"
    >
      <:crumb>{gettext("Policy")}</:crumb>

      <div
        id="organisation-policy"
        class="q-policy grid grid-cols-[minmax(0,1fr)] gap-6"
        phx-hook="PolicyPage"
      >
        <.page_header id="policy-header" title={gettext("Policy")}>
          <:description>
            {gettext(
              "Rules every workspace of %{name} follows. A workspace or a target may narrow them, never widen them.",
              name: @current_scope.organisation.name
            )}
          </:description>
        </.page_header>

        <.mode_card
          policy={@policy}
          can_change={@owner?}
          operator={@operator}
          pick={@mode_pick}
          error={@mode_error}
          summary={@summary}
          scope={@current_scope}
        />

        <.page_tabs id="policy-tabs" label={gettext("Policy")} current={@live_action}>
          <:tab
            key={:rules}
            patch={~p"/#{@current_scope.organisation}/policy"}
            icon="hero-shield-check"
            count={positive(length(@own))}
          >
            {gettext("Rules")}
          </:tab>
          <:tab
            key={:workspaces}
            patch={~p"/#{@current_scope.organisation}/policy/workspaces"}
            icon="hero-squares-2x2"
            count={positive(length(@workspaces))}
          >
            {gettext("Workspaces")}
          </:tab>
          <:tab
            key={:history}
            patch={~p"/#{@current_scope.organisation}/policy/history"}
            icon="hero-clock"
            count={positive(@history_total)}
          >
            {gettext("History")}
          </:tab>
        </.page_tabs>

        <div id="policy-announce" class="sr-only" role="status" aria-live="polite">{@announce}</div>

        <.notice :if={@write_error} kind={:error} class="max-w-[80ch]">
          <span id="policy-write-error" role="alert">{@write_error}</span>
        </.notice>

        <%= case @live_action do %>
          <% :workspaces -> %>
            <.workspaces_tab summary={@summary} scope={@current_scope} />
          <% :history -> %>
            <.history_tab
              history={@history}
              workspace_names={@workspace_names}
              scope={@current_scope}
              now={@now}
            />
          <% _rules -> %>
            {rules_tab(assigns)}
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  # A tab's number, where there is one to show.
  defp positive(n) when n > 0, do: n
  defp positive(_none), do: nil

  ## Rules

  defp rules_tab(assigns) do
    assigns =
      assigns
      |> assign(:activity_now, Common.async_value(assigns.activity))
      |> assign(:listing, Common.listing(assigns))
      |> assign(:switch_counts, switch_counts(assigns))
      |> assign(:edit_path, assigns.owner? && (&Common.edit_rule_path(assigns, &1)))

    ~H"""
    <p :if={!@owner?} id="policy-owners" class="text-[13px]/5 text-muted">
      {Words.owners_line(@operator, @current_scope.organisation.name)}
    </p>
    <%!-- The settings' heading, for a screen reader: the confirm's question under it is an h3. --%>
    <h2 id="policy-settings-h" class="sr-only">{gettext("Settings")}</h2>
    <%!-- No rule over the setting: the tab bar's rule is right above it. --%>
    <ul id="policy-settings" class="q-plain-list border-t-0!" aria-labelledby="policy-settings-h">
      <.setting_line
        id="policy-switch"
        on={@policy.own_allows}
        can_change={@owner?}
        ask="switch_ask"
        name={gettext("Workspaces may allow more hosts")}
      >
        <.rich
          text={Words.switch_now(@policy.own_allows, @switch_counts)}
          phx-no-format
        ><:part name={:counts}><span class="q-hot" id="policy-switch-counts">{@switch_counts}</span></:part></.rich>
        <:confirm :if={match?({:switch, _to}, @dialog)}>
          <.setting_confirm
            to={elem(@dialog, 1)}
            summary={@summary}
            scope={@current_scope}
          />
        </:confirm>
      </.setting_line>
    </ul>

    <section id="policy-hosts" class="q-psec" aria-labelledby="policy-hosts-h">
      <.rule_list
        id="policy-rules"
        title={gettext("Network access")}
        heading_id="policy-hosts-h"
        count={length(@rows)}
        add_path={@owner? && Common.new_rule_path(assigns)}
        edit_path={@edit_path}
        label={gettext("Network access rules of %{name}", name: @current_scope.organisation.name)}
        listing={@listing}
        query={@list_query}
        path={&Common.list_path(@base, &1)}
        sections={RuleList.sections(@rows, @activity_now)}
        default_sort={gettext("Denies first")}
        activity={@activity_now}
        fresh={@fresh}
        ruled_host={@ruled_host}
        views={[:all, :allow, :deny]}
        use_label={gettext("Last 14 days, every workspace")}
        empty={
          if @owner?,
            do:
              gettext("No host rules yet. Add the first with Add rule: it holds in every workspace."),
            else: gettext("No rules yet.")
        }
      >
        <:link>
          <.link :if={@back} id="policy-back" navigate={@back.path} class="q-sect-link">
            <.icon name="hero-arrow-left-micro" class="size-3.5" />{gettext("Back to %{place}",
              place: @back.label
            )}
          </.link>
        </:link>
        <:description>
          {gettext(
            "The hosts the runs of every workspace of %{name} may reach, and those they may not.",
            name: @current_scope.organisation.name
          )}
        </:description>
      </.rule_list>
      <p id="policy-hosts-note" class="q-psec-note">
        {gettext(
          "A deny here holds in every workspace and target, in either mode; an allow reaches every workspace, and a workspace or a target may still deny it. Each workspace whose policy a change changes gets a new version of it."
        )}
      </p>
    </section>
    """
  end

  # The allows the switch leaves out of force, or would turned off, by workspace: nil until
  # the summary is read, and where there are none.
  defp switch_counts(assigns) do
    case Common.async_value(assigns.summary) do
      summary when is_list(summary) -> Words.allows_off(summary, assigns.policy.own_allows)
      _not_yet -> nil
    end
  end

  attr :id, :string, required: true
  attr :on, :boolean, required: true
  attr :can_change, :boolean, required: true
  attr :ask, :string, required: true
  attr :name, :string, required: true
  slot :inner_block, required: true
  slot :confirm, doc: "the setting's confirm in place, under its switch, while it asks"

  # One setting, a line of the core's plain list (`.q-plain-list`) holding the core's
  # switch (`ApiaryWeb.CoreComponents.switch/1`): its name beside it and its sentence under
  # them; disabled for a reader who may not turn it, whom the line above the settings tells
  # why. Its confirm, while it asks, sits on the same line under the switch.
  defp setting_line(assigns) do
    ~H"""
    <li id={@id} class="py-3">
      <.switch
        id={"#{@id}-switch"}
        label={@name}
        checked={@on}
        disabled={!@can_change}
        phx-click={@can_change && @ask}
      >
        {render_slot(@inner_block)}
      </.switch>
      <div :if={@confirm != []} class="basis-full pt-1">{render_slot(@confirm)}</div>
    </li>
    """
  end

  attr :to, :boolean, required: true
  attr :summary, :any, required: true
  attr :scope, :map, required: true

  # The switch turned asks in place, under its line, never over the page (the core's
  # `ApiaryWeb.PolicyLive.Views.confirm_panel/1`): what it does to every workspace, its
  # button and Cancel, which takes the focus; Cancel and Escape give it back to the
  # switch. Its button is never red, as the core's mode card's: either way can be turned
  # back.
  defp setting_confirm(assigns) do
    assigns = assign(assigns, :summary_now, Common.async_value(assigns.summary))

    ~H"""
    <.confirm_panel
      id="policy-setting-confirm"
      question={Words.setting_title(:switch, @to)}
      return="policy-switch-switch"
    >
      <:effect>
        {Words.setting_effect(:switch, @to, @scope.organisation.name)}
        <span :if={not @to and is_list(@summary_now)} id="policy-setting-leaves">
          {Words.leaves_out(@summary_now)}
        </span>
        <span :if={@to and is_list(@summary_now)} id="policy-setting-back">
          {Words.puts_back(@summary_now, @scope.organisation.name)}
        </span>
      </:effect>
      <p class="text-muted">{Words.versions()}</p>
      <:action>
        <.button
          id="policy-setting-confirm-button"
          variant="primary"
          size="xs"
          phx-click="setting_confirm"
          loading_text={gettext("Setting")}
        >
          {Words.setting_button(:switch, @to)}
        </.button>
      </:action>
    </.confirm_panel>
    """
  end

  ## The mode

  attr :policy, :map, required: true
  attr :can_change, :boolean, required: true

  attr :operator, :map,
    default: nil,
    doc: "the operator whose owners alone change its client's policy, or nil"

  attr :pick, :string, default: nil, doc: "the choice picked while the card is open"
  attr :error, :string, default: nil, doc: "why the pick was refused, under the question"
  attr :summary, :any, required: true
  attr :scope, :map, required: true

  # The floor, a card above the tabs in the core's mode card's pattern, with its classes
  # and ids (`ApiaryWeb.PolicyComponents.mode_card/1`, which takes only a workspace or a
  # target): its tile, "Mode" and the floor as the heading's value, what it does, and for
  # an owner Change mode, which opens the two choices in the card. A pick that is not the
  # mode now shows its question, what it changes in every workspace and the button that
  # names it, never red; a refusal stays under the question, as an alert.
  defp mode_card(assigns) do
    current = mode(assigns.policy)
    open? = assigns.pick != nil and assigns.can_change
    summary = Common.async_value(assigns.summary)
    to = assigns.pick == "enforce"

    assigns =
      assign(assigns,
        current: current,
        open?: open?,
        options: mode_options(),
        to: to,
        summary_now: summary,
        preview: is_list(summary) && Words.floor_preview(summary, to)
      )

    ~H"""
    <section
      id="policy-mode"
      class="q-modecard"
      aria-labelledby="policy-mode-h"
      data-mode={@current}
    >
      <div class="q-modecard-main">
        <span class="q-modecard-tile" aria-hidden="true">
          <.icon name={mode_icon(@current)} class="size-5" />
        </span>
        <div class="q-modecard-text">
          <div class="q-modecard-title">
            <h2 id="policy-mode-h" class="q-modecard-h">
              <span class="q-modecard-label">{gettext("Mode")}<span class="sr-only">: </span></span>
              <span id="policy-mode-value" class="q-modecard-value">{Words.mode_value(@current)}</span>
            </h2>
          </div>
          <p id="policy-mode-effect" class="q-modecard-p">
            {Words.floor_now(@current == "enforce", @scope.organisation.name)}
            <span :if={!@can_change} id="policy-mode-owners">
              {Words.only_owners(@operator, @scope.organisation.name)}
            </span>
          </p>
        </div>
        <.button
          :if={@can_change && !@open?}
          id="policy-mode-change"
          type="button"
          class="q-modecard-change"
          phx-click="mode_open"
          aria-controls="policy-mode-form"
          aria-expanded="false"
        >
          {gettext("Change mode")}
        </.button>
      </div>

      <form
        :if={@open?}
        id="policy-mode-form"
        class="q-modecard-form"
        phx-change="mode_pick"
        phx-submit="mode_set"
        novalidate
      >
        <fieldset>
          <legend id="policy-mode-legend" class="q-modecard-legend">
            {gettext("Choose the mode of %{name}'s workspaces", name: @scope.organisation.name)}
          </legend>
          <div class="q-modeopts">
            <label :for={option <- @options} class="q-modeopt">
              <input
                id={"policy-mode-opt-#{option.value}"}
                type="radio"
                class="radio radio-sm radio-primary"
                name="mode"
                value={option.value}
                checked={@pick == option.value}
                aria-labelledby={"policy-mode-opt-#{option.value}-h"}
                aria-describedby={"policy-mode-opt-#{option.value}-p"}
              />
              <span id={"policy-mode-opt-#{option.value}-h"} class="q-modeopt-h">
                <.icon name={option.icon} class="size-5" />{option.label}
                <span :if={option.value == @current} id="policy-mode-current" class="badge badge-sm">
                  {gettext("Current")}
                </span>
              </span>
              <span id={"policy-mode-opt-#{option.value}-p"} class="q-modeopt-p">
                {option.line}
              </span>
            </label>
          </div>
        </fieldset>

        <p :if={@pick == @current} id="policy-mode-now" class="q-modecard-p">
          {Words.mode_now(@current)}
        </p>
        <div
          :if={@pick != @current}
          class="q-modeask"
          role="group"
          aria-labelledby="policy-mode-q"
          aria-describedby="policy-mode-q-effect"
        >
          <h3 id="policy-mode-q" class="q-confirm-q">{Words.setting_title(:floor, @to)}</h3>
          <p id="policy-mode-q-effect" class="text-muted">
            {Words.setting_effect(:floor, @to, @scope.organisation.name)}
          </p>
          <div :if={is_list(@summary_now)} id="policy-mode-preview">
            <ul :if={@preview} class="grid list-disc gap-1 pl-5">
              <li :for={line <- @preview}>{line}</li>
            </ul>
            <p :if={!@preview} class="text-muted">{Words.floor_unchanged(@to)}</p>
          </div>
          <p class="text-muted">{Words.versions()}</p>
          <p :if={@error} id="policy-mode-error" class="text-error" role="alert">{@error}</p>
        </div>

        <div class="q-modecard-act">
          <.button
            :if={@pick != @current}
            id="policy-mode-set"
            type="submit"
            variant="primary"
            aria-describedby="policy-mode-q-effect"
            loading_text={gettext("Setting")}
          >
            {Words.setting_button(:floor, @to)}
          </.button>
          <button id="policy-mode-cancel" type="button" class="btn btn-sm" phx-click="mode_cancel">
            {gettext("Cancel")}
          </button>
        </div>
      </form>
    </section>
    """
  end

  # The card's choices, in their order: the floor off, then on.
  defp mode_options do
    for mode <- @modes do
      %{
        value: mode,
        label: Words.mode_option(mode),
        icon: mode_icon(mode),
        line: Words.mode_line(mode)
      }
    end
  end

  defp mode_icon("enforce"), do: "hero-shield-exclamation"
  defp mode_icon(_own), do: "hero-squares-2x2"

  ## Workspaces

  attr :summary, :any, required: true
  attr :scope, :map, required: true

  defp workspaces_tab(assigns) do
    ~H"""
    <.async_result :let={summary} assign={@summary}>
      <:loading>
        <div id="policy-workspaces-loading" class="grid gap-3" aria-busy="true">
          <span class="sr-only">{gettext("Loading the workspaces")}</span>
          <div class="rounded-box border border-line bg-base-100 p-5 shadow-xs">
            <span class="skeleton q-skel w-48"></span>
          </div>
        </div>
      </:loading>
      <:failed>
        <.notice kind={:error} class="max-w-[80ch]">
          <span id="policy-workspaces-error">
            {gettext(
              "The workspaces could not be loaded. Reload the page; if it keeps happening, Qory Apiary's log has the reason."
            )}
          </span>
        </.notice>
      </:failed>

      <.table
        id="policy-workspaces"
        label={gettext("Workspaces and their policy")}
        rows={summary}
        row_id={&"policy-workspace-#{&1.workspace.id}"}
      >
        <:col :let={row} label={gettext("Workspace")} kind="title">
          <span class="q-nm">
            <.link
              id={"policy-workspace-#{row.workspace.id}-link"}
              navigate={~p"/#{@scope.organisation}/#{row.workspace}/policy"}
              class="q-title hover:underline"
            >
              {row.workspace.name}
            </.link>
            <span class="q-side q-mono" title={~p"/#{@scope.organisation}/#{row.workspace}"}>
              {~p"/#{@scope.organisation}/#{row.workspace}"}
            </span>
          </span>
        </:col>
        <:col :let={row} label={gettext("Mode")}>
          <span id={"policy-workspace-#{row.workspace.id}-mode"}>{Words.mode(row.mode)}</span>
        </:col>
        <:col :let={row} label={gettext("Workspace rules")} from="sm">
          <span id={"policy-workspace-#{row.workspace.id}-own"} class="tabular-nums">
            {ngettext("%{number} rule", "%{number} rules", row.own_rules,
              number: Format.number(row.own_rules)
            )}
          </span>
        </:col>
        <:col :let={row} label={gettext("Not in force")}>
          <span
            id={"policy-workspace-#{row.workspace.id}-off"}
            class={[if(row.allows_off > 0, do: "q-hot", else: "q-faint"), "tabular-nums"]}
          >
            {if row.allows_off > 0,
              do:
                ngettext("%{number} allow", "%{number} allows", row.allows_off,
                  number: Format.number(row.allows_off)
                ),
              else: gettext("none")}
          </span>
        </:col>
        <:col :let={row} label={gettext("Version")} from="md">
          <span :if={row.version} class="q-mono tabular-nums">v{row.version}</span>
          <span :if={!row.version} class="q-faint">{gettext("no version yet")}</span>
        </:col>
      </.table>
      <p id="policy-workspaces-note" class="q-psec-note">
        {gettext("Workspace and target rules narrow %{name}'s.",
          name: @scope.organisation.name
        )}
      </p>
    </.async_result>
    """
  end

  ## History

  # Who made a change, by their account, member or not: their address; "Former member"
  # for a deleted account; nil for nobody.
  defp who(change), do: People.email(change.changed_by)

  attr :history, :any, required: true
  attr :workspace_names, :map, required: true
  attr :scope, :map, required: true
  attr :now, :any, required: true

  defp history_tab(%{history: %{items: []}} = assigns) do
    ~H"""
    <div id="policy-history-empty">
      <.empty_state icon="hero-clock" tone="neutral" title={gettext("No changes yet")}>
        {gettext(
          "Every change to %{name}'s policy is listed here, with the workspaces it rendered again.",
          name: @scope.organisation.name
        )}
      </.empty_state>
    </div>
    """
  end

  defp history_tab(assigns) do
    ~H"""
    <%!-- The pager as close under the table as the core's rule list puts it. --%>
    <div class="grid gap-3">
      <.table
        id="policy-history"
        label={gettext("Changes to %{name}'s policy", name: @scope.organisation.name)}
        rows={@history.items}
        row_id={&"policy-change-#{&1.id}"}
      >
        <:col :let={change} label={gettext("Change")} kind="title">
          <span id={"policy-change-#{change.id}-what"} class="min-w-0 whitespace-normal">
            <.rich text={Words.change_sentence(change, who(change), @scope.user.email)} />
          </span>
        </:col>
        <%!-- Where the table is narrow, the workspaces rendered again give way first, and the
      change wraps: the change and its time always show. --%>
        <:col :let={change} label={gettext("Rendered again")} from="md">
          <span
            :if={Words.rendered(change.rendered, @workspace_names)}
            id={"policy-change-#{change.id}-rendered"}
            class="q-mono tabular-nums"
          >
            {Words.rendered(change.rendered, @workspace_names)}
          </span>
          <span
            :if={!Words.rendered(change.rendered, @workspace_names)}
            id={"policy-change-#{change.id}-rendered"}
            class="q-faint"
          >
            {gettext("no new version: the bytes stayed the same")}
          </span>
        </:col>
        <:col :let={change} label={gettext("When")} class="whitespace-nowrap">
          <RunComponents.relative_time at={change.inserted_at} />
        </:col>
      </.table>
      <RunComponents.pager
        :if={@history.total > 0}
        id="policy-history-pages"
        prefix="policy-history-pages"
        first={(@history.page - 1) * 50 + 1}
        last={min(@history.page * 50, @history.total)}
        total={@history.total}
        previous={
          @history.page > 1 &&
            ~p"/#{@scope.organisation}/policy/history?#{%{"page" => @history.page - 1}}"
        }
        next={
          @history.page < @history.pages &&
            ~p"/#{@scope.organisation}/policy/history?#{%{"page" => @history.page + 1}}"
        }
        previous_label={gettext("Previous")}
        next_label={gettext("Next")}
      />
    </div>
    """
  end
end
