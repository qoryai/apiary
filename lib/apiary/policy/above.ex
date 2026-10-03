defmodule Apiary.Policy.Above do
  @moduledoc """
  What holds above a workspace's policy: the level the edition keeps over its workspaces,
  as `c:Apiary.Edition.above_workspace/1` answers it, or nothing, which is the core's
  answer. The core resolves, renders and shows it without knowing whose it is: the words
  come from `name`, and nothing else of it.

    * `id`, `name`, `slug`: what the level is called, for the pages (the source label and
      the token `source:<slug>`);
    * `rules`: its host rules, each an `Apiary.Policy.Rule` the edition materialises (not
      a row of `policy_rules`), in any order: `Apiary.Policy.Resolution` sorts;
    * `floor`: whether it requires `enforce` in every workspace, so no workspace or target
      may observe;
    * `own_allows`: whether a workspace or a target may allow hosts of its own; off, only
      the level's allows grant, and every lower host allow is listed struck
      (`Apiary.Policy.Entry`'s `reason: :only_above_allows`);
    * `variables`: its variables, each an `Apiary.Variables.Variable` the edition
      materialises (not a row of `variables`), with its `name`, `value` and `locked`: they
      reach every workspace below it, and one it locks is set by no workspace or
      repository. `Apiary.Variables.Resolution` resolves them first in every chain.

  Its denies hold everywhere; its allows reach every workspace and can be narrowed by a
  lower deny, never widened: how they meet the workspace's and a target's rules is
  `Apiary.Policy.Resolution`'s to say.
  """

  alias Apiary.Organisations.Workspace
  alias Apiary.Policy.Rule

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          slug: String.t() | nil,
          rules: [Rule.t()],
          floor: boolean,
          own_allows: boolean,
          variables: [Apiary.Variables.Variable.t()]
        }

  defstruct id: nil,
            name: nil,
            slug: nil,
            rules: [],
            floor: false,
            own_allows: true,
            variables: []

  @doc false
  # What holds above `workspace`, asked of the edition once per operation. A test sets
  # `config :apiary, Apiary.Policy.Above, answer: fun` (`Application.put_env/3`, in a
  # module that is not async) to see what the core makes of a level above it: the
  # configuration is read at each call, as `Apiary.Policy.Activity.cap/0` is.
  @spec for_workspace(%Workspace{}) :: t | nil
  def for_workspace(%Workspace{} = workspace) do
    case Keyword.fetch(Application.get_env(:apiary, __MODULE__, []), :answer) do
      {:ok, fun} when is_function(fun, 1) -> fun.(workspace)
      _ -> Apiary.Edition.above_workspace(workspace)
    end
  end
end
