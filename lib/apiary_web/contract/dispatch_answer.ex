defmodule ApiaryWeb.Contract.DispatchAnswer do
  @moduledoc false

  # The parts the answers of the provisioner contract share, the claim's
  # (`ApiaryWeb.Contract.PoolClaimController`) and the handover's
  # (`ApiaryWeb.Contract.HandoverController`): a run's target and its work item, as
  # `definitions.schema.json` has them, what a run of a step may do on its target, present
  # together with the target or left out with it, and a time in UTC to the whole second.

  alias Apiary.WorkItems

  # what_for/1 is the access, the target and the work item of an explore run, the access
  # and the target of a prebuild's collection with no work item: `{name, value}` members,
  # in order. An explore run whose work item has no target has neither access nor target.
  @doc false
  @spec what_for(map) :: [{String.t(), String.t() | Jason.OrderedObject.t()}]
  def what_for(%{work_item: nil, collection: collection, run: run}),
    do: reach(run.step, target_of(collection))

  def what_for(%{work_item: work_item, run: run}),
    do: reach(run.step, target_of(work_item)) ++ [{"work_item", work_item(work_item)}]

  # handover_body/1 is the handover answer's JSON (`handover-answer.schema.json`), its
  # members in the schema's order: `revision`, the run's `run_id`, its `run_key`, its
  # `step`, the workspace's `domain`, the run's `target` (nil for none), its `work_item`
  # (nil for a prebuild), its `run_settings` (nil for none, a `Jason.OrderedObject`) and
  # its `inputs`. The controller sends it, and the handover measures it
  # (`Apiary.Dispatches.Handover`), so both read one encoding.
  @doc false
  @spec handover_body(%{
          revision: pos_integer,
          run_id: String.t(),
          run_key: String.t(),
          step: String.t(),
          domain: String.t(),
          target: %{system: String.t(), path: String.t()} | nil,
          work_item: Apiary.WorkItems.WorkItem.t() | nil,
          run_settings: Jason.OrderedObject.t() | nil,
          inputs: Jason.OrderedObject.t()
        }) :: binary
  def handover_body(%{} = answer) do
    work_item = if answer.work_item, do: [{"work_item", work_item(answer.work_item)}], else: []
    run_settings = if answer.run_settings, do: [{"run_settings", answer.run_settings}], else: []

    Jason.encode!(
      Jason.OrderedObject.new(
        [
          {"version", 1},
          {"revision", answer.revision},
          {"run_id", answer.run_id},
          {"run_key", answer.run_key},
          {"step", answer.step},
          {"domain", answer.domain}
        ] ++
          reach(answer.step, answer.target) ++
          work_item ++ run_settings ++ [{"inputs", answer.inputs}]
      )
    )
  end

  # reach/2 is the `access` of a run of `step` and its `target`, both present for a run
  # with a target and both left out for one without, as the contract requires them
  # together: `{name, value}` members, in order.
  @doc false
  @spec reach(String.t(), %{system: String.t(), path: String.t()} | nil) ::
          [{String.t(), String.t() | Jason.OrderedObject.t()}]
  def reach(_step, nil), do: []

  def reach(step, %{system: system, path: path}),
    do: [{"access", access(step)}, {"target", target(system, path)}]

  defp target_of(%{target_system: nil}), do: nil
  defp target_of(%{target_system: system, target_path: path}), do: %{system: system, path: path}

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
