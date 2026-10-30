defmodule Apiary.Runs.LeakedSecret do
  @moduledoc """
  One secret found in a run's text when Qory Apiary stored it (`Apiary.Runs.LeakedSecrets`):
  its kind (`Apiary.SecretScan`), where it is, and what it belongs to when that was found.
  The row has no secret: `offset` and `length` are the secret's bytes in the stored text,
  read again when the diagnostics document is built.

  `place` is where the text is:

    * `step` and `log`: the run's output, of step `step` or of no step. The secret starts
      in the log chunk whose sequence is `source_sequence`, at byte `offset`, and may
      go on in the chunks of that step after it.
    * `event`: the data of the event whose sequence is `source_sequence`, as
      `Apiary.Runs.LeakedSecrets.event_text/1` writes it.
    * `machine_log` and `release_reason`: the machine log or the release reason of the
      dispatch `dispatch_id`.

  `at` is the time of the output, the event or the release, and, for a machine log,
  when Qory Apiary stored it. `matched_id` is the public id of the access key, run or node
  the secret belongs to (`Apiary.SecretScan.identify/3`).
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "leaked_secrets" do
    field :kind, :string
    field :place, :string
    field :step, :integer
    field :source_sequence, :integer
    field :offset, :integer
    field :length, :integer
    field :matched_id, :string
    field :at, :utc_datetime_usec

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :run, Apiary.Runs.Run
    belongs_to :dispatch, Apiary.Dispatches.Dispatch

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
