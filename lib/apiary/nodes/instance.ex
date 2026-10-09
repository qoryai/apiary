defmodule Apiary.Nodes.Instance do
  @moduledoc """
  An instance of a node: what a runner using the node's access key reports itself as, by
  the instance id it signs on every request. The id is a **claim**: anyone with the key
  can report any instance, so it serves display, the audit and the instance limit, and
  never authorisation. The row carries no integrity code.

  An instance is the node's, not its key's: `(node_id, instance_id)` is unique, so an
  instance that moves to the node's replacement key stays one instance, and
  `access_key_id` is the key it last used. `name` is what the runner said it is called
  (`X-Qory-Instance-Name`, unsigned), kept only when it matches `name_pattern/0`.
  `first_seen_at` and `last_seen_at` are this server's clock; `cleared_at` and
  `cleared_by_id` say who last cleared it (`Apiary.Nodes.clear_instance/3`).

  Rows are written by `Apiary.Nodes.seen/3` alone, outside any changeset, and pruned by
  `Apiary.Nodes.prune_instances/1`.
  """
  use Ecto.Schema

  @typedoc "An instance of a node."
  @type t :: %__MODULE__{}

  @name_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/
  @max_id 128

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "node_instances" do
    field :instance_id, :string
    field :name, :string
    field :first_seen_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    field :last_runner_version, :string
    field :last_contract_version, :integer
    field :cleared_at, :utc_datetime_usec

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :node, Apiary.Nodes.Node
    belongs_to :access_key, Apiary.AccessKeys.AccessKey
    belongs_to :cleared_by, Apiary.Accounts.User
  end

  @doc """
  name_pattern/0 is what an instance's name must match to be kept: a letter or a digit,
  then up to 63 letters, digits, dots, underscores and hyphens.
  """
  @spec name_pattern() :: Regex.t()
  def name_pattern, do: @name_pattern

  @doc """
  instance_id?/1 says whether `id` can be kept as an instance id: a string of 1 to
  #{@max_id} characters, none of them a control character.
  """
  @spec instance_id?(term) :: boolean
  def instance_id?(id) when is_binary(id) do
    String.valid?(id) and String.length(id) in 1..@max_id and
      not String.match?(id, ~r/[[:cntrl:]]/u)
  end

  def instance_id?(_id), do: false

  @doc "name/1 is `name` when it can be kept as an instance's name, nil otherwise."
  @spec name(term) :: String.t() | nil
  def name(name) when is_binary(name), do: if(Regex.match?(@name_pattern, name), do: name)
  def name(_name), do: nil
end
