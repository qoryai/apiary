defmodule ApiaryWeb.WorkspaceTypeLive do
  @moduledoc """
  A template's page, `/:org/workspaces/new/<key>`, where a card of New workspace and of the
  empty organisation overview leads (`ApiaryWeb.SetUpComponents.kind_cards/1`,
  `ApiaryWeb.SetUpComponents.template_cards/1`). The breadcrumb is the organisation, New
  workspace, then the template's name. The page is for the people New workspace is for
  (`workspace.create`); for anyone else it is New workspace's not-found page.

  **The Qory template**, `qory.software`: with the feature `workflow_model`, the stages a
  new workspace starts with, the newest version of its default process
  (`Apiary.Processes.TypeTemplates.newest/1`), fill the window on the view-only canvas
  (`StagesLive.Canvas.canvas/1`, in a `.q-canvas-fill` box), whose cards open nothing.
  Beside it, a side panel has the template's name, its summary, "How it works" with its
  description (`Apiary.Processes.type_texts/1`, a blank line between paragraphs),
  "Stages" with one line on where they change after, the harness line, "Harness: Qory
  harness, stack software" (the copied template's `stack`), and **Create workspace**.
  Without the feature there is no canvas: "How it works" takes the main area, and the side
  panel has the name, the summary, the harness line and Create workspace.

  Create workspace creates the workspace and opens its Name step
  (`ApiaryWeb.SetUpComponents.choose_kind/3`). Where the organisation had no workspace when
  the page opened, it is the organisation's first; if someone else created one since, the
  organisation's overview opens instead, as on the empty overview before.

  **A template of a harness repository**, with the key `<prefix>.<module>`, split at its
  first dot, as a module's name may have dots: the page reads the repository outside its
  process and shows "Reading harnesses…" meanwhile. It then shows the same page from the
  template's `process`, its name, summary and description, with the harness line,
  "Harness: <repository>, stack <stack>", where the Qory page has it. For a shared harness
  that runs hide, the line is "Harness: shared harness, stack <stack>". A read that fails
  shows its reason and a link to New workspace; a module that gave no template opens New
  workspace. Create workspace shows once the read has succeeded. It makes the workspace
  from the template the page read, with no second read, and opens its Name step
  (`ApiaryWeb.SetUpComponents.choose_template/4`). The source, the commit and the template
  come from the page's read, and no parameter of the event is used. The link carries no
  commit.

  A key of no place that New workspace lists for the person, and any key but the Qory
  template's while the feature `factory` is off, is a path that does not exist.
  """
  use ApiaryWeb, :live_view

  alias Apiary.{Access, Features, Organisations, Processes}
  alias Apiary.Harnesses.QoryCopy
  alias Apiary.Processes.TypeTemplates
  alias Apiary.Stacks.Sources
  alias ApiaryWeb.{SetUpComponents, SettingsComponents}
  alias ApiaryWeb.StagesLive.Canvas

  @impl true
  def mount(%{"type" => type}, _session, socket) do
    scope = socket.assigns.current_scope

    unless Access.can?(scope, :"workspace.create", scope.organisation),
      do: raise(ApiaryWeb.NotFound, page: :new_workspace)

    case SetUpComponents.card_domain(type) do
      nil -> {:ok, repository_template(socket, scope, type)}
      domain -> {:ok, qory_template(socket, scope, domain, type)}
    end
  end

  # The Qory template: the newest version of the type's default process and its texts.
  defp qory_template(socket, scope, domain, type) do
    newest = TypeTemplates.newest(type)
    texts = Processes.type_texts(newest)

    assign(socket,
      page_title: texts.name,
      domain: domain,
      texts: texts,
      paragraphs: paragraphs(texts.description),
      document: newest.document,
      canvas: Features.visible?(scope, :workflow_model),
      which: if(Organisations.has_workspace?(scope.organisation), do: :any, else: :first),
      harness: gettext("Harness: Qory harness, stack %{stack}", stack: QoryCopy.template().stack),
      create: true,
      start: nil,
      reading: false,
      read_error: nil,
      module: nil
    )
  end

  # A template of a place `Apiary.Stacks.Sources.listed/1` gives, read once the socket is
  # connected; a key of no place is a path that does not exist.
  defp repository_template(socket, scope, key) do
    case Sources.find_listed(scope, key) do
      {:ok, place, module} ->
        if connected?(socket) do
          source = place.source
          start_async(socket, :template, fn -> Sources.templates(scope, source) end)
        else
          socket
        end
        |> assign(
          page_title: gettext("New workspace"),
          place: place,
          module: module,
          texts: nil,
          paragraphs: [],
          document: nil,
          canvas: Features.visible?(scope, :workflow_model),
          harness: nil,
          create: false,
          start: nil,
          domain: nil,
          which: if(Organisations.has_workspace?(scope.organisation), do: :any, else: :first),
          reading: true,
          read_error: nil
        )

      :error ->
        raise ApiaryWeb.NotFound
    end
  end

  # The description's paragraphs: a blank line starts a new one.
  defp paragraphs(nil), do: []

  defp paragraphs(text),
    do: text |> String.split(~r/\n\s*\n/) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  @impl true
  # `start` is set from the read of this page's own source (`handle_async/3`), and no
  # parameter of the event is read.
  def handle_event("create", _params, %{assigns: %{create: true, start: %{} = start}} = socket) do
    %{place: place, which: which} = socket.assigns
    {:noreply, SetUpComponents.choose_template(socket, place, start, which)}
  end

  def handle_event("create", _params, %{assigns: %{create: true, domain: domain}} = socket)
      when not is_nil(domain) do
    %{which: which} = socket.assigns
    {:noreply, SetUpComponents.choose_kind(socket, domain.name(), which)}
  end

  def handle_event("create", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:template, {:ok, {:ok, %{templates: templates} = result}}, socket) do
    %{module: module, place: place} = socket.assigns

    case Enum.find(templates, &(&1.module == module)) do
      nil ->
        {:noreply,
         push_navigate(socket,
           to: ~p"/#{socket.assigns.current_scope.organisation}/workspaces/new"
         )}

      template ->
        stack = template.stack

        harness =
          if place.hidden,
            do: gettext("Harness: shared harness, stack %{stack}", stack: stack),
            else:
              gettext("Harness: %{repository}, stack %{stack}",
                repository: place.source.label,
                stack: stack
              )

        {:noreply,
         assign(socket,
           page_title: template.name,
           texts: %{name: template.name, summary: template.summary},
           paragraphs: paragraphs(template.description),
           document: template.process,
           harness: harness,
           create: true,
           start: %{source: place.source, commit: result.commit, template: template},
           reading: false
         )}
    end
  end

  def handle_async(:template, {:ok, {:error, reason}}, socket),
    do: {:noreply, read_failed(socket, reason)}

  def handle_async(:template, {:exit, _reason}, socket),
    do: {:noreply, read_failed(socket, :exited)}

  defp read_failed(socket, reason) do
    organisation = socket.assigns.current_scope.organisation

    assign(socket,
      reading: false,
      read_error: SetUpComponents.read_line(reason, socket.assigns.place, organisation)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      place={:organisation}
      width="work"
    >
      <:crumb navigate={~p"/#{@current_scope.organisation}/workspaces/new"}>
        {gettext("New workspace")}
      </:crumb>
      <:crumb :if={@texts}>{@texts.name}</:crumb>

      <section
        :if={!@texts}
        id="workspace-type-read"
        class="grid max-w-[45rem] content-start gap-3 px-8 py-8"
      >
        <p :if={@reading} id="workspace-type-reading" class="text-[13px]/5 text-muted">
          {gettext("Reading harnesses…")}
        </p>
        <p :if={@read_error} id="workspace-type-read-error" class="text-[14px]/5">
          <.rich text={@read_error} />
        </p>
        <.link
          :if={@read_error}
          id="workspace-type-back"
          navigate={~p"/#{@current_scope.organisation}/workspaces/new"}
          class="text-[14px]/5 font-medium"
        >
          {gettext("New workspace")}
        </.link>
      </section>

      <div :if={@texts} id="workspace-type" class="q-canvas-fill">
        <Canvas.canvas
          :if={@canvas}
          id="workspace-type-canvas"
          document={@document}
          mode={:view}
          selectable={false}
        />
        <section
          :if={!@canvas}
          id="workspace-type-how"
          aria-labelledby="workspace-type-how-title"
          class="grid max-w-[45rem] content-start gap-3 px-8 py-8"
        >
          <h2 id="workspace-type-how-title" class="text-lg/7 font-semibold">
            {gettext("How it works")}
          </h2>
          <p :for={paragraph <- @paragraphs} class="text-[14px]/5">{paragraph}</p>
        </section>

        <aside
          id="workspace-type-side"
          class="q-canvas-side"
          style="--q-canvas-side: 24rem"
          aria-labelledby="workspace-type-title"
        >
          <div class="grid gap-4">
            <h1 id="workspace-type-title" class="text-xl/7 font-semibold tracking-[-0.01em]">
              {@texts.name}
            </h1>
            <p :if={@texts.summary} id="workspace-type-summary" class="text-[14px]/5">
              {@texts.summary}
            </p>
            <section
              :if={@canvas and @paragraphs != []}
              id="workspace-type-description"
              aria-labelledby="workspace-type-description-title"
              class="grid gap-2"
            >
              <h2 id="workspace-type-description-title" class="text-[13px]/5 font-semibold">
                {gettext("How it works")}
              </h2>
              <p :for={paragraph <- @paragraphs} class="text-[13px]/5 text-muted">
                {paragraph}
              </p>
            </section>
            <section
              :if={@canvas and @create}
              id="workspace-type-stages"
              aria-labelledby="workspace-type-stages-title"
              class="grid gap-2"
            >
              <h2 id="workspace-type-stages-title" class="text-[13px]/5 font-semibold">
                {gettext("Stages")}
              </h2>
              <p class="text-[13px]/5 text-muted">
                {gettext(
                  "The workspace starts with the stages shown. After you create it, owners and admins can change them in Workspace settings › %{stages}.",
                  stages: SettingsComponents.stages_label()
                )}
              </p>
            </section>
            <p id="workspace-type-harness" class="text-[13px]/5 text-muted">{@harness}</p>
            <.button
              :if={@create}
              id="workspace-type-create"
              variant="primary"
              size="md"
              class="w-full"
              phx-click="create"
              phx-disable-with={gettext("Creating")}
            >
              {gettext("Create workspace")}
            </.button>
          </div>
        </aside>
      </div>
    </Layouts.app>
    """
  end
end
