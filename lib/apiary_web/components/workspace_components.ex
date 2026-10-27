defmodule ApiaryWeb.WorkspaceComponents do
  @moduledoc """
  What a form that creates a workspace shares: its Type field (`type_field/1`), the
  workspace's domain (`Apiary.Lingo.Domain`), which is chosen when the workspace is
  created and fixed after. The workspace set-up page, `/:org/set-up`, has it, and so may
  an edition's form for a new workspace.
  """
  use ApiaryWeb, :html

  alias Apiary.Lingo.Domain

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
  type_field/1 is the Type field: a select with one option per domain, its name and its
  line (`c:Apiary.Lingo.Domain.type_name/0`, `c:Apiary.Lingo.Domain.type_line/0`), and
  none chosen until the person picks one ("Choose a type"). Under it, that the type
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
      type="select"
      label={gettext("Type")}
      prompt={gettext("Choose a type")}
      options={@options}
      hint={@shown_hint}
      size={@size}
    />
    """
  end

  defp options(domains) do
    for domain <- domains do
      {pgettext("workspace type", "%{type} — %{line}",
         type: domain.type_name(),
         line: domain.type_line()
       ), domain.name()}
    end
  end
end
