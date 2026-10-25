defmodule Apiary.Harnesses.Assignment do
  # An instance assignment of a harness source: the runs of the organisation
  # `organisation_id`, or of every organisation when `every_organisation` is true and
  # `organisation_id` is nil, may use the instance's links for `source`
  # (`Apiary.Harnesses.allowed?/3`). `source` is the harness source as it is in a harness
  # document, with text keys: `git` and `ref`, and at most one of `path`, `stack` and
  # `module`. A source with none of the three is the root of the remote source. Only an
  # instance admin creates and deletes one (`Apiary.Harnesses`). The table and its rules
  # are `20261025140100_keep_the_instance_s_harness_assignments`'s.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false
  use Ecto.Schema

  @typedoc "An instance assignment of a harness source."
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "harness_assignments" do
    field :every_organisation, :boolean
    field :source, :map

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :created_by, Apiary.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end
end
