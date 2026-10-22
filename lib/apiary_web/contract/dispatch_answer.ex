defmodule ApiaryWeb.Contract.DispatchAnswer do
  @moduledoc false

  # The parts of the answers of the provisioner contract: the machine type of the claim
  # answer (`ApiaryWeb.Contract.PoolClaimController`) from the machines file
  # (`Apiary.Dispatches.MachinesFile`); a run's documents, with its target and its work
  # item, as `definitions.schema.json` has them, what a run of a step may do on its
  # target, present together with the target or left out with it, and the run's stack
  # (`Apiary.Stacks.for_run/3`); and a time in UTC to the whole second.

  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Dispatches.MachinesFile
  alias Apiary.{Stacks, WorkItems}

  # machine/1 is the `machine` member of the claim answer of a run of the workspace of the
  # node pool's key `access_key`, which `Apiary.AccessKeys.fetch_for_verification/1`
  # loads with its organisation and its workspace: the machine type of the workspace's
  # entry in the machines file, or no member.
  @doc false
  @spec machine(AccessKey.t()) :: [{String.t(), String.t()}]
  def machine(%AccessKey{organisation: organisation, workspace: workspace}) do
    case MachinesFile.machine(organisation.slug, workspace.slug) do
      nil -> []
      machine -> [{"machine", machine}]
    end
  end

  # documents/1 is a run's documents (the run contract's `documents.schema.json`), in
  # this order: the run's `step`, the
  # workspace's `domain`, the run's `access` and `target` (none for a run without a
  # target), its `work_item` (none for a prebuild), its `run_settings` (none for none, a
  # `Jason.OrderedObject`), its `stack`, `workflow` and `harness_hidden` (none for none
  # and for a prebuild, `Apiary.Stacks.for_run/3`) and its `inputs`. The claim measures
  # them (`Apiary.Dispatches.Handover`).
  @doc false
  @spec documents(%{
          required(:step) => String.t(),
          required(:domain) => String.t(),
          required(:target) => %{system: String.t(), path: String.t()} | nil,
          required(:work_item) => Apiary.WorkItems.WorkItem.t() | nil,
          required(:run_settings) => Jason.OrderedObject.t() | nil,
          required(:stack) => Stacks.run_stack() | nil,
          required(:inputs) => Jason.OrderedObject.t(),
          optional(atom) => term
        }) :: Jason.OrderedObject.t()
  def documents(%{step: step} = run) do
    work_item = if run.work_item, do: [{"work_item", work_item(run.work_item)}], else: []
    run_settings = if run.run_settings, do: [{"run_settings", run.run_settings}], else: []

    Jason.OrderedObject.new(
      [{"step", step}, {"domain", run.domain}] ++
        reach(step, run.target) ++
        work_item ++ run_settings ++ stack(run.stack) ++ [{"inputs", run.inputs}]
    )
  end

  # The `stack`, the `workflow` and `harness_hidden` of a run's documents, all three or
  # none.
  defp stack(nil), do: []

  defp stack(%{stack: stack, workflow: workflow, harness_hidden: hidden}),
    do: [{"stack", stack}, {"workflow", workflow}, {"harness_hidden", hidden}]

  # reach/2 is the `access` of a run of `step` and its `target`, both present for a run
  # with a target and both left out for one without, as the contract requires them
  # together: `{name, value}` members, in order.
  @doc false
  @spec reach(String.t(), %{system: String.t(), path: String.t()} | nil) ::
          [{String.t(), String.t() | Jason.OrderedObject.t()}]
  def reach(_step, nil), do: []

  def reach(step, %{system: system, path: path}),
    do: [{"access", access(step)}, {"target", target(system, path)}]

  # target/2 is a target of `system` and `path`.
  @doc false
  @spec target(String.t(), String.t()) :: Jason.OrderedObject.t()
  def target(system, path), do: Jason.OrderedObject.new([{"system", system}, {"path", path}])

  # work_item/1 is a run's work item: its public id, its address and its title.
  @doc false
  @spec work_item(Apiary.WorkItems.WorkItem.t()) :: Jason.OrderedObject.t()
  def work_item(work_item) do
    Jason.OrderedObject.new([
      {"id", work_item.public_id},
      {"url", WorkItems.stable_url(work_item)},
      {"title", work_item.title}
    ])
  end

  # access/1 is what a run of a step may do on its target: an explore run and a prebuild
  # read.
  @doc false
  @spec access(String.t()) :: String.t()
  def access("explore"), do: "read"
  def access("prebuild"), do: "read"

  # time/1 is `at` in UTC to the whole second.
  @doc false
  @spec time(DateTime.t()) :: String.t()
  def time(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
