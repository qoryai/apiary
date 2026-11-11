defmodule ApiaryWeb.ArtifactComponents do
  # The artifacts of a work item, as Qory Apiary shows them, under the feature
  # `workflow_model`: the plain list of a work item's artifacts (`list/1`), the view of a
  # version by its type's base view (`view/1`), and a version's files (`files/1`).
  #
  # Every artifact is untrusted data, written by a run or a person (`Apiary.Artifacts`). It
  # reaches a page only through these components: as text, which HEEx escapes; as the
  # Markdown of a document, rendered without raw HTML and sanitised
  # (`ApiaryWeb.ArtifactLive.Markdown`); or as a file the browser loads from the download
  # route (`ApiaryWeb.ArtifactFileController`), which serves every file as an attachment.
  # An SVG is never shown inline: it is a download.
  #
  # The module reference leaves out this module of the `workflow_model` feature.
  @moduledoc false

  use ApiaryWeb, :html

  alias Apiary.Artifacts.{Artifact, ArtifactFile, Type, Version}
  alias Apiary.Runs.Run
  alias ApiaryWeb.People
  alias ApiaryWeb.WorkItemComponents

  # The content types an image view shows inline: raster formats only.
  @inline_images ~w(image/png image/jpeg image/gif image/webp)
  @videos ~w(video/mp4 video/webm)
  @subtitles "text/vtt; charset=utf-8"

  # The most values a structured view shows; the file has the rest.
  @max_values 5000

  ## Paths

  @doc """
  version_path/3 is the address of a version's page: `scope`'s organisation and
  workspace, the work item's `number`, and the version's public id (`av_…`).
  """
  @spec version_path(Apiary.Accounts.Scope.t(), integer | String.t(), String.t()) :: String.t()
  def version_path(scope, number, version_id),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{number}/artifacts/#{version_id}"

  @doc "new_path/2 is the address of the page that adds a version by hand to work item `number`."
  @spec new_path(Apiary.Accounts.Scope.t(), integer | String.t()) :: String.t()
  def new_path(scope, number),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{number}/artifacts/new"

  @doc """
  file_path/4 is the download address of `file`, a file of the version `version_id` of
  work item `number`. Its last segment is the filename, percent-encoded.
  """
  @spec file_path(Apiary.Accounts.Scope.t(), integer | String.t(), String.t(), ArtifactFile.t()) ::
          String.t()
  def file_path(scope, number, version_id, %ArtifactFile{filename: filename}) do
    ~p"/#{scope.organisation}/#{scope.workspace}/work/#{number}/artifacts/#{version_id}/files/#{filename}"
  end

  @doc """
  mockup_path/5 is the address of the screen `screen_id` of a mockup of pages, the
  version `version_id` of work item `number`, which the version page's frame loads with
  `token` (`ApiaryWeb.ArtifactMockupController`): the screen's `<id>.html`, the address
  its pages' links resolve to.
  """
  @spec mockup_path(
          Apiary.Accounts.Scope.t(),
          integer | String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: String.t()
  def mockup_path(scope, number, version_id, token, screen_id) do
    ~p"/#{scope.organisation}/#{scope.workspace}/work/#{number}/artifacts/#{version_id}/mockup/#{token}/#{screen_id <> ".html"}"
  end

  @doc """
  size/1 is a size in binary units, 1 KiB being 1,024 bytes, as every artifact page
  shows one: "812 B", "64 KiB", "1.5 MiB", "2 GiB". A whole number has no decimal, and
  a size that rounds up to 1,024 of its unit is shown in the next one.
  """
  @spec size(non_neg_integer) :: String.t()
  def size(bytes) when is_integer(bytes) and bytes < 1024,
    do: gettext("%{number} B", number: Format.number(bytes))

  def size(bytes) when is_integer(bytes),
    do: size(bytes, [{1024, :kib}, {1_048_576, :mib}, {1_073_741_824, :gib}])

  defp size(bytes, [{unit, name} | larger]) do
    # Tenths of the unit, a half rounded up.
    tenths = div(bytes * 10 + div(unit, 2), unit)

    if tenths >= 10_240 and larger != [] do
      size(bytes, larger)
    else
      number =
        if rem(tenths, 10) == 0,
          do: Format.number(div(tenths, 10)),
          else: Format.number(tenths / 10, digits: 1)

      case name do
        :kib -> gettext("%{number} KiB", number: number)
        :mib -> gettext("%{number} MiB", number: number)
        :gib -> gettext("%{number} GiB", number: number)
      end
    end
  end

  @doc """
  documents/2 is the files of `version` that its document view shows: of a `proposal`,
  its Markdown files (`text/markdown`), so an image or `sources.json` of the version is
  never shown as a document; of any other type, every file.
  """
  @spec documents(Type.t(), Version.t()) :: [ArtifactFile.t()]
  def documents(%Type{name: "proposal"}, %Version{files: files}),
    do: Enum.filter(files, &markdown?/1)

  def documents(_type, %Version{files: files}), do: files

  defp markdown?(%ArtifactFile{content_type: type}),
    do: is_binary(type) and String.starts_with?(type, "text/markdown")

  ## The plain list

  @doc """
  list/1 is the plain list of a work item's artifacts: one row per artifact, with its
  type, its name where it is not `main`, its newest version's number, file count and
  writer, the check result where the caller passes one, and a link to the newest
  version's page.

  For the work item page (`ApiaryWeb.WorkItemLive.Show`, piece W), under the feature
  `workflow_model`:

      <ApiaryWeb.ArtifactComponents.list
        id="work-item-artifact-list"
        artifacts={Apiary.Artifacts.list(work_item)}
        scope={@current_scope}
        number={work_item.number}
        checks={%{"demo-video" => :passed}}
      />

  Attributes:

    * `id`, required: the list's DOM id; each row's id is `<id>-<artifact public id>`.
    * `artifacts`, required: `Apiary.Artifacts.list/1`, each artifact with its versions,
      newest first, their files, and their `user` and `run` where the version has one,
      as `Apiary.Artifacts.list/1` reads them.
    * `scope` and `number`: the reader's scope and the work item's number, for the links
      to each version's page and to Add a version. Without both, the rows have no links.
    * `checks`: a map from a type's name to `:passed`, `:missing` or `:not_checked`, the
      Exists check of the stage's output of that type (piece R's `Apiary.Stages.status/1`,
      `outputs`). A type with no entry shows no check.
    * `add`: whether the reader may add a version by hand (`artifact.write`); true shows
      Add a version, which needs `scope` and `number`.
    * `round`: whether a run's writer shows its round (`writer/2`); false in the Explore
      tab's fold at the Explore stage, true elsewhere.
  """
  attr :id, :string, required: true
  attr :artifacts, :list, required: true
  attr :scope, :any, default: nil
  attr :number, :any, default: nil
  attr :checks, :map, default: %{}
  attr :add, :boolean, default: false
  attr :round, :boolean, default: true

  def list(assigns) do
    assigns = assign(assigns, :links?, assigns.scope != nil and assigns.number != nil)

    ~H"""
    <div id={@id} class="q-artifact-list">
      <p :if={@artifacts == []} id={"#{@id}-empty"} class="text-[13px]/5 text-muted">
        {gettext("No artifacts yet.")}
      </p>
      <ul :if={@artifacts != []} class="grid gap-2">
        <li
          :for={artifact <- @artifacts}
          :if={newest = newest(artifact)}
          id={"#{@id}-#{artifact.public_id}"}
          class="grid gap-0.5 border-b border-base-300 pb-2 last:border-b-0"
        >
          <div class="flex flex-wrap items-baseline gap-x-2">
            <.link
              :if={@links?}
              navigate={version_path(@scope, @number, newest.public_id)}
              class="font-medium text-accent"
            >
              {title(artifact, newest)}
            </.link>
            <span :if={!@links?} class="font-medium">{title(artifact, newest)}</span>
            <.check_word :if={check = Map.get(@checks, artifact.type)} check={check} />
          </div>
          <span class="text-[12.5px]/5 text-muted">
            {ngettext("%{number} file", "%{number} files", length(newest.files),
              number: Format.number(length(newest.files))
            )} · <.made_by version={newest} scope={@scope} round={@round} />
          </span>
        </li>
      </ul>
      <.button
        :if={@add && @links?}
        id={"#{@id}-add"}
        navigate={new_path(@scope, @number)}
        variant="link"
        class="mt-2 text-[13px]"
      >
        {gettext("Add a version")}
      </.button>
    </div>
    """
  end

  attr :check, :atom, required: true

  defp check_word(%{check: :passed} = assigns) do
    ~H"""
    <span class="text-[12.5px] text-success">{gettext("Check passed")}</span>
    """
  end

  defp check_word(%{check: :missing} = assigns) do
    ~H"""
    <.state_word hot class="text-[12.5px]">{gettext("Check failed")}</.state_word>
    """
  end

  defp check_word(%{check: :not_checked} = assigns) do
    ~H"""
    <span class="text-[12.5px] text-muted">{gettext("Not checked in this version")}</span>
    """
  end

  defp check_word(assigns), do: ~H""

  defp newest(%Artifact{versions: [newest | _older]}), do: newest
  defp newest(_artifact), do: nil

  @doc """
  title/2 is an artifact's words in a list or a heading: its type, its name where it is
  not `main`, and the version's number, such as "demo-video v2" or "mockup checkout v1".
  """
  @spec title(Artifact.t(), Version.t()) :: String.t()
  def title(%Artifact{type: type, name: "main"}, %Version{number: number}),
    do: gettext("%{type} v%{number}", type: type, number: number)

  def title(%Artifact{type: type, name: name}, %Version{number: number}),
    do: gettext("%{type} %{name} v%{number}", type: type, name: name, number: number)

  @doc """
  writer/2 is who made a version, in words: a person's email address, "Former member"
  for an account that is gone; for a run, "Run" and the number of the run its claim
  registered (`Apiary.Runs.Run`), and the round where the run of the queue has one and
  `round` is true, such as "Run 14 · round 2" or "Run 14"; "A run" where no run is
  registered or read. The Explore tab passes `round` false: inside a work item, its
  runs count by attempt.
  """
  @spec writer(Version.t(), boolean) :: String.t()
  def writer(version, round \\ true)

  def writer(%Version{writer: :person, user: %Apiary.Accounts.User{} = user}, _round),
    do: People.email(user)

  def writer(%Version{writer: :person}, _round), do: People.former_member()

  def writer(%Version{writer: :run, run: %{run: %Run{number: number}, round: round}}, true)
      when is_integer(number) and is_integer(round),
      do: gettext("Run %{run} · round %{round}", run: number, round: Format.number(round))

  def writer(%Version{writer: :run, run: %{run: %Run{number: number}}}, _round)
      when is_integer(number),
      do: gettext("Run %{run}", run: number)

  def writer(%Version{writer: :run}, _round), do: gettext("A run")

  @doc """
  made_by/1 is who made a version (`writer/2`, with its round where `round` is true); for
  a run, a link to the run's page where `scope` is given, a run is registered, and the
  reader may read the workspace's runs (`run.read`, `Apiary.Access.can?/3`); else its
  words.
  """
  attr :version, Version, required: true
  attr :scope, :any, default: nil
  attr :round, :boolean, default: true

  def made_by(
        %{version: %Version{writer: :run, run: %{run: %Run{number: number}}}, scope: %{}} =
          assigns
      )
      when is_integer(number) do
    assigns =
      assign(
        assigns,
        :link?,
        # A work item moves with its artifacts and its runs stay: a number in this address
        # would be another run's, of the workspace the reader is in.
        assigns.version.run.workspace_id == assigns.scope.workspace.id and
          Apiary.Access.can?(assigns.scope, :"run.read", assigns.scope.workspace)
      )

    ~H"""
    <span :if={!@link?}>{writer(@version, @round)}</span>
    <.link
      :if={@link?}
      navigate={~p"/#{@scope.organisation}/#{@scope.workspace}/runs/#{@version.run.run}"}
      class="text-accent"
    >
      {writer(@version, @round)}
    </.link>
    """
  end

  def made_by(assigns), do: ~H"{writer(@version, @round)}"

  ## A version's files

  @doc """
  files/1 is a version's files, each with its size and a link that downloads it. `path`
  is a function from a file to its download address (`file_path/4`).
  """
  attr :id, :string, required: true
  attr :files, :list, required: true
  attr :path, :any, required: true

  def files(assigns) do
    ~H"""
    <ul id={@id} class="grid gap-1.5">
      <li
        :for={{file, index} <- Enum.with_index(@files)}
        id={"#{@id}-#{index}"}
        class="flex flex-wrap items-baseline gap-x-2"
      >
        <a href={@path.(file)} download={file.filename} class="font-medium text-accent break-all">
          {file.filename}
        </a>
        <span class="text-[12.5px] text-muted tabular-nums">{size(file.size)}</span>
      </li>
    </ul>
    """
  end

  ## The views

  @doc """
  view/1 is a version shown by its type's base view:

    * document: the Markdown file `shown` of the version's documents (`documents/2`),
      the first unless given, rendered (`ApiaryWeb.ArtifactLive.Markdown`), with Mermaid
      diagrams drawn in the browser (`assets/js/hooks/mermaid.js`); with more than one
      document, a list of them above it, each other document a button that sends
      `show-document` with its filename;
    * image: PNG, JPEG, GIF and WebP inline from the download address; an SVG as a
      download only;
    * video: each MP4 or WebM file with the controls, the version's WebVTT files as its
      captions;
    * file: the downloads;
    * mockup, a version of `mockup` a run pushed with a `screens.json`: the start screen
      in a frame, `<iframe sandbox>` with no token, so its page runs no script, has an
      opaque origin and sends no form, and beside it the list of the screens, in the
      order of `screens.json`, each title a link that opens its screen in the frame, by
      the frame's name, with no script; the start screen has "Start screen" after its
      title. `mockup` is the screens (`ApiaryWeb.ArtifactLive.Load.mockup/2`), and
      `screen_path` a function from a screen's id to its address (`mockup_path/5`);
    * structured: the JSON document as a table, nested objects and lists as nested
      rows, every value as text; a `change`'s `url` is a link where it is `http` or `https`,
      and a `questions` document's `context` is Markdown, as on Explore's tab.

  `content` is what the page read of the files, a map from filename: for a document,
  `{:markdown, rendered}` (`ApiaryWeb.ArtifactLive.Markdown.render/1`) or `:too_large`;
  for a structured view, `{:json, value}` or `:unreadable`. `:pending`, before the page
  has read them, shows the document and structured views empty. `path` is a function from a file to its download address. `script` is
  the address of the Mermaid bundle.
  """
  attr :id, :string, required: true
  attr :type, Type, required: true
  attr :version, Version, required: true
  attr :content, :any, default: %{}
  attr :shown, :string, default: nil
  attr :path, :any, required: true
  attr :script, :string, default: nil
  attr :mockup, :map, default: nil
  attr :screen_path, :any, default: nil

  # Before the page has read the files, the view is an empty block of another id: the
  # document's block is left alone by later patches (`phx-update="ignore"`, so the
  # Mermaid hook keeps its drawings), and a browser would keep the empty block's children
  # were its id the same.
  def view(%{type: %Type{base_view: :document}, content: :pending} = assigns),
    do: ~H|<div id={"#{@id}-pending"} class="min-h-6"></div>|

  def view(%{type: %Type{base_view: :document}} = assigns) do
    files = documents(assigns.type, assigns.version)
    index = Enum.find_index(files, &(&1.filename == assigns.shown)) || 0
    assigns = assign(assigns, files: files, index: index, file: Enum.at(files, index))

    ~H"""
    <div class="grid gap-4">
      <nav
        :if={length(@files) > 1}
        id={"#{@id}-documents"}
        aria-label={gettext("Documents of this version")}
      >
        <ul class="flex flex-wrap gap-x-4 gap-y-1 text-[13px]/5">
          <li :for={{file, at} <- Enum.with_index(@files)}>
            <span :if={at == @index} class="font-medium break-all" aria-current="true">
              {file.filename}
            </span>
            <.button
              :if={at != @index}
              type="button"
              variant="link"
              phx-click="show-document"
              phx-value-file={file.filename}
              class="break-all"
            >
              {file.filename}
            </.button>
          </li>
        </ul>
      </nav>
      <div
        :if={@file}
        id={"#{@id}-#{@index}"}
        class="grid gap-6"
        phx-hook="Mermaid"
        phx-update="ignore"
        data-script={@script}
        data-alt={gettext("Diagram")}
        data-source={gettext("Diagram source")}
        data-not-drawn={gettext("Qory Apiary does not draw this diagram, so it is shown as written.")}
        data-failed={gettext("This diagram has an error, so it is shown as written.")}
      >
        <section class="grid gap-2" aria-label={@file.filename}>
          <.document
            id={"#{@id}-#{@index}"}
            text={content(@content, @file)}
            file={@file}
            path={@path}
            proposal={@type.name == "proposal"}
          />
        </section>
      </div>
    </div>
    """
  end

  def view(%{type: %Type{base_view: :mockup}, mockup: %{start: _start}} = assigns) do
    assigns = assign(assigns, :frame, "#{assigns.id}-frame")

    ~H"""
    <div id={@id} class="grid gap-6 lg:grid-cols-[minmax(0,1fr)_minmax(10rem,14rem)]">
      <iframe
        id={@frame}
        name={@frame}
        sandbox
        src={@screen_path.(@mockup.start)}
        title={gettext("Mockup screen")}
        phx-update="ignore"
        class="h-[70vh] w-full rounded-field border border-base-300 bg-white"
      ></iframe>
      <nav
        id={"#{@id}-screens"}
        aria-labelledby={"#{@id}-screens-title"}
        class="grid content-start gap-3"
      >
        <h3 id={"#{@id}-screens-title"} class="q-part-h">
          {gettext("Screens")}
          <span class="q-part-n">{ApiaryWeb.Format.number(length(@mockup.screens))}</span>
        </h3>
        <ul class="grid gap-1.5 text-[13px]/5">
          <li :for={screen <- @mockup.screens} id={"#{@id}-screen-#{screen.id}"}>
            <a href={@screen_path.(screen.id)} target={@frame} class="text-accent break-words">
              {screen.title}
            </a>
            <span :if={screen.id == @mockup.start} class="text-[12.5px] text-muted">
              {gettext("Start screen")}
            </span>
          </li>
        </ul>
      </nav>
    </div>
    """
  end

  def view(%{type: %Type{base_view: :image}} = assigns) do
    ~H"""
    <div id={@id} class="grid gap-6">
      <figure :for={file <- @version.files} class="grid gap-2">
        <img
          :if={file.content_type in inline_images()}
          src={@path.(file)}
          alt={gettext("Image: %{filename}", filename: file.filename)}
          class="max-h-[70vh] max-w-full rounded-field border border-base-300 object-contain object-left"
          loading="lazy"
        />
        <p :if={file.content_type not in inline_images()} class="text-[13px]/5 text-muted">
          {gettext("An SVG image is offered as a download only, so no script in it runs here.")}
        </p>
        <figcaption class="flex flex-wrap items-baseline gap-x-2 text-[12.5px]">
          <a href={@path.(file)} download={file.filename} class="text-accent break-all">
            {file.filename}
          </a>
          <span class="text-muted tabular-nums">{size(file.size)}</span>
        </figcaption>
      </figure>
    </div>
    """
  end

  def view(%{type: %Type{base_view: :video}} = assigns) do
    assigns =
      assign(assigns,
        videos: Enum.filter(assigns.version.files, &(&1.content_type in @videos)),
        subtitles: Enum.filter(assigns.version.files, &(&1.content_type == @subtitles))
      )

    ~H"""
    <div id={@id} class="grid gap-6">
      <figure :for={file <- @videos} class="grid gap-2">
        <video
          controls
          preload="metadata"
          class="max-h-[70vh] max-w-full rounded-field bg-black"
          aria-label={file.filename}
        >
          <source src={@path.(file)} type={file.content_type} />
          <track
            :for={{track, index} <- Enum.with_index(@subtitles)}
            kind="captions"
            label={track.filename}
            src={@path.(track)}
            default={index == 0}
          />
        </video>
        <figcaption class="text-[12.5px] text-muted break-all">{file.filename}</figcaption>
      </figure>
    </div>
    """
  end

  def view(%{type: %Type{base_view: :file}} = assigns) do
    ~H"""
    <div id={@id}>
      <.files id={"#{@id}-files"} files={@version.files} path={@path} />
    </div>
    """
  end

  def view(%{type: %Type{base_view: :structured}} = assigns) do
    ~H"""
    <div id={@id} class="grid gap-4">
      <.structured
        :for={file <- @version.files}
        content={content(@content, file)}
        view={@type.view}
      />
    </div>
    """
  end

  defp inline_images, do: @inline_images

  defp content(:pending, _file), do: :pending
  defp content(content, file), do: Map.get(content, file.filename)

  attr :id, :string, required: true
  attr :text, :any, required: true
  attr :file, ArtifactFile, required: true
  attr :path, :any, required: true
  attr :proposal, :boolean, required: true

  # A proposal's Sources are a closed fold under its text, as on Explore's tab. Another
  # type's document shows a `## Sources` heading as any other heading.
  defp document(%{text: {:markdown, rendered}} = assigns) do
    {rendered, sources, count} =
      if assigns.proposal,
        do: WorkItemComponents.split_sources(rendered),
        else: {rendered, nil, 0}

    assigns = assign(assigns, rendered: rendered, sources: sources, count: count)

    ~H"""
    <%= case @rendered do %>
      <% {:html, html} -> %>
        <div class="q-ticket-formatted">{html}</div>
        <WorkItemComponents.sources_fold
          :if={@sources}
          id={"#{@id}-sources"}
          sources={@sources}
          count={@count}
        />
      <% {:as_written, written} -> %>
        <div class="grid gap-2">
          <p class="text-[13px]/5 text-muted">{gettext("Shown as written.")}</p>
          <div class="q-ticket-written" phx-no-format>{written}</div>
        </div>
    <% end %>
    """
  end

  defp document(assigns) do
    ~H"""
    <p class="text-[13px]/5 text-muted">
      {gettext("This document is too large to show here. Download it to read it.")}
      <a href={@path.(@file)} download={@file.filename} class="text-accent">
        {gettext("Download %{filename}", filename: @file.filename)}
      </a>
    </p>
    """
  end

  attr :content, :any, required: true
  attr :view, :atom, default: nil

  defp structured(%{content: :pending} = assigns), do: ~H|<div class="min-h-6"></div>|

  defp structured(%{content: {:json, value}} = assigns) do
    {rows, _shown} = rows(value, assigns.view, 0, @max_values)
    assigns = assign(assigns, rows: rows, cut: values(value, @max_values + 1) > @max_values)

    ~H"""
    <div class="grid gap-2">
      <.value_table rows={@rows} />
      <p :if={@cut} class="text-[13px]/5 text-muted">
        {gettext("Shown: the first %{number} values. Download the file for the rest.",
          number: Format.number(max_values())
        )}
      </p>
    </div>
    """
  end

  defp structured(assigns) do
    ~H"""
    <p class="text-[13px]/5 text-muted">
      {gettext("This file cannot be shown here. Download it to read it.")}
    </p>
    """
  end

  defp max_values, do: @max_values

  attr :rows, :list, required: true

  defp value_table(assigns) do
    ~H"""
    <table class="q-artifact-table w-full border-collapse text-[13px]/5">
      <tbody>
        <tr :for={row <- @rows} class="border-b border-base-300 align-top last:border-b-0">
          <th scope="row" class="w-[1%] whitespace-nowrap py-1.5 pr-4 text-left font-medium">
            {row.key}
          </th>
          <td class="py-1.5 break-words">
            <%= case row.value do %>
              <% {:rows, []} -> %>
                <span class="text-muted">{gettext("(empty)")}</span>
              <% {:rows, nested} -> %>
                <.value_table rows={nested} />
              <% {:link, url} -> %>
                <.external_link href={url}>{url}</.external_link>
              <% {:markdown, text} -> %>
                <WorkItemComponents.run_text value={%{text: text}} key={:text} />
              <% {:null} -> %>
                <span class="text-muted">{gettext("(none)")}</span>
              <% {:text, text} -> %>
                <span class="whitespace-pre-wrap">{text}</span>
            <% end %>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  # The rows of a JSON value, and how many values they show, at most `left` more: an
  # object's members by key, a list's items by position from 1, nested values as nested
  # rows. A scalar at the top is one row with no key.
  defp rows(value, view, used, left) when is_map(value) do
    value
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({[], used}, fn {key, member}, {acc, used} ->
      if used >= left do
        {:halt, {acc, used}}
      else
        {cell, used} = cell(member, shown_as(view, key), view, used + 1, left)
        {:cont, {[%{key: Apiary.ExternalText.lines(key), value: cell} | acc], used}}
      end
    end)
    |> then(fn {acc, used} -> {Enum.reverse(acc), used} end)
  end

  defp rows(value, view, used, left) when is_list(value) do
    value
    |> Enum.with_index(1)
    |> Enum.reduce_while({[], used}, fn {item, index}, {acc, used} ->
      if used >= left do
        {:halt, {acc, used}}
      else
        {cell, used} = cell(item, :text, view, used + 1, left)
        {:cont, {[%{key: Integer.to_string(index), value: cell} | acc], used}}
      end
    end)
    |> then(fn {acc, used} -> {Enum.reverse(acc), used} end)
  end

  defp rows(value, _view, used, _left) do
    {cell, used} = cell(value, :text, nil, used + 1, used + 1)
    {[%{key: "", value: cell}], used}
  end

  defp shown_as(:change, "url"), do: :url
  defp shown_as(:questions, "context"), do: :markdown
  defp shown_as(_view, _key), do: :text

  # How many values `rows/4` would show of a JSON value with no bound, counted up to
  # `limit`: each member or item, nested ones too, and a scalar at the top as one.
  defp values(value, limit) when is_map(value) or is_list(value), do: count(value, 0, limit)
  defp values(_scalar, _limit), do: 1

  defp count(value, counted, limit) when is_map(value),
    do: count(Map.values(value), counted, limit)

  defp count(value, counted, limit) when is_list(value) do
    Enum.reduce_while(value, counted, fn item, counted ->
      if counted >= limit, do: {:halt, counted}, else: {:cont, count(item, counted + 1, limit)}
    end)
  end

  defp count(_scalar, counted, _limit), do: counted

  defp cell(value, _shown_as, view, used, left) when is_map(value) or is_list(value) do
    {nested, used} = rows(value, view, used, left)
    {{:rows, nested}, used}
  end

  defp cell(nil, _shown_as, _view, used, _left), do: {{:null}, used}

  defp cell(value, :markdown, _view, used, _left) when is_binary(value),
    do: {{:markdown, value}, used}

  defp cell(value, :url, _view, used, _left) when is_binary(value) do
    if web_url?(value),
      do: {{:link, value}, used},
      else: {{:text, Apiary.ExternalText.lines(value)}, used}
  end

  defp cell(value, _shown_as, _view, used, _left) when is_binary(value),
    do: {{:text, Apiary.ExternalText.lines(value)}, used}

  defp cell(value, _shown_as, _view, used, _left) when is_boolean(value),
    do: {{:text, if(value, do: "true", else: "false")}, used}

  defp cell(value, _shown_as, _view, used, _left), do: {{:text, to_string(value)}, used}

  # An absolute `http` or `https` URL with a host and no user name or password.
  defp web_url?(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil}} when is_binary(scheme) ->
        String.downcase(scheme) in ["http", "https"] and is_binary(host) and host != ""

      _not ->
        false
    end
  end
end
