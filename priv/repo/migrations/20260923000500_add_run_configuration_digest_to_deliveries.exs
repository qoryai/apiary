defmodule Apiary.Repo.Migrations.AddRunConfigurationDigestToDeliveries do
  use Ecto.Migration

  # Expand only. What a batch's `X-Qory-Run-Configuration` said the run holds, per batch;
  # null when the header was absent or not a digest. Deliveries recorded before this
  # migration keep null: the header was not stored then.
  def change do
    alter table(:deliveries) do
      add :run_configuration_digest, :text
    end
  end
end
