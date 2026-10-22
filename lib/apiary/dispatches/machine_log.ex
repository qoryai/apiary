defmodule Apiary.Dispatches.MachineLog do
  # The record of a dispatch's machine log, at most one per dispatch: the text is the file
  # `storage_key` in the folder of `Apiary.Dispatches.MachineLogStore`, the dispatch's
  # public id. `byte_size` is the text's size in bytes, `truncated` whether the starter
  # cut the log to its last part, and `uploaded_at` when Qory Apiary stored it. The run
  # it belongs to is the dispatch's run of the queue (`Apiary.Dispatches.DispatchRun`).
  #
  # Left out of the documentation at `/docs` (`@moduledoc false`), as the dispatches are.
  @moduledoc false
  use Ecto.Schema

  @typedoc "The record of a dispatch's machine log."
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "dispatch_machine_logs" do
    field :storage_key, :string
    field :byte_size, :integer
    field :truncated, :boolean, default: false
    field :uploaded_at, :utc_datetime_usec

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :dispatch, Apiary.Dispatches.Dispatch
  end
end
