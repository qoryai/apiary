defmodule Apiary.Policy.Effective do
  @moduledoc """
  The security policy in force for the workspace's baseline or for one target: what
  `Apiary.Policy.Resolution` makes of the rules, and what the document is rendered from.

  `mode` is the mode in force and `mode_source` where it came from: `:target` when
  the target has a mode of its own, `:workspace` when it follows the workspace's (and for
  the baseline).

  `entries` holds one `Apiary.Policy.Entry` per rule that took part, the workspace's and
  the target's, each saying where it came from and whether it is in force. `allow`,
  `deny`, `paths` and `credentials` are what the document says, in its order: `deny` is
  what the runner denies in either mode, `allow` what it reaches under `enforce`.
  """

  alias Apiary.Policy.Entry

  @type t :: %__MODULE__{
          mode: String.t(),
          mode_source: :workspace | :target,
          target_id: Ecto.UUID.t() | nil,
          entries: [Entry.t()],
          allow: [String.t()],
          deny: [String.t()],
          paths: %{optional(String.t()) => [String.t()]},
          credentials: [%{required(:name) => String.t(), optional(:argument) => String.t()}]
        }

  defstruct mode: "observe",
            mode_source: :workspace,
            target_id: nil,
            entries: [],
            allow: [],
            deny: [],
            paths: %{},
            credentials: []
end
