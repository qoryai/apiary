defmodule Apiary.Runs.SessionChunk do
  @moduledoc """
  One chunk of the transcript of a run's runtime session: the decoded bytes of one
  `dev.qory.session.transcript` event, keyed by the event's sequence, with the session's
  number, the runtime's session id, the file's path and the chunk's offset in the file
  (`Apiary.Runs.Transcript`). A projection of the events, kept after the retention
  deletes them, until the run's work item is closed or undone (`Apiary.Retention`).
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "session_chunks" do
    field :sequence, :integer
    field :session, :integer
    field :session_id, :string
    field :path, :string
    field :offset, :integer
    field :bytes, :binary, redact: true

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :run, Apiary.Runs.Run
  end
end
