defmodule ApiaryWeb.WorkspaceComponents do
  @moduledoc """
  What a form that creates a workspace shares: its Type field (`type_field/1`), the
  workspace's domain (`Apiary.Lingo.Domain`), which is chosen when the workspace is
  created and fixed after, and the preview of the stages a workspace of a type starts
  with (`process_preview/1`). An edition's form for a new workspace may have them.
  """
  use ApiaryWeb, :html

  alias Apiary.Lingo.Domain
  alias ApiaryWeb.SettingsComponents
  alias ApiaryWeb.StagesLive.Canvas

  attr :field, Phoenix.HTML.FormField,
    required: true,
    doc: "the form's field for the domain's name, such as `@form[:domain]`"

  attr :domains, :list,
    default: nil,
    doc:
      "the domains offered, in their order; every domain (`Apiary.Lingo.Domain.choices/0`) by default"

  attr :hint, :string, default: nil, doc: "the line under the field; the core's by default"
  attr :size, :string, default: "md", values: ~w(sm md)

  @doc """
  type_field/1 is the Type field: a choice (`<.input type="choice">`) with one option per
  domain, its name as the title and its line under it
  (`c:Apiary.Lingo.Domain.type_name/0`, `c:Apiary.Lingo.Domain.type_line/0`), and none
  chosen until the person picks one ("Choose a type"). Under it, that the type
  can't be changed after the workspace is created, unless `hint` says otherwise.

      <WorkspaceComponents.type_field field={@form[:domain]} />
  """
  def type_field(assigns) do
    assigns =
      assigns
      |> assign(:options, options(assigns.domains || Domain.choices()))
      |> assign_new(:shown_hint, fn ->
        assigns.hint || gettext("You can't change the type after you create the workspace.")
      end)

    ~H"""
    <.input
      field={@field}
      type="choice"
      label={gettext("Type")}
      prompt={gettext("Choose a type")}
      options={@options}
      hint={@shown_hint}
      size={@size}
    />
    """
  end

  defp options(domains) do
    for domain <- domains,
        do: %{value: domain.name(), title: domain.type_name(), subtitle: domain.type_line()}
  end

  attr :id, :string, required: true

  attr :document, :map,
    required: true,
    doc: "the process document the workspace starts with, a type's newest version"

  attr :workspace, :string, default: nil, doc: "the workspace's name, nil before one is typed"

  @doc """
  process_preview/1 is the stages a new workspace starts with, the newest version of its
  type's default process (`Apiary.Processes.TypeTemplates.newest/1`), on the Stages canvas
  in its view-only mode, whose cards open nothing and send no event, under one line on
  where they change after.

      <WorkspaceComponents.process_preview id="new-preview" document={document} />
  """
  def process_preview(assigns) do
    ~H"""
    <section id={@id} class="grid gap-2">
      <p id={"#{@id}-line"} class="text-[13.5px]/5">{preview_line(@workspace)}</p>
      <Canvas.canvas id={"#{@id}-canvas"} document={@document} mode={:view} selectable={false} />
    </section>
    """
  end

  defp preview_line(name) when is_binary(name) and name != "",
    do:
      gettext(
        "%{workspace} starts with these stages. After you create it, owners and admins can change them in Workspace settings › %{stages}.",
        workspace: name,
        stages: SettingsComponents.stages_label()
      )

  defp preview_line(_none),
    do:
      gettext(
        "The workspace starts with these stages. After you create it, owners and admins can change them in Workspace settings › %{stages}.",
        stages: SettingsComponents.stages_label()
      )
end
