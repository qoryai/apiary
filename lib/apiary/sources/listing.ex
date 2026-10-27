defmodule Apiary.Sources.Listing do
  # The bookkeeping of one items listing of a collection (`POST /v1/source-items` with a
  # `listing`), by the listing's id, `external_id`, 1 to 200 characters, unique on its
  # collection. The table and its rules are `20261017143000_keep_source_items`'s.
  #
  # `started_at` is when the adapter began reading the source for it, the same on each
  # part. `parts` are the part numbers that arrived, each once, from 1 to 10,000;
  # `last_part` is the number of the part that said `complete`, at least every part that
  # arrived; `completed_at` is when every part from 1 to `last_part` had arrived, and only
  # a listing with a last part has it. `inserted_at` is when the row was made.
  #
  # A listing is of its collection's organisation, held to it by the composite key.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false
  use Ecto.Schema

  @typedoc "The bookkeeping of an items listing of a collection."
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "source_item_listings" do
    field :external_id, :string
    field :started_at, :utc_datetime
    field :parts, {:array, :integer}
    field :last_part, :integer
    field :completed_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :collection, Apiary.Adapters.Collection
  end
end
