defmodule Apiary.Repo.Migrations.KeepARunSVariables do
  use Ecto.Migration

  # `registration_variables`, the run variables Qory set for a run of a workspace's queue
  # when it registered the run (`Apiary.Runs.Run`): each name with its value, given to
  # the run after its run configuration's last member at its attach and at every reload,
  # under the stored configuration's digest. Written once with the registration and never
  # changed; NULL for every other run. The projector does not fold it, so a rebuild
  # keeps it.
  #
  # NULL for every row there already, and adding a column with no default rewrites no
  # row.
  def change do
    alter table(:runs) do
      add :registration_variables, :map
    end

    create constraint(:runs, :runs_registration_variables_check,
             check: "registration_variables IS NULL OR registered_at IS NOT NULL"
           )
  end
end
