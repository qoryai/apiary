defmodule ApiaryWeb.SetUpComponents do
  @moduledoc """
  What the pages of the set-up share, from the set-up link through the instance's
  connections to the workspace set-up, the sign-up and an invitation's page included.

  - `steps_for/3` is the list of the set-up's steps for a person and this instance, each
    with its state, as the edition answers it (`c:Apiary.Edition.set_up_steps/2`).
  - `frame/1` is the frame of every page of the set-up: the progress indicator
    (`steps/1`), the step's form, and its context, "About this step", in three columns
    from 1280 px. Below 1280 px the indicator is a bar on top; below 1024 px the context
    stacks under the form.
  - `heading/1` is a step's title, and `back/1` the Back button at the form's foot.

  Each step belongs to one of two progresses, its `:progress`. The instance's,
  `:instance`, is set up once, by the instance admin: Your account, one step for each
  adapter, then Mail, each of the group `:connect`. The organisation's, `:organisation`,
  is the flow that sets up a workspace (the list of Apiary.WorkspaceSetup), after Your
  account: Name, Work sources, Destinations, Model, Harness, Machines and Test run, with
  no group.
  Invitation and Your account belong to the instance's progress for an instance admin and
  on the set-up link's page, and to the organisation's for everyone else. A step without
  `:progress`, such as one an edition adds or renames, is the organisation's. The
  indicator and Back show the current step's progress alone, counted from 1. Finishing
  or skipping the instance's last step on `/instance/set-up` leads to the first step of
  the organisation's progress that is not done and has a page, such as Name;
  with none left, to `/`, which sends the admin on as a sign-in does
  (`ApiaryWeb.UserAuth.signed_in_path/1`).
  """
  use ApiaryWeb, :html

  # `steps/1` is this module's progress indicator, not the core's numbered list.
  import ApiaryWeb.CoreComponents, except: [steps: 1]

  alias Apiary.{Access, Adapters, Features, Mail, Organisations, WorkspaceSetup}
  alias Apiary.Accounts.Scope
  alias Apiary.Lingo.Domain
  alias Apiary.Organisations.{Invitation, Organisation, Workspace}

  ## The steps

  @doc """
  steps_for/3 is the list of the set-up's steps that `scope`'s person sees on this
  instance, in order (`t:Apiary.Edition.set_up_step/0`), with `current` the id of the step
  the page shows, as the edition answers it (`c:Apiary.Edition.set_up_steps/2`). `scope`
  is nil on a page read signed out.

  1. Invitation, with `invitation:`, an invitation without a workspace, and `token:`, its
     token: done, a link back to its page, unless it is the page's step.
  2. Your account: done once the person is signed in; never a link.
  3. One step for each of the instance's adapters, with the `factory` feature, then Mail,
     the instance's progress (`progress: :instance`):
     for an instance admin, and with `first: true` on the set-up link's page, whose reader
     becomes one. First the adapters `QORY_INSTALLED_ADAPTERS` lists, in its order:
     before the installer makes one, its step is `{:installing, name}`, labelled with the
     name, never done, with its page at `/instance/set-up?step=<name>`; then the other
     adapters, by name. An adapter is done once it is configured; Mail once mail is on,
     or the relay accepted the last test link of the settings saved
     (`Apiary.Mail.sent_or_on?/1`). Where the server's environment sets mail
     (`Apiary.Mail.source/0` is `:env`), there is no Mail step: nothing is left to
     configure. With no adapter either, the list has no step under Connect.
  4. The flow's steps (the list of Apiary.WorkspaceSetup), of the organisation's progress
     (`progress: :organisation`), with no group, each done by its rule in
     Apiary.WorkspaceSetup: every step with the `factory` feature, Model with
     the `secrets` feature too; without `factory`, Name alone. `flow:` is the flow the
     page sets up (`flow/5`). Without it, the flow of the workspace the scope has once
     the organisation has a workspace, and before, of a new workspace of the default
     type, whose steps lead to the organisation's overview, for a person who may create
     it (`workspace.create`); none
     for anyone else. Signed out, every step, none done and none with a page, where the
     organisation is still to be made; Name alone where it is the invitation's and has
     no workspace.

  Invitation and Your account are of the instance's progress for an instance admin, and
  with `first: true`, even where the list has no adapter or Mail step; else of the
  organisation's. The progress is set once the edition has answered, so a step the
  edition renames from them, with another id, has no progress and is the organisation's.

  The step `current` names is current; a step before it that is not done is skipped,
  but for an `{:installing, name}` step on a page that is not of the instance's
  connections; every other step is done or to come.
  """
  @spec steps_for(Scope.t() | nil, term, keyword) :: [Apiary.Edition.set_up_step()]
  def steps_for(scope, current, opts \\ []) do
    invitation = opts[:invitation]
    signed_in? = match?(%Scope{user: %{}}, scope)
    first = opts[:first] == true
    admin? = Access.instance_admin?(scope)

    steps =
      invitation_step(invitation, opts[:token], current) ++
        [step(:account, gettext("Your account"), nil, signed_in?, nil)] ++
        instance_steps(scope, first, admin?) ++
        flow_steps(scope, invitation, signed_in?, opts)

    start = if first or admin?, do: :instance, else: :organisation

    scope
    |> Apiary.Edition.set_up_steps(states(steps, current))
    |> starting_progress(start)
  end

  # `done` stands in the state until `states/2` sets it. Invitation and Your account get
  # their progress from `starting_progress/2`, after the edition answers.
  defp step(id, label, group, done, path),
    do: %{id: id, label: label, group: group, state: done, path: path, note: nil}

  defp step(id, label, group, done, path, progress),
    do: Map.put(step(id, label, group, done, path), :progress, progress)

  # Sets `start` as the progress of each step whose id is still `:invitation` or
  # `:account` and that has none. A step the edition gave another id keeps no progress.
  defp starting_progress(steps, start) do
    Enum.map(steps, fn
      %{id: id} = step when id in [:invitation, :account] -> Map.put_new(step, :progress, start)
      step -> step
    end)
  end

  # With the invitation's organisation's id, for the edition (`c:Apiary.Edition.set_up_steps/2`);
  # no page shows it.
  defp invitation_step(%Invitation{workspace: nil} = invitation, token, current)
       when is_binary(token) do
    step =
      step(
        :invitation,
        gettext("Invitation"),
        nil,
        current != :invitation,
        ~p"/invitations/#{token}"
      )

    [Map.put(step, :organisation_id, invitation.organisation_id)]
  end

  defp invitation_step(_invitation, _token, _current), do: []

  defp instance_steps(scope, first, admin?) do
    if first or admin? do
      adapters =
        cond do
          first -> Adapters.list_for_set_up()
          Adapters.authorize_instance(scope) == :ok -> Adapters.list_adapters(scope)
          true -> []
        end

      adapter_steps = for entry <- Adapters.set_up_list(adapters), do: adapter_step(entry, admin?)
      adapter_steps ++ mail_step(admin?)
    else
      []
    end
  end

  # No Mail step where the server's environment sets mail.
  defp mail_step(admin?) do
    if Mail.source() == :env do
      []
    else
      # On the set-up link's page, signed out, the steps have no page to open yet.
      mail_path = if(admin?, do: ~p"/instance/set-up?step=mail")
      [step(:mail, gettext("Mail"), :connect, mail_done?(), mail_path, :instance)]
    end
  end

  # An adapter listed in `QORY_INSTALLED_ADAPTERS` that the installer has not made yet is
  # a step by its name, never done.
  defp adapter_step({:installing, name}, admin?),
    do:
      step(
        {:installing, name},
        name,
        :connect,
        false,
        if(admin?, do: ~p"/instance/set-up?#{[step: name]}"),
        :instance
      )

  defp adapter_step(adapter, admin?),
    do:
      step(
        {:adapter, adapter.public_id},
        Adapters.title(adapter),
        :connect,
        Adapters.configured?(adapter),
        if(admin?, do: ~p"/instance/set-up?#{[step: adapter.public_id]}"),
        :instance
      )

  # Mail is done once it is on, or the relay accepted the last test link, followed or not.
  defp mail_done?, do: Mail.sent_or_on?(Mail.settings())

  # Signed in: the flow of the person's organisation, for the workspace the page sets up.
  # Before the organisation's first workspace exists, only for a person who may create
  # it: another person waits, and the page shows them no step of the flow.
  defp flow_steps(%Scope{organisation: %Organisation{}} = scope, _invitation, true, opts) do
    case opts[:flow] || default_flow(scope) do
      nil ->
        []

      flow ->
        for id <- flow_ids(scope) do
          step(
            id,
            step_label(id),
            nil,
            WorkspaceSetup.done?(id, flow.organisation, {flow.domain, flow.workspace}),
            flow_path(flow, id),
            :organisation
          )
        end
    end
  end

  defp flow_steps(_scope, _invitation, true, _opts), do: []

  # Signed out: the organisation the sign-up or the set-up link makes, whose owner the
  # reader becomes: every step of the flow, none done and none with a page yet. For the
  # invitation's organisation while it has none, Name alone: an invitation makes a
  # member, who may not create the workspace (`workspace.create`) nor connect.
  defp flow_steps(_scope, invitation, false, _opts) do
    cond do
      is_nil(invitation) ->
        for id <- flow_ids(nil), do: step(id, step_label(id), nil, false, nil, :organisation)

      not Organisations.has_workspace?(invitation.organisation) ->
        [step(:name, step_label(:name), nil, false, nil, :organisation)]

      true ->
        []
    end
  end

  # The flow a page shows without naming one: the workspace the scope has, of its
  # organisation, once the organisation has a workspace; before, a new workspace of the
  # default type for a person who may create it, whose step paths lead to the
  # organisation's overview and its kind cards; else none.
  defp default_flow(%Scope{organisation: organisation} = scope) do
    cond do
      Organisations.has_workspace?(organisation) ->
        case organisation_workspace(scope) do
          nil -> nil
          workspace -> flow(organisation, Domain.for_workspace(workspace), workspace, :set_up)
        end

      Access.can?(scope, :"workspace.create", organisation) ->
        flow(organisation, Domain.default(), nil, :set_up)

      true ->
        nil
    end
  end

  @typedoc """
  The flow a page sets up (`flow/5`): the organisation, the type of the workspace
  (`Apiary.Lingo.Domain`), the workspace, nil before it exists, and what the page sets
  up: `:set_up`, the steps of a workspace, in the workspace
  (`/:org/:workspace/set-up/<step>`), or `:new`. Before the workspace exists, the steps'
  paths lead to the organisation's overview, whose kind cards create it. `type` is
  whether the flow names the type; no page of the core sets it, since a card's
  **Choose** creates the workspace.
  """
  @type flow :: %{
          organisation: %Organisation{},
          domain: module,
          workspace: %Workspace{} | nil,
          page: :set_up | :new,
          type: boolean
        }

  @doc """
  flow/5 is the flow of a workspace of `organisation`, of the type `domain`: `workspace`,
  or a new one where it is nil, set up on `page`, `:set_up` or `:new`. With `type: true`
  in `opts`, the step's paths name the type.
  """
  @spec flow(%Organisation{}, module, %Workspace{} | nil, :set_up | :new, keyword) :: flow
  def flow(organisation, domain, workspace, page, opts \\ []),
    do: %{
      organisation: organisation,
      domain: domain,
      workspace: workspace,
      page: page,
      type: opts[:type] == true
    }

  @doc """
  flow_path/2 is the path of the step `id` of `flow`: once the workspace exists, its page
  in the workspace, `/:org/:workspace/set-up/<id>`; before, the organisation's overview,
  `/:org`, whose kind cards create it.
  """
  @spec flow_path(flow, atom) :: String.t()
  def flow_path(%{organisation: organisation, workspace: %Workspace{} = workspace}, id),
    do: ~p"/#{organisation}/#{workspace}/set-up/#{id}"

  def flow_path(%{organisation: organisation}, _id), do: ~p"/#{organisation}"

  # The flow's steps the scope's person sees, nil signed out: every step with the
  # `factory` feature, Model with `secrets` too; without `factory`, Name alone.
  defp flow_ids(scope) do
    factory? = shown?(scope, :factory)
    secrets? = shown?(scope, :secrets)

    for id <- WorkspaceSetup.flow(),
        factory? or id == :name,
        id != :model or secrets?,
        do: id
  end

  defp shown?(%Scope{} = scope, feature), do: Features.visible?(scope, feature)
  defp shown?(nil, feature), do: Features.on?(feature)

  @doc """
  step_label/1 is the name of the flow's step `id` in the indicator.
  """
  @spec step_label(atom) :: String.t()
  def step_label(:name), do: gettext("Name")
  def step_label(:sources), do: gettext("Work sources")
  def step_label(:destinations), do: gettext("Destinations")
  def step_label(:model), do: gettext("Model")
  def step_label(:harness), do: gettext("Harness")
  def step_label(:machines), do: gettext("Machines")
  def step_label(:test), do: gettext("Test run")

  @doc """
  flow_title/1 is the line above the indicator's count: "Set up Payments · Software
  factory", or "Set up a new Software factory" before the workspace exists.
  """
  @spec flow_title(flow) :: String.t()
  def flow_title(%{workspace: %Workspace{name: name}, domain: domain}),
    do: gettext("Set up %{workspace} · %{type}", workspace: name, type: domain.type_name())

  def flow_title(%{domain: domain}),
    do: gettext("Set up a new %{type}", type: domain.type_name())

  defp organisation_workspace(%Scope{
         organisation: %{id: id},
         workspace: %{organisation_id: id} = workspace
       }),
       do: workspace

  defp organisation_workspace(_scope), do: nil

  # An adapter the installer has not made yet counts as skipped only on a page of the
  # instance's connections, where the person passed its step; elsewhere it is to come.
  defp states(steps, current) do
    at = Enum.find_index(steps, &(&1.id == current))
    connecting? = at != nil and Enum.at(steps, at).group == :connect

    steps
    |> Enum.with_index()
    |> Enum.map(fn {step, index} ->
      state =
        cond do
          index == at -> :current
          step.state -> :done
          at && index < at && (connecting? or not match?({:installing, _}, step.id)) -> :skipped
          true -> :to_come
        end

      %{step | state: state}
    end)
  end

  @doc """
  connect_steps?/1 is whether the instance's connections, `/instance/set-up`, have a
  step for `scope`'s person: they are an instance admin, and the instance has an adapter,
  with the `factory` feature, or a Mail step (`steps_for/3`).
  """
  @spec connect_steps?(Scope.t()) :: boolean
  def connect_steps?(scope), do: instance_steps(scope, false, Access.instance_admin?(scope)) != []

  @doc """
  next_step/2 is the step after the one whose id is `id` in `steps`, or nil.
  """
  @spec next_step([Apiary.Edition.set_up_step()], term) :: Apiary.Edition.set_up_step() | nil
  def next_step(steps, id) do
    case Enum.find_index(steps, &(&1.id == id)) do
      nil -> nil
      index -> Enum.at(steps, index + 1)
    end
  end

  @typedoc """
  The set-up of a workspace while it is not finished (`workspace_set_up/1`): the flow's steps the
  reader sees, in order, each with its name, its page and whether it is done by its rule;
  how many are done, of how many; and the next step, the first that is not done.
  """
  @type workspace_set_up :: %{
          steps: [%{id: atom, label: String.t(), path: String.t(), done: boolean}],
          done: non_neg_integer,
          total: pos_integer,
          next: %{id: atom, label: String.t(), path: String.t(), done: boolean}
        }

  @doc """
  workspace_set_up/1 is the set-up of the scope's workspace while it is not finished
  (`t:workspace_set_up/0`): the workspace sidebar's group Set up, the Overview's list and the
  organisation overview's line read it. The set-up is finished once the test run passed,
  the Test run step's rule in Apiary.WorkspaceSetup. Nil once it is, where the reader sees
  no Test run step (without the `factory` feature), and for a scope without a workspace.

  While the set-up is finished it reads one rule, the Test run step's; before, the rule of
  every step.
  """
  @spec workspace_set_up(Scope.t() | nil) :: workspace_set_up | nil
  def workspace_set_up(
        %Scope{organisation: %Organisation{} = organisation, workspace: %Workspace{} = workspace} =
          scope
      ) do
    ids = flow_ids(scope)

    if :test in ids and not WorkspaceSetup.test?(workspace) do
      domain = Domain.for_workspace(workspace)
      flow = flow(organisation, domain, workspace, :set_up)

      steps =
        for id <- ids do
          %{
            id: id,
            label: step_label(id),
            path: flow_path(flow, id),
            done: id != :test and WorkspaceSetup.done?(id, organisation, {domain, workspace})
          }
        end

      %{
        steps: steps,
        done: Enum.count(steps, & &1.done),
        total: length(steps),
        next: Enum.find(steps, List.last(steps), &(not &1.done))
      }
    end
  end

  def workspace_set_up(_scope), do: nil

  @doc """
  set_up_path/1 is the page of the next step of the scope's workspace's set-up while it is
  not finished: the first step of the flow that is not done (`workspace_set_up/1`). Nil once it is
  finished, where the reader sees no Test run step, and for a scope without a workspace.
  """
  @spec set_up_path(Scope.t() | nil) :: String.t() | nil
  def set_up_path(scope) do
    case workspace_set_up(scope) do
      nil -> nil
      %{next: next} -> next.path
    end
  end

  ## The frame

  attr :steps, :list,
    default: [],
    doc: "the set-up's steps (`steps_for/3`); the indicator shows where there are two or more"

  attr :title, :string, default: nil, doc: "the line above the indicator's count"
  attr :page, :string, default: nil, doc: "the page's path, where a step's link patches"
  slot :inner_block, required: true, doc: "the step: its title, form and foot"
  slot :context, doc: "why the step exists and what it changes, under About this step"

  @doc """
  frame/1 is the frame of a page of the set-up: the progress indicator (`steps/1`), the
  step's form, and its context under "About this step", an `<aside>` that follows the
  form in reading order.

  From 1280 px the three are columns: 220 px, 480 px and 320 px. From 1024 px the
  indicator is a bar on top, with the form and its context side by side under it.
  Below 1024 px they stack. A page with fewer than two steps in `steps` shows no
  indicator; one whose current step's progress has one step shows it, "Step 1 of 1". A
  page with no context shows no aside.
  """
  def frame(assigns) do
    assigns = assign(assigns, :indicator, length(assigns.steps) > 1)

    ~H"""
    <div
      id="set-up"
      class={[
        "q-su-frame",
        @indicator && "q-su-has-steps",
        @context != [] && "q-su-has-ctx"
      ]}
    >
      <.steps :if={@indicator} steps={@steps} title={@title} page={@page} />
      <div class="q-su-form">{render_slot(@inner_block)}</div>
      <aside
        :if={@context != []}
        id="set-up-context"
        class="q-context"
        aria-labelledby="set-up-context-h"
      >
        <h2 id="set-up-context-h" class="q-context-h">{gettext("About this step")}</h2>
        {render_slot(@context)}
      </aside>
    </div>
    """
  end

  attr :steps, :list, required: true
  attr :title, :string, default: nil
  attr :page, :string, default: nil

  @doc """
  steps/1 is the progress indicator of the current step's progress alone, the instance's
  or the organisation's, with no current step the last step's: `title` where given, then
  "Step 1 of 2" and a progress bar of the same value, counted from 1 in each progress,
  then the list of that progress's steps, each with its mark: done, a filled circle with
  a check; skipped, an empty circle with a dash and "Skipped"; current, a ring,
  `aria-current="step"`; to come, an empty circle. A step that is done or skipped and has
  a path is a link, after the current one too: a patch where its path is `page`, else a
  navigation. The instance's steps (`group: :connect`) are listed under the heading
  "Connect Qory Apiary"; every other step has no heading.

  Below 1280 px it is a bar, "Step 1 of 2: Workspace", whose **All steps** opens the list
  in place, a disclosure that Escape closes.
  """
  def steps(assigns) do
    steps = progress_steps(assigns.steps)
    at = Enum.find_index(steps, &(&1.state == :current))

    assigns =
      assign(assigns,
        number: at && at + 1,
        total: length(steps),
        current: at && Enum.at(steps, at),
        groups: steps |> Enum.chunk_by(& &1.group) |> Enum.map(&{&1, group_heading(hd(&1))}),
        escape:
          JS.set_attribute({"aria-expanded", "false"}, to: "#set-up-steps-toggle")
          |> JS.focus(to: "#set-up-steps-toggle")
      )

    ~H"""
    <nav id="set-up-steps" class="q-su-steps" aria-label={gettext("Set-up steps")}>
      <div :if={@number} class="q-su-count">
        <p :if={@title} id="set-up-title" class="q-su-title">{@title}</p>
        <p id="set-up-step" class="q-su-count-wide">
          {gettext("Step %{step} of %{total}", step: @number, total: @total)}
        </p>
        <p id="set-up-step-bar" class="q-su-count-bar">
          {gettext("Step %{step} of %{total}: %{name}",
            step: @number,
            total: @total,
            name: @current.label
          )}
        </p>
        <button
          id="set-up-steps-toggle"
          type="button"
          class="q-su-disc"
          aria-expanded="false"
          aria-controls="set-up-step-list"
          phx-click={JS.toggle_attribute({"aria-expanded", "true", "false"})}
          phx-keydown={@escape}
          phx-key="Escape"
        >
          {gettext("All steps")}<.icon name="hero-chevron-down-micro" class="size-4" />
        </button>
        <progress class="q-su-progress" value={@number} max={@total} aria-labelledby="set-up-step"></progress>
      </div>
      <ol id="set-up-step-list" class="q-su-list">
        <%= for {group, heading} <- @groups do %>
          <li :if={hd(group).group && heading} class="q-su-grp">
            <p id={"set-up-group-#{hd(group).group}"} class="q-su-grp-h">{heading}</p>
            <ol aria-labelledby={"set-up-group-#{hd(group).group}"}>
              <li :for={step <- group}>
                <.step_row step={step} page={@page} escape={@escape} />
              </li>
            </ol>
          </li>
          <li :for={step <- group} :if={!(hd(group).group && heading)}>
            <.step_row step={step} page={@page} escape={@escape} />
          </li>
        <% end %>
      </ol>
    </nav>
    """
  end

  # The steps of the progress the page shows: the current step's, or, with no current
  # step, the last step's. A step without `:progress` is of the organisation's.
  defp progress_steps([]), do: []

  defp progress_steps(steps) do
    progress = progress(Enum.find(steps, List.last(steps), &(&1.state == :current)))
    Enum.filter(steps, &(progress(&1) == progress))
  end

  defp progress(step), do: Map.get(step, :progress, :organisation)

  defp group_heading(%{group: :connect}),
    do: gettext("Connect %{name}", name: Apiary.ProductName.name())

  defp group_heading(_step), do: nil

  attr :step, :map, required: true
  attr :page, :string, default: nil
  attr :escape, :any, required: true

  defp step_row(assigns) do
    assigns =
      assign(assigns,
        link: assigns.step.state in [:done, :skipped] and is_binary(assigns.step.path),
        patch: patch?(assigns.step.path, assigns.page)
      )

    ~H"""
    <.link
      :if={@link}
      id={step_id(@step)}
      class={["q-su-step", "is-#{@step.state}"]}
      patch={@patch && @step.path}
      navigate={!@patch && @step.path}
      phx-keydown={@escape}
      phx-key="Escape"
    >
      <.step_parts step={@step} />
    </.link>
    <span
      :if={!@link}
      id={step_id(@step)}
      class={["q-su-step", "is-#{@step.state}"]}
      aria-current={@step.state == :current && "step"}
    >
      <.step_parts step={@step} />
    </span>
    """
  end

  attr :step, :map, required: true

  defp step_parts(assigns) do
    ~H"""
    <span class="q-su-mark" aria-hidden="true">
      <.icon :if={@step.state == :done} name="hero-check-micro" class="size-3" />
    </span>
    <span class="q-su-text">
      <span class="q-su-nm">{@step.label}</span>
      <span :if={@step.state == :done} class="sr-only">{gettext(", done")}</span>
      <small :if={@step.note} class="q-su-note">{@step.note}</small>
    </span>
    <small :if={@step.state == :skipped} class="q-su-skipped">{gettext("Skipped")}</small>
    """
  end

  defp step_id(%{id: {:adapter, public_id}}), do: "set-up-steps-adapter-#{public_id}"
  defp step_id(%{id: id}) when is_atom(id), do: "set-up-steps-#{id}"
  defp step_id(_step), do: nil

  defp patch?(path, page) when is_binary(path) and is_binary(page),
    do: same_page?(path, page)

  defp patch?(_path, _page), do: false

  attr :steps, :list, required: true
  attr :page, :string, default: nil

  @doc """
  back/1 is the Back button at the foot of a step's form: a ghost button to the step
  before the current one in its progress, a patch where its path is `page`. None on the
  first step of a progress, such as Name, which leads back to no step of the
  instance's, nor where the step before has no page, such as Your account.
  """
  def back(assigns) do
    steps = progress_steps(assigns.steps)
    at = Enum.find_index(steps, &(&1.state == :current))
    before = if at && at > 0, do: Enum.at(steps, at - 1)
    before = if before && is_binary(before.path), do: before

    assigns = assign(assigns, before: before, patch: before && patch?(before.path, assigns.page))

    ~H"""
    <.button
      :if={@before}
      id="set-up-back"
      variant="ghost"
      size="md"
      class="q-su-back"
      patch={@patch && @before.path}
      navigate={!@patch && @before.path}
      aria-label={gettext("Back to %{step}", step: @before.label)}
    >
      <.icon name="hero-chevron-left-micro" class="size-4" />{gettext("Back")}
    </.button>
    """
  end

  @doc false
  # same_page?/2 is whether `path` opens in the LiveView of `page`, so a link to it is a
  # patch: the same path, or, for a workspace's set-up, `/:org/:workspace/set-up`, a step
  # under it.
  @spec same_page?(String.t(), String.t()) :: boolean
  def same_page?(path, page) do
    at = URI.parse(path).path
    at == page or (String.ends_with?(page, "/set-up") and String.starts_with?(at, page <> "/"))
  end

  ## Parts of a step

  slot :inner_block, required: true, doc: "the title"
  slot :subtitle, doc: "one line under the title"

  @doc """
  heading/1 is a step's title, the page's `<h1>`, and its line under it.
  """
  def heading(assigns) do
    ~H"""
    <div class="grid gap-1.5">
      <h1 class="text-2xl/8 font-semibold tracking-[-0.025em]">{render_slot(@inner_block)}</h1>
      <p :if={@subtitle != []} id="set-up-line" class="text-sm/5 text-muted">
        {render_slot(@subtitle)}
      </p>
    </div>
    """
  end

  ## The kind cards

  @doc """
  kind_cards/1 is the choice of what a new workspace does: one card per domain of
  `Apiary.Lingo.Domain.choices/0` that has a card's words, Software alone, each with the
  type's name (`c:Apiary.Lingo.Domain.type_name/0`), what you do there, what you
  connect, and Choose, which sends the event `choose_kind` with the domain's name as
  `type`. The empty organisation overview (`ApiaryWeb.OrganisationLive`) and New
  workspace (`/:org/workspaces/new`) show it, and each takes the event with
  `choose_kind/3`. With `limit`, that line shows in place of the cards.
  """
  attr :id, :string, default: "set-up-cards"
  attr :title, :string, required: true
  attr :heading, :string, default: "h1", values: ~w(h1 h2)
  attr :limit, :string, default: nil, doc: "the line of an organisation that may have no more"

  def kind_cards(assigns) do
    assigns =
      assign(
        assigns,
        :cards,
        for(domain <- Domain.choices(), c = kind_card_words(domain), do: {domain, c})
      )

    ~H"""
    <div class="grid gap-4">
      <.dynamic_tag
        tag_name={@heading}
        id={"#{@id}-title"}
        class="text-2xl/8 font-semibold tracking-[-0.025em]"
      >
        {@title}
      </.dynamic_tag>
      <.notice :if={@limit} kind={:error}>
        <span id="set-up-limit">{@limit}</span>
      </.notice>
      <ul :if={!@limit} id={@id} class="grid gap-3">
        <li
          :for={{domain, card} <- @cards}
          id={"set-up-card-#{domain.name()}"}
          class="grid gap-2 rounded-box border border-line bg-base-100 px-4 py-3"
        >
          <h2 class="font-semibold">{domain.type_name()}</h2>
          <p class="text-[13.5px]/5">{card.what}</p>
          <p class="text-[13.5px]/5 text-muted">{card.connect}</p>
          <div class="flex justify-end">
            <.button
              id={"set-up-card-#{domain.name()}-choose"}
              variant="primary"
              size="md"
              phx-click="choose_kind"
              phx-value-type={domain.name()}
              phx-disable-with={gettext("Creating")}
            >
              {gettext("Choose")}
            </.button>
          </div>
        </li>
      </ul>
    </div>
    """
  end

  # The words of a domain's card, nil for a domain without one, which shows no card. A
  # person reads a card's line where they pick a type, in any locale, so the line is in the
  # `workspace type` context and keeps the type's words.
  defp kind_card_words(Domain.Software) do
    %{
      what: pgettext("workspace type", "Agents change code in your repositories."),
      connect: gettext("You connect: where work comes from, where changes go, a model.")
    }
  end

  defp kind_card_words(_domain), do: nil

  @doc """
  choose_kind/3 takes Choose of a kind card (`kind_cards/1`) on `socket`'s page: it creates
  a workspace of that type in the scope's organisation, named after the type
  (`Apiary.Organisations.create_workspace_of_kind/3`, with `which`, `:first` on the empty
  organisation overview), and opens its first set-up step, Name. A type with no card
  changes nothing. Where someone else created the organisation's first workspace a moment
  before, or the person may no longer create one, the organisation's overview opens
  again; where the organisation may have no more, the page says so.
  """
  @spec choose_kind(Phoenix.LiveView.Socket.t(), term, :first | :any) ::
          Phoenix.LiveView.Socket.t()
  def choose_kind(socket, type, which) do
    scope = socket.assigns.current_scope
    organisation = scope.organisation

    case Enum.find(Domain.choices(), &(&1.name() == type and kind_card_words(&1) != nil)) do
      nil ->
        socket

      domain ->
        case Organisations.create_workspace_of_kind(scope, domain, which) do
          {:ok, workspace} ->
            Phoenix.LiveView.push_navigate(socket,
              to: flow_path(flow(organisation, domain, workspace, :set_up), :name)
            )

          {:error, :limit} ->
            Phoenix.LiveView.put_flash(socket, :error, limit_line(organisation))

          {:error, reason} when reason in [:exists, :forbidden, :not_found] ->
            Phoenix.LiveView.push_navigate(socket, to: ~p"/#{organisation}")

          {:error, _changeset} ->
            Phoenix.LiveView.put_flash(socket, :error, gettext("Nothing was changed. Try again."))
        end
    end
  end

  @doc "limit_line/1 is the line of an organisation that may have no more workspaces."
  @spec limit_line(%Organisation{}) :: String.t()
  def limit_line(%Organisation{name: name}),
    do: gettext("%{organisation} may have no more workspaces.", organisation: name)

  attr :id, :string, required: true
  attr :title, :string, required: true, doc: "where the steps happen, such as \"On GitHub\""

  attr :guide, :map,
    required: true,
    doc: "the adapter's part of its guide (`Apiary.Adapters.guide/2`)"

  slot :note, doc: "a line of Qory Apiary's under the adapter's steps"

  @doc false
  # outside/1 is the steps a person takes in another system, in the context column, under
  # `title`: an adapter's guide, its line before the steps, its steps, its line after
  # them, then Qory Apiary's notes. The adapter's lines are its words, shown as plain text
  # (`ApiaryWeb.ExternalText.external_text/1`), never as Markdown or HTML. The function is
  # of the `factory` feature, and left out of the module reference.
  def outside(assigns) do
    ~H"""
    <div id={@id} class="contents">
      <h3>{@title}</h3>
      <p :if={@guide.before}><.external_text text={@guide.before} /></p>
      <ol :if={@guide.steps != []}>
        <li :for={step <- @guide.steps}><.external_text text={step} /></li>
      </ol>
      <p :if={@guide.after}><.external_text text={@guide.after} /></p>
      <p :for={note <- @note}>{render_slot(note)}</p>
    </div>
    """
  end
end
