defmodule Mix.Tasks.Apiary.Prune do
  @shortdoc "Deletes the events and log bytes older than each workspace's retention"

  @moduledoc """
  Runs the retention job now, as the nightly `Apiary.Retention.Scheduler` does: for every
  workspace with a retention setting, the runs last heard from before the cut-off lose
  their log bytes, or all their events, in bounded batches (`Apiary.Retention`).

      mix apiary.prune              # prune, record it, print what was pruned
      mix apiary.prune --dry-run    # delete nothing, record nothing, print the same counts
      mix apiary.prune --batch 500  # rows a delete (default 2000)

  Safe beside a running server; when the nightly job or another `mix apiary.prune` is at
  work it says so and does nothing. In a release, where there is no Mix:
  `bin/apiary eval "Apiary.Release.prune()"`, or `"Apiary.Release.prune(dry_run: true)"`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [dry_run: :boolean, batch: :integer])
    Mix.Task.run("app.start")

    case Apiary.Retention.prune_all(Keyword.put(opts, :trigger, "manual")) do
      {:ok, []} ->
        Mix.shell().info("No workspace has a retention setting: nothing to prune.")

      {:ok, results} ->
        Enum.each(results, &Mix.shell().info(Apiary.Retention.sentence(&1)))

      {:error, :locked} ->
        Mix.raise("The retention job is already running on this database.")
    end
  end
end
