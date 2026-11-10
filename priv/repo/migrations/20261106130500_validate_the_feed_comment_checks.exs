defmodule Apiary.Repo.Migrations.ValidateTheFeedCommentChecks do
  use Ecto.Migration

  # Validates the two checks the migration before this one added NOT VALID: scans that
  # take no lock that blocks writes to `adapter_feed`. Every row takes them, as the checks
  # before took fewer kinds and the same bound for every kind but `comment`. Down leaves
  # the checks as they are; the migration before this one replaces them.
  def up do
    execute "ALTER TABLE adapter_feed VALIDATE CONSTRAINT adapter_feed_kind_check"
    execute "ALTER TABLE adapter_feed VALIDATE CONSTRAINT adapter_feed_data_check"
  end

  def down, do: :ok
end
