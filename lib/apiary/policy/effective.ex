defmodule Apiary.Policy.Effective do
  @moduledoc """
  The security policy in force for the hive's baseline or for one repository: what
  `Apiary.Policy.Resolution` makes of the rules, and what the document is rendered from.

  `entries` holds one `Apiary.Policy.Entry` per rule that took part, the hive's and the
  repository's, each saying where it came from and whether it is in force. `allow`,
  `paths` and `credentials` are what the document says, in its order.
  """

  alias Apiary.Policy.Entry

  @type t :: %__MODULE__{
          mode: String.t(),
          repository_id: Ecto.UUID.t() | nil,
          entries: [Entry.t()],
          allow: [String.t()],
          paths: %{optional(String.t()) => [String.t()]},
          credentials: [%{required(:name) => String.t(), optional(:argument) => String.t()}]
        }

  defstruct mode: "observe",
            repository_id: nil,
            entries: [],
            allow: [],
            paths: %{},
            credentials: []
end
