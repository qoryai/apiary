defmodule Apiary.Repo.Migrations.AddLastHeartbeatAtToAccessKeys do
  use Ecto.Migration

  def change do
    alter table(:access_keys) do
      add :last_heartbeat_at, :utc_datetime_usec
    end
  end
end
