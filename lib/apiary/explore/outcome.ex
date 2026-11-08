defmodule Apiary.Explore.Outcome do
  # Outcome is what a run of Explore gave once it ended, read from the artifacts it
  # pushed during the run through the run API, never from an event of the run:
  #
  #   * `:questions` when the newest questions of its work item have a question of its
  #     take in that waits for an answer (`Apiary.Explore.Questions.open_in_take_in/2`),
  #     whatever else the run did: open questions come before a proposal and before a run
  #     that stopped. A question left open in an earlier take in does not count;
  #   * `:none` when the run ended by its exit and its newest `verdict` named `main` is
  #     `escalate` (`Apiary.Stages.reported_verdict/1`): its stage escalates, so no
  #     proposal of the take in is at the gate for a confirmation, also not one an earlier
  #     run pushed. A verdict other than `escalate` counts as none;
  #   * `:proposal` when a run of its take in, this one or an earlier one, pushed a
  #     version of the work item's `proposal` named `main`, the one Explore reads
  #     (`Apiary.WorkItems.Explore.proposal/2`), and the run did not stop: its registered
  #     run did not exit failed, lost or cancelled, as the stage runner reads a run that
  #     stopped (`Apiary.Stages`);
  #   * `:none` otherwise.
  #
  # nil when the newest questions cannot be read (`Apiary.Explore.Questions.current/1`),
  # when the store cannot read the file of the run's newest verdict
  # (`Apiary.Stages.reported_verdict/1`), or when whether the run is a run of Explore is
  # not known yet (`Apiary.Stages.known_explore/1`): what the run gave is not known yet,
  # so `Apiary.Dispatches.Settle` stores nothing and its sweep reads the run again, rather
  # than keep `proposal` or `none` while questions wait or a verdict escalates.
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
  @spec at_end(DispatchRun.t()) :: t | nil
  def at_end(%DispatchRun{work_item_id: work_item_id} = run) when is_binary(work_item_id) do
    case Apiary.Stages.known_explore(run) do
      %DispatchRun{explore: true} = run -> explore_at_end(run, work_item_id)
      %DispatchRun{explore: false} -> :none
      nil -> nil
    end
  end

  def at_end(%DispatchRun{}), do: :none

  defp explore_at_end(run, work_item_id) do
    with %WorkItem{} = work_item <- Repo.get(WorkItem, work_item_id),
         {:ok, questions} <- Questions.current(work_item) do
      if open?(questions, run), do: :questions, else: without_questions(run)
    else
      {:error, :store_unavailable} -> nil
      _other -> :none
    end
  end

  defp open?({_version, document}, %DispatchRun{work_item_id: id, take_in: take_in}),
    do: Questions.open_in_take_in(document, Questions.take_in_runs(id, take_in)) != []

  defp open?(nil, _run), do: false

  # What a run with no open question gave: nil where the store cannot read its verdict.
  defp without_questions(run) do
    case Apiary.Stages.reported_verdict(run) do
      {:error, :store_unavailable} -> nil
      {:verdict, :escalate, _points} -> :none
      _none_or_other -> if not stopped?(run) and proposal?(run), do: :proposal, else: :none
    end
  end

  defp stopped?(%DispatchRun{id: id}),
    do:
      Repo.exists?(
        from r in Apiary.Runs.Run,
          where: r.dispatch_run_id == ^id and r.exit_state in ["failed", "lost", "cancelled"]
      )

  # Whether a run of the take in of `run`, up to it, pushed a version of the proposal
  # named `main`.
  defp proposal?(%DispatchRun{work_item_id: id, take_in: take_in, attempt: attempt}) do
    Repo.exists?(
      from v in Version,
        join: a in Artifact,
        on: a.id == v.artifact_id,
        join: d in DispatchRun,
        on: d.id == v.run_id,
        where: a.work_item_id == ^id and a.type == "proposal" and a.name == "main",
        where: d.work_item_id == ^id and d.take_in == ^take_in and d.attempt <= ^attempt
    )
  end
end
