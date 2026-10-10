defmodule Apiary.Repo.Migrations.RegisterARun do
  use Ecto.Migration

  # A run's registration (`Apiary.Runs.Registration`), on its own row of `runs`:
  #
  # `registered_at`, when the run registered; `registration_labels` and `registration_about`,
  # its labels and `about` as the registration's body sent them; `registration_digest`, the
  # SHA-256 of the body's bytes, 32 bytes, by which a repeat of the same registration is
  # told from another.
  #
  # All NULL for a run that did not register, every existing row among them, and all set
  # for one that did. The projector does not fold them, so a rebuild keeps them.
  def change do
    alter table(:runs) do
      add :registered_at, :utc_datetime_usec
      add :registration_labels, :map
      add :registration_about, :map
      add :registration_digest, :binary
    end

    create constraint(:runs, :runs_registration_check,
             check:
               "(registered_at IS NULL AND registration_labels IS NULL AND " <>
                 "registration_about IS NULL AND registration_digest IS NULL) OR " <>
                 "(registered_at IS NOT NULL AND registration_labels IS NOT NULL AND " <>
                 "registration_about IS NOT NULL AND registration_digest IS NOT NULL)"
           )

    create constraint(:runs, :runs_registration_digest_length,
             check: "octet_length(registration_digest) = 32"
           )
  end
end
