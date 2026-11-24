defmodule Apiary.Repo.Migrations.AddTargetRemovedToTheDeliveryFailures do
  use Ecto.Migration

  # `delivery_failure` of `artifact_versions` takes a second value of Qory Apiary beside
  # `invalid`: `target_removed`, the version's target row was deleted before the entry
  # was sent, so nothing was sent.
  #
  # The check is added NOT VALID, so adding it takes no scan of `artifact_versions` under
  # its lock; the next migration validates it. Rolled back, the check takes the six values
  # again, NOT VALID as well, so the rollback takes no scan under the lock either, and a
  # version that has `target_removed` keeps it.
  @failures ~w(not_permitted unreachable target_gone too_long refused invalid)

  def up do
    drop constraint(:artifact_versions, :artifact_versions_delivery_failure_check)
    create_check(@failures ++ ["target_removed"])
  end

  def down do
    drop constraint(:artifact_versions, :artifact_versions_delivery_failure_check)
    create_check(@failures)
  end

  defp create_check(failures) do
    create constraint(:artifact_versions, :artifact_versions_delivery_failure_check,
             check:
               "delivery_failure IS NULL OR delivery_failure IN (" <>
                 Enum.map_join(failures, ", ", &"'#{&1}'") <> ")",
             validate: false
           )
  end
end
