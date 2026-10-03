defmodule Apiary.Kinds.Runtime do
  @moduledoc """
  Runtime is one runtime of the catalogue (`Apiary.Kinds.Runtimes`): its fields as the
  contract's `runtimes.json` has them, the declarations and groups as JSON maps with
  string keys.
  """
  @enforce_keys [:name, :title]
  defstruct name: nil,
            title: nil,
            declares: [],
            one_of: [],
            reserves: [],
            denies: [],
            credential_files: []

  @typedoc "A runtime of the catalogue."
  @type t :: %__MODULE__{
          name: String.t(),
          title: String.t(),
          declares: [map],
          one_of: [map],
          reserves: [String.t()],
          denies: [String.t()],
          credential_files: [String.t()]
        }
end
