defmodule ApiaryPro.ClientReach do
  @moduledoc """
  A client of an operator, as a person of the operator reaches it: the client
  organisation, the person's membership in the operator, their membership in the
  client when they have one too, and the workspaces of the client, every one, by name,
  since an operator's people read every workspace of its clients. Not stored: what
  `Apiary.Organisations.list_places/1` gives the switcher beside the person's memberships.
  """

  @enforce_keys [:organisation, :operator_membership]
  defstruct organisation: nil,
            organisation_id: nil,
            operator_membership: nil,
            membership: nil,
            workspaces: [],
            workspace_access: []

  @typedoc "A client reached through its operator."
  @type t :: %__MODULE__{
          organisation: %Apiary.Organisations.Organisation{},
          organisation_id: Ecto.UUID.t(),
          operator_membership: %Apiary.Organisations.Membership{},
          membership: %Apiary.Organisations.Membership{} | nil,
          workspaces: [%Apiary.Organisations.Workspace{}],
          workspace_access: []
        }
end
