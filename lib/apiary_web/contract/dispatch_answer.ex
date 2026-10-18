defmodule ApiaryWeb.Contract.DispatchAnswer do
  @moduledoc false

  # The parts the answers of the provisioner contract share, the claim's
  # (`ApiaryWeb.Contract.PoolClaimController`) and the handover's
  # (`ApiaryWeb.Contract.HandoverController`): a run's target and its work item, as
  # `definitions.schema.json` has them, what a run of a step may do on its target, and a
  # time in UTC to the whole second.

  alias Apiary.WorkItems

  # what_for/1 is the target and the work item of an explore run, the target of a
  # prebuild's collection with no work item: `{name, value}` members, in order.
  @doc false
  @spec what_for(map) :: [{String.t(), Jason.OrderedObject.t()}]
  def what_for(%{work_item: nil, collection: collection}),
    do: [{"target", target(collection.target_system, collection.target_path)}]

  def what_for(%{work_item: work_item}) do
    [
      {"target", target(work_item.target_system, work_item.target_path)},
      {"work_item", work_item(work_item)}
    ]
  end

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
