defmodule Apiary.Repo.Migrations.LetAVersionHaveAnAnswerAsItsDecision do
  use Ecto.Migration

  # A run's version may have as its `decision` a member's answer to a run's question
  # (`an_…`) or the comment of Run another round (`rc_…`), beside a decision at a gate
  # (`gd_…`) and an escalation (`es_…`): `Apiary.Stages.Notes`. The two new ids are made
  # from the member's move (`Apiary.PublicId.derive/2`), in the same shape.
  #
  # The check is dropped and added again NOT VALID, so adding it takes no scan of
  # `artifact_versions` under its lock; the migration after this one validates it. Every
  # stored `decision_id` is `gd_…` or `es_…`, which the new check allows.
  @id "[0-9a-hjkmnp-tv-z]{16}"

  def up do
    drop constraint(:artifact_versions, :artifact_versions_decision_id_check)

    create constraint(:artifact_versions, :artifact_versions_decision_id_check,
             check: "decision_id IS NULL OR decision_id ~ '^(gd|es|an|rc)_#{@id}$'",
             validate: false
           )
  end

  # Rolled back, a version whose `decision` is an answer or a comment of Run another round
  # loses it.
  def down do
    drop constraint(:artifact_versions, :artifact_versions_decision_id_check)

    execute "UPDATE artifact_versions SET decision_id = NULL " <>
              "WHERE decision_id !~ '^(gd|es)_#{@id}$'"

    create constraint(:artifact_versions, :artifact_versions_decision_id_check,
             check: "decision_id IS NULL OR decision_id ~ '^(gd|es)_#{@id}$'",
             validate: false
           )
  end
end
