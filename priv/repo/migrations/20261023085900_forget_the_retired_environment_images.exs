defmodule Apiary.Repo.Migrations.ForgetTheRetiredEnvironmentImages do
  use Ecto.Migration

  # An environment record retired before `20261023090000_hold_runs_for_their_environment_build`
  # (`retired_at` set: its collection's `environment_ref` went from a value to none) gave
  # its image to no run. That migration takes `retired_at` away and sets `built_ref` to
  # `reported_ref` on every record that keeps an image, so a retired image would serve a
  # run again once its collection's `environment_ref` is that ref
  # (`Apiary.Environments.image_for/2`). This migration runs before it and clears the build
  # of each retired record that keeps one, as `Apiary.Environments.forget_image/3` clears
  # one: `image`, `size`, `commit`, `built_at`, `reported_ref`, the built target and
  # `built_queued_at`. That migration then sets no `built_ref` on it, and the next build of
  # the collection's `environment_ref` for the pool makes an image again. The last failure
  # is left as it is.
  #
  # Where that migration has run already, `retired_at` is gone and this one changes
  # nothing. Down changes nothing: a cleared image does not come back.

  def up do
    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = current_schema() AND table_name = 'environments'
          AND column_name = 'retired_at'
      ) THEN
        EXECUTE 'UPDATE environments SET image = NULL, size = NULL, commit = NULL, '
          'built_at = NULL, reported_ref = NULL, built_target_system = NULL, '
          'built_target_path = NULL, built_queued_at = NULL, updated_at = now() '
          'WHERE retired_at IS NOT NULL AND image IS NOT NULL';
      END IF;
    END
    $$
    """
  end

  def down, do: :ok
end
