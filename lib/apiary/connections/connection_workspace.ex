defmodule Apiary.Connections.ConnectionWorkspace do
  @moduledoc """
  A workspace a `selected` connection applies to (`connection_workspaces`), one of the
  connection's organisation. The row goes with its connection and with its workspace.
  Changed only through `Apiary.Connections`.
  """
  use Ecto.Schema

  @typedoc "A workspace of a connection."
  @type t :: %__MODULE__{}

  @primary_key false
  @foreign_key_type :binary_id
  schema "connection_workspaces" do
    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :connection, Apiary.Connections.Connection, primary_key: true
    belongs_to :workspace, Apiary.Organisations.Workspace, primary_key: true

    timestamps(type: :utc_datetime_usec)
  end
end
