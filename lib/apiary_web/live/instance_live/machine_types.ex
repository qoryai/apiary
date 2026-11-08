defmodule ApiaryWeb.InstanceLive.MachineTypes do
  @moduledoc """
  Instance settings › Machine types, `/instance/machine-types`, for the instance's admins on
  an instance with the feature `factory` (`use ApiaryWeb.Features, instance: :factory`);
  anyone else gets the page for a path that does not exist. The page lists the instance's
  machine types (`Apiary.MachineTypes`): each type's name, with the mark Default on the
  default, its vCPUs, memory, disk, architecture and virtualization, the workflows that run
  on it, and the pools that serve it, with a row menu of Edit, Make default (on a type that
  is not the default) and Delete…, confirmed in its row (`…/:name/delete`).

  Add machine type opens `…/new`, a separate page with the type's name, its spec and
  whether it is the default; Edit opens `…/:name/edit`, the same form without the name,
  which never changes. A save that no pool fits is refused under vCPUs; a type that a
  workflow uses, or the default, is kept, with a line under the table with the workflows
  or the reason. A save needs a recent sign-in, as Instance settings ›
  Configuration does.
  """
  use ApiaryWeb, :live_view
  use ApiaryWeb.Features, instance: :factory

  alias Apiary.{Access, MachineTypes}
  alias Apiary.MachineTypes.MachineType
  alias ApiaryWeb.{MachineTypeWords, SettingsComponents}

  @index "/instance/machine-types"

  # The longest number the form reads: a longer one is refused before it is parsed.
  @number_bytes 16

  @impl true
  def mount(_params, _session, socket) do
    if Access.instance_admin?(socket.assigns.current_scope) do
      {:ok, socket |> assign(form: nil, editing: nil, deleting: nil, refused: nil) |> load()}
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
          &{&1.name, Enum.filter(pools, fn pool -> MachineTypes.serves?(pool, &1) end)}
        )
    )
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = assign(socket, page_title: title(socket))
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params),
    do: assign(socket, form: nil, editing: nil, deleting: nil)

  defp apply_action(socket, :new, _params) do
    params = %{"vcpus" => "", "memory_gib" => "", "disk_gib" => "", "arch" => "amd64"}
    assign(socket, editing: nil, deleting: nil, refused: nil, form: to_form(params, as: :type))
  end

  defp apply_action(socket, :edit, %{"name" => name}) do
    case find(socket, name) do
      %MachineType{} = type ->
        params = %{
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
          form: to_form(params, as: :type)
        )

      nil ->
        push_patch(socket, to: @index)
    end
  end

  defp apply_action(socket, :delete, %{"name" => name}) do
    case find(socket, name) do
      %MachineType{} = type ->
        assign(socket, deleting: type, form: nil, editing: nil, refused: nil)

      nil ->
        push_patch(socket, to: @index)
    end
  end

  defp find(socket, name), do: Enum.find(socket.assigns.types, &(&1.name == name))

  defp title(socket) do
    words =
      case socket.assigns.live_action do
        :new -> [gettext("Add machine type"), gettext("Machine types")]
        _other -> [gettext("Machine types")]
      end

    SettingsComponents.page_title(socket.assigns.current_scope, :instance, words)
  end

  @impl true
  def handle_event("validate", %{"type" => params}, socket),
    do: {:noreply, assign(socket, form: to_form(params, as: :type))}

  def handle_event("save", %{"type" => params}, socket) do
    scope = socket.assigns.current_scope

    case attrs(params) do
      {:ok, attrs} ->
        result =
          case socket.assigns.editing do
            nil -> MachineTypes.create(scope, attrs)
            type -> MachineTypes.update(scope, type, Map.delete(attrs, :name))
          end

        saved(socket, params, result)

      {:error, errors} ->
        {:noreply, assign(socket, form: to_form(params, as: :type, errors: errors))}
    end
  end

  def handle_event("make_default", %{"name" => name}, socket) do
    case find(socket, name) do
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

  def handle_event("delete", %{"name" => name}, socket) do
    case find(socket, name) do
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

  defp kept(socket, reason, type),
    do: socket |> assign(refused: {reason, type.name}) |> load() |> push_patch(to: @index)

  defp saved(socket, _params, {:ok, type}) do
    message =
      if socket.assigns.editing,
        do: gettext("%{name} saved.", name: type.name),
        else: gettext("%{name} added.", name: type.name)

    {:noreply, socket |> load() |> put_flash(:info, message) |> push_patch(to: @index)}
  end

  defp saved(socket, params, {:error, %Ecto.Changeset{} = changeset}) do
    errors =
      for {field, {_message, opts}} <- changeset.errors, uniq: true do
        {form_field(field), {field_line(field, opts, params), []}}
      end

    {:noreply, assign(socket, form: to_form(params, as: :type, errors: errors))}
  end

  defp saved(socket, _params, {:error, reason}), do: {:noreply, refused(socket, reason)}

  defp refused(socket, :sudo) do
    socket
    |> put_flash(:error, gettext("You must re-authenticate to access this page."))
    |> redirect(to: ~p"/users/log-in")
  end

  defp refused(socket, _reason), do: socket |> load() |> push_patch(to: @index)

  defp form_field(:memory_mib), do: :memory_gib
  defp form_field(field), do: field

  defp field_line(:name, opts, params) do
    case opts[:validation] || opts[:constraint] do
      :reserved ->
        gettext("Choose another name: default means the default type.")

      :unique ->
        gettext("Choose another name: %{name} exists.", name: String.trim(params["name"] || ""))

      _format ->
        gettext("Use lowercase letters, digits and hyphens, starting with a letter, at most 64.")
    end
  end

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
         name: String.trim(params["name"] || ""),
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
      <:crumb patch={~p"/instance/machine-types"}>{gettext("Machine types")}</:crumb>
      <:crumb>
        {if @editing,
          do: gettext("Edit %{name}", name: @editing.name),
          else: gettext("Add machine type")}
      </:crumb>
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
            :if={!@editing}
            field={@form[:name]}
            type="text"
            label={gettext("Name")}
            hint={
              gettext(
                "Lowercase letters, digits and hyphens, starting with a letter, such as large. It cannot change later."
              )
            }
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
          <SettingsComponents.save cancel={~p"/instance/machine-types"} cancel_by="patch">
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
            row_id={&"machine-type-#{&1.name}"}
            confirming={@deleting && "machine-type-#{@deleting.name}"}
          >
            <:col :let={type} label={gettext("Name")} kind="title">
              <span class="inline-flex items-center gap-2">
                {type.name}
                <.badge :if={type.is_default}>
                  {gettext("Default")}
                </.badge>
              </span>
            </:col>
            <:col :let={type} label={gettext("vCPUs")} kind="num">{Format.number(type.vcpus)}</:col>
            <:col :let={type} label={gettext("Memory")} kind="num">
              {MachineTypeWords.memory(type.memory_mib)}
            </:col>
            <:col :let={type} label={gettext("Disk")} kind="num">
              {MachineTypeWords.disk(type.disk_gib)}
            </:col>
            <:col :let={type} label={gettext("Architecture")}>{type.arch}</:col>
            <:col :let={type} label={gettext("Virtualization")}>
              {if type.virtualization, do: gettext("Yes"), else: gettext("No")}
            </:col>
            <:col :let={type} label={gettext("Used by")}>
              {used_by(Map.get(@used_by, type.name, 0))}
            </:col>
            <:col :let={type} label={gettext("Pools")}>
              <%!-- The names wrap: on one line, the table is wider than its frame at 1280 px. --%>
              <span id={"machine-type-#{type.name}-pools"} class="whitespace-normal">
                {pools(@serving[type.name])}
              </span>
            </:col>
            <:action :let={type}>
              <.row_menu
                id={"machine-type-#{type.name}-menu"}
                label={gettext("Actions for %{name}", name: type.name)}
              >
                <.menu_item patch={~p"/instance/machine-types/#{type.name}/edit"}>
                  {gettext("Edit")}
                </.menu_item>
                <.menu_item
                  :if={!type.is_default}
                  phx-click="make_default"
                  phx-value-name={type.name}
                >
                  {gettext("Make default")}
                </.menu_item>
                <.menu_item patch={~p"/instance/machine-types/#{type.name}/delete"}>
                  {gettext("Delete…")}
                </.menu_item>
              </.row_menu>
            </:action>
            <:confirm :let={type}>
              <.inline_confirm
                id={"machine-type-#{type.name}-confirm"}
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
                    phx-value-name={type.name}
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
    </Layouts.app>
    """
  end

  defp subtitle,
    do:
      gettext(
        "The machines that runs start on. A workflow runs on the type it picks, else on the workspace's default, else on the instance default."
      )

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

  defp refused_line({{:in_use, uses}, name}),
    do:
      gettext("%{name} cannot be deleted: these workflows use it: %{workflows}.",
        name: name,
        workflows: Enum.map_join(uses, ", ", &use_line/1)
      )

  defp use_line(%{place: place, workflow: nil}),
    do: gettext("%{place}: %{workflow}", place: place, workflow: gettext("Default machine type"))

  defp use_line(%{place: place, workflow: workflow}),
    do: gettext("%{place}: %{workflow}", place: place, workflow: workflow)
end
