defmodule Apiary.Explore.Outcome do
  # Outcome is what a run of Explore gave once it ended, read from the artifacts it
  # pushed during the run through the run API, never from an event of the run:
  #
  #   * `:questions` when the newest questions of its work item have a question that waits
  #     for an answer (`Apiary.Explore.Questions`), whatever else the run did: open
  #     questions come before a proposal and before a run that stopped;
  #   * `:proposal` when a run of its take in, this one or an earlier one, pushed a
  #     version of the work item's `proposal`, and the run did not stop: its registered
  #     run did not exit failed, lost or cancelled, as the stage runner reads a run that
  #     stopped (`Apiary.Stages`);
  #   * `:none` otherwise.
  #
  # A run of a workflow other than Explore's (`Apiary.Stages.explore_run?/1`) gives
  # `:none`: its stage reads its artifacts itself. With the workflow model off no run can
  # push an artifact, as the run API answers 404, so every run gives `:none`.
  #
  # `Apiary.Dispatches.Settle` keeps the outcome on the run of the queue when it ends, and
  # `Apiary.WorkItems.Explore` reads it from there.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias Apiary.Artifacts.{Artifact, Version}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Explore.Questions
  alias Apiary.Repo
  alias Apiary.WorkItems.WorkItem

  @typedoc "What a run of Explore gave."
  @type t :: :questions | :proposal | :none

  # at_end/1 is what the run of the queue `run`, which ended, gave (the moduledoc).
  @doc false
  @spec at_end(DispatchRun.t()) :: t
  def at_end(%DispatchRun{work_item_id: work_item_id} = run) when is_binary(work_item_id) do
    with true <- Apiary.Stages.explore_run?(run),
         %WorkItem{} = work_item <- Repo.get(WorkItem, work_item_id) do
      cond do
        Questions.open?(work_item) -> :questions
        not stopped?(run) and proposal?(run) -> :proposal
        true -> :none
      end
    else
      _other -> :none
    end
  end

  def at_end(%DispatchRun{}), do: :none

  defp stopped?(%DispatchRun{id: id}),
    do:
      Repo.exists?(
        from r in Apiary.Runs.Run,
          where: r.dispatch_run_id == ^id and r.exit_state in ["failed", "lost", "cancelled"]
      )

  # Whether a run of the take in of `run`, up to it, pushed a version of the proposal.
  defp proposal?(%DispatchRun{work_item_id: id, take_in: take_in, attempt: attempt}) do
    Repo.exists?(
      from v in Version,
        join: a in Artifact,
        on: a.id == v.artifact_id,
        join: d in DispatchRun,
        on: d.id == v.run_id,
        where: a.work_item_id == ^id and a.type == "proposal",
        where: d.work_item_id == ^id and d.take_in == ^take_in and d.attempt <= ^attempt
    )
  end
end
