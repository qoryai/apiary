defmodule Apiary.Kinds.Runtime do
  @moduledoc """
  Runtime is one runtime of the catalogue (`Apiary.Kinds.Runtimes`): its fields named as
  the contract's `runtimes.json` names them, the declarations (`declares`) and groups as
  JSON maps with string keys.
  """
  @enforce_keys [:name, :title]
  defstruct name: nil,
            title: nil,
            reserves: [],
            denies: [],
            credential_files: [],
            declares: [],
            one_of: []

  @typedoc "A runtime of the catalogue."
  @type t :: %__MODULE__{
          name: String.t(),
          title: String.t(),
          reserves: [String.t()],
          denies: [String.t()],
          credential_files: [String.t()],
          declares: [map],
          one_of: [map]
        }
end
