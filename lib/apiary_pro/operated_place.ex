defmodule ApiaryPro.OperatedPlace do
  @moduledoc """
  An organisation as a person of an operator reaches it through the workspaces the
  operator operates there: the organisation, the person's membership in the organisation
  when they have one too, and the workspaces they reach there, by name: those the
  operators they belong to operate, and those their membership reaches besides; and
  `operated`, the workspaces the operators operate, each as `{operator_id, workspace}`.
  Not stored: what `Apiary.Organisations.list_places/1` gives the switcher beside the
  person's memberships.
  """

  @enforce_keys [:organisation]
  defstruct organisation: nil,
            organisation_id: nil,
            membership: nil,
            workspaces: [],
            operated: [],
            workspace_access: []

  @typedoc "An organisation reached through the operators of some of its workspaces."
  @type t :: %__MODULE__{
          organisation: %Apiary.Organisations.Organisation{},
          organisation_id: Ecto.UUID.t(),
          membership: %Apiary.Organisations.Membership{} | nil,
          workspaces: [%Apiary.Organisations.Workspace{}],
          operated: [{Ecto.UUID.t(), %Apiary.Organisations.Workspace{}}],
          workspace_access: []
        }
end
