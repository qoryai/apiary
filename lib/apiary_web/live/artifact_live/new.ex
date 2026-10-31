defmodule ApiaryWeb.ArtifactLive.New do
  # Add a version by hand, `/:org/:workspace/work/:number/artifacts/new`, under the
  # feature `workflow_model`, for a member who may `artifact.write` the work item: a type
  # of the workspace's (`Apiary.Artifacts.types/1`), a name, `main` unless changed, the
  # files, uploaded with LiveView's uploads, and an optional note. `?type=` and `?name=`
  # fill the type and the name, as Add a version on a version's page does.
  #
  # The upload is set from the chosen type: at most its most files, each of at most its
  # size limit, and set again when the reader chooses another type while no file is
  # added (LiveView keeps an upload's settings while it has files). The chosen type's most
  # files and size limit, for all the files together, are checked as the reader changes
  # the form, before the push, and again by the push. A file starts to upload only while
  # all the files fit the chosen type (`ApiaryWeb.ArtifactLive.UploadWriter`), so one Add
  # version puts at most the type's size limit in the temporary folder.
  # Add version pushes the version as the reader (`Apiary.Artifacts.push/5`, `{:person,
  # scope}`), made in the work item's current stage, and goes to the new version's page.
  # Each refusal of the push is one line that says what to change, under the field it is
  # about; the uploaded files stay, so the reader changes only what the line says.
  #
  # The module reference leaves out this module of the `workflow_model` feature.
  @moduledoc false

  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :workflow_model
  on_mount {ApiaryWeb.Access, :"work_item.read"}
  on_mount {ApiaryWeb.Access, :"artifact.write"}

  alias Apiary.{Access, Artifacts}
  alias Apiary.Artifacts.Type
  alias ApiaryWeb.ArtifactComponents
  alias ApiaryWeb.ArtifactLive.{Load, UploadWriter}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:work_items}
      width="read"
    >
      <:crumb navigate={~p"/#{@current_scope.organisation}/#{@current_scope.workspace}/work"}>
        {gettext("Work items")}
      </:crumb>
      <:crumb navigate={work_item_path(@current_scope, @number)}>
        {gettext("Work item #%{number}", number: @number)}
      </:crumb>
      <:crumb>{gettext("Add a version")}</:crumb>

      <.page_form id="artifact-new" title={gettext("Add a version")}>
        <:description>
          {gettext("Store files on work item #%{number} as a new version of one of its artifacts.",
            number: @number
          )}
        </:description>
        <.form
          for={@form}
          id="artifact-form"
          phx-change="validate"
          phx-submit="save"
          class="q-form"
          novalidate
        >
          <.input
            field={@form[:type]}
            type="select"
            label={gettext("Type")}
            options={Enum.map(@types, &{&1.name, &1.name})}
            hint={type_hint(@type)}
          />
          <.input
            field={@form[:name]}
            type="text"
            label={gettext("Name")}
            hint={
              gettext(
                "main, unless this work item keeps two artifacts of this type, such as cart and receipt."
              )
            }
            autocomplete="off"
            spellcheck="false"
          />

          <fieldset class="fieldset" id="artifact-files-field">
            <label for={@uploads.files.ref} class="text-[13px]/[18px] font-medium">{gettext("Files")}</label>
            <.live_file_input upload={@uploads.files} class="file-input file-input-sm w-full" />
            <ul
              :if={@uploads.files.entries != []}
              id="artifact-uploads"
              class="grid gap-1.5 text-[13px]/5"
            >
              <li
                :for={entry <- @uploads.files.entries}
                id={"artifact-upload-#{entry.ref}"}
                class="flex flex-wrap items-baseline gap-x-2"
              >
                <span class="font-medium break-all">{entry.client_name}</span>
                <span class="text-muted tabular-nums">{Format.bytes(entry.client_size)}</span>
                <span :if={entry.progress < 100} class="text-muted tabular-nums">
                  {gettext("%{percent} % uploaded", percent: entry.progress)}
                </span>
                <.button
                  type="button"
                  variant="link"
                  phx-click="remove"
                  phx-value-ref={entry.ref}
                  aria-label={gettext("Remove %{filename}", filename: entry.client_name)}
                >
                  {gettext("Remove")}
                </.button>
              </li>
            </ul>
            <p
              :for={{message, index} <- Enum.with_index(@file_errors)}
              id={"artifact-files-error-#{index}"}
              class="flex items-center gap-1.5 text-[12.5px]/[18px] text-error"
            >
              <.icon name="hero-exclamation-circle-micro" class="size-4 flex-none" />
              {message}
            </p>
          </fieldset>

          <.input
            field={@form[:note]}
            type="textarea"
            label={gettext("Note")}
            optional
            rows="3"
            hint={gettext("What changed in this version, for the people and runs that read it.")}
          />

          <p :if={@error} id="artifact-error" class="text-[13px]/5 text-error" role="alert">
            {@error}
          </p>

          <.page_form_foot cancel={work_item_path(@current_scope, @number)}>
            <.button
              type="submit"
              variant="primary"
              loading_text={gettext("Adding")}
              disabled={@uploads.files.entries == [] or @file_errors != []}
            >
              {gettext("Add version")}
            </.button>
          </.page_form_foot>
        </.form>
      </.page_form>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"number" => number} = params, _session, socket) do
    scope = socket.assigns.current_scope

    with %{} = work_item <- Load.work_item(scope, number),
         true <- Access.can?(scope, :"artifact.write", work_item) do
      types = Artifacts.types(scope.workspace)
      type = Enum.find(types, &(&1.name == params["type"])) || hd(types)
      name = if Type.name?(params["name"]), do: params["name"], else: "main"

      {:ok,
       socket
       |> assign(
         work_item: work_item,
         number: work_item.number,
         types: types,
         type: type,
         error: nil,
         file_errors: [],
         page_title: gettext("Add a version")
       )
       |> assign_form(%{"type" => type.name, "name" => name, "note" => ""}, [])
       |> allow_files(type)}
    else
      _not -> raise ApiaryWeb.NotFound
    end
  end

  defp assign_form(socket, params, errors),
    do: assign(socket, :form, to_form(params, as: :artifact, errors: errors))

  # The upload, set from `type`; `upload_type` is the type it was set from.
  defp allow_files(socket, %Type{} = type) do
    socket
    |> assign(:upload_type, type.name)
    |> allow_upload(:files,
      accept: :any,
      max_entries: type.max_files,
      max_file_size: type.size_limit,
      chunk_size: 256_000,
      writer: &writer/3
    )
  end

  # The upload set again from the chosen type, where it has no file.
  defp follow_type(socket) do
    %{type: type, upload_type: upload_type, uploads: uploads} = socket.assigns

    if type.name != upload_type and uploads.files.entries == [],
      do: allow_files(socket, type),
      else: socket
  end

  # LiveView calls it, in this page's process, as a file starts to upload.
  defp writer(_name, _entry, socket), do: {UploadWriter, fits: fits?(socket.assigns)}

  # Whether the files added come to at most the chosen type's most files and size limit.
  defp fits?(%{type: type, uploads: %{files: %{entries: entries}}, file_errors: []}) do
    length(entries) <= type.max_files and
      entries |> Enum.map(& &1.client_size) |> Enum.sum() <= type.size_limit
  end

  defp fits?(_assigns), do: false

  @impl true
  def handle_event("validate", %{"artifact" => params}, socket) do
    type = Enum.find(socket.assigns.types, &(&1.name == params["type"])) || socket.assigns.type

    {:noreply,
     socket
     |> assign(type: type, error: nil)
     |> follow_type()
     |> assign_form(params, [])
     |> check_files()}
  end

  def handle_event("remove", %{"ref" => ref}, socket),
    do: {:noreply, socket |> cancel_upload(:files, ref) |> follow_type() |> check_files()}

  def handle_event("save", %{"artifact" => params}, socket) do
    socket = socket |> assign(:error, nil) |> assign_form(params, []) |> check_files()

    if socket.assigns.file_errors == [] do
      push(socket, params)
    else
      {:noreply, socket}
    end
  end

  # Push with the uploaded files where LiveView keeps them; the entries stay until the
  # push succeeds, so a refused push keeps them for the next try.
  defp push(socket, params) do
    scope = socket.assigns.current_scope
    work_item = socket.assigns.work_item

    files =
      consume_uploaded_entries(socket, :files, fn %{path: path}, entry ->
        {:postpone, %{filename: entry.client_name, content_type: entry.client_type, path: path}}
      end)

    result =
      Artifacts.push({:person, scope}, work_item, params["type"], files,
        name: blank_to_main(params["name"]),
        stage_id: Map.get(work_item, :stage_id),
        note: params["note"]
      )

    case result do
      {:ok, version} ->
        consume_uploaded_entries(socket, :files, fn _meta, _entry -> {:ok, :pushed} end)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Version %{number} added.", number: version.number))
         |> push_navigate(
           to: ArtifactComponents.version_path(scope, socket.assigns.number, version.public_id)
         )}

      {:error, refusal} ->
        {:noreply, refused(socket, params, refusal, files)}
    end
  end

  defp blank_to_main(name) when is_binary(name) do
    case String.trim(name) do
      "" -> "main"
      trimmed -> trimmed
    end
  end

  defp blank_to_main(_name), do: "main"

  # The chosen type's most files and size limit, against the files uploaded so far.
  defp check_files(socket) do
    type = socket.assigns.type
    entries = socket.assigns.uploads.files.entries
    size = entries |> Enum.map(& &1.client_size) |> Enum.sum()

    errors =
      Enum.reject(
        [
          length(entries) > type.max_files && too_many(type),
          size > type.size_limit && too_large(type)
        ],
        &(&1 == false)
      )

    errors = errors ++ upload_errors(socket, type, errors)
    assign(socket, :file_errors, Enum.uniq(errors))
  end

  # LiveView's refusals of the files, by the type the upload was set from. Where the
  # reader chose another type since, and the files fit it, the line asks for the files
  # again, so LiveView checks them against the chosen type.
  defp upload_errors(socket, type, type_errors) do
    uploads = socket.assigns.uploads.files

    refused =
      upload_errors(uploads) ++ Enum.flat_map(uploads.entries, &upload_errors(uploads, &1))

    cond do
      refused == [] ->
        []

      socket.assigns.upload_type == type.name ->
        Enum.map(refused, &upload_error(&1, type))

      type_errors == [] ->
        [
          gettext("Remove the files and add them again, so they are checked against %{type}.",
            type: type.name
          )
        ]

      true ->
        []
    end
  end

  defp upload_error(:too_large, type), do: too_large(type)
  defp upload_error(:too_many_files, type), do: too_many(type)
  defp upload_error(_other, _type), do: gettext("Upload the files again.")

  defp too_many(type) do
    ngettext(
      "Remove files: a version of %{type} has at most %{number} file.",
      "Remove files: a version of %{type} has at most %{number} files.",
      type.max_files,
      type: type.name,
      number: Format.number(type.max_files)
    )
  end

  defp too_large(type) do
    gettext("Remove or shrink files: the files of a version of %{type} come to at most %{size}.",
      type: type.name,
      size: Format.bytes(type.size_limit)
    )
  end

  # The line of a refused push, under the field it is about.
  defp refused(socket, params, refusal, files) do
    type = Enum.find(socket.assigns.types, &(&1.name == params["type"])) || socket.assigns.type
    filename = fn index -> files |> Enum.at(index, %{}) |> Map.get(:filename, "") end

    case refusal do
      {:invalid, :name} ->
        assign_form(socket, params, name: {name_rule(), []})

      {:invalid, :note} ->
        assign_form(socket, params, note: {note_rule(), []})

      {kind, _name} when kind in [:unknown_type, :not_writable] ->
        assign_form(socket, params, type: {gettext("Choose a type from the list."), []})

      {:invalid, :type} ->
        assign_form(socket, params, type: {gettext("Choose a type from the list."), []})

      {:invalid, :no_files} ->
        assign(socket, :file_errors, [gettext("Add at least one file.")])

      {:invalid, :no_video} ->
        assign(socket, :file_errors, [
          gettext("Add an MP4 or WebM video: a WebVTT file goes with a video.")
        ])

      {:too_many_files, _max} ->
        assign(socket, :file_errors, [too_many(type)])

      {:too_large, _limit} ->
        assign(socket, :file_errors, [too_large(type)])

      {:invalid, {reason, index}} ->
        assign(socket, :file_errors, [file_line(reason, filename.(index), type)])

      :store_unavailable ->
        assign(
          socket,
          :error,
          gettext(
            "Qory Apiary could not store the files. Try again; if it fails again, tell the instance admin."
          )
        )

      _gone ->
        assign(
          socket,
          :error,
          gettext("You can no longer add a version to this work item. Open the work item again.")
        )
    end
  end

  defp file_line(:filename, filename, _type),
    do:
      gettext(
        "Rename %{filename}: a filename has at most 255 bytes, and no slash, backslash or control character.",
        filename: filename
      )

  defp file_line(:duplicate_filename, filename, _type),
    do:
      gettext(
        "Rename one of the files called %{filename}: the files of a version have different names.",
        filename: filename
      )

  defp file_line(:extension, filename, _type),
    do:
      gettext("Rename %{filename} to end in .md: a document is a Markdown file.",
        filename: filename
      )

  defp file_line(:schema, filename, type),
    do:
      gettext("Fix %{filename}: it does not match the JSON Schema of %{type}.",
        filename: filename,
        type: type.name
      )

  defp file_line(:format, filename, %Type{base_view: base_view}),
    do: format_line(base_view, filename)

  defp file_line(_unreadable, filename, _type),
    do: gettext("Upload %{filename} again.", filename: filename)

  defp format_line(:document, filename),
    do: gettext("Replace %{filename} with a Markdown file of UTF-8 text.", filename: filename)

  defp format_line(:image, filename),
    do:
      gettext("Replace %{filename} with a PNG, JPEG, GIF, WebP or SVG image.", filename: filename)

  defp format_line(:video, filename),
    do:
      gettext("Replace %{filename} with an MP4 or WebM video, or a WebVTT file (.vtt).",
        filename: filename
      )

  defp format_line(_structured, filename),
    do: gettext("Replace %{filename} with one JSON document.", filename: filename)

  defp name_rule,
    do:
      gettext(
        "Use lowercase letters and digits, in groups joined by single hyphens, at most 64 characters."
      )

  defp note_rule,
    do: gettext("Shorten the note to 4,000 characters, and remove any control characters.")

  defp type_hint(%Type{} = type) do
    gettext("%{view}. At most %{files}, %{size} in all.",
      view: Load.base_view(type.base_view),
      files:
        ngettext("%{number} file", "%{number} files", type.max_files,
          number: Format.number(type.max_files)
        ),
      size: Format.bytes(type.size_limit)
    )
  end

  defp work_item_path(scope, number),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/work/#{number}"
end
