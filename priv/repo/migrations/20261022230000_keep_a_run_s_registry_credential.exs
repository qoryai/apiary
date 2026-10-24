defmodule Apiary.Repo.Migrations.KeepARunSRegistryCredential do
  use Ecto.Migration

  # With the `registry` feature: the registry credential of a run and the instance's
  # registry name.
  #
  # - `runs.registry_credential_sha256`, the SHA-256 of the random secret the secrets
  #   request sealed for the run's gateway last (`Apiary.Registry.Credential`), 32 bytes,
  #   NULL until then. The secret itself is stored nowhere.
  # - `instance_settings.registry_instance`, the instance's name in the registry's image
  #   names (`Apiary.InstanceConfig.registry_instance/0`): 16 lower-case hex digits, made
  #   once, NULL until then.
  #
  # The check on `runs` is added NOT VALID, so adding it takes no scan of the table under
  # its lock; the next migration validates it.
  def change do
    alter table(:runs) do
      add :registry_credential_sha256, :binary
    end

    create constraint(:runs, :runs_registry_credential_check,
             check:
               "registry_credential_sha256 IS NULL OR octet_length(registry_credential_sha256) = 32",
             validate: false
           )

    alter table(:instance_settings) do
      add :registry_instance, :text
    end

    create constraint(:instance_settings, :instance_settings_registry_instance_format,
             check: "registry_instance IS NULL OR registry_instance ~ '^[0-9a-f]{16}$'"
           )
  end
end
