defmodule Apiary.Stages.Withdrawals do
  # The rule for which approvals and confirmations count after a work item goes back to an
  # earlier stage. Every way back writes a `:move` (`Apiary.Stages.GateDecision`) with the
  # stage it lands on, `to_stage_id`: a member's Move, an escalation's Move back, a switch
  # of track, a run's return, a return of Request changes and a take in again.
  #
  # A decision of the work item counts when it was made in the work item's take in and no
  # move of that take in made after it lands on its stage or an earlier one. So a move back
  # to Shape withdraws every approval of Shape and of each later stage, and a later
  # approval counts again. A switch sets the track of the gate before the stage it lands
  # on, so a move withdraws it only when it lands before that stage. Both stages are placed
  # in the process version the move was written under, its `process_version_id`, so two
  # versions that order stages differently (`Apiary.Processes.assign/3`) are never
  # compared. Where the move's version does not have either stage, the place is unknown,
  # and the move withdraws the decision. A move with no `to_stage_id` withdraws nothing.
  #
  # A confirmation of Explore's proposal (`Apiary.WorkItems.Confirmation`) counts when no
  # move of its take in made after it lands on Explore's stage, the stage of the run it
  # confirms, or an earlier one. A run with no stage is Explore's
  # (`Apiary.WorkItems.Explore.at_stage/2`), at the first stage, where a take in starts
  # (`Apiary.Stages.take_in/2`). The run's stage is placed in the move's version too, and
  # an unknown place withdraws the confirmation, as it withdraws a decision.
  #
  # A withdrawn decision or confirmation stays in its table: nothing deletes or changes it.
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias Apiary.WorkItems.{Confirmation, WorkItem}

  # The SQL of the place of the stage `stage` in the process version `version`, from 1;
  # NULL for a stage the version does not have.
  position = fn version, stage ->
    "(SELECT s.o FROM process_versions AS pv, " <>
      "jsonb_array_elements(pv.document -> 'stages') WITH ORDINALITY AS s(stage, o) " <>
      "WHERE pv.id = #{version} AND s.stage ->> 'id' = #{stage})"
  end

  # Whether a move made after the decision withdraws it. The arguments are the decision's
  # work item, take in and time, its `escalation_id`, its `stage_id`, and its
  # `to_stage_id`. A comparison with an unknown place is NULL, which COALESCE turns into a
  # withdrawal.
  @withdrawn """
  EXISTS (
    SELECT 1 FROM gate_decisions AS m
    WHERE m.work_item_id = ? AND m.take_in = ? AND m.kind = 'move' AND m.inserted_at > ?
      AND m.to_stage_id IS NOT NULL
      AND COALESCE(
        #{position.("m.process_version_id", "m.to_stage_id")} <=
          CASE WHEN ? IS NULL THEN #{position.("m.process_version_id", "?")}
            ELSE #{position.("m.process_version_id", "?")} - 1 END,
        true
      )
  )
  """

  # Whether a move made after the confirmation withdraws it, with the confirmation's
  # columns in place of the marks. A run with no stage is at place 1.
  confirmation = """
  EXISTS (
    SELECT 1 FROM dispatch_runs AS wr
    JOIN gate_decisions AS wm ON wm.work_item_id = wr.work_item_id AND wm.take_in = wr.take_in
    WHERE wr.work_item_id = {work_item_id} AND wr.take_in = {take_in}
      AND wr.attempt = {attempt} AND wm.kind = 'move' AND wm.inserted_at > {confirmed_at}
      AND wm.to_stage_id IS NOT NULL
      AND COALESCE(
        #{position.("wm.process_version_id", "wm.to_stage_id")} <=
          CASE WHEN wr.stage_id IS NULL THEN 1
            ELSE #{position.("wm.process_version_id", "wr.stage_id")} END,
        true
      )
  )
  """

  fill = fn columns ->
    Enum.reduce(columns, confirmation, fn {key, value}, sql ->
      String.replace(sql, "{#{key}}", value)
    end)
  end

  @confirmation_withdrawn fill.(
                            work_item_id: "?",
                            take_in: "?",
                            attempt: "?",
                            confirmed_at: "?"
                          )
  @confirmation_withdrawn_c fill.(
                              work_item_id: "c.work_item_id",
                              take_in: "c.take_in",
                              attempt: "c.attempt",
                              confirmed_at: "c.confirmed_at"
                            )

  # counted/2 is `query`, whose gate decisions are bound as `:decision`, with only the
  # decisions of `work_item` that count: made in its take in and withdrawn by no later
  # move. None counts for a work item with no take in.
  @doc false
  @spec counted(Ecto.Queryable.t(), WorkItem.t()) :: Ecto.Query.t()
  def counted(query, %WorkItem{take_in: nil}), do: from(_ in query, where: false)

  def counted(query, %WorkItem{take_in: take_in}) do
    from [decision: d] in query,
      where: d.take_in == ^take_in,
      where:
        not fragment(
          @withdrawn,
          d.work_item_id,
          d.take_in,
          d.inserted_at,
          d.escalation_id,
          d.stage_id,
          d.to_stage_id
        )
  end

  # confirmations/0 is the query of the confirmations that count, bound as
  # `:confirmation`.
  @doc false
  @spec confirmations() :: Ecto.Query.t()
  def confirmations do
    from c in Confirmation,
      as: :confirmation,
      where:
        not fragment(
          @confirmation_withdrawn,
          c.work_item_id,
          c.take_in,
          c.attempt,
          c.confirmed_at
        )
  end

  # confirmation_withdrawn_sql/0 is the rule of `confirmations/0` as SQL text, for a query
  # written as SQL text with the confirmation as `c`: true where a move withdraws it.
  @doc false
  @spec confirmation_withdrawn_sql() :: String.t()
  def confirmation_withdrawn_sql, do: @confirmation_withdrawn_c
end
