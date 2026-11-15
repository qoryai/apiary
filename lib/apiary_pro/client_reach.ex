defmodule ApiaryPro.ClientReach do
  @moduledoc """
  An organisation as a person of an operator reaches it through the workspaces the
  operator operates there: the organisation, the person's membership in the operator it
  is listed under, their membership in the organisation when they have one too, and the
  workspaces they reach there, by name: those the operators they belong to operate, and
  those their membership reaches besides. Not stored: what
  `Apiary.Organisations.list_places/1` gives the switcher beside the person's memberships.
  """

  @enforce_keys [:organisation, :operator_membership]
  defstruct organisation: nil,
            organisation_id: nil,
            operator_membership: nil,
            membership: nil,
            workspaces: [],
            workspace_access: []

  @typedoc "An organisation reached through the operators of some of its workspaces."
  @type t :: %__MODULE__{
          organisation: %Apiary.Organisations.Organisation{},
          organisation_id: Ecto.UUID.t(),
          operator_membership: %Apiary.Organisations.Membership{},
          membership: %Apiary.Organisations.Membership{} | nil,
          workspaces: [%Apiary.Organisations.Workspace{}],
          workspace_access: []
        }
end
