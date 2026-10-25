defmodule Apiary.Repo.Migrations.KeepTheChannelOfAConnection do
  use Ecto.Migration

  # A run's connections (`Apiary.Runs.Connection`) come from two proxies of the run:
  # `session`, the run's proxy, which every session, host work and setup goes through, and
  # `stack`, the stack proxy, which qory's fetch of the harness definition goes through
  # before the run's first session joins (`channel` `stack` on `dev.qory.run.egress`).
  # The stack proxy decides by the run configuration's `stack_hosts`, never by the
  # workspace's rules, so one host reached on both channels is two rows: `channel` joins
  # the unique key.
  #
  # Rolled back, the column and the key are as before. The roll back raises an error while
  # a connection has the channel `stack`, since its row and a `session` row of the same
  # destination would break the older key.
  def up do
    alter table(:connections) do
      add :channel, :text, null: false, default: "session"
    end

    create constraint(:connections, :connections_channel_check,
             check: "channel IN ('session', 'stack')"
           )

    drop unique_index(:connections, [:run_id, :host, :port, :path])
    create unique_index(:connections, [:run_id, :channel, :host, :port, :path])
  end

  def down do
    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM connections WHERE channel = 'stack') THEN
        RAISE EXCEPTION 'Delete the connections of the channel stack, then roll back again: the key before this migration has no channel, so a stack row and a session row of one destination would break it'
          USING ERRCODE = 'check_violation';
      END IF;
    END
    $$
    """

    drop unique_index(:connections, [:run_id, :channel, :host, :port, :path])
    create unique_index(:connections, [:run_id, :host, :port, :path])
    drop constraint(:connections, :connections_channel_check)

    alter table(:connections) do
      remove :channel
    end
  end
end
