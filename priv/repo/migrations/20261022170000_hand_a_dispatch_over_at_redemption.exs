defmodule Apiary.Repo.Migrations.HandADispatchOverAtRedemption do
  use Ecto.Migration

  # A dispatch is handed over at its first `dispatched`, or at the first redemption of its
  # run's code, which may come before the `dispatched`
  # (`Apiary.Dispatches.Handover`). A dispatch handed over so has no `dispatched_at` yet,
  # so the check keeps the rest: handed over before its `lease_until`, and never stale.
  def up do
    drop constraint(:dispatches, :dispatches_handed_over_check)

    create constraint(:dispatches, :dispatches_handed_over_check,
             check:
               "handed_over_at IS NULL OR (handed_over_at < lease_until AND stale_at IS NULL)"
           )
  end

  def down do
    drop constraint(:dispatches, :dispatches_handed_over_check)

    create constraint(:dispatches, :dispatches_handed_over_check,
             check:
               "handed_over_at IS NULL OR (dispatched_at IS NOT NULL AND " <>
                 "handed_over_at < lease_until AND stale_at IS NULL)"
           )
  end
end
