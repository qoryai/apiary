defmodule Apiary.Repo.Migrations.StoreWhereADeliveryStandsOnItsVersion do
  use Ecto.Migration

  # A version of a type that the process marks `deliver` reaches one adapter, as one
  # `change_request` entry (integration contract, `changes.schema.json`). Where that
  # delivery stands is stored on the version, not in a `deliveries` table, because a version
  # has one target and so one entry:
  #
  # - `delivery`: `sent`, `delivered` or `failed`; nil for a version with no delivery.
  # - `delivery_reply`: the adapter's reply to the entry, a JSON object with its `action`,
  #   `address` and `data` (`changes-submitted.schema.json`); nil until a reply is stored.
  # - `delivery_failure`: why the delivery failed, one of the reasons of a change request in
  #   `changes-failed.schema.json` (`not_permitted`, `unreachable`, `target_gone`,
  #   `too_long`, `refused`), or `invalid` when Qory Apiary's check of the entry against
  #   `changes.schema.json` failed and nothing was sent; nil until a failure is stored.
  # - `delivery_detail`: what failed, nil for none, bounded as `detail` of
  #   `changes-failed.schema.json` is: 1 to 1000 characters on one line. For `invalid`, the
  #   first member of the entry that the check refused (`#/title`); for another failure,
  #   the adapter's `detail`. The check refuses a control character, U+2028 and U+2029;
  #   the schema also refuses a format character (category Cf) other than U+200C and
  #   U+200D, which a Postgres pattern cannot say, so the code that writes the column
  #   checks it.
  # - `delivery_target_id`: the target of the workspace (`targets`) that the entry went to,
  #   by its adapter and collection, nil until the entry is sent and once the target's row
  #   is gone (`ON DELETE SET NULL` of this column alone, as `runs.target_id` does). A
  #   report from an adapter applies only to a version whose target is that adapter's.
  # - `delivery_at`: when the last of these was stored, nil until one is.
  #
  # The columns are nullable with no default, so no existing row changes. The checks are
  # added NOT VALID and take no scan under the lock; `20261120140100` validates them, as
  # `20261117140000` and `20261117140100` did for `decision_id`. No check ties the
  # columns to each other, and none bounds `delivery_reply`: the contract bounds the
  # reply's `data` at 786432 bytes serialized.
  #
  # Rolled back, a version loses its delivery columns and what they stored.
  @failures ~w(not_permitted unreachable target_gone too_long refused invalid)

  def up do
    alter table(:artifact_versions) do
      add :delivery, :text
      add :delivery_reply, :map
      add :delivery_failure, :text
      add :delivery_detail, :text

      add :delivery_target_id,
          references(:targets,
            type: :binary_id,
            with: [workspace_id: :workspace_id],
            on_delete: {:nilify, [:delivery_target_id]}
          )

      add :delivery_at, :utc_datetime_usec
    end

    create constraint(:artifact_versions, :artifact_versions_delivery_check,
             check: "delivery IS NULL OR delivery IN ('sent', 'delivered', 'failed')",
             validate: false
           )

    create constraint(:artifact_versions, :artifact_versions_delivery_reply_check,
             check: "delivery_reply IS NULL OR jsonb_typeof(delivery_reply) = 'object'",
             validate: false
           )

    create constraint(:artifact_versions, :artifact_versions_delivery_detail_check,
             check:
               "delivery_detail IS NULL OR (char_length(delivery_detail) BETWEEN 1 AND 1000 " <>
                 "AND delivery_detail !~ '[\\x01-\\x1f\\x7f-\\x9f\\u2028\\u2029]')",
             validate: false
           )

    create constraint(:artifact_versions, :artifact_versions_delivery_failure_check,
             check:
               "delivery_failure IS NULL OR delivery_failure IN (" <>
                 Enum.map_join(@failures, ", ", &"'#{&1}'") <> ")",
             validate: false
           )
  end

  def down do
    drop constraint(:artifact_versions, :artifact_versions_delivery_failure_check)
    drop constraint(:artifact_versions, :artifact_versions_delivery_detail_check)
    drop constraint(:artifact_versions, :artifact_versions_delivery_reply_check)
    drop constraint(:artifact_versions, :artifact_versions_delivery_check)

    alter table(:artifact_versions) do
      remove :delivery_target_id
      remove :delivery_at
      remove :delivery_detail
      remove :delivery_failure
      remove :delivery_reply
      remove :delivery
    end
  end
end
