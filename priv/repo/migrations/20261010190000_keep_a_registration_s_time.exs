defmodule Apiary.Repo.Migrations.KeepARegistrationSTime do
  use Ecto.Migration

  # `registration_time`, the `time` a run's registration was built at, on the gateway's
  # clock, as its body sent it (`Apiary.Runs.Registration`). With `registered_at`, when this
  # server took it, it gives the clock offset of a run a gateway opened (`Apiary.Runs.Fold`),
  # as the ping's time and arrival gave it. Set only with a registration; nil for a run that
  # did not register. The projector does not fold it, so a rebuild keeps it.
  def change do
    alter table(:runs) do
      add :registration_time, :utc_datetime_usec
    end

    create constraint(:runs, :runs_registration_time_check,
             check: "registration_time IS NULL OR registered_at IS NOT NULL"
           )
  end
end
