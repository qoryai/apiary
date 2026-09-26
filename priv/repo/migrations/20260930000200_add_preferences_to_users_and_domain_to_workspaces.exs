defmodule Apiary.Repo.Migrations.AddPreferencesToUsersAndDomainToWorkspaces do
  use Ecto.Migration

  # Expand only. What a page looks like for its reader is decided by two things, kept
  # apart: a person's preferences and a workspace's domain.
  #
  # A person gets a language, a time zone and a skin: English, UTC and the standard skin
  # (the domain's words) until changed. A workspace gets its domain, chosen when it is
  # created; every existing workspace is of the software domain. The values are checked by
  # the application (`Apiary.Accounts.Preferences`, `Apiary.Lingo.Domain`), not by the
  # database: a new language, zone or domain is then a release, never a migration.
  #
  # Each column is NOT NULL with a constant default, which Postgres records in the
  # catalogue without rewriting a row: instant, and every existing row reads the default.
  def change do
    alter table(:users) do
      add :language, :string, null: false, default: "en"
      add :time_zone, :string, null: false, default: "Etc/UTC"
      add :skin, :string, null: false, default: "standard"
    end

    alter table(:workspaces) do
      add :domain, :string, null: false, default: "software"
    end
  end
end
