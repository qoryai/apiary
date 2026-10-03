defmodule Apiary.Connections.Target do
  @moduledoc """
  A repository a connection applies to (`connection_targets`), and the ways an
  integration is used there: `credential` ("Calls its API") and `tool` ("Uses it as a tool
  (MCP)"), or nil, every way the integration offers. A runtime's and a service's rows have
  no ways. Changed only through `Apiary.Connections`.
  """
  use Ecto.Schema

  @typedoc "A repository of a connection."
  @type t :: %__MODULE__{}

  @primary_key false
  @foreign_key_type :binary_id
  schema "connection_targets" do
    field :ways, {:array, :string}

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :connection, Apiary.Connections.Connection, primary_key: true
    belongs_to :target, Apiary.Runs.Target, primary_key: true

    timestamps(type: :utc_datetime_usec)
  end
end
