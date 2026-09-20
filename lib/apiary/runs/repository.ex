defmodule Apiary.Runs.Repository do
  @moduledoc """
  A repository the hive's runs have worked in, created on first sight from a
  run's `forge` and `repository` labels. Unique per hive on forge and path.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "repositories" do
    field :forge, :string
    field :path, :string
    field :first_seen_at, :utc_datetime_usec
    # The repository's own mode of the security policy; nil follows the hive's. Changed
    # through `Apiary.Policy.set_mode/3`.
    field :egress_mode, :string

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :hive, Apiary.Organisations.Hive
    has_many :runs, Apiary.Runs.Run

    timestamps(type: :utc_datetime_usec)
  end
end
