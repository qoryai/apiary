defmodule Apiary.Nodes.Node do
  @moduledoc """
  A node of a workspace: a place that runs. Its `kind` is `:node`, one permanent machine
  that runs one instance at a time, or `:pool`, a fleet of short-lived instances that run
  up to its `instance_limit`, or any number when the limit is nil. The kind is chosen
  when the node is made (`create_changeset/2`) and never changes: `changeset/2` does not
  cast it, and the database refuses an update that changes it.

  `public_id` is the node's name in a URL, `/:org/:workspace/nodes/:public_id`: `nd_` for
  a node or `np_` for a pool, then sixteen lowercase Crockford base32 characters, made
  once with the node (`Apiary.PublicId`). A path built with
  `~p"/\#{organisation}/\#{workspace}/nodes/\#{node}"` uses it.

  A node is deleted softly: `deleted_at` and `deleted_by_id` are set
  (`Apiary.Nodes.delete_node/2`), it leaves every page, and its name is free again.
  `instance_limit_refused` and `instance_limit_refused_at` (the starts refused at the
  instance limit), and `instance_ids_over_bound` and `instance_ids_over_bound_at` (the
  instances not recorded past the bound of new ones a day), are written outside any
  changeset.
  """
  use Ecto.Schema
  use Gettext, backend: ApiaryWeb.Gettext
  import Ecto.Changeset

  @typedoc "A node or a node pool of a workspace."
  @type t :: %__MODULE__{}

  @typedoc "A node's kind: one permanent machine, or a pool of short-lived instances."
  @type kind :: :node | :pool

  @kinds [:node, :pool]
  @max_limit 10_000
  @prefixes %{node: "nd", pool: "np"}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Phoenix.Param, key: :public_id}
  schema "nodes" do
    field :public_id, :string
    field :name, :string
    field :kind, Ecto.Enum, values: @kinds
    field :instance_limit, :integer
    field :instance_limit_refused, :integer, default: 0
    field :instance_limit_refused_at, :utc_datetime_usec
    field :instance_ids_over_bound, :integer, default: 0
    field :instance_ids_over_bound_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :created_by, Apiary.Accounts.User
    belongs_to :deleted_by, Apiary.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @doc "kinds/0 is the kinds a node may be made as."
  @spec kinds() :: [kind]
  def kinds, do: @kinds

  @doc "max_limit/0 is the highest instance limit a pool may have."
  @spec max_limit() :: pos_integer
  def max_limit, do: @max_limit

  @doc """
  create_changeset/2 is the changeset of a new node: its kind, which nothing changes
  after, then its name and limit as `changeset/2` checks them, and a public id of its
  kind.
  """
  @spec create_changeset(t, map) :: Ecto.Changeset.t()
  def create_changeset(node, attrs) do
    node
    |> cast(attrs, [:kind])
    |> validate_required([:kind])
    |> changeset(attrs)
    |> put_public_id()
  end

  @doc """
  changeset/2 is the changeset of a node's name and, for a pool, its instance limit: the
  name 1 to 80 characters without control characters, unique among the workspace's
  nodes in use; a pool's limit empty, for none, or 1 to `max_limit/0`. A node's limit is
  1 whatever `attrs` says. The kind is never cast.
  """
  @spec changeset(t, map) :: Ecto.Changeset.t()
  def changeset(node, attrs) do
    node
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_format(:name, ~r/\A[^[:cntrl:]]+\z/u,
      message: dgettext_noop("errors", "must not contain control characters")
    )
    |> unique_constraint([:organisation_id, :workspace_id, :name],
      name: :nodes_live_name_index,
      error_key: :name,
      message: dgettext_noop("errors", "is already the name of a node in this workspace")
    )
    |> put_limit(attrs)
  end

  # A node runs one instance at a time; a pool runs up to its limit, or any number.
  defp put_limit(changeset, attrs) do
    case get_field(changeset, :kind) do
      :node ->
        put_change(changeset, :instance_limit, 1)

      :pool ->
        changeset
        |> cast(attrs, [:instance_limit])
        |> validate_number(:instance_limit,
          greater_than_or_equal_to: 1,
          less_than_or_equal_to: @max_limit
        )

      nil ->
        changeset
    end
  end

  defp put_public_id(changeset) do
    case get_field(changeset, :kind) do
      kind when kind in @kinds ->
        put_change(changeset, :public_id, Apiary.PublicId.generate(Map.fetch!(@prefixes, kind)))

      nil ->
        changeset
    end
  end
end
