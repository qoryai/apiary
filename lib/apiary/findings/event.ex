defmodule Apiary.Findings.Event do
  @moduledoc false
  use Ecto.Schema

  # One event of a finding's history (`Apiary.Findings`). Rows are only inserted: the
  # table's trigger refuses an update and a delete (the migration that makes it).

  @typedoc "An event of a finding."
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "finding_events" do
    field :position, :integer
    field :kind, :string
    field :round, :integer
    field :stage_id, :string
    field :actor_kind, :string
    field :actor_name, :string
    field :run_id, :binary_id
    field :user_id, :binary_id
    field :version, :string
    field :reason, :string
    field :inserted_at, :utc_datetime_usec

    belongs_to :finding, Apiary.Findings.Finding
  end
end
