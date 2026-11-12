defmodule ApiaryPro.HarnessAssignments.Assignment do
  # An operator's assignment of a harness source to one of its clients: the runs of the
  # client `organisation_id` may use the operator's links `operator_id` for the source
  # (`ApiaryPro.HarnessAssignments.source_allowed?/3`). The source is as it is in a
  # harness document: `git` and `ref`, and at most one of `path`, `stack` and `module`;
  # one with none of the three is the root of the remote source. The table and its rules
  # are `20261025170000_create_operator_harness_assignments`'s.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false
  use Ecto.Schema

  @typedoc "An operator's assignment of a harness source to a client."
  @type t :: %__MODULE__{}

  # The keys that narrow a source to a part of its remote source.
  @narrowing ~w(path stack module)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "operator_harness_assignments" do
    field :git, :string
    field :ref, :string
    field :path, :string
    field :stack, :string
    field :module, :string

    belongs_to :operator, Apiary.Organisations.Organisation
    belongs_to :organisation, Apiary.Organisations.Organisation

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  # narrowing/0 is the keys that narrow a source: `path`, `stack` and `module`.
  @spec narrowing() :: [String.t()]
  def narrowing, do: @narrowing

  @doc false
  # source/1 is the source of `assignment` as a harness document has it: a map with text
  # keys, `git` and `ref` and the narrowing key that is set, if any.
  @spec source(t) :: %{String.t() => String.t()}
  def source(%__MODULE__{} = assignment) do
    for key <- ~w(git ref) ++ @narrowing,
        text = Map.fetch!(assignment, String.to_existing_atom(key)),
        not is_nil(text),
        into: %{},
        do: {key, text}
  end
end
