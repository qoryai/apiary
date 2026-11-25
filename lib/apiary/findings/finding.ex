defmodule Apiary.Findings.Finding do
  @moduledoc false
  use Ecto.Schema

  # One finding of a work item (`Apiary.Findings`), with its events in the order they were
  # written. The table's comment is in the migration that makes it.

  @typedoc "A finding."
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "findings" do
    field :number, :integer
    field :take_in, :integer
    field :stage_id, :string
    field :source_kind, :string
    field :source_name, :string
    field :severity, :string
    field :place, :map
    field :point, :string
    field :problem, :string
    field :fix, :string
    field :proof, :string
    field :state, :string, default: "open"
    field :closed_by_person, :boolean, default: false
    field :disputed, :boolean, default: false

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :work_item, Apiary.WorkItems.WorkItem
    belongs_to :target, Apiary.Runs.Target
    has_many :events, Apiary.Findings.Event, preload_order: [asc: :position]

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The id a finding is shown and read by: `f` and its number, `f3`."
  @spec id(t | pos_integer) :: String.t()
  def id(%__MODULE__{number: number}), do: id(number)
  def id(number) when is_integer(number), do: "f#{number}"

  @doc "The number of the id `f<number>`, or nil for any other value."
  @spec number(term) :: pos_integer | nil
  def number("f" <> digits) when byte_size(digits) in 1..9 do
    case Integer.parse(digits) do
      {number, ""} when number >= 1 -> if Integer.to_string(number) == digits, do: number
      _other -> nil
    end
  end

  def number(_id), do: nil
end
