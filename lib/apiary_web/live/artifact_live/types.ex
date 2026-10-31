defmodule ApiaryWeb.ArtifactLive.Types do
  # Workspace settings › Artifact types, `/:org/:workspace/settings/artifact-types`, under
  # the feature `workflow_model`, for owners and admins (`artifact_type.edit`): the
  # standard types, read only, each with its base view, size limit and most files; then
  # the workspace's custom types (`Apiary.Artifacts.types/1`), with Add a type
  # (`…/new`), Edit (`…/:type_id/edit`: size limit, most files and, for a structured
  # type, the JSON Schema) and Delete, confirmed in its row (`…/:type_id/delete`). A
  # custom type's name and base view are fixed once it is made. A type that artifacts of
  # the workspace have is kept, and a line under the table says why (`:in_use`).
  #
  # A custom type's workflows, the ones that write or read it, come from the harness's
  # declarations, which have none yet, so the list shows no workflows.
  #
  # The module reference leaves out this module of the `workflow_model` feature.
  @moduledoc false

  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, :workflow_model
  on_mount {ApiaryWeb.Access, :"artifact_type.edit"}

  alias Apiary.Artifacts
  alias Apiary.Artifacts.Type
  alias ApiaryWeb.ArtifactLive.Load
  alias ApiaryWeb.SettingsComponents

  @mib 1_048_576

  # The largest size limit the form reads, in MiB: more than any base view takes
  # (`Apiary.Artifacts.Type.max_size_limit/1`), so the size rule's line says the limit.
  @most_mib 1_048_576

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:settings}
      sections={@sections}
      section={:artifact_types}
    >
      <:crumb :if={@mode in [:new, :edit]}>
        {if @mode == :new,
          do: gettext("Add a type"),
          else: gettext("Edit %{name}", name: @editing.name)}
      </:crumb>
      <SettingsComponents.layout
        scope={@current_scope}
        counts={@nav_counts}
        kind={:workspace}
        current={:artifact_types}
        measure={if @mode in [:new, :edit], do: "read", else: "list"}
        title={gettext("Artifact types")}
      >
        <:subtitle>
          {gettext("What runs and people store on a work item, and how Qory Apiary shows it.")}
        </:subtitle>
        <:actions :if={@mode not in [:new, :edit]}>
          <.button id="artifact-type-add" variant="primary" patch={types_path(@current_scope, :new)}>
            {gettext("Add a type")}
          </.button>
        </:actions>

        <%= if @mode in [:new, :edit] do %>
          <.type_form form={@form} editing={@editing} scope={@current_scope} base_view={@base_view} />
        <% else %>
          <SettingsComponents.part
            id="artifact-types-custom"
            title={gettext("Custom types")}
            count={length(@custom)}
          >
            <p :if={@custom == []} id="artifact-types-custom-empty" class="text-[13px]/5 text-muted">
              {gettext(
                "No custom types yet. Add one when a workflow stores something no standard type fits."
              )}
            </p>
            <.table
              :if={@custom != []}
              id="artifact-types-custom-table"
              label={gettext("Custom types")}
              rows={@custom}
              row_id={&"artifact-type-#{&1.public_id}"}
              confirming={@deleting && "artifact-type-#{@deleting.public_id}"}
            >
              <:col :let={type} label={gettext("Name")} kind="title">{type.name}</:col>
              <:col :let={type} label={gettext("Base view")}>{Load.base_view(type.base_view)}</:col>
              <:col :let={type} label={gettext("Size limit")} kind="num">
                {size(type.size_limit)}
              </:col>
              <:col :let={type} label={gettext("Most files")} kind="num">
                {Format.number(type.max_files)}
              </:col>
              <:action :let={type}>
                <.row_menu
                  id={"artifact-type-#{type.public_id}-menu"}
                  label={gettext("Actions for %{name}", name: type.name)}
                >
                  <.menu_item patch={types_path(@current_scope, :edit, type)}>
                    {gettext("Edit")}
                  </.menu_item>
                  <.menu_item patch={types_path(@current_scope, :delete, type)}>
                    {gettext("Delete…")}
                  </.menu_item>
                </.row_menu>
              </:action>
              <:confirm :let={type}>
                <.inline_confirm
                  id={"artifact-type-#{type.public_id}-confirm"}
                  question={gettext("Delete %{name}?", name: type.name)}
                  cancel={types_path(@current_scope, :index)}
                >
                  {gettext(
                    "Runs and people can no longer store artifacts of this type. You cannot undo this."
                  )}
                  <:action>
                    <.button
                      id="artifact-type-delete"
                      variant="danger"
                      size="xs"
                      phx-click="delete"
                      phx-value-id={type.public_id}
                      loading_text={gettext("Deleting")}
                    >
                      {gettext("Yes, delete")}
                    </.button>
                  </:action>
                </.inline_confirm>
              </:confirm>
            </.table>
            <p :if={@in_use} id="artifact-type-in-use" class="text-[13px]/5 text-error" role="alert">
              {gettext(
                "%{name} cannot be deleted: work items of this workspace have artifacts of this type.",
                name: @in_use
              )}
            </p>
          </SettingsComponents.part>

          <SettingsComponents.part
            id="artifact-types-standard"
            title={gettext("Standard types")}
            count={length(@standard)}
          >
            <p class="text-[13px]/5 text-muted">
              {gettext("Qory Apiary ships these types. They cannot be changed.")}
            </p>
            <.table
              id="artifact-types-standard-table"
              label={gettext("Standard types")}
              rows={@standard}
              row_id={&"artifact-type-#{&1.name}"}
            >
              <:col :let={type} label={gettext("Name")} kind="title">{type.name}</:col>
              <:col :let={type} label={gettext("Base view")}>{Load.base_view(type.base_view)}</:col>
              <:col :let={type} label={gettext("Size limit")} kind="num">
                {size(type.size_limit)}
              </:col>
              <:col :let={type} label={gettext("Most files")} kind="num">
                {Format.number(type.max_files)}
              </:col>
            </.table>
          </SettingsComponents.part>
        <% end %>
      </SettingsComponents.layout>
    </Layouts.app>
    """
  end

  attr :form, :any, required: true
  attr :editing, :any, required: true
  attr :scope, :any, required: true
  attr :base_view, :atom, required: true

  defp type_form(assigns) do
    ~H"""
    <.form
      for={@form}
      id="artifact-type-form"
      phx-change="validate"
      phx-submit="save"
      class="q-form"
      novalidate
    >
      <.input
        :if={!@editing}
        field={@form[:name]}
        type="text"
        label={gettext("Name")}
        hint={
          gettext(
            "Lowercase letters and digits joined by hyphens, such as demo-findings. It cannot change later."
          )
        }
        autocomplete="off"
        spellcheck="false"
      />
      <.input
        :if={!@editing}
        field={@form[:base_view]}
        type="select"
        label={gettext("Base view")}
        options={Enum.map(Type.base_views(), &{Load.base_view(&1), &1})}
        hint={base_view_hint(@base_view)}
      />
      <p :if={@editing} class="text-[13px]/5 text-muted">
        {gettext("Base view: %{view}. The name and the base view cannot change.",
          view: Load.base_view(@editing.base_view)
        )}
      </p>
      <div class="q-form-two">
        <.input
          field={@form[:size_mib]}
          type="text"
          inputmode="decimal"
          label={gettext("Size limit in MiB")}
          hint={
            gettext("All files of one version together. At most %{size}.",
              size: size(Type.max_size_limit(@base_view))
            )
          }
        />
        <.input
          field={@form[:max_files]}
          type="text"
          inputmode="numeric"
          label={gettext("Most files")}
          hint={
            if @base_view == :structured,
              do: gettext("A structured type has one file."),
              else: gettext("Per version, 1 to %{number}.", number: Type.max_files_limit())
          }
          disabled={@base_view == :structured}
        />
      </div>
      <.input
        :if={@base_view == :structured}
        field={@form[:json_schema]}
        type="textarea"
        rows="12"
        class="font-mono text-[12.5px]"
        label={gettext("JSON Schema")}
        hint={gettext("Each version's one file is a JSON document valid against this schema.")}
        spellcheck="false"
      />
      <SettingsComponents.save cancel={types_path(@scope, :index)} cancel_by="patch">
        <.button type="submit" variant="primary" loading_text={gettext("Saving")}>
          {if @editing, do: gettext("Save"), else: gettext("Add type")}
        </.button>
      </SettingsComponents.save>
    </.form>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(
       sections: SettingsComponents.sections(scope, :workspace),
       page_title: SettingsComponents.page_title(scope, :workspace, [gettext("Artifact types")]),
       mode: :index,
       deleting: nil,
       in_use: nil,
       editing: nil,
       base_view: :document,
       form: nil
     )
     |> load()}
  end

  defp load(socket) do
    {standard, custom} =
      socket.assigns.current_scope.workspace
      |> Artifacts.types()
      |> Enum.split_with(& &1.standard)

    assign(socket, standard: standard, custom: custom)
  end

  @impl true
  def handle_params(params, _uri, socket),
    do: {:noreply, apply_action(socket, socket.assigns.live_action, params)}

  # `?name=` on the list, as Define it links here from the Stages page, opens the add
  # form with that name filled in, while the name is one a type may have and no type of
  # the workspace has it; any other name opens the form empty.
  defp apply_action(socket, :index, %{"name" => _name} = params),
    do: apply_action(socket, :new, params)

  defp apply_action(socket, :index, _params),
    do: assign(socket, mode: :index, deleting: nil, editing: nil, form: nil)

  defp apply_action(socket, :new, params) do
    name = params["name"]

    name =
      if Type.name?(name) and
           not Enum.any?(socket.assigns.standard ++ socket.assigns.custom, &(&1.name == name)),
         do: name,
         else: ""

    params = %{
      "name" => name,
      "base_view" => "document",
      "size_mib" => mib(Type.default_size_limit(:document)),
      "max_files" => "1",
      "json_schema" => ""
    }

    socket
    |> assign(mode: :new, deleting: nil, editing: nil, in_use: nil, base_view: :document)
    |> assign_form(params, [])
  end

  defp apply_action(socket, :edit, %{"type_id" => id}) do
    case custom(socket, id) do
      %Type{} = type ->
        params = %{
          "size_mib" => mib(type.size_limit),
          "max_files" => Integer.to_string(type.max_files),
          "json_schema" =>
            if(type.json_schema, do: Jason.encode!(type.json_schema, pretty: true), else: "")
        }

        socket
        |> assign(
          mode: :edit,
          deleting: nil,
          editing: type,
          in_use: nil,
          base_view: type.base_view
        )
        |> assign_form(params, [])

      nil ->
        gone(socket)
    end
  end

  defp apply_action(socket, :delete, %{"type_id" => id}) do
    case custom(socket, id) do
      %Type{} = type ->
        assign(socket, mode: :index, deleting: type, editing: nil, in_use: nil, form: nil)

      nil ->
        gone(socket)
    end
  end

  defp custom(socket, id), do: Enum.find(socket.assigns.custom, &(&1.public_id == id))

  defp gone(socket) do
    socket
    |> put_flash(:error, gettext("That type is no longer here."))
    |> push_patch(to: types_path(socket.assigns.current_scope, :index))
  end

  # The reader's role no longer lets them edit the types (`artifact_type.edit`).
  defp not_allowed(socket) do
    socket
    |> put_flash(
      :error,
      gettext("Your role no longer lets you change artifact types.")
    )
    |> push_patch(to: types_path(socket.assigns.current_scope, :index))
  end

  defp assign_form(socket, params, errors),
    do: assign(socket, :form, to_form(params, as: :artifact_type, errors: errors))

  @impl true
  def handle_event("validate", %{"artifact_type" => params}, socket) do
    base_view =
      if socket.assigns.editing,
        do: socket.assigns.editing.base_view,
        else: base_view(params["base_view"])

    {:noreply, socket |> assign(:base_view, base_view) |> assign_form(params, [])}
  end

  def handle_event("save", %{"artifact_type" => params}, socket) do
    scope = socket.assigns.current_scope

    case attrs(params, socket.assigns.base_view) do
      {:ok, attrs} ->
        result =
          case socket.assigns.editing do
            nil -> Artifacts.create_type(scope, scope.workspace, attrs)
            type -> Artifacts.update_type(scope, type, Map.drop(attrs, [:name, :base_view]))
          end

        saved(socket, params, result)

      {:error, errors} ->
        {:noreply, assign_form(socket, params, errors)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case custom(socket, id) do
      %Type{} = type ->
        case Artifacts.delete_type(scope, type) do
          {:ok, _deleted} ->
            {:noreply,
             socket
             |> load()
             |> put_flash(:info, gettext("%{name} deleted.", name: type.name))
             |> push_patch(to: types_path(scope, :index))}

          {:error, :in_use} ->
            {:noreply,
             socket |> assign(in_use: type.name) |> push_patch(to: types_path(scope, :index))}

          {:error, :forbidden} ->
            {:noreply, socket |> load() |> not_allowed()}

          {:error, _refused} ->
            {:noreply, socket |> load() |> gone()}
        end

      nil ->
        {:noreply, gone(socket)}
    end
  end

  defp saved(socket, _params, {:ok, type}) do
    message =
      if socket.assigns.editing,
        do: gettext("%{name} saved.", name: type.name),
        else: gettext("%{name} added.", name: type.name)

    {:noreply,
     socket
     |> load()
     |> put_flash(:info, message)
     |> push_patch(to: types_path(socket.assigns.current_scope, :index))}
  end

  defp saved(socket, params, {:error, %Ecto.Changeset{} = changeset}) do
    errors =
      for {field, {_message, opts}} <- changeset.errors, uniq: true do
        {form_field(field), {field_line(field, opts, params, socket.assigns.base_view), []}}
      end

    {:noreply, assign_form(socket, params, errors)}
  end

  defp saved(socket, _params, {:error, :forbidden}), do: {:noreply, not_allowed(socket)}
  defp saved(socket, _params, {:error, _refused}), do: {:noreply, gone(socket)}

  defp form_field(:size_limit), do: :size_mib
  defp form_field(field), do: field

  defp field_line(:name, opts, params, _base_view) do
    case opts[:validation] || opts[:constraint] do
      :standard ->
        gettext("Choose another name: %{name} is a standard type.", name: params["name"])

      :unique ->
        gettext("Choose another name: this workspace has a type called %{name}.",
          name: params["name"]
        )

      _format ->
        name_rule()
    end
  end

  defp field_line(:base_view, _opts, _params, _base_view), do: gettext("Choose a base view.")

  defp field_line(:size_limit, _opts, _params, base_view), do: size_rule(base_view)
  defp field_line(:max_files, _opts, _params, base_view), do: files_rule(base_view)

  defp field_line(_json_schema, _opts, _params, _base_view), do: schema_rule()

  # The form's values as `Apiary.Artifacts.create_type/3` takes them, or the lines of the
  # fields that are not numbers.
  defp attrs(params, base_view) do
    size = parse_mib(params["size_mib"])
    files = if base_view == :structured, do: 1, else: parse_integer(params["max_files"])

    errors =
      Enum.reject(
        [
          size == :error && {:size_mib, {size_rule(base_view), []}},
          files == :error && {:max_files, {files_rule(base_view), []}}
        ],
        &(&1 == false)
      )

    if errors == [] do
      attrs = %{
        name: String.trim(params["name"] || ""),
        base_view: base_view,
        size_limit: size,
        max_files: files
      }

      {:ok,
       if(base_view == :structured,
         do: Map.put(attrs, :json_schema, params["json_schema"] || ""),
         else: attrs
       )}
    else
      {:error, errors}
    end
  end

  # A size in MiB, from above 0 to `@most_mib`: a larger number, such as `1e308`, would
  # overflow the bytes, and no base view takes it.
  defp parse_mib(text) when is_binary(text) do
    case Float.parse(String.trim(text)) do
      {mib, ""} when mib > 0 and mib <= @most_mib -> max(round(mib * @mib), 1)
      _not -> :error
    end
  end

  defp parse_mib(_text), do: :error

  defp parse_integer(text) when is_binary(text) do
    case Integer.parse(String.trim(text)) do
      {n, ""} -> n
      _not -> :error
    end
  end

  defp parse_integer(_text), do: :error

  defp base_view(name) do
    Enum.find(Type.base_views(), :document, &(Atom.to_string(&1) == name))
  end

  defp name_rule,
    do:
      gettext(
        "Use lowercase letters and digits, in groups joined by single hyphens, at most 64 characters."
      )

  defp size_rule(base_view),
    do:
      gettext("Set a size limit above 0 and at most %{size}.",
        size: size(Type.max_size_limit(base_view))
      )

  defp files_rule(:structured), do: gettext("A structured type has one file.")

  defp files_rule(_base_view),
    do:
      gettext("Set most files to a whole number from 1 to %{number}.",
        number: Type.max_files_limit()
      )

  defp schema_rule,
    do:
      gettext(
        "Paste a JSON Schema: one JSON object of at most 64 KiB that Qory Apiary can build."
      )

  defp base_view_hint(:document), do: gettext("Markdown, with Mermaid diagrams.")
  defp base_view_hint(:image), do: gettext("PNG, JPEG, GIF, WebP or SVG images.")
  defp base_view_hint(:video), do: gettext("MP4 or WebM videos, with WebVTT captions.")
  defp base_view_hint(:file), do: gettext("Any file, offered as a download.")
  defp base_view_hint(:structured), do: gettext("One JSON document, shown as a table.")

  defp size(bytes), do: ApiaryWeb.ArtifactComponents.size(bytes)

  # A size limit in MiB, as the form shows it: at most four decimals, without trailing
  # zeros.
  defp mib(bytes) do
    (bytes / @mib)
    |> :erlang.float_to_binary(decimals: 4)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end

  defp types_path(scope, :index),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/settings/artifact-types"

  defp types_path(scope, :new),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/settings/artifact-types/new"

  defp types_path(scope, :edit, type),
    do:
      ~p"/#{scope.organisation}/#{scope.workspace}/settings/artifact-types/#{type.public_id}/edit"

  defp types_path(scope, :delete, type),
    do:
      ~p"/#{scope.organisation}/#{scope.workspace}/settings/artifact-types/#{type.public_id}/delete"
end
