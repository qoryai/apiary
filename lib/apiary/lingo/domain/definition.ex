defmodule Apiary.Lingo.Domain.Definition do
  @moduledoc """
  The definition of a workspace type: what a domain's `c:Apiary.Lingo.Domain.definition/0`
  returns. A workspace stores the `key` of the type it was made from, in
  `workspaces.type`, beside its domain.

    * `key`: the type's key, `<provider>.<name>`, such as `qory.software`.
    * `provided_by`: who provides the type. Every type in the code is Qory's, `"qory"`.
    * `harness`: the harness a workspace of the type starts with, as a harness document's
      source has it, with text keys: `git`, `ref` and `stack`. Its `ref` is the commit of
      the newest version of the Qory harness this release ships (`qory_harness/0`).
    * `model_plan` and `node_pool`: nil in every type in the code.

  `qory_harness/0` is the list of Qory harness versions this release ships: the newest
  version, the stacks the Qory harness exports, and the named versions. A harness choice
  of the Qory harness at "latest" takes the newest version at each run, so an upgrade of
  Qory Apiary moves it to the newest version of the upgrade.
  """

  @enforce_keys [:key, :provided_by, :harness]
  defstruct [:key, :provided_by, :harness, model_plan: nil, node_pool: nil]

  @type t :: %__MODULE__{
          key: String.t(),
          provided_by: String.t(),
          harness: %{required(String.t()) => String.t()},
          model_plan: nil,
          node_pool: nil
        }

  @typedoc """
  The Qory harness versions a release ships: its repository's address (`git`), the stack
  a workspace starts with (`stack`), the stacks the Qory harness exports (`stacks`), the
  full commit id of the newest version (`latest`), and the named versions, each a name
  and its full commit id (`named`).
  """
  @type qory_harness :: %{
          git: String.t(),
          stack: String.t(),
          stacks: [String.t()],
          latest: String.t(),
          named: [%{name: String.t(), commit: String.t()}]
        }

  # The Qory harness versions this release ships. The newest is a commit of the `main`
  # branch of the Qory harness, by its full commit id. This release ships no named
  # versions: the Qory harness has no tags.
  @qory_harness %{
    git: "https://github.com/qoryai/harness",
    stack: "core",
    stacks: ["core"],
    latest: "fe3b3ab4a02cd7c57d9efa16bbaf498d5f5de305",
    named: []
  }

  @doc """
  The definition of a type Qory provides, with the key `key`: the Qory harness at the
  newest version this release ships, and no model plan or node pool.
  """
  @spec qory(String.t()) :: t
  def qory("qory." <> _name = key),
    do: %__MODULE__{
      key: key,
      provided_by: "qory",
      harness: %{
        "git" => @qory_harness.git,
        "ref" => @qory_harness.latest,
        "stack" => @qory_harness.stack
      }
    }

  @doc "The Qory harness versions this release ships (`t:qory_harness/0`)."
  @spec qory_harness() :: qory_harness
  def qory_harness, do: @qory_harness

  @doc """
  The full commit id of a version of the Qory harness: `:latest` for the newest, or a
  name among `qory_harness/0`'s named versions. Nil for a name this release does not ship.
  """
  @spec qory_commit(:latest | String.t()) :: String.t() | nil
  def qory_commit(:latest), do: @qory_harness.latest

  def qory_commit(name) when is_binary(name) do
    Enum.find_value(@qory_harness.named, fn
      %{name: ^name, commit: commit} -> commit
      _other -> nil
    end)
  end
end
