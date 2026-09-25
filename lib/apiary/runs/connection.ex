defmodule Apiary.Runs.Connection do
  @moduledoc """
  The egress of a run to one destination (host, port, path; the path is `""`
  when the events carry none), counted over the run's `dev.qory.run.egress`
  events. A projection: rebuilt from `events`.

  The `last_*` columns are those of the attempt with the highest sequence. `last_tool` is
  the name of the tool whose host the last attempt was for, when the proxy decided it by
  its path for a host a tool serves, and `last_status` the status the host or the tool
  answered it with; both are nil when the event did not say. The last attempt was a tool
  invocation when it names a tool and was allowed (`Apiary.Runs.tool_invocation?/2`).
  """
  use Ecto.Schema

  @typedoc "One destination of one run."
  @type t :: %__MODULE__{}

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
    field :last_tool, :string
    field :last_status, :integer
    field :first_seen_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    field :last_sequence, :integer, default: 0

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :hive, Apiary.Organisations.Hive
    belongs_to :run, Apiary.Runs.Run
  end
end
