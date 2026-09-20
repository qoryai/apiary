defmodule Apiary.Runs.Connection do
  @moduledoc """
  The egress of a run to one destination (host, port, path; the path is `""`
  when the events carry none), counted over the run's `ai.qory.run.egress`
  events. A projection: rebuilt from `events`.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "connections" do
    field :host, :string
    field :port, :integer
    field :path, :string, default: ""
    field :method, :string
    field :attempts, :integer, default: 0
    field :allowed, :integer, default: 0
    field :denied, :integer, default: 0
    field :last_decision, :string
    field :last_rule, :string
    field :last_outcome, :string
    field :last_mode, :string
    field :last_path_rule, :string
    field :last_credential, :string
    field :last_request_method, :string
    field :first_seen_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    field :last_sequence, :integer, default: 0

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :hive, Apiary.Organisations.Hive
    belongs_to :run, Apiary.Runs.Run
  end
end
