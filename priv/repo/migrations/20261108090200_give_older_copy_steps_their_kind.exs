defmodule Apiary.Repo.Migrations.GiveOlderCopyStepsTheirKind do
  use Ecto.Migration

  # A copy step folded before `copy` was a kind of `run_steps` (20261108090000) has no
  # kind, as the fold left any kind outside its list, so the run page would show it as a
  # step of the run. `qory run` sends the copy step with the name "copy work out" (qory,
  # `cmd/hoststep.go`, `textCopyStep`, sent by `cmd/runcopy.go` with the kind `copy`).
  #
  # Up sets the kind to `copy` on each step with no kind and that name. A step with
  # another name, or with a kind, stays as it is.
  #
  # Down changes nothing: the kind `copy` is in the check while 20261108090000 is applied,
  # and its down removes the kind from every copy step.
  def up do
    execute "UPDATE run_steps SET kind = 'copy' WHERE kind IS NULL AND name = 'copy work out'"
  end

  def down, do: :ok
end
