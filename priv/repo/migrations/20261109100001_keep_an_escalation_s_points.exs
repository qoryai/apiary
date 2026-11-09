defmodule Apiary.Repo.Migrations.KeepAnEscalationSPoints do
  use Ecto.Migration

  # `escalations.points` replaces `escalations.gaps`: what a person reads in the block
  # "What the run needs from you", a JSON array of `{text, action, question?}` objects,
  # with `action` `answer` or `run_again`. A run writes them in its verdict
  # (`verdict.schema.json`), and Qory Apiary writes one for a cause it sets itself. Nothing
  # is released, so the gaps of an earlier escalation are dropped, not copied.
  def change do
    alter table(:escalations) do
      remove :gaps, :text
      add :points, :jsonb, null: false, default: fragment("'[]'::jsonb")
    end
  end
end
