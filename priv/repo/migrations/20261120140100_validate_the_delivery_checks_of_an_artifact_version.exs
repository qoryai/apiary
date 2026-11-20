defmodule Apiary.Repo.Migrations.ValidateTheDeliveryChecksOfAnArtifactVersion do
  use Ecto.Migration

  # Validates the three delivery checks that the migration before this one added NOT
  # VALID: a scan that takes no lock that blocks writes to `artifact_versions`. Down
  # leaves them as they are; the migration before this one drops them.
  @checks ~w(delivery delivery_reply delivery_failure)

  def up do
    for check <- @checks do
      execute "ALTER TABLE artifact_versions VALIDATE CONSTRAINT artifact_versions_#{check}_check"
    end
  end

  def down, do: :ok
end
