defmodule Apiary.Adapters.ConnectionWorkspace do
  # A workspace a `selected` connection to an adapter reaches (`Apiary.Adapters.Connection`,
  # `adapter_connection_workspaces`), one of the connection's organisation. The table and
  # its rules are `20261028170000_keep_the_workspaces_an_adapter_connection_reaches`'s.
  # Written once, as the connection is made (`Apiary.Adapters.Connections.start/4`); the
  # row goes with its connection, with its workspace, and with the workspace's purge.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false
  use Ecto.Schema

  @typedoc "A workspace a connection to an adapter reaches."
  @type t :: %__MODULE__{}

  @primary_key false
  @foreign_key_type :binary_id
  schema "adapter_connection_workspaces" do
    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :connection, Apiary.Adapters.Connection, primary_key: true
    belongs_to :workspace, Apiary.Organisations.Workspace, primary_key: true

    timestamps(type: :utc_datetime_usec)
  end
end
