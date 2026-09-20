defmodule Mix.Tasks.Apiary.Rebuild do
  @shortdoc "Projects runs again from their events, in batches"

  @moduledoc """
  Projects runs again from their events: what fills the columns a release adds to the
  projection on the rows that were projected before it.

      mix apiary.rebuild              # the runs that need it
      mix apiary.rebuild --all        # every run
      mix apiary.rebuild --batch 50   # runs read at a time (default 100)

  Batched, idempotent and safe beside a running server (`Apiary.Runs.Rebuild`). In a
  release, where there is no Mix: `bin/apiary eval "Apiary.Release.rebuild()"`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [all: :boolean, batch: :integer])
    Mix.Task.run("app.start")

    %{rebuilt: rebuilt, failed: failed} = Apiary.Runs.Rebuild.run(opts)
    Mix.shell().info("Rebuilt #{rebuilt} runs, #{failed} failed.")
    if failed > 0, do: Mix.raise("#{failed} runs could not be rebuilt: see the log")
  end
end
