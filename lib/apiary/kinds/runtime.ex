defmodule Apiary.Kinds.Runtime do
  @moduledoc """
  Runtime is one runtime of the catalogue (`Apiary.Kinds.Runtimes`): its fields named as
  the contract's `runtimes.json` names them, the declarations (`declares`) and groups as
  JSON maps with string keys. `model` is the runtime's `model` member as a JSON map, or
  nil for a runtime without one; its `formats` are the model API formats the runtime
  sends.

  Three fields are read out of `model`, empty for a runtime without them:

    * `model_keys`, its `keys`: the variables the runtime reads a model key from, each
      `%{"format" => format, "auth" => auth, "variable" => name}`, `auth` as the
      contract's `auth.schema.json` has it, with `"oauth" => true` for an OAuth token;
    * `effort_values`, the `values` of its `effort.run`: the effort values the runtime
      accepts for a run;
    * `endpoint_variable`, the `variable` of its `endpoint`: where the runtime reads the
      base URL of its model API from, or nil.
  """
  @enforce_keys [:name, :title]
  defstruct name: nil,
            title: nil,
            reserves: [],
            denies: [],
            credential_files: [],
            declares: [],
            one_of: [],
            model: nil,
            model_keys: [],
            effort_values: [],
            endpoint_variable: nil

  @typedoc "A runtime of the catalogue."
  @type t :: %__MODULE__{
          name: String.t(),
          title: String.t(),
          reserves: [String.t()],
          denies: [String.t()],
          credential_files: [String.t()],
          declares: [map],
          one_of: [map],
          model: map | nil,
          model_keys: [%{String.t() => String.t() | map}],
          effort_values: [String.t()],
          endpoint_variable: String.t() | nil
        }
end
