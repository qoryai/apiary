defmodule Apiary.Repo.Migrations.KeepTheImageARunStartedIn do
  use Ecto.Migration

  # What a run started in, set at its attach (`Apiary.Runs.Attach`), which its reloads
  # carry as the gateway checks it (`Apiary.Policy.ComposedConfiguration`):
  #
  # - `runs.started_image_from`: where the image came from: `top_level`, the image the run
  #   configuration named beside its `security_policy` (the one in `configured_image`);
  #   `policy`, the image the `security_policy` named; `none`, no image, the gateway's
  #   default. Nil for a run that did not attach since, whose reloads are as they were;
  # - `runs.started_image`: the image, for `top_level` and `policy`; nil for `none` and
  #   for nil.
  #
  # A check holds the two together, and a `top_level` image to `configured_image`.
  # Nothing exists to fill: a run that attached before is answered as it was. Down drops
  # the check and the columns.
  def change do
    alter table(:runs) do
      add :started_image_from, :text
      add :started_image, :text
    end

    create constraint(:runs, :runs_started_image_check,
             check: """
             (started_image_from IS NULL AND started_image IS NULL)
             OR (started_image_from = 'none' AND started_image IS NULL)
             OR (started_image_from = 'policy' AND started_image IS NOT NULL)
             OR (started_image_from = 'top_level' AND started_image IS NOT NULL
                 AND started_image = configured_image)
             """
           )
  end
end
