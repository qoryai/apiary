defmodule Apiary.Repo.Migrations.KeepTheConfiguration do
  use Ecto.Migration

  # The settings an instance admin saves in Instance settings › Configuration
  # (`Apiary.InstanceConfig`), in the instance's row of `instance_settings`, used where the
  # variable of the same name in the server's environment is not set, or is blank:
  #
  # `audit_retention_days`, how many days the audit trail keeps an entry, as
  # AUDIT_RETENTION_DAYS sets it: at least 30 here, while the edition's ceiling
  # (`Apiary.Edition.audit_retention_max_days/0`) is checked by the save, and a value above
  # it reads as the ceiling;
  #
  # `audit_address_retention_days`, how many days an entry keeps the address and the client
  # it came from, as AUDIT_ADDRESS_RETENTION_DAYS sets it: at least 1, and read as never
  # longer than the entries are kept;
  #
  # `deletion_grace_days`, the grace period before a deleted workspace or organisation is
  # purged, as DELETION_GRACE_DAYS sets it: 1 to 90;
  #
  # `invitations_per_day`, how many invitations an organisation makes in 24 hours, as
  # INVITATIONS_PER_DAY sets it: at least 1.
  #
  # All NULL until an instance admin saves them, and NULL is the default. No row changes.
  def change do
    alter table(:instance_settings) do
      add :audit_retention_days, :integer
      add :audit_address_retention_days, :integer
      add :deletion_grace_days, :integer
      add :invitations_per_day, :integer
    end

    create constraint(:instance_settings, :instance_settings_audit_retention_days_check,
             check: "audit_retention_days >= 30"
           )

    create constraint(:instance_settings, :instance_settings_audit_address_retention_days_check,
             check: "audit_address_retention_days >= 1"
           )

    create constraint(:instance_settings, :instance_settings_deletion_grace_days_check,
             check: "deletion_grace_days BETWEEN 1 AND 90"
           )

    create constraint(:instance_settings, :instance_settings_invitations_per_day_check,
             check: "invitations_per_day >= 1"
           )
  end
end
