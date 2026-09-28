defmodule Apiary.Repo.Migrations.CreateAuditEntries do
  use Ecto.Migration

  # The audit trail: one row per change a person, an access key or the instance made to what
  # the apiary holds, written by the context function in the change's transaction
  # (`Apiary.Audit`). Append-only: nothing updates a row, and only the audit retention job
  # deletes them, by age. The history of the security policy is part of it.
  #
  # The workspace is empty for an organisation's own changes, so its composite key matches
  # simple, not full: a row without a workspace is not checked against `workspaces`. The
  # actor and the subject are ids without a foreign key: a subject may be deleted (a removed
  # member, a revoked invitation), and the entry stays. The checks keep the actor's kind to
  # the three there are, and an id with every actor but the instance.
  #
  # The indexes: an organisation's entries by time, for the Activity page and the retention
  # job; a workspace's by subject and time, the policy page's history among them; the
  # entries that still hold an address or a client, which retention clears sooner than it
  # deletes the entry, so a cleared entry leaves the index; and the entries that name an
  # allowance (`details.allowance_id`, which every invitation's entry does) by allowance and
  # time, for the count of the day's invitations. That one names no action: whichever
  # action counts against an allowance is in it.
  def change do
    create table(:audit_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organisation_id,
          references(:organisations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :workspace_id,
          references(:workspaces,
            type: :binary_id,
            with: [organisation_id: :organisation_id],
            on_delete: :delete_all
          )

      # `person` (a user's id), `access_key` (the key's row id) or `instance` (no id).
      add :actor_kind, :text, null: false
      add :actor_id, :binary_id
      # An action of `Apiary.Access`, such as `member.remove`.
      add :action, :text, null: false
      add :subject_kind, :text, null: false
      add :subject_id, :binary_id
      # The fields the change changed, as they were and as they are; never a secret, never
      # a person's name or email address.
      add :before, :map
      add :after, :map
      # What the entry says beyond them, such as the kind of a policy change.
      add :details, :map
      # From where: the request's address and client, or the job that made the change.
      add :remote_ip, :text
      add :user_agent, :text
      add :worker, :text
      # The transaction's time, in UTC.
      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("timezone('UTC', now())")
    end

    create constraint(:audit_entries, :audit_entries_actor_kind_check,
             check: "actor_kind IN ('person', 'access_key', 'instance')"
           )

    create constraint(:audit_entries, :audit_entries_actor_id_check,
             check: "(actor_kind = 'instance') = (actor_id IS NULL)"
           )

    create index(:audit_entries, [:organisation_id, :inserted_at, :id])
    create index(:audit_entries, [:workspace_id, :subject_id, :inserted_at])

    create index(:audit_entries, [:organisation_id, :inserted_at],
             where: "remote_ip IS NOT NULL OR user_agent IS NOT NULL",
             name: :audit_entries_with_address_index
           )

    create index(:audit_entries, ["(details->>'allowance_id')", :inserted_at],
             where: "details ? 'allowance_id'",
             name: :audit_entries_invitations_by_allowance_index
           )
  end
end
