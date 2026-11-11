defmodule ApiaryWeb.ArtifactLive.Show do
  # A version of a work item's artifact, `/:org/:workspace/work/:number/artifacts/:version_id`,
  # under the feature `workflow_model`: its type and base view, its name, its number,
  # who made it (a run or a person), the stage it was made in, its note, its files with
  # their sizes and downloads, the view of its type's base view
  # (`ApiaryWeb.ArtifactComponents.view/1`), and the artifact's history, every version
  # newest first, each a link to its page. A version of `mockup` that a run pushed with a
  # `screens.json` is shown as a mockup of pages, "Mockup", in place of its type's
  # "Image" (`Load.mockup/2`), its frame and links with a token of the reader's for the
  # frame's address; a version of pictures as its type.
  #
  # Every member who may read the work item reads it (`work_item.read`); a number, or a
  # version id, of no work item or version the reader may read is not found. A reader who
  # may add a version (`artifact.write`) has Add a version on a version of a type the add
  # page lists (`Apiary.Artifacts.person_types/1`), so not on the questions or the review
  # comments, which members write through Explore's actions. Add a version opens the add
  # page with the type and the name filled in (`ApiaryWeb.ArtifactLive.New`).
  #
  # **Live.** The page listens on its work item's artifacts topic
  # (`Apiary.Artifacts.subscribe/2`) and reads the history again on
  # `{:artifact_pushed, work_item_id, version_id}`, while `work_item.read`, asked of the
  # reader as they are now, passes; once it fails, the page stops listening.
  #
  # The module reference leaves out this module of the `workflow_model` feature.
  @moduledoc false

  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :workflow_model
  on_mount {ApiaryWeb.Access, :"work_item.read"}

  alias Apiary.{Access, Artifacts}
  alias ApiaryWeb.ArtifactComponents
  alias ApiaryWeb.ArtifactLive.Load

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:work_items}
      width="list"
    >
      <:crumb navigate={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/work"}>
        {gettext("Work items")}
      </:crumb>
      <:crumb navigate={
        ~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/work/#{@number}"
      }>
        {gettext("Work item #%{number}", number: @number)}
      </:crumb>
      <:crumb>{ArtifactComponents.title(@version.artifact, @version)}</:crumb>

      <.page_header id="artifact-header" title={ArtifactComponents.title(@version.artifact, @version)}>
        <:description>
          {gettext("Version %{number} of this artifact, made on %{date}.",
            number: @version.number,
            date: Format.datetime(@version.inserted_at, zone: true)
          )}
        </:description>
        <:actions :if={@writes}>
          <.button
            id="artifact-add"
            navigate={add_path(@current_scope, @number, @version.artifact)}
          >
            {gettext("Add a version")}
          </.button>
        </:actions>
      </.page_header>

      <div class="q-art-cols grid gap-8">
        <div class="grid min-w-0 content-start gap-8">
          <section id="artifact-view-part" aria-labelledby="artifact-view-title" class="grid gap-3">
            <h2 id="artifact-view-title" class="q-part-h">{Load.base_view(@view.base_view)}</h2>
            <ArtifactComponents.view
              id={"artifact-view-#{@version.public_id}"}
              type={@view}
              mockup={@mockup}
              screen_path={
                &ArtifactComponents.mockup_path(
                  @current_scope,
                  @number,
                  @version.public_id,
                  @frame_token,
                  &1
                )
              }
              version={@version}
              content={@content}
              shown={@shown}
              path={&ArtifactComponents.file_path(@current_scope, @number, @version.public_id, &1)}
              script={~p"/assets/js/mermaid.js"}
            />
          </section>

          <section id="artifact-files-part" aria-labelledby="artifact-files-title" class="grid gap-3">
            <h2 id="artifact-files-title" class="q-part-h">
              {gettext("Files")}
              <span class="q-part-n">{Format.number(length(@version.files))}</span>
            </h2>
            <ArtifactComponents.files
              id="artifact-files"
              files={@version.files}
              path={&ArtifactComponents.file_path(@current_scope, @number, @version.public_id, &1)}
            />
          </section>
        </div>

        <aside class="grid content-start gap-8">
          <section id="artifact-details" aria-labelledby="artifact-details-title" class="grid gap-3">
            <h2 id="artifact-details-title" class="q-part-h">{gettext("Details")}</h2>
            <dl class="grid grid-cols-[auto_minmax(0,1fr)] gap-x-4 gap-y-1.5 text-[13px]/5">
              <dt class="text-muted">{gettext("Type")}</dt>
              <dd id="artifact-type">
                {@version.artifact.type}
                <span class="text-muted">· {Load.base_view(@view.base_view)}</span>
              </dd>
              <dt class="text-muted">{gettext("Name")}</dt>
              <dd id="artifact-name" class="break-all">{@version.artifact.name}</dd>
              <dt class="text-muted">{gettext("Version")}</dt>
              <dd id="artifact-number" class="tabular-nums">{@version.number}</dd>
              <dt class="text-muted">{gettext("Made by")}</dt>
              <dd id="artifact-writer" class="break-all">
                <ArtifactComponents.made_by version={@version} scope={@current_scope} />
              </dd>
              <dt class="text-muted">{gettext("Stage")}</dt>
              <dd id="artifact-stage">{@stage || gettext("None")}</dd>
              <dt class="text-muted">{gettext("Note")}</dt>
              <dd id="artifact-note" class="whitespace-pre-wrap break-words" phx-no-format>{@note || gettext("None")}</dd>
            </dl>
          </section>

          <section id="artifact-history" aria-labelledby="artifact-history-title" class="grid gap-3">
            <h2 id="artifact-history-title" class="q-part-h">
              {gettext("History")}
              <span class="q-part-n">{Format.number(length(@history))}</span>
            </h2>
            <ol class="grid gap-2 text-[13px]/5">
              <li :for={version <- @history} id={"artifact-history-#{version.public_id}"} class="grid">
                <.link
                  navigate={
                    ArtifactComponents.version_path(@current_scope, @number, version.public_id)
                  }
                  aria-current={version.id == @version.id && "page"}
                  class={[
                    "font-medium",
                    version.id == @version.id && "text-base-content",
                    version.id != @version.id && "text-accent"
                  ]}
                >
                  {gettext("Version %{number}", number: version.number)}
                </.link>
                <span class="text-[12.5px] text-muted">
                  <ArtifactComponents.made_by version={version} scope={@current_scope} />
                  · {Format.datetime(version.inserted_at)}
                </span>
              </li>
            </ol>
          </section>
        </aside>
      </div>
    </Layouts.app>
    """
  end

  # The token of the frame's address (`ApiaryWeb.ArtifactMockupController.token/3`), for
  # the reader of the page, who may read the version. Signed at the minute, so the page's
  # first render and its connected one have the same token and the frame loads once.
  defp frame_token(socket, scope, work_item, version) do
    ApiaryWeb.ArtifactMockupController.token(
      socket,
      %{version: version.public_id, work_item: work_item.id, user: scope.user.id},
      signed_at: div(System.system_time(:second), 60) * 60
    )
  end

  @impl true
  def mount(%{"number" => number, "version_id" => version_id}, _session, socket) do
    scope = socket.assigns.current_scope

    with %{} = work_item <- Load.work_item(scope, number),
         %{} = version <- Load.version(work_item, version_id) do
      if connected?(socket), do: Artifacts.subscribe(scope, work_item)
      type = Load.type(work_item, version.artifact.type)
      mockup = Load.mockup(type, version)

      {:ok,
       socket
       |> assign(
         work_item: work_item,
         number: work_item.number,
         version: version,
         type: type,
         view: if(mockup, do: %{type | base_view: :mockup}, else: type),
         mockup: with({:ok, index} <- mockup, do: index),
         frame_token: mockup && frame_token(socket, scope, work_item, version),
         shown: nil,
         content: if(connected?(socket), do: Load.content(type, version), else: :pending),
         stage: Load.stage_name(work_item, version.stage_id),
         note: Apiary.ExternalText.present_lines(version.note),
         writes:
           Access.can?(scope, :"artifact.write", work_item) and
             person_type?(scope, version.artifact.type),
         page_title: ArtifactComponents.title(version.artifact, version)
       )
       |> load_history()}
    else
      _not_found -> raise ApiaryWeb.NotFound
    end
  end

  defp load_history(socket),
    do: assign(socket, :history, Artifacts.versions(socket.assigns.version.artifact))

  # Another file of a document version: rendered as the reader opens it, in place of the
  # one shown (`Load.content/3`). The file already shown is not rendered again. Only a
  # document of the version (`ArtifactComponents.documents/2`) is rendered.
  @impl true
  def handle_event("show-document", %{"file" => filename}, socket) do
    %{type: type, version: version, shown: shown} = socket.assigns
    documents = ArtifactComponents.documents(type, version)
    shown = shown || Enum.at(Enum.map(documents, & &1.filename), 0)

    if type.base_view == :document and filename != shown and
         Enum.any?(documents, &(&1.filename == filename)),
       do:
         {:noreply,
          assign(socket, shown: filename, content: Load.content(type, version, filename))},
       else: {:noreply, socket}
  end

  def handle_event("show-document", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:artifact_pushed, work_item_id, _version_id}, socket) do
    %{work_item: work_item, current_scope: scope} = socket.assigns

    cond do
      work_item_id != work_item.public_id ->
        {:noreply, socket}

      Access.authorize(scope, :"work_item.read", work_item) == :ok ->
        {:noreply, load_history(socket)}

      # The reader can no longer read the work item: the page stops listening, and shows
      # the history it had.
      true ->
        Phoenix.PubSub.unsubscribe(Apiary.PubSub, Artifacts.topic(work_item))
        {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # True for exactly the types of `Artifacts.person_types/1`, without its 2 queries:
  # `Artifacts.type/2` returns a type for exactly the names in `Artifacts.types/1`.
  defp person_type?(scope, name),
    do: name not in Artifacts.member_types() and Artifacts.type(scope.workspace, name) != nil

  defp add_path(scope, number, artifact),
    do:
      ArtifactComponents.new_path(scope, number) <>
        "?" <> URI.encode_query(type: artifact.type, name: artifact.name)
end
