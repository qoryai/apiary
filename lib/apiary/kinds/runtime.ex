defmodule Apiary.Kinds.Runtime do
  @moduledoc """
  Runtime is one runtime of the catalogue (`Apiary.Kinds.Runtimes`): its fields named as
  the contract's `runtimes.json` names them, the declarations (`declares`) and groups as
  JSON maps with string keys. `model` is the runtime's `model` member as a JSON map, or
  nil for a runtime without one; its `formats` are the model API formats the runtime
  sends.
  """
  @enforce_keys [:name, :title]
  defstruct name: nil,
            title: nil,
            reserves: [],
            denies: [],
            credential_files: [],
            declares: [],
            one_of: [],
            model: nil

  @typedoc "A runtime of the catalogue."
  @type t :: %__MODULE__{
          name: String.t(),
          title: String.t(),
          reserves: [String.t()],
          denies: [String.t()],
          credential_files: [String.t()],
          declares: [map],
          one_of: [map],
          model: map | nil
        }
end
