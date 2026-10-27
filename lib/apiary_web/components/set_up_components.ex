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
  """
  use ApiaryWeb, :html

  # `steps/1` is this module's progress indicator, not the core's numbered list.
  import ApiaryWeb.CoreComponents, except: [steps: 1]

  alias Apiary.{Access, Adapters, Features, Mail, Organisations}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Invitation, Organisation}

  ## The steps

  @doc """
  steps_for/3 is the list of the set-up's steps that `scope`'s person sees on this
  instance, in order (`t:Apiary.Edition.set_up_step/0`), with `current` the id of the step
  the page shows, as the edition answers it (`c:Apiary.Edition.set_up_steps/2`). `scope`
  is nil on a page read signed out.

  1. Invitation, with `invitation:`, an invitation without a workspace, and `token:`, its
     token: done, a link back to its page, unless it is the page's step.
  2. Your account: done once the person is signed in; never a link.
  3. One step for each of the instance's adapters, by name, with the `factory` feature,
     then Mail: for an instance admin, and with
     `first: true` on the set-up link's page, whose reader becomes one. An adapter is
     done once it is configured; Mail where the
     environment sets it, or once settings are saved and their test link sent.
  4. Workspace: for a person of an organisation who may create its first workspace
     (`workspace.create`), or once it has one, done then
     (`Apiary.Organisations.has_workspace?/1`); signed out, where the organisation is
     still to be made, or is the invitation's and has none.
  5. Work source, with the `factory` feature, for a person who may connect an adapter or
     whom the edition tells who may (`c:ApiaryWeb.Edition.who_may_sentence/2`): done by the
     Overview's rule, the edition's `work_source_ready/1`. Signed out, only where the
     organisation is still to be made: an invitation makes a member, who may not connect.

  The step `current` names is current; a step before it that is not done is skipped;
  every other step is done or to come.
  """
  @spec steps_for(Scope.t() | nil, term, keyword) :: [Apiary.Edition.set_up_step()]
  def steps_for(scope, current, opts \\ []) do
    invitation = opts[:invitation]
    signed_in? = match?(%Scope{user: %{}}, scope)

    steps =
      invitation_step(invitation, opts[:token], current) ++
        [step(:account, gettext("Your account"), nil, signed_in?, nil)] ++
        instance_steps(scope, opts[:first] == true) ++
        workspace_steps(scope, invitation, signed_in?)

    Apiary.Edition.set_up_steps(scope, states(steps, current))
  end

  # `done` stands in the state until `states/2` sets it.
  defp step(id, label, group, done, path),
    do: %{id: id, label: label, group: group, state: done, path: path, note: nil}

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

  defp instance_steps(scope, first) do
    admin? = Access.instance_admin?(scope)

    if first or admin? do
      adapters =
        cond do
          first -> Adapters.list_for_set_up()
          Adapters.authorize_instance(scope) == :ok -> Adapters.list_adapters(scope)
          true -> []
        end

      adapter_steps =
        for adapter <- adapters,
            do:
              step(
                {:adapter, adapter.public_id},
                adapter.name,
                :connect,
                Adapters.configured?(adapter),
                if(admin?, do: ~p"/instance/set-up?#{[step: adapter.public_id]}")
              )

      # On the set-up link's page, signed out, the steps have no page to open yet.
      mail_path = if(admin?, do: ~p"/instance/set-up?step=mail")
      adapter_steps ++ [step(:mail, gettext("Mail"), :connect, mail_done?(), mail_path)]
    else
      []
    end
  end

  # Mail is done where the environment sets it, or once settings are saved and their
  # test link sent, followed or not.
  defp mail_done?, do: Mail.source() == :env or Mail.shown().state in [:pending, :on]

  # Signed in: the person's organisation, which has its workspace or is to have one.
  # Before the workspace exists, only for a person who may create it: another person
  # waits, and the page shows them no step of the workspace's.
  defp workspace_steps(%Scope{organisation: %Organisation{} = organisation} = scope, _, true) do
    made? = Organisations.has_workspace?(organisation)

    if made? or Access.can?(scope, :"workspace.create", organisation),
      do: workspace_and_source(scope, organisation, made?),
      else: []
  end

  defp workspace_steps(_scope, _invitation, true), do: []

  # Signed out: the organisation the sign-up or the set-up link makes, whose owner the
  # reader becomes, or the invitation's while it has no workspace. Work source only where
  # the workspace set-up shows it to the reader: to an owner, with the `factory` feature;
  # an invitation makes a member, who may not connect an adapter (`adapter.connect`).
  defp workspace_steps(_scope, invitation, false) do
    if is_nil(invitation) or not Organisations.has_workspace?(invitation.organisation) do
      source =
        if is_nil(invitation) and Features.on?(:factory),
          do: [step(:source, gettext("Work source"), :workspace, false, nil)],
          else: []

      [step(:workspace, gettext("Workspace"), :workspace, false, nil) | source]
    else
      []
    end
  end

  defp workspace_and_source(scope, organisation, made?) do
    workspace = [
      step(
        :workspace,
        gettext("Workspace"),
        :workspace,
        made?,
        ~p"/#{organisation}/set-up?step=type"
      )
    ]

    if source_step?(scope, organisation) do
      done = organisation_workspace(scope) |> source_done?()

      workspace ++
        [
          step(
            :source,
            gettext("Work source"),
            :workspace,
            done,
            ~p"/#{organisation}/set-up?step=source"
          )
        ]
    else
      workspace
    end
  end

  defp organisation_workspace(%Scope{
         organisation: %{id: id},
         workspace: %{organisation_id: id} = workspace
       }),
       do: workspace

  defp organisation_workspace(_scope), do: nil

  defp source_done?(nil), do: false
  defp source_done?(workspace), do: Apiary.Edition.work_source_ready(workspace) != []

  defp source_step?(scope, organisation),
    do:
      Features.visible?(scope, :factory) and
        (Access.can?(scope, :"adapter.connect", organisation) or
           ApiaryWeb.Edition.who_may_sentence(:"adapter.connect", scope) != nil)

  defp states(steps, current) do
    at = Enum.find_index(steps, &(&1.id == current))

    steps
    |> Enum.with_index()
    |> Enum.map(fn {step, index} ->
      state =
        cond do
          index == at -> :current
          step.state -> :done
          at && index < at -> :skipped
          true -> :to_come
        end

      %{step | state: state}
    end)
  end

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

  @doc """
  next?/1 says whether the indicator names the stage after its last step, the
  Overview's setup list: with the `factory` feature where `scope` is, or on the instance
  for a page read signed out.
  """
  @spec next?(Scope.t() | nil) :: boolean
  def next?(%Scope{} = scope), do: Features.visible?(scope, :factory)
  def next?(nil), do: Features.on?(:factory)

  ## The frame

  attr :steps, :list,
    default: [],
    doc: "the set-up's steps (`steps_for/3`); the indicator shows where there are two or more"

  attr :next, :boolean, default: false, doc: "whether the indicator names the next stage"
  attr :page, :string, default: nil, doc: "the page's path, where a step's link patches"
  slot :inner_block, required: true, doc: "the step: its title, form and foot"
  slot :context, doc: "why the step exists and what it changes, under About this step"

  @doc """
  frame/1 is the frame of a page of the set-up: the progress indicator (`steps/1`), the
  step's form, and its context under "About this step", an `<aside>` that follows the
  form in reading order.

  From 1280 px the three are columns: 220 px, 480 px and 320 px. From 1024 px the
  indicator is a bar on top, with the form and its context side by side under it.
  Below 1024 px they stack. A page with fewer than two steps shows no indicator; one
  with no context, no aside.
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
      <.steps :if={@indicator} steps={@steps} next={@next} page={@page} />
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
  attr :next, :boolean, default: false
  attr :page, :string, default: nil

  @doc """
  steps/1 is the progress indicator: "Step 4 of 5" and a progress bar of the same value,
  then the list of `steps`, under their groups' headings, each with its mark: done, a
  filled circle with a check; skipped, an empty circle with a dash and "Skipped";
  current, a ring, `aria-current="step"`; to come, an empty circle. A step that is done or
  skipped and has a path is a link, after the current one too: a patch where its path is
  `page`, else a navigation. With `next`, "Next: on the Overview, …" follows the last.

  Below 1280 px it is a bar, "Step 4 of 5: Workspace", whose **All steps** opens the list
  in place, a disclosure that Escape closes.
  """
  def steps(assigns) do
    at = Enum.find_index(assigns.steps, &(&1.state == :current))

    assigns =
      assign(assigns,
        number: at && at + 1,
        total: length(assigns.steps),
        current: at && Enum.at(assigns.steps, at),
        groups: Enum.chunk_by(assigns.steps, & &1.group),
        escape:
          JS.set_attribute({"aria-expanded", "false"}, to: "#set-up-steps-toggle")
          |> JS.focus(to: "#set-up-steps-toggle")
      )

    ~H"""
    <nav id="set-up-steps" class="q-su-steps" aria-label={gettext("Set-up steps")}>
      <div :if={@number} class="q-su-count">
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
        <%= for group <- @groups do %>
          <li :if={hd(group).group} class="q-su-grp">
            <p id={"set-up-group-#{hd(group).group}"} class="q-su-grp-h">
              {group_heading(hd(group).group)}
            </p>
            <ol aria-labelledby={"set-up-group-#{hd(group).group}"}>
              <li :for={step <- group}>
                <.step_row step={step} page={@page} escape={@escape} />
              </li>
            </ol>
          </li>
          <li :for={step <- group} :if={!hd(group).group}>
            <.step_row step={step} page={@page} escape={@escape} />
          </li>
        <% end %>
      </ol>
      <p :if={@next} id="set-up-next" class="q-su-next">
        {gettext("Next: on the Overview, Machines for runs, Model key and Test run")}
      </p>
    </nav>
    """
  end

  defp group_heading(:connect), do: gettext("Connect %{name}", name: Apiary.ProductName.name())
  defp group_heading(:workspace), do: gettext("Set up your workspace")

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
    do: URI.parse(path).path == page

  defp patch?(_path, _page), do: false

  attr :steps, :list, required: true
  attr :page, :string, default: nil

  @doc """
  back/1 is the Back button at the foot of a step's form: a ghost button to the step
  before the current one in `steps`, a patch where its path is `page`. None on the first
  step, nor where the step before has no page, such as Your account.
  """
  def back(assigns) do
    at = Enum.find_index(assigns.steps, &(&1.state == :current))
    before = if at && at > 0, do: Enum.at(assigns.steps, at - 1)
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
