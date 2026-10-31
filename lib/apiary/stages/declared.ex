defmodule Apiary.Stages.Declared do
  # Declared is the one place the stage runner (`Apiary.Stages`) reaches the stored
  # snapshot of the workflow names a workspace's harness lists: `snapshot/1` and
  # `record/2`.
  #
  # Transition: `Apiary.Processes.declared_snapshot/1` and `record_declared/2` are built on
  # another branch. Until they are merged, the module these calls go to is configured
  # (`config :apiary, Apiary.Stages.Declared, module`), `Apiary.Processes` by default, and
  # the tests configure a stand-in with the same functions (`Apiary.StagesDeclaredStub`).
  # Once they are merged, these functions call them directly and the setting goes.
  @moduledoc false

  # snapshot/1 is the workflow names the workspace's harness listed when it was last read,
  # with the time of that read: `%{names, read_at}`, nil for no read yet.
  @doc false
  @spec snapshot(struct) :: %{names: [String.t()], read_at: DateTime.t()} | nil
  def snapshot(workspace), do: impl().declared_snapshot(workspace)

  # record/2 stores `names` as the workspace's snapshot, read now.
  @doc false
  @spec record(struct, [String.t()]) :: term
  def record(workspace, names), do: impl().record_declared(workspace, names)

  defp impl, do: Application.get_env(:apiary, __MODULE__, Apiary.Processes)
end
