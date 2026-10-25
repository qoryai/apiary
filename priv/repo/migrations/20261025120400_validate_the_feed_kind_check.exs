defmodule Apiary.Repo.Migrations.ValidateTheFeedKindCheck do
  use Ecto.Migration

  # Validates the check the migration before this one added NOT VALID: a scan that takes
  # no lock that blocks writes to `adapter_feed`. Every row takes it, as the check before
  # took fewer kinds. Down leaves the check as it is; the migration before this one
  # replaces it.
  def up do
    execute "ALTER TABLE adapter_feed VALIDATE CONSTRAINT adapter_feed_kind_check"
  end

  def down, do: :ok
end
