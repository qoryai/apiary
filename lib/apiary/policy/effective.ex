defmodule Apiary.Policy.Effective do
  @moduledoc """
  The security policy in force for the workspace's baseline or for one target: what
  `Apiary.Policy.Resolution` makes of the rules, and what the document is rendered from.

  `mode` is the mode in force and `mode_source` where it came from: `:organisation` when
  the level above the workspace requires it (`Apiary.Policy.Above`'s `floor`), `:target`
  when the target has a mode of its own, `:workspace` when it follows the workspace's
  (and for the baseline).

  `entries` holds one `Apiary.Policy.Entry` per rule that took part, the level above's,
  the workspace's and the target's, each saying where it came from and whether it is in
  force. `allow`, `deny` and `paths` are what the document says, in its order: `deny` is what the runner denies in either mode, `allow` what it reaches under
  `enforce`. `above` is the level above the workspace the rules were resolved under, nil
  where there is none or where it carries variables only (`Apiary.Policy.Above`'s
  `policy: false`).
  """

  alias Apiary.Policy.{Above, Entry}

  @type t :: %__MODULE__{
          mode: String.t(),
          mode_source: :workspace | :target | :organisation,
          target_id: Ecto.UUID.t() | nil,
          above: Above.t() | nil,
          entries: [Entry.t()],
          allow: [String.t()],
          deny: [String.t()],
          paths: %{optional(String.t()) => [String.t()]}
        }

  defstruct mode: "observe",
            mode_source: :workspace,
            target_id: nil,
            above: nil,
            entries: [],
            allow: [],
            deny: [],
            paths: %{}
end
