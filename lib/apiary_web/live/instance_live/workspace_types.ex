defmodule ApiaryWeb.InstanceLive.WorkspaceTypes do
  @moduledoc """
  Instance settings › Workspace types, with the feature `workflow_model`, for the
  instance's admins (`Apiary.Processes.TypeTemplates.may_edit?/1`); anyone else is
  answered as a path that does not exist. A page of the Instance level: its gate asks the
  instance whether the feature is on (`use ApiaryWeb.Features, instance: :workflow_model`).

  `/instance/workspace-types` lists each workspace type with its newest version.
  `/instance/workspace-types/:type` edits one type's default process, the stages a new
  workspace of that type starts with (`Apiary.Processes.TypeTemplates`), on the Stages
  page's canvas and inspector. Save makes a new version at once, with its author;
  there are no trials and no work items. A stage's workflow is a text field that
  suggests the Qory harness's workflows (`Apiary.Processes.TypeTemplates.workflows/0`)
  and takes any name the schema's pattern allows; each workflow has a check when the Qory
  harness lists it, else a cross. A gate is none or any member, since a type has no
  members to name. The history lists every version with
  its changes against the version it started from. A type key no type has is a path that
  does not exist.
  """
  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, instance: :workflow_model

  alias Apiary.Processes
  alias Apiary.Processes.{TypeTemplate, TypeTemplates}
  alias ApiaryWeb.{People, SettingsComponents}
  alias ApiaryWeb.StagesLive.{Canvas, Editor, Inspector, Words}

  @edits Editor.events()

  @impl true
  def mount(_params, _session, socket) do
    if TypeTemplates.may_edit?(socket.assigns.current_scope),
      do: {:ok, socket},
      else: raise(ApiaryWeb.NotFound)
  end

  @impl true
  def handle_params(params, _uri, socket),
    do: {:noreply, apply_action(socket, socket.assigns.live_action, params)}

  defp apply_action(socket, :index, _params) do
    assign(socket,
      page_title: title(socket, []),
      types: TypeTemplates.list()
    )
  end

  defp apply_action(socket, :edit, %{"type" => type}) do
    case Enum.find(TypeTemplates.list(), &(&1.type == type)) do
      nil ->
        raise ApiaryWeb.NotFound

      entry ->
        socket
        |> assign(
          page_title: title(socket, [entry.name]),
          type: type,
          name: entry.name,
          declared: TypeTemplates.workflows(),
          types: TypeTemplates.artifact_types(),
          notice: nil,
          save_errors: [],
          save_note: nil,
          stage_errors: %{},
          rounds_errors: %{},
          workflow_errors: %{}
        )
        |> load(entry.newest)
    end
  end

  defp title(socket, parts),
    do:
      SettingsComponents.page_title(
        socket.assigns.current_scope,
        :instance,
        [gettext("Workspace types") | parts]
      )

  # The editor on `version`, the newest: its document as the draft, its first stage
  # selected.
  defp load(socket, %TypeTemplate{} = version) do
    socket
    |> assign(
      base: version,
      draft: version.document,
      selected: Editor.first_id(version.document),
      versions: TypeTemplates.versions(socket.assigns.type),
      stage_errors: %{},
      save_note: nil
    )
    |> refresh()
  end

  # The draft checked against the Qory harness's workflows and the standard artifact
  # types, and the canvas's view pushed.
  defp refresh(socket) do
    %{draft: draft, declared: declared, types: types} = socket.assigns

    problems =
      draft
      |> Processes.placement_check(declared, types)
      |> Enum.reject(&match?({:output_not_written, _id, _type}, &1))

    socket = assign(socket, problems: problems)
    push_event(socket, "stages:view", view(socket.assigns))
  end

  defp view(assigns),
    do:
      Canvas.view(assigns.draft, :edit,
        selected: assigns.selected,
        alerts: canvas_alerts(assigns),
        marks: assigns.declared
      )

  defp canvas_alerts(assigns) do
    Map.new(assigns.draft["stages"], fn stage ->
      {stage["id"],
       Inspector.stage_alerts(assigns.problems, stage, :qory) ++
         Map.get(assigns.stage_errors, stage["id"], [])}
    end)
  end

  @impl true
  def handle_event("select", %{"id" => id}, %{assigns: %{live_action: :edit}} = socket)
      when is_binary(id) do
    if Processes.stage(socket.assigns.draft, id),
      do:
        {:noreply,
         socket |> assign(selected: id, rounds_errors: %{}, workflow_errors: %{}) |> refresh()},
      else: {:noreply, socket}
  end

  def handle_event(event, params, %{assigns: %{live_action: :edit}} = socket)
      when event in @edits,
      do: {:noreply, Editor.edit_event(event, params, socket, &refresh/1)}

  def handle_event("discard", _params, %{assigns: %{live_action: :edit}} = socket),
    do: {:noreply, socket |> fresh() |> load(socket.assigns.base)}

  def handle_event("save", _params, %{assigns: %{live_action: :edit}} = socket) do
    socket = fresh(socket)
    %{current_scope: scope, type: type, draft: draft, base: base} = socket.assigns

    case TypeTemplates.save(scope, type, draft, based_on: base.number) do
      {:ok, version} ->
        notice =
          gettext("Saved as version %{number}. New workspaces of this type start with it.",
            number: version.number
          )

        {:noreply, socket |> load(version) |> assign(notice: notice)}

      {:error, :stale} ->
        newest = TypeTemplates.newest(type)

        {:noreply,
         socket
         |> assign(save_errors: [stale(newest.number)], versions: TypeTemplates.versions(type))
         |> refresh()}

      {:error, errors} when is_list(errors) ->
        {:noreply, Editor.refused_document(socket, errors, &refresh/1)}

      # No longer an instance admin, or the feature is off: the page itself is not found.
      {:error, _forbidden_or_unknown} ->
        {:noreply, push_navigate(socket, to: ~p"/instance/workspace-types")}
    end
  end

  # Each action starts with no message from an earlier one.
  defp fresh(socket), do: assign(socket, notice: nil, save_errors: [], save_note: nil)

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      place={:instance}
      section={:workspace_types}
    >
      <.settings_page section={:workspace_types} title={gettext("Workspace types")} measure="list">
        <:subtitle>
          {gettext(
            "The stages a new workspace of each type starts with. A change here changes no workspace that exists."
          )}
        </:subtitle>

        <ul id="workspace-types" role="list" class="grid gap-3">
          <li
            :for={entry <- @types}
            id={"workspace-type-#{slug(entry.type)}"}
            class="flex flex-wrap items-center justify-between gap-3 rounded-box border border-base-300 p-4"
          >
            <div class="grid gap-0.5">
              <p class="font-medium">{entry.name}</p>
              <p class="text-[13px]/5 text-muted">
                {gettext("Version %{number}", number: entry.newest.number)} · {author_line(
                  entry.newest
                )}
              </p>
            </div>
            <.button
              id={"workspace-type-#{slug(entry.type)}-edit"}
              size="sm"
              navigate={~p"/instance/workspace-types/#{entry.type}"}
              aria-label={gettext("Edit the stages of %{type}", type: entry.name)}
            >
              {gettext("Edit stages")}
            </.button>
          </li>
        </ul>
      </.settings_page>
    </Layouts.app>
    """
  end

  def render(assigns) do
    assigns =
      assign(assigns,
        stage: Processes.stage(assigns.draft, assigns.selected),
        dirty: assigns.draft != assigns.base.document
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      place={:instance}
      section={:workspace_types}
    >
      <:crumb>{@name}</:crumb>

      <.settings_page section={:workspace_types} title={@name} measure="list">
        <:subtitle>
          {gettext(
            "New workspaces of this type start with these stages. Each save makes a new version; workspaces that exist keep their stages."
          )}
        </:subtitle>

        <div id="type-stages" class="grid gap-6">
          <div id="type-version" class="flex flex-wrap items-center gap-x-4 gap-y-2">
            <p class="text-[13.5px]/5">
              {gettext("Editing version %{number}.", number: @base.number)}
              <span :if={@dirty} id="type-dirty" class="badge badge-sm badge-warning ml-2">
                {gettext("Unsaved changes")}
              </span>
            </p>
            <div class="flex flex-wrap gap-2">
              <.button id="type-save" variant="primary" phx-click="save" disabled={!@dirty}>
                {gettext("Save")}
              </.button>
              <.button id="type-discard" variant="ghost" phx-click="discard" disabled={!@dirty}>
                {gettext("Discard changes")}
              </.button>
              <p :if={@save_note} id="type-save-note" class="self-center text-[13px]/5 text-error">
                {@save_note}
              </p>
            </div>
          </div>
          <.notice :if={@notice} kind={:success}>
            <span id="type-notice">{@notice}</span>
          </.notice>
          <.notice :if={@save_errors != []} kind={:error}>
            <span :for={error <- @save_errors} class="block" data-save-error>{error}</span>
          </.notice>

          <div id="type-editor" class="grid items-start gap-4">
            <Canvas.canvas
              id="type-canvas"
              document={@draft}
              mode={:edit}
              selected={@selected}
              alerts={canvas_alerts(assigns)}
              marks={@declared}
            />

            <Inspector.stage_panel
              :if={@stage}
              stage={@stage}
              may={true}
              named={false}
              last={length(@draft["stages"]) == 1}
              declared={@declared}
              types={@types}
              members={[]}
              people={%{}}
              stage_errors={@stage_errors}
              rounds_errors={@rounds_errors}
              workflow_errors={@workflow_errors}
              problems={@problems}
              machine={@draft["machine"]}
              marks={@declared}
              harness={:qory}
            />
          </div>

          <.form
            for={%{}}
            as={:process}
            id="type-process-form"
            phx-change="edit_process"
            novalidate
            class="max-w-md"
          >
            <.input
              id="type-machine"
              name="process[machine]"
              value={@draft["machine"]}
              label={gettext("Default machine type")}
              hint={Inspector.machine_hint()}
              autocomplete="off"
              spellcheck="false"
            />
          </.form>

          <section id="type-history" aria-labelledby="type-history-title" class="grid gap-2">
            <h2 id="type-history-title" class="text-[15px]/6 font-semibold">
              {gettext("History")}
            </h2>
            <ol class="grid gap-3">
              <li
                :for={{version, older} <- with_older(@versions)}
                id={"type-version-#{version.number}"}
                class="grid gap-1"
              >
                <p class="text-[13.5px]/5">
                  <span class="font-medium">
                    {gettext("Version %{number}", number: version.number)}
                  </span>
                  <span :if={version.number == hd(@versions).number} class="ml-2 badge badge-sm">
                    {gettext("Newest")}
                  </span>
                  <span class="ml-2 text-muted">{author_line(version)}</span>
                </p>
                <ul class="grid gap-0.5 text-[13px]/5 text-muted">
                  <li :for={line <- change_lines(older, version)}>{line}</li>
                </ul>
              </li>
            </ol>
          </section>
        </div>
      </.settings_page>
    </Layouts.app>
    """
  end

  # A type's key in an element id: `qory.software` as `qory-software`.
  defp slug(type), do: String.replace(type, ~r/[^a-z0-9_-]/, "-")

  ## Words

  defp stale(number),
    do:
      gettext(
        "Version %{number} was saved after you opened this page. Copy your changes, then reload.",
        number: number
      )

  # The author of a version and its date: "Qory Apiary default" for a copy of the
  # release's default, else the short form of the admin's address (`ApiaryWeb.People`),
  # "Former member" for an account that is gone.
  defp author_line(%TypeTemplate{} = version) do
    who =
      cond do
        version.author -> People.short(People.email(version.author))
        version.release -> gettext("Qory Apiary default")
        true -> People.former_member()
      end

    gettext("%{person}, %{date}", person: who, date: Format.date(version.inserted_at))
  end

  # Each version with the version its save started from (`based_on`), or, for a copy of
  # the release's default, the version before it.
  defp with_older(versions) do
    by_number = Map.new(versions, &{&1.number, &1})

    for v <- versions,
        do: {v, Map.get(by_number, v.based_on || v.number - 1)}
  end

  defp change_lines(nil, _version), do: [gettext("The first version.")]

  defp change_lines(older, version) do
    case Processes.diff(older.document, version.document) do
      [] -> [gettext("No change.")]
      changes -> Enum.map(changes, &Words.change(&1, older.document, version.document, %{}))
    end
  end
end
