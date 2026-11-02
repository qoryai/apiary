defmodule ApiaryWeb.WorkspaceTypeLive do
  @moduledoc """
  A workspace type's page, `/:org/workspaces/new/<type key>`, such as
  `/acme/workspaces/new/qory.software`: where a kind card of New workspace and of the empty
  organisation overview leads (`ApiaryWeb.SetUpComponents.kind_cards/1`). The breadcrumb
  is the organisation, New workspace, then the type's name.

  With the feature `workflow_model`, the stages a new workspace of the type starts with,
  the newest version of its default process (`Apiary.Processes.TypeTemplates.newest/1`),
  fill the window on the view-only canvas (`StagesLive.Canvas.canvas/1`, in a
  `.q-canvas-fill` box), whose cards open nothing. Beside it, a side panel has the type's
  name, its summary, "How it works" with its description (`Apiary.Processes.type_texts/1`,
  a blank line between paragraphs), "Stages" with one line on where they change after,
  and **Create workspace**. Without the feature there is no canvas: "How it works" takes
  the main area, and the side panel has the name, the summary and Create workspace.

  Create workspace creates the workspace and opens its Name step
  (`ApiaryWeb.SetUpComponents.choose_kind/3`). Where the organisation had no workspace when
  the page opened, it is the organisation's first; if someone else created one since, the
  organisation's overview opens instead, as on the empty overview before. The page is for
  the people New workspace is for (`workspace.create`); for anyone else it is New
  workspace's not-found page. A key of no type with a card
  (`ApiaryWeb.SetUpComponents.card_domain/1`) is a path that does not exist.
  """
  use ApiaryWeb, :live_view

  alias Apiary.{Access, Features, Organisations, Processes}
  alias Apiary.Processes.TypeTemplates
  alias ApiaryWeb.{SetUpComponents, SettingsComponents}
  alias ApiaryWeb.StagesLive.Canvas

  @impl true
  def mount(%{"type" => type}, _session, socket) do
    scope = socket.assigns.current_scope

    unless Access.can?(scope, :"workspace.create", scope.organisation),
      do: raise(ApiaryWeb.NotFound, page: :new_workspace)

    domain = SetUpComponents.card_domain(type) || raise ApiaryWeb.NotFound
    newest = TypeTemplates.newest(type)
    texts = Processes.type_texts(newest)

    {:ok,
     assign(socket,
       page_title: texts.name,
       domain: domain,
       texts: texts,
       paragraphs: paragraphs(texts.description),
       document: newest.document,
       canvas: Features.visible?(scope, :workflow_model),
       which: if(Organisations.has_workspace?(scope.organisation), do: :any, else: :first)
     )}
  end

  # The description's paragraphs: a blank line starts a new one.
  defp paragraphs(nil), do: []

  defp paragraphs(text),
    do: text |> String.split(~r/\n\s*\n/) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  @impl true
  def handle_event("create", _params, socket) do
    %{domain: domain, which: which} = socket.assigns
    {:noreply, SetUpComponents.choose_kind(socket, domain.name(), which)}
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
      <:crumb>{@texts.name}</:crumb>

      <div id="workspace-type" class="q-canvas-fill">
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
              :if={@canvas}
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
            <.button
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
