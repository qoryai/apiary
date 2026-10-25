defmodule ApiaryWeb.Contract.DispatchAnswer do
  @moduledoc false

  # The parts of the answers of the provisioner contract: a run's documents, with its
  # target and its work item, as `definitions.schema.json` has them, what a run may do on
  # its target, present together with the target or left out with it, and the run's
  # harness members (`Apiary.Harnesses.WalkJob`); and a time in UTC to the whole second.

  alias Apiary.WorkItems

  @typedoc """
  The harness members of an explore run's documents, from its harness walk: the target's
  version, nil for none; the workflow and `harness_hidden`; the access level the walk
  resolved; and the stacks' harness document, nil where the target's harness file
  applies.
  """
  @type harness :: %{
          target_version: String.t() | nil,
          workflow: String.t(),
          harness_hidden: boolean,
          access: :read | :write,
          harness: map | nil
        }

  # documents/1 is a run's documents (the run contract's `documents.schema.json`), in
  # this order: the run's `step`, the workspace's `domain`, the run's `access` and
  # `target` (none for a run without a target), its `target_version`, its `work_item`
  # (none for a prebuild), its `run_settings` (none for none, a `Jason.OrderedObject`),
  # its `workflow`, `harness_hidden` and `harness` (`harness/1`) and its `inputs`. The
  # claim measures them (`Apiary.Dispatches.Handover`).
  @doc false
  @spec documents(%{
          required(:step) => String.t(),
          required(:domain) => String.t(),
          required(:target) => %{system: String.t(), path: String.t()} | nil,
          required(:work_item) => Apiary.WorkItems.WorkItem.t() | nil,
          required(:run_settings) => Jason.OrderedObject.t() | nil,
          required(:harness) => harness | nil,
          required(:inputs) => Jason.OrderedObject.t(),
          optional(atom) => term
        }) :: Jason.OrderedObject.t()
  def documents(%{step: step} = run) do
    work_item = if run.work_item, do: [{"work_item", work_item(run.work_item)}], else: []
    run_settings = if run.run_settings, do: [{"run_settings", run.run_settings}], else: []

    Jason.OrderedObject.new(
      [{"step", step}, {"domain", run.domain}] ++
        reach(run.harness, run.target) ++
        target_version(run.harness) ++
        work_item ++ run_settings ++ harness(run.harness) ++ [{"inputs", run.inputs}]
    )
  end

  defp target_version(%{target_version: version}) when is_binary(version),
    do: [{"target_version", version}]

  defp target_version(_harness), do: []

  # The `workflow` and `harness_hidden` of a run's documents, both or neither, and its
  # `harness`, `{"harness": document}`, where the stacks' document applies: the run's
  # target has no harness file whose harness section has `extends` or lists modules
  # without it, or the run has no `target_version`. The machine composes the target's
  # file at `target_version` where `harness` is absent.
  defp harness(nil), do: []

  defp harness(%{workflow: workflow, harness_hidden: hidden, harness: document}) do
    harness = if document, do: [{"harness", %{"harness" => document}}], else: []
    [{"workflow", workflow}, {"harness_hidden", hidden}] ++ harness
  end

  # reach/2 is the `access` of a run with the harness members `harness` (`access/1`) and
  # its `target`, both present for a run with a target and both left out for one
  # without, as the contract requires them together: `{name, value}` members, in order.
  @doc false
  @spec reach(harness | nil, %{system: String.t(), path: String.t()} | nil) ::
          [{String.t(), String.t() | Jason.OrderedObject.t()}]
  def reach(_harness, nil), do: []

  def reach(harness, %{system: system, path: path}),
    do: [{"access", access(harness)}, {"target", target(system, path)}]

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

  # access/1 is what a run with the harness members `harness` may do on its target: the
  # level its harness walk resolved, `read` or `write`. A run with no harness members, a
  # prebuild or an explore run with no workflow, reads.
  @doc false
  @spec access(harness | nil) :: String.t()
  def access(%{access: level}) when level in [:read, :write], do: Atom.to_string(level)
  def access(_none), do: "read"

  # time/1 is `at` in UTC to the whole second.
  @doc false
  @spec time(DateTime.t()) :: String.t()
  def time(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
