defmodule Mix.Tasks.Apiary.Policy.Rerender do
  @shortdoc "Renders every workspace's run configurations again through today's resolution"

  @moduledoc """
  Renders the run configurations of every managed workspace again, the baseline and every
  target with rules or a mode of its own, through today's resolution and in the
  workspace's lock: what an upgrade that changed what a render says needs once. A holder
  whose bytes change gets a new version and a `rerendered` row in its history, no change
  of the rules; unchanged bytes write nothing, so the task can be run again at any time.
  Runs in flight take a new version within a heartbeat, as after any change.

      mix apiary.policy.rerender

  Safe beside a running server. In a release, where there is no Mix:
  `bin/apiary eval "Apiary.Release.policy_rerender()"`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    %{workspaces: workspaces, versions: versions} = Apiary.Policy.rerender_all()
    Mix.shell().info("Rendered #{workspaces} workspaces again: #{versions} new versions.")
  end
end
