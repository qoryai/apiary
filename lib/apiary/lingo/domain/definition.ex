defmodule Apiary.Lingo.Domain.Definition do
  @moduledoc """
  The definition of a workspace type: what a domain's `c:Apiary.Lingo.Domain.definition/0`
  returns. A workspace stores the `key` of the type it was made from, in
  `workspaces.type`, beside its domain.

    * `key`: the type's key, `<provider>.<name>`, such as `qory.software`.
    * `provided_by`: who provides the type. Every type in the code is Qory's, `"qory"`.
    * `harness`: the harness a workspace of the type starts with, as a harness document's
      source has it, with text keys: `git`, `ref` and `stack`. It is the Qory harness
      (Apiary.Harnesses.Qory) at its default branch, `main`: a run reads the commit the
      branch is at when the run starts.
    * `model_plan` and `node_pool`: nil in every type in the code.
  """

  alias Apiary.Harnesses.Qory

  @enforce_keys [:key, :provided_by, :harness]
  defstruct [:key, :provided_by, :harness, model_plan: nil, node_pool: nil]

  @type t :: %__MODULE__{
          key: String.t(),
          provided_by: String.t(),
          harness: %{required(String.t()) => String.t()},
          model_plan: nil,
          node_pool: nil
        }

  @doc """
  The definition of a type Qory provides, with the key `key`: the Qory harness
  (Apiary.Harnesses.Qory) at its default branch and default stack, and no model plan
  or node pool.
  """
  @spec qory(String.t()) :: t
  def qory("qory." <> _name = key),
    do: %__MODULE__{
      key: key,
      provided_by: "qory",
      harness: %{
        "git" => Qory.git(),
        "ref" => Qory.default_branch(),
        "stack" => Qory.default_stack()
      }
    }
end
