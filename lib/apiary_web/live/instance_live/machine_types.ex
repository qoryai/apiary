defmodule ApiaryWeb.InstanceLive.MachineTypes do
  @moduledoc """
  Instance settings › Machine types, `/instance/machine-types`, for the instance's admins on
  an instance with the feature `factory` (`use ApiaryWeb.Features, instance: :factory`);
  anyone else gets the page for a path that does not exist. The page lists the instance's
  machine types (`Apiary.MachineTypes`): each type's name, with its key and the mark
  Default on the default under it, its spec in two lines (vCPUs and memory; disk,
  architecture and virtualization), its image (the last part of its name and the first 12
  digits of its digest, the whole reference on hover), the workflows that run on it, and
  the pools that serve it, with a row menu of Edit, Make default (on a type that is not
  the default) and Delete…, confirmed in its row (`…/:key/delete`).

  Add machine type opens `…/new`, a separate page with the type's name, key, spec, image
  and whether it is the default; Edit opens `…/:key/edit`, the same form. A save that
  changes the key shows a warning first, under the form: the key change breaks every file
  that uses the key, with the counts of the workspaces, workspace types and waiting runs
  that use it, the Qory harness's `process.yaml` files that the instance admin fixes, and
  the number of files each organisation fixes in its harness
  (`Apiary.MachineTypes.key_change/1`), and Change key, which saves, and Cancel. After
  Change key, the list shows a message with the key it saved and those files, which stays
  until it is dismissed. The warning and the message show no workspace name, workflow or
  repository of an organisation. A save that no pool fits is refused under vCPUs; a type
  that a workflow uses, or the default, is kept, with a line under the table with the
  reason: the number of workflows and organisations that use the type, the number of
  workspaces and organisations whose process has it as its default, and the names of the
  workspace types that use it. A save needs a recent sign-in, as Instance settings ›
  Configuration does.
  """
  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, instance: :factory

  on_mount {ApiaryWeb.Access, :instance}

  alias Apiary.{Access, MachineTypes}
  alias Apiary.MachineTypes.MachineType
  alias ApiaryWeb.{MachineTypeWords, SettingsComponents}

  @index "/instance/machine-types"

  # The longest number the form reads: a longer one is refused before it is parsed.
  @number_bytes 16

  @impl true
  def mount(_params, _session, socket) do
    %{scope: instance} = socket.assigns

    if Access.can?(instance, :"instance.read_factory", instance.organisation) do
      {:ok,
       socket
       |> assign(
         form: nil,
         editing: nil,
         deleting: nil,
         refused: nil,
         key_warning: nil,
         key_saved: nil
       )
       |> load()}
    else
      raise ApiaryWeb.NotFound
    end
  end

  defp load(socket) do
    types = MachineTypes.list()
    pools = MachineTypes.pools()

    assign(socket,
      types: types,
      used_by: MachineTypes.used_by(),
      serving:
        Map.new(
          types,
          &{&1.key, Enum.filter(pools, fn pool -> MachineTypes.serves?(pool, &1) end)}
        )
    )
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = assign(socket, page_title: title(socket))
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params),
    do: assign(socket, form: nil, editing: nil, deleting: nil, key_warning: nil)

  defp apply_action(socket, :new, _params) do
    params = %{
      "name" => "",
      "key" => "",
      "image" => "",
      "vcpus" => "",
      "memory_gib" => "",
      "disk_gib" => "",
      "arch" => "amd64"
    }

    assign(socket,
      editing: nil,
      deleting: nil,
      refused: nil,
      key_warning: nil,
      form: to_form(params, as: :type)
    )
  end

  defp apply_action(socket, :edit, %{"key" => key}) do
    case find(socket, key) do
      %MachineType{} = type ->
        params = %{
          "name" => type.name,
          "key" => type.key,
          "image" => type.image || "",
          "vcpus" => to_string(type.vcpus),
          "memory_gib" => gib(type.memory_mib),
          "disk_gib" => to_string(type.disk_gib),
          "arch" => type.arch,
          "virtualization" => to_string(type.virtualization),
          "is_default" => to_string(type.is_default)
        }

        assign(socket,
          editing: type,
          deleting: nil,
          refused: nil,
          key_warning: nil,
          form: to_form(params, as: :type)
        )

      nil ->
        push_patch(socket, to: @index)
    end
  end

  defp apply_action(socket, :delete, %{"key" => key}) do
    case find(socket, key) do
      %MachineType{} = type ->
        assign(socket, deleting: type, form: nil, editing: nil, refused: nil)

      nil ->
        push_patch(socket, to: @index)
    end
  end

  defp find(socket, key), do: Enum.find(socket.assigns.types, &(&1.key == key))

  defp title(socket) do
    words =
      case socket.assigns.live_action do
        :new -> [gettext("Add machine type"), gettext("Machine types")]
        _other -> [gettext("Machine types")]
      end

    SettingsComponents.page_title(socket.assigns.current_scope, :instance, words)
  end

  @impl true
  # A change of the key after the warning shows takes the warning away: it is about the
  # key the save read.
  def handle_event("validate", %{"type" => params}, socket) do
    warning =
      with %{to: to} = warning <- socket.assigns.key_warning,
           ^to <- String.trim(params["key"] || ""),
           do: warning,
           else: (_other -> nil)

    {:noreply, assign(socket, form: to_form(params, as: :type), key_warning: warning)}
  end

  def handle_event("save", %{"type" => params}, socket), do: save(socket, params, false)

  def handle_event("change_key", _params, socket),
    do: save(socket, socket.assigns.form.params, true)

  def handle_event("cancel_key", _params, socket),
    do: {:noreply, assign(socket, key_warning: nil)}

  def handle_event("dismiss_key_saved", _params, socket),
    do: {:noreply, assign(socket, key_saved: nil)}

  def handle_event("make_default", %{"key" => key}, socket) do
    case find(socket, key) do
      %MachineType{} = type ->
        case MachineTypes.make_default(socket.assigns.current_scope, type) do
          {:ok, type} ->
            {:noreply,
             socket
             |> assign(refused: nil)
             |> load()
             |> put_flash(:info, gettext("%{name} is the default.", name: type.name))}

          {:error, reason} ->
            {:noreply, refused(socket, reason)}
        end

      nil ->
        {:noreply, load(socket)}
    end
  end

  def handle_event("delete", %{"key" => key}, socket) do
    case find(socket, key) do
      %MachineType{} = type ->
        case MachineTypes.delete(socket.assigns.current_scope, type) do
          {:ok, _deleted} ->
            {:noreply,
             socket
             |> assign(refused: nil)
             |> load()
             |> put_flash(:info, gettext("%{name} deleted.", name: type.name))
             |> push_patch(to: @index)}

          {:error, :default} ->
            {:noreply, kept(socket, :default, type)}

          {:error, {:in_use, _uses} = reason} ->
            {:noreply, kept(socket, reason, type)}

          {:error, reason} ->
            {:noreply, refused(socket, reason)}
        end

      nil ->
        {:noreply, socket |> load() |> push_patch(to: @index)}
    end
  end

  # A save of the form. A save of an edit that changes the key and is valid shows the
  # warning first, unless `confirmed?`, the press of Change key.
  defp save(socket, params, confirmed?) do
    scope = socket.assigns.current_scope

    case {attrs(params), socket.assigns.editing} do
      {{:ok, attrs}, nil} ->
        saved(socket, params, MachineTypes.create(scope, attrs))

      {{:ok, %{key: key} = attrs}, %MachineType{key: old} = type} when key != old ->
        changeset = MachineType.changeset(type, attrs)

        cond do
          confirmed? ->
            saved(socket, params, MachineTypes.update(scope, type, attrs), %{from: old, to: key})

          changeset.valid? ->
            warning = Map.merge(MachineTypes.key_change(type), %{from: old, to: key})
            {:noreply, assign(socket, form: to_form(params, as: :type), key_warning: warning)}

          true ->
            saved(socket, params, {:error, changeset})
        end

      {{:ok, attrs}, type} ->
        saved(socket, params, MachineTypes.update(scope, type, attrs))

      {{:error, errors}, _type} ->
        {:noreply, assign(socket, form: to_form(params, as: :type, errors: errors))}
    end
  end

  defp kept(socket, reason, type),
    do: socket |> assign(refused: {reason, type.name}) |> load() |> push_patch(to: @index)

  defp saved(socket, params, result, key_change \\ nil)

  # After a key change with files to fix, the message with the files stays until it is
  # dismissed, in place of the toast, which goes after a few seconds.
  defp saved(socket, _params, {:ok, type}, %{from: from, to: to}) do
    case socket.assigns.key_warning do
      %{files: files, organisations: organisations} when files != [] or organisations != [] ->
        saved = %{name: type.name, from: from, to: to, files: files, organisations: organisations}

        {:noreply,
         socket
         |> assign(key_saved: saved)
         |> load()
         |> push_patch(to: @index)}

      _none ->
        message =
          gettext("%{name} saved. Its key is now %{key}.", name: type.name, key: to)

        {:noreply, socket |> load() |> put_flash(:info, message) |> push_patch(to: @index)}
    end
  end

  defp saved(socket, _params, {:ok, type}, nil) do
    message =
      if socket.assigns.editing,
        do: gettext("%{name} saved.", name: type.name),
        else: gettext("%{name} added.", name: type.name)

    {:noreply, socket |> load() |> put_flash(:info, message) |> push_patch(to: @index)}
  end

  defp saved(socket, params, {:error, %Ecto.Changeset{} = changeset}, _key_change) do
    errors =
      for {field, {_message, opts}} <- changeset.errors, uniq: true do
        {form_field(field), {field_line(field, opts, params), []}}
      end

    {:noreply, assign(socket, form: to_form(params, as: :type, errors: errors), key_warning: nil)}
  end

  defp saved(socket, _params, {:error, reason}, _key_change),
    do: {:noreply, refused(socket, reason)}

  defp refused(socket, :sudo) do
    socket
    |> put_flash(:error, gettext("You must re-authenticate to access this page."))
    |> redirect(to: ~p"/users/log-in")
  end

  # A key change that met a save of a workspace type: the form stays, without the
  # warning, so that Change key can be pressed again
  # (`Apiary.Processes.TypeTemplates.rekey_machine/3`).
  defp refused(socket, :stale) do
    socket
    |> assign(key_warning: nil)
    |> put_flash(
      :error,
      gettext(
        "Change the key again. A workspace type was saved at the same moment, so the key change was not saved."
      )
    )
  end

  defp refused(socket, _reason), do: socket |> load() |> push_patch(to: @index)

  defp form_field(:memory_mib), do: :memory_gib
  defp form_field(field), do: field

  defp field_line(:key, opts, params) do
    case opts[:validation] || opts[:constraint] do
      :reserved ->
        gettext("Choose another key: default means the default type.")

      :unique ->
        gettext("Choose another key: %{key} exists.", key: String.trim(params["key"] || ""))

      _format ->
        gettext("Use lowercase letters, digits and hyphens, starting with a letter, at most 64.")
    end
  end

  defp field_line(:name, opts, params) do
    if opts[:constraint] == :unique,
      do:
        gettext("Choose another name: %{name} exists.", name: String.trim(params["name"] || "")),
      else: gettext("Write a name of 1 to 100 characters on one line, with no tabs.")
  end

  defp field_line(:image, _opts, _params),
    do:
      gettext(
        "Write a reference pinned by digest, such as ghcr.io/qoryai/qory-agent-prerelease@sha256: and 64 hexadecimal digits."
      )

  defp field_line(:vcpus, opts, _params) do
    if opts[:validation] == :no_pool,
      do: gettext("No pool offers a machine that fits this type."),
      else: vcpus_line()
  end

  defp field_line(:memory_mib, _opts, _params), do: memory_line()
  defp field_line(:disk_gib, _opts, _params), do: disk_line()
  defp field_line(_arch, _opts, _params), do: gettext("Choose amd64 or arm64.")

  defp vcpus_line, do: gettext("Write a whole number from 1 to 1024.")
  defp memory_line, do: gettext("Write a number from 0.5 to 8192, in steps of 1 MiB.")
  defp disk_line, do: gettext("Write a whole number from 1 to 65536.")

  # The form's values as `Apiary.MachineTypes.create/2` takes them, or the lines of the
  # fields that are not numbers. Memory is read in GiB and kept in MiB, a whole number.
  defp attrs(params) do
    vcpus = integer(params["vcpus"])
    memory = mib(params["memory_gib"])
    disk = integer(params["disk_gib"])

    errors =
      Enum.reject(
        [
          vcpus == :error && {:vcpus, {vcpus_line(), []}},
          memory == :error && {:memory_gib, {memory_line(), []}},
          disk == :error && {:disk_gib, {disk_line(), []}}
        ],
        &(&1 == false)
      )

    if errors == [] do
      {:ok,
       %{
         key: String.trim(params["key"] || ""),
         name: String.trim(params["name"] || ""),
         image: String.trim(params["image"] || ""),
         vcpus: vcpus,
         memory_mib: memory,
         disk_gib: disk,
         arch: params["arch"],
         virtualization: params["virtualization"] == "true",
         is_default: params["is_default"] == "true"
       }}
    else
      {:error, errors}
    end
  end

  defp integer(text) when is_binary(text) and byte_size(text) <= @number_bytes do
    case Integer.parse(String.trim(text)) do
      {n, ""} -> n
      _not -> :error
    end
  end

  defp integer(_text), do: :error

  # GiB as MiB, a whole number of MiB: 1.5 is 1536, 0.3 is not one.
  defp mib(text) when is_binary(text) and byte_size(text) <= @number_bytes do
    with {:ok, gib} <- Decimal.cast(String.trim(text)),
         mib = Decimal.mult(gib, 1024),
         true <- Decimal.integer?(mib) do
      Decimal.to_integer(mib)
    else
      _not -> :error
    end
  end

  defp mib(_text), do: :error

  defp gib(mib) do
    if rem(mib, 1024) == 0,
      do: Integer.to_string(div(mib, 1024)),
      else: mib |> Decimal.div(1024) |> Decimal.normalize() |> Decimal.to_string(:normal)
  end

  ## Rendering

  @impl true
  def render(%{live_action: action} = assigns) when action in [:new, :edit] do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      place={:instance}
      section={:machine_types}
    >
      <:crumb>{crumb(@editing)}</:crumb>
      <.settings_page section={:machine_types} title={gettext("Machine types")}>
        <:subtitle>{subtitle()}</:subtitle>
        <.form
          for={@form}
          id="machine-type-form"
          phx-change="validate"
          phx-submit="save"
          class="q-form"
          novalidate
        >
          <.input
            field={@form[:name]}
            type="text"
            label={gettext("Name")}
            hint={
              gettext(
                "What people see when they pick a type, such as Browser tests. You can change it at any time."
              )
            }
            maxlength="100"
            autocomplete="off"
          />
          <.input
            field={@form[:key]}
            type="text"
            label={gettext("Key")}
            hint={
              if @editing,
                do:
                  gettext(
                    "Process files and stages use the key. If you change it, Qory Apiary lists the files that use it before it saves."
                  ),
                else:
                  gettext(
                    "Process files and stages use the key, such as browser. Lowercase letters, digits and hyphens, starting with a letter, at most 64."
                  )
            }
            class="font-mono"
            maxlength="64"
            autocomplete="off"
            spellcheck="false"
          />
          <div class="q-form-two">
            <.input field={@form[:vcpus]} type="text" inputmode="numeric" label={gettext("vCPUs")} />
            <.input
              field={@form[:memory_gib]}
              type="text"
              inputmode="decimal"
              label={gettext("Memory (GiB)")}
            />
          </div>
          <div class="q-form-two">
            <.input
              field={@form[:disk_gib]}
              type="text"
              inputmode="numeric"
              label={gettext("Disk (GiB)")}
            />
            <.input
              field={@form[:arch]}
              type="select"
              label={gettext("Architecture")}
              options={MachineType.arches()}
            />
          </div>
          <.input
            field={@form[:image]}
            type="text"
            label={gettext("Image (optional)")}
            placeholder={gettext("registry/name@sha256:…")}
            hint={
              gettext(
                "The image a run on this type starts in, pinned by digest, such as ghcr.io/qoryai/qory-agent-prerelease@sha256:… Leave it empty to start runs in the target's prebuilt image, else in the default type's image, else in the run machine's image."
              )
            }
            class="font-mono"
            maxlength="327"
            autocomplete="off"
            spellcheck="false"
          />
          <div class="grid gap-1">
            <.input
              field={@form[:virtualization]}
              type="checkbox"
              label={gettext("Needs virtualization")}
            />
            <p id="machine-type-virtualization-hint" class="ml-6 text-[12.5px]/[18px] text-muted">
              {gettext("Runs on this type can start virtual machines inside the machine (KVM).")}
            </p>
          </div>
          <div :if={!(@editing && @editing.is_default)} class="grid gap-1">
            <.input field={@form[:is_default]} type="checkbox" label={gettext("Default")} />
            <p id="machine-type-default-hint" class="ml-6 text-[12.5px]/[18px] text-muted">
              {gettext(
                "Runs start on the default when neither the workflow nor its workspace picks a type."
              )}
            </p>
          </div>
          <p class="text-[13px]/5 text-muted">
            {gettext(
              "A run on this type starts on the pool's smallest machine with at least these vCPUs and memory, and this disk size."
            )}
          </p>
          <.key_warning :if={@key_warning} warning={@key_warning} />
          <SettingsComponents.save
            :if={!@key_warning}
            cancel={~p"/instance/machine-types"}
            cancel_by="patch"
          >
            <.button type="submit" variant="primary" loading_text={gettext("Saving")}>
              {if @editing, do: gettext("Save"), else: gettext("Add")}
            </.button>
          </SettingsComponents.save>
        </.form>
      </.settings_page>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      place={:instance}
      section={:machine_types}
    >
      <.settings_page section={:machine_types} title={gettext("Machine types")} measure="list">
        <:subtitle>{subtitle()}</:subtitle>
        <:actions>
          <.button
            id="machine-type-add"
            variant="primary"
            patch={~p"/instance/machine-types/new"}
          >
            {gettext("Add machine type")}
          </.button>
        </:actions>

        <div class="grid gap-3">
          <.table
            id="machine-types"
            label={gettext("Machine types")}
            rows={@types}
            row_id={&"machine-type-#{&1.key}"}
            confirming={@deleting && "machine-type-#{@deleting.key}"}
          >
            <:col :let={type} label={gettext("Name")} kind="title">
              <span id={"machine-type-#{type.key}-name"}>{type.name}</span>{" "}
              <span class="mt-0.5 flex items-center gap-2 text-[12px]/4 font-normal text-muted">
                <span id={"machine-type-#{type.key}-key"} class="font-mono">{type.key}</span>
                <.badge :if={type.is_default}>
                  {gettext("Default")}
                </.badge>
              </span>
            </:col>
            <:col :let={type} label={gettext("Spec")}>
              <span id={"machine-type-#{type.key}-spec"}>
                {spec_line(type)}
                <span class="mt-0.5 block text-[12px]/4 text-muted">{disk_line(type)}</span>
              </span>
            </:col>
            <:col :let={type} label={gettext("Image")}>
              <span
                :if={type.image}
                id={"machine-type-#{type.key}-image"}
                class="grid min-w-44 whitespace-normal"
                title={type.image}
              >
                <span class="font-mono text-[12.5px]/[18px] [overflow-wrap:anywhere]">
                  {image_name(type.image)}
                </span>
                <span class="mt-0.5 block font-mono text-[12px]/4 text-muted">
                  {image_digest(type.image)}
                </span>
              </span>
              <span :if={!type.image} id={"machine-type-#{type.key}-image"} class="text-muted">
                {gettext("Not set")}
              </span>
            </:col>
            <:col :let={type} label={gettext("Used by")}>
              {used_by(Map.get(@used_by, type.key, 0))}
            </:col>
            <:col :let={type} label={gettext("Pools")}>
              <%!-- The names wrap: on one line, the table is wider than its frame at 1280 px. --%>
              <span id={"machine-type-#{type.key}-pools"} class="block min-w-24 whitespace-normal">
                {pools(@serving[type.key])}
              </span>
            </:col>
            <:action :let={type}>
              <.row_menu
                id={"machine-type-#{type.key}-menu"}
                label={gettext("Actions for %{name}", name: type.name)}
              >
                <.menu_item patch={~p"/instance/machine-types/#{type.key}/edit"}>
                  {gettext("Edit")}
                </.menu_item>
                <.menu_item
                  :if={!type.is_default}
                  phx-click="make_default"
                  phx-value-key={type.key}
                >
                  {gettext("Make default")}
                </.menu_item>
                <.menu_item patch={~p"/instance/machine-types/#{type.key}/delete"}>
                  {gettext("Delete…")}
                </.menu_item>
              </.row_menu>
            </:action>
            <:confirm :let={type}>
              <.inline_confirm
                id={"machine-type-#{type.key}-confirm"}
                question={gettext("Delete %{name}?", name: type.name)}
                cancel={~p"/instance/machine-types"}
              >
                {gettext("Workflows can no longer pick this type. You cannot undo this.")}
                <:action>
                  <.button
                    id="machine-type-delete"
                    variant="danger"
                    size="xs"
                    phx-click="delete"
                    phx-value-key={type.key}
                    loading_text={gettext("Deleting")}
                  >
                    {gettext("Yes, delete")}
                  </.button>
                </:action>
              </.inline_confirm>
            </:confirm>
          </.table>
          <p :if={@refused} id="machine-type-refused" class="text-[13px]/5 text-error" role="alert">
            {refused_line(@refused)}
          </p>
        </div>
      </.settings_page>
      <.key_saved :if={@key_saved} saved={@key_saved} />
    </Layouts.app>
    """
  end

  attr :warning, :map, required: true

  # The warning before a key change: what Qory Apiary updates, the files the instance
  # admin fixes, and the number of files each organisation fixes, with Change key and
  # Cancel.
  defp key_warning(assigns) do
    ~H"""
    <div
      id="machine-type-key-warning"
      role="alert"
      class="alert alert-soft items-start bg-primary-soft text-primary-soft-content"
    >
      <.icon name="hero-exclamation-triangle-micro" class="mt-px size-4" />
      <div class="min-w-0">
        <p>
          <strong class="font-semibold">
            <.rich text={
              rich_gettext("Changing the key breaks every file that uses %{key}.",
                key: {:code, @warning.from, ""}
              )
            } />
          </strong>
          {updates_line(@warning)}
        </p>
        <.files :if={@warning.files != []} files={@warning.files} id="machine-type-key-files" />
        <.organisations
          :if={@warning.organisations != []}
          organisations={@warning.organisations}
          id="machine-type-key-organisations"
        />
        <div class="mt-3 flex gap-2">
          <.button
            id="machine-type-change-key"
            type="button"
            variant="danger"
            phx-click="change_key"
            loading_text={gettext("Saving")}
          >
            {gettext("Change key")}
          </.button>
          <.button id="machine-type-cancel-key" type="button" phx-click="cancel_key">
            {gettext("Cancel")}
          </.button>
        </div>
      </div>
    </div>
    """
  end

  attr :saved, :map, required: true

  # The message after a key change with files to fix: it stays until it is dismissed.
  defp key_saved(assigns) do
    ~H"""
    <div class="toast toast-end toast-bottom pointer-events-none z-[60] p-4 max-sm:inset-x-0 sm:p-6">
      <div
        id="machine-type-key-saved"
        role="status"
        class="pointer-events-auto grid w-full grid-cols-[16px_1fr_auto] items-start gap-2.5 rounded-box bg-base-100 p-3 text-[13px]/[18px] shadow-pop sm:w-[360px]"
      >
        <.icon name="hero-check-circle-micro" class="mt-px size-4 text-success" />
        <div class="min-w-0 break-words">
          <p class="font-medium">{gettext("%{name} saved.", name: @saved.name)}</p>
          <p class="text-muted">
            <%= if @saved.files != [] do %>
              {ngettext(
                "Its key is now %{key}. Fix the file that still uses %{old}.",
                "Its key is now %{key}. Fix the %{count} files that still use %{old}.",
                length(@saved.files),
                key: @saved.to,
                old: @saved.from
              )}
            <% else %>
              {gettext("Its key is now %{key}.", key: @saved.to)}
            <% end %>
          </p>
          <.files :if={@saved.files != []} files={@saved.files} id="machine-type-key-saved-files" />
          <.organisations
            :if={@saved.organisations != []}
            organisations={@saved.organisations}
            id="machine-type-key-saved-organisations"
          />
        </div>
        <button
          type="button"
          phx-click="dismiss_key_saved"
          class="grid size-5 cursor-pointer place-items-center rounded-selector text-faint transition-colors hover:bg-base-300 hover:text-base-content"
          aria-label={gettext("Dismiss")}
        >
          <.icon name="hero-x-mark-micro" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  attr :files, :list, required: true
  attr :id, :string, required: true

  # One line per file of the Qory harness: the repository, then its path, else its module
  # for a commit whose files are not kept, and the commit it was read at.
  defp files(assigns) do
    ~H"""
    <ul id={@id} class="mt-2 grid gap-1 text-[12.5px]/[18px]">
      <li :for={file <- @files} class="grid">
        <code class="[overflow-wrap:anywhere]">{file.repository}</code>{" "}
        <span class="[overflow-wrap:anywhere]">
          <code>{file.path || file.module}</code>
          <%= if file.commit do %>
            {gettext("at")} <code>{String.slice(file.commit, 0, 7)}</code>
          <% end %>
        </span>
      </li>
    </ul>
    """
  end

  attr :organisations, :list, required: true
  attr :id, :string, required: true

  # The files each organisation fixes, one line per organisation with the number of files
  # in its harness: no repository, workspace or workflow of an organisation.
  defp organisations(assigns) do
    ~H"""
    <div id={@id} class="mt-2 text-[12.5px]/[18px]">
      <p>{gettext("Organisations fix the files in their harnesses:")}</p>
      <ul class="mt-1 grid gap-1">
        <li :for={organisation <- @organisations} class="[overflow-wrap:anywhere]">
          {ngettext(
            "%{count} file in %{organisation}'s harness",
            "%{count} files in %{organisation}'s harness",
            organisation.files,
            count: Format.number(organisation.files),
            organisation: organisation.name
          )}
        </li>
      </ul>
    </div>
    """
  end

  # The last part of the breadcrumb: the type by its name on Edit.
  defp crumb(nil), do: gettext("Add machine type")
  defp crumb(type), do: gettext("Edit %{name}", name: type.name)

  defp updates_line(%{workspaces: workspaces, templates: templates, waiting: waiting} = warning) do
    counts = [
      workspaces:
        ngettext("%{count} workspace", "%{count} workspaces", workspaces,
          count: Format.number(workspaces)
        ),
      types:
        ngettext("%{count} workspace type", "%{count} workspace types", templates,
          count: Format.number(templates)
        ),
      waiting:
        ngettext("%{count} waiting run", "%{count} waiting runs", waiting,
          count: Format.number(waiting)
        )
    ]

    if warning.files == [],
      do: gettext("Qory Apiary updates %{workspaces}, %{types}, %{waiting}.", counts),
      else:
        gettext(
          "Qory Apiary updates %{workspaces}, %{types}, %{waiting}. Fix these files yourself:",
          counts
        )
  end

  defp subtitle,
    do:
      gettext(
        "The machines that runs start on, and the image a run starts in. A workflow runs on the type it picks, else on the workspace's default, else on the instance default."
      )

  defp spec_line(type),
    do:
      ngettext("%{count} vCPU, %{memory}", "%{count} vCPUs, %{memory}", type.vcpus,
        memory: MachineTypeWords.memory(type.memory_mib)
      )

  defp disk_line(%MachineType{virtualization: true} = type),
    do:
      gettext("%{disk} disk, %{arch}, virtualization",
        disk: MachineTypeWords.disk(type.disk_gib),
        arch: type.arch
      )

  defp disk_line(type),
    do:
      gettext("%{disk} disk, %{arch}",
        disk: MachineTypeWords.disk(type.disk_gib),
        arch: type.arch
      )

  # The last part of an image's name, without its registry and its path:
  # `ghcr.io/qoryai/qory-agent-prerelease@sha256:…` is qory-agent-prerelease.
  defp image_name(image),
    do: image |> String.split("@") |> hd() |> String.split("/") |> List.last()

  # An image's digest cut to its first 12 digits: sha256:cbe08a2e8275.
  defp image_digest(image),
    do: "sha256:" <> (image |> String.split(":") |> List.last() |> binary_part(0, 12))

  defp used_by(count),
    do: ngettext("%{count} workflow", "%{count} workflows", count, count: Format.number(count))

  defp pools([]), do: gettext("None")
  defp pools(pools), do: Enum.map_join(pools, ", ", & &1.name)

  defp refused_line({:default, name}),
    do:
      gettext(
        "%{name} cannot be deleted: it is the default. Make another type the default first.",
        name: name
      )

  # The uses of a type kept for them: the number of workflows in organisations'
  # workspaces, the number of those workspaces whose process has the type as its default,
  # each with the number of their organisations, and the names of the instance's
  # workspace types, with no workspace name or workflow of an organisation.
  defp refused_line({{:in_use, uses}, name}) do
    {workspaces, types} = Enum.split_with(uses, &is_binary(&1.organisation_id))
    {defaults, workflows} = Enum.split_with(workspaces, &is_nil(&1.workflow))

    clauses =
      Enum.reject(
        [workflows_clause(workflows), defaults_clause(defaults), types_clause(types)],
        &is_nil/1
      )

    case clauses do
      [uses] ->
        gettext("%{name} cannot be deleted: %{uses}.", name: name, uses: uses)

      [first, second] ->
        gettext("%{name} cannot be deleted: %{first}, and %{second}.",
          name: name,
          first: first,
          second: second
        )

      [first, second, third] ->
        gettext("%{name} cannot be deleted: %{first}, %{second}, and %{third}.",
          name: name,
          first: first,
          second: second,
          third: third
        )
    end
  end

  defp workflows_clause([]), do: nil

  defp workflows_clause(uses) do
    ngettext(
      "%{count} workflow in %{organisations} uses it",
      "%{count} workflows in %{organisations} use it",
      length(uses),
      count: Format.number(length(uses)),
      organisations: organisations_words(uses)
    )
  end

  # The workspaces whose process has the type as its default while every workflow picks
  # another type: a use with no workflow.
  defp defaults_clause([]), do: nil

  defp defaults_clause(uses) do
    workspaces = uses |> Enum.uniq_by(&{&1.organisation_id, &1.place}) |> length()

    ngettext(
      "%{count} workspace in %{organisations} has it as its default machine type",
      "%{count} workspaces in %{organisations} have it as their default machine type",
      workspaces,
      count: Format.number(workspaces),
      organisations: organisations_words(uses)
    )
  end

  defp organisations_words(uses) do
    count = uses |> Enum.uniq_by(& &1.organisation_id) |> length()

    ngettext("%{count} organisation", "%{count} organisations", count,
      count: Format.number(count)
    )
  end

  defp types_clause([]), do: nil

  defp types_clause(uses) do
    names = uses |> Enum.map(& &1.place) |> Enum.uniq() |> Enum.sort()

    ngettext(
      "the workspace type %{names} uses it",
      "the workspace types %{names} use it",
      length(names),
      names: Enum.join(names, ", ")
    )
  end
end
