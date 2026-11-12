defmodule ApiaryProWeb.OrganisationComponents do
  @moduledoc """
  What the pages that create an organisation share: the sign-up, a person's New
  organisation and Instance settings › Organisations › New.

  `kind_field/1` is the choice of what is created, an organisation or an operator, as the
  core's choice field (`ApiaryWeb.CoreComponents.input/1`, `type="choice"`).
  `new_organisation_steps/0` is the steps list of the two New organisation pages, in the
  core's set-up frame (`ApiaryWeb.SetUpComponents.frame/1`): the core's list has no
  step for an organisation made from a page of the console, so the edition lists Your
  organisation. The steps of the workspace's flow are set up inside the workspace.
  """
  use Phoenix.Component
  use Gettext, backend: ApiaryProWeb.Gettext

  import ApiaryWeb.CoreComponents, only: [input: 1]

  attr :field, Phoenix.HTML.FormField,
    required: true,
    doc: "the form's `kind` field, which holds \"organisation\" or \"operator\""

  @doc """
  kind_field/1 is the Kind field: Organisation and Operator, each with a line on what it
  creates, and a prompt until one is chosen.
  """
  def kind_field(assigns) do
    ~H"""
    <.input
      field={@field}
      type="choice"
      label={gettext("Kind")}
      prompt={gettext("Choose a kind")}
      options={[
        %{
          value: "organisation",
          title: gettext("Organisation"),
          subtitle: gettext("For a team that works in workspaces.")
        },
        %{
          value: "operator",
          title: gettext("Operator"),
          subtitle: gettext("Creates and runs organisations for clients.")
        }
      ]}
      required
    />
    """
  end

  @doc """
  new_organisation_steps/0 is the steps list of a New organisation page
  (`t:Apiary.Edition.set_up_step/0`): Your organisation, current, alone. The organisation
  has no workspace yet: the person creates the first one on its overview.
  """
  @spec new_organisation_steps() :: [Apiary.Edition.set_up_step()]
  def new_organisation_steps do
    [
      %{
        id: :organisation,
        label: gettext("Your organisation"),
        group: nil,
        state: :current,
        path: nil,
        note: nil,
        progress: :organisation
      }
    ]
  end
end
