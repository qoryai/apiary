defmodule Apiary.Repo.Migrations.KeepWhenTheInstanceSConnectionsWereReviewed do
  use Ecto.Migration

  # `connections_reviewed_at`: when an instance admin finished or skipped the last step of
  # the instance's connections (`/instance/set-up`, `Apiary.Setup`); NULL before, and
  # while it is NULL an instance admin who signs in is sent there. No row is filled in: an
  # instance set up before has its admin go through the steps once.
  def change do
    alter table(:instance_settings) do
      add :connections_reviewed_at, :utc_datetime_usec
    end
  end
end
