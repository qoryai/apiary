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

  alias Apiary.{Access, Artifacts, Processes}
  alias ApiaryWeb.ArtifactComponents
  alias ApiaryWeb.ArtifactLive.Load
  alias ApiaryWeb.WorkItemLive.VerifyTab

  @videos ~w(video/mp4 video/webm)

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
        <div class="q-art-main grid min-w-0 content-start gap-8">
          <%!-- A withdrawal has no file, so it has no view and no file list. --%>
          <p :if={@version.withdrawn} id="artifact-withdrawn" class="text-[13px]/5">
            {withdrew(@version.artifact, @version)}
          </p>
          <section
            :if={!@version.withdrawn}
            id="artifact-view-part"
            aria-labelledby="artifact-view-title"
            class="grid gap-3"
          >
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

          <div :if={!@version.withdrawn} class="q-art-rest grid gap-8">
            <section
              :if={@scenario}
              id="artifact-scenario"
              aria-labelledby="artifact-scenario-title"
              class="grid gap-3"
            >
              <h2 id="artifact-scenario-title" class="q-part-h">
                {VerifyTab.scenario_title(@scenario)}
              </h2>
              <ul :if={@scenario.steps != []} class="grid gap-2 text-[13px]/5">
                <li :for={{step, i} <- Enum.with_index(@scenario.steps, 1)} class="grid gap-0.5">
                  <span>{VerifyTab.step_title(i, step)}</span>
                  <span :if={step.expected} class="text-[12.5px]/5 text-muted">
                    {gettext("Expected: %{result}", result: step.expected)}
                  </span>
                </li>
              </ul>
            </section>

            <section
              id="artifact-files-part"
              aria-labelledby="artifact-files-title"
              class="grid gap-3"
            >
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
        </div>

        <aside class="grid content-start gap-8">
          <section
            :if={@scenario}
            id="artifact-queue"
            aria-labelledby="artifact-queue-title"
            class="grid gap-3"
          >
            <h2 id="artifact-queue-title" class="q-part-h">
              {gettext("Scenarios")}
              <span class="q-part-n">
                {gettext("%{number} of %{total}", number: @place, total: length(@queue))}
              </span>
            </h2>
            <ol class="grid gap-1">
              <.queue_item
                :for={entry <- @queue}
                entry={entry}
                current={entry.version.id == @version.id}
                scope={@current_scope}
                number={@number}
              />
            </ol>
          </section>

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
                  <%= if version.withdrawn do %>
                    {withdrew(@version.artifact, version)}
                  <% else %>
                    {gettext("Version %{number}", number: version.number)}
                  <% end %>
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

  attr :entry, :map, required: true, doc: "a scenario of `VerifyTab.queue/4`"
  attr :current, :boolean, required: true
  attr :scope, :any, required: true
  attr :number, :integer, required: true

  # A scenario of the queue: its first picture or the film's first frame, its title, and
  # "Demo video · 0:10" or "3 pictures". The `QueueMedia` hook fills the film's length from
  # the thumbnail's metadata, as no length is stored.
  defp queue_item(assigns) do
    %{entry: entry, scope: scope, number: number} = assigns
    pictures = if entry.kind == :pictures, do: VerifyTab.pictures(entry), else: []
    film = Enum.find(entry.version.files, &(&1.content_type in @videos))
    src = &ArtifactComponents.file_path(scope, number, entry.version.public_id, &1)

    assigns =
      assign(assigns,
        path: ArtifactComponents.version_path(scope, number, entry.version.public_id),
        film: film && src.(film),
        picture: with([{file, _step, _i} | _more] <- pictures, do: src.(file)),
        pictures: length(pictures)
      )

    ~H"""
    <li id={"artifact-queue-item-#{@entry.key}"} phx-hook="QueueMedia">
      <.link
        navigate={@path}
        aria-current={@current && "page"}
        class={["flex gap-3 rounded-field p-2", @current && "bg-base-200"]}
      >
        <video
          :if={@film}
          src={@film <> "#t=0.1"}
          muted
          playsinline
          preload="metadata"
          tabindex="-1"
          aria-hidden="true"
          class="h-14 w-24 shrink-0 rounded-field border border-base-300 bg-black object-contain"
        ></video>
        <img
          :if={@picture}
          src={@picture}
          alt=""
          loading="lazy"
          class="h-14 w-24 shrink-0 rounded-field border border-base-300 bg-base-200 object-contain"
        />
        <span
          :if={!@film and !@picture}
          class="h-14 w-24 shrink-0 rounded-field border border-base-300 bg-base-200"
        ></span>
        <span class="grid min-w-0 content-start gap-0.5">
          <span class={["text-[13px]/5", @current && "font-medium"]}>
            {VerifyTab.scenario_title(@entry)}
          </span>
          <span
            :if={@entry.kind == :film}
            data-length={gettext("Demo video · %{length}", length: "%{length}")}
            class="text-[12.5px]/5 text-muted"
          >
            {gettext("Video")}
          </span>
          <span :if={@entry.kind == :pictures} class="text-[12.5px]/5 text-muted">
            {ngettext("%{count} picture", "%{count} pictures", @pictures)}
          </span>
        </span>
      </.link>
    </li>
    """
  end

  # A withdrawal in words: "Withdrew demo video scenario-2 (version 3)", the artifact in its
  # plain form (`ArtifactComponents.plain_name/2`).
  defp withdrew(artifact, version) do
    gettext("Withdrew %{artifact} (version %{number})",
      artifact: ArtifactComponents.plain_name(artifact.type, artifact.name),
      number: version.number
    )
  end

  # The token of the frame's address (`ApiaryWeb.ArtifactMockupController.token/3`), for
  # the reader of the page, who may read the version, in the session the page was opened
  # in (its record's id, so that signing out ends the token). Signed at the minute, so
  # the page's first render and its connected one have the same token and the frame
  # loads once.
  defp frame_token(socket, session, scope, work_item, version) do
    session_id =
      with token when is_binary(token) <- session["user_token"],
           do: Apiary.Accounts.session_token_id(token)

    ApiaryWeb.ArtifactMockupController.token(
      socket,
      %{
        version: version.public_id,
        work_item: work_item.id,
        user: scope.user.id,
        session: session_id
      },
      signed_at: div(System.system_time(:second), 60) * 60
    )
  end

  @impl true
  def mount(%{"number" => number, "version_id" => version_id}, session, socket) do
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
         frame_token: mockup && frame_token(socket, session, scope, work_item, version),
         shown: nil,
         content: if(connected?(socket), do: Load.content(type, version), else: :pending),
         stage: Load.stage_name(work_item, version.stage_id),
         note: Apiary.ExternalText.present_lines(version.note),
         writes:
           Access.can?(scope, :"artifact.write", work_item) and
             person_type?(scope, version.artifact.type),
         page_title: ArtifactComponents.title(version.artifact, version)
       )
       |> load_history()
       |> load_queue()}
    else
      _not_found -> raise ApiaryWeb.NotFound
    end
  end

  # The scenarios of the verification stage that the version's film or pictures belong
  # to (`VerifyTab.queue/4`), as the Verify tab lists them for the version's take in, and
  # `scenario`, the one whose version this page shows, with its `place` in the queue. A
  # version in no scenario (a person's, an older one, a withdrawal, one of a cancelled run,
  # another type) has neither, so the page shows no queue.
  defp load_queue(socket) do
    {queue, scenario} = read_queue(socket.assigns.work_item, socket.assigns.version)

    assign(socket,
      queue: queue,
      scenario: scenario,
      place: scenario && Enum.find_index(queue, &(&1.version.id == scenario.version.id)) + 1
    )
  end

  defp read_queue(work_item, version) do
    with true <- version.artifact.type in VerifyTab.media(),
         false <- version.withdrawn,
         %{take_in: take_in} <- version.run do
      artifacts = work_item |> Artifacts.list() |> Enum.reject(&Artifacts.withdrawn?/1)

      Enum.find_value(verify_stages(work_item, version), {[], nil}, fn stage_id ->
        queue = VerifyTab.queue(work_item, artifacts, stage_id, take_in)

        with %{} = scenario <- Enum.find(queue, &(&1.version.id == version.id)),
             do: {queue, scenario}
      end)
    else
      _no_scenario -> {[], nil}
    end
  end

  # The ids of the stages of the work item's process with a `verification` output, the
  # version's own stage first.
  defp verify_stages(work_item, version) do
    stages =
      for %{"id" => id, "outputs" => outputs} <-
            Processes.version_for(work_item).document["stages"] || [],
          Enum.any?(outputs, &(&1["type"] == "verification")),
          do: id

    {own, others} = Enum.split_with(stages, &(&1 == version.stage_id))
    own ++ others
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
        {:noreply, socket |> load_history() |> load_queue()}

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
