defmodule ApiaryWeb.Contract.DispatchAnswer do
  @moduledoc false

  # The parts of the answers of the provisioner contract: a run's documents, with its
  # target and its subject, as `definitions.schema.json` has them, what a run may do on
  # its target, present together with the target or left out with it, and the run's
  # harness members (`Apiary.Harnesses.WalkJob`); and a time in UTC to the whole second.

  alias Apiary.WorkItems

  # The characters a prose line of the integration contract refuses
  # (`description.schema.json`, `$defs.line`).
  @not_in_line ~r/[\x{0}-\x{1F}\x{7F}-\x{9F}\x{AD}\x{61C}\x{180E}\x{200B}\x{200E}\x{200F}\x{2028}\x{2029}\x{202A}-\x{202E}\x{2060}-\x{2064}\x{2066}-\x{2069}\x{FEFF}\x{FFF9}-\x{FFFB}]/u
  # A title of spaces alone, or empty, which `draft_title` refuses.
  @blank ~r/\A[\x{20}\x{A0}\x{1680}\x{2000}-\x{200A}\x{202F}\x{205F}\x{3000}]*\z/u

  @typedoc """
  The harness members of an explore run's documents, from its harness walk: the target's
  version, nil for none; the workflow and `harness_hidden`; the access level the walk
  resolved, lowered by the run's stage entry; and the harness document the walk took, nil
  where the target's harness file applies.
  """
  @type harness :: %{
          required(:target_version) => String.t() | nil,
          required(:workflow) => String.t(),
          required(:harness_hidden) => boolean,
          required(:access) => :read | :write_no_push | :write,
          required(:harness) => map | nil
        }

  # documents/1 is a run's documents (the run contract's `documents.schema.json`), in
  # this order: the run's `step`, the workspace's `domain`, the run's `access` and
  # `target` (none for a run without a target), its `target_version`, its `subject`, the
  # run's work item (none for a prebuild), its `trigger` (`trigger/1`), its
  # `run_settings` (a `Jason.OrderedObject`; every run of the step workflow has them,
  # `Apiary.Dispatches.RunSettings`, and a prebuild none),
  # the members about its first session, `time_limit_minutes`, `shared_run` and
  # `type_settings`, each where present (`:session`, `{name, value}` members, none for a
  # prebuild), its `workflow`, `harness_hidden` and `harness` (`harness/1`), a
  # prebuild's destinations, `image_destination` and then `environment_destination` or
  # `environment_image`, and
  # `largest_prebuilt_image_bytes` where it has one (`:destinations`, `{name, value}`
  # members, none for any other run), and its `inputs`. The claim measures them
  # (`Apiary.Dispatches.Handover`).
  @doc false
  @spec documents(%{
          required(:step) => String.t(),
          required(:domain) => String.t(),
          required(:target) => Apiary.Lingo.Domain.target() | nil,
          required(:work_item) => Apiary.WorkItems.WorkItem.t() | nil,
          required(:run_settings) => Jason.OrderedObject.t() | nil,
          required(:harness) => harness | nil,
          required(:inputs) => Jason.OrderedObject.t(),
          optional(:session) => [{String.t(), pos_integer | boolean | map}],
          optional(:destinations) => [{String.t(), String.t() | pos_integer}],
          optional(atom) => term
        }) :: Jason.OrderedObject.t()
  def documents(%{step: step} = run) do
    subject = if run.work_item, do: [{"subject", subject(run.work_item)}], else: []
    run_settings = if run.run_settings, do: [{"run_settings", run.run_settings}], else: []
    destinations = Map.get(run, :destinations, [])

    Jason.OrderedObject.new(
      [{"step", step}, {"domain", run.domain}] ++
        reach(run.harness, run.target) ++
        target_version(run.harness) ++
        subject ++
        trigger(run) ++
        run_settings ++
        Map.get(run, :session, []) ++
        harness(run.harness) ++ destinations ++ [{"inputs", run.inputs}]
    )
  end

  defp target_version(%{target_version: version}) when is_binary(version),
    do: [{"target_version", version}]

  defp target_version(_harness), do: []

  # The `workflow` and `harness_hidden` of a run's documents, both or neither, and its
  # `harness`, `{"harness": document}`, where the walk took a document other than the
  # target's harness file: a stack chosen for the target, the workspace's or the
  # organisation's harness choice, or the Qory harness. The machine composes the
  # target's file at `target_version` where `harness` is absent.
  defp harness(nil), do: []

  defp harness(%{workflow: workflow, harness_hidden: hidden, harness: document}) do
    harness = if document, do: [{"harness", %{"harness" => document}}], else: []
    [{"workflow", workflow}, {"harness_hidden", hidden}] ++ harness
  end

  # reach/2 is the `access` of a run with the harness members `harness` (`access/1`) and
  # its `target`, both present for a run with a target and both left out for one
  # without, as the contract requires them together: `{name, value}` members, in order.
  # The target is `{collection, address?}` (`Apiary.Runs.Target.document/1`).
  @doc false
  @spec reach(harness | nil, Apiary.Lingo.Domain.target() | nil) ::
          [{String.t(), String.t() | Jason.OrderedObject.t()}]
  def reach(_harness, nil), do: []

  def reach(harness, target),
    do: [{"access", access(harness)}, {"target", Apiary.Runs.Target.document(target)}]

  # subject/1 is a run's subject, its work item: the kind `work_item`, its public id, its
  # address and its title. A title that the contract's `draft_title` refuses is left out.
  @doc false
  @spec subject(Apiary.WorkItems.WorkItem.t()) :: Jason.OrderedObject.t()
  def subject(work_item) do
    title = if draft_title?(work_item.title), do: [{"title", work_item.title}], else: []

    Jason.OrderedObject.new(
      [
        {"kind", "work_item"},
        {"id", work_item.public_id},
        {"url", WorkItems.stable_url(work_item)}
      ] ++ title
    )
  end

  # Whether `title` fits the integration contract's `draft_title`: 1 to 256 characters on
  # one line, none of them a character that a prose line refuses, and one not a space.
  defp draft_title?(title) when is_binary(title) do
    length(String.codepoints(title)) <= 256 and not Regex.match?(@not_in_line, title) and
      not Regex.match?(@blank, title)
  end

  defp draft_title?(_title), do: false

  # The trigger of the run that a take in starts: `take_in`, on each of its attempts
  # (`Apiary.Dispatches.take_in_run?/1`): its first, and each requeue of it after a missing
  # image or a pause. A later round, a retry and a return to the first stage have none.
  defp trigger(%{dispatch_run: %{explore: true} = dispatch_run, work_item: %{}}) do
    if Apiary.Dispatches.take_in_run?(dispatch_run), do: [{"trigger", "take_in"}], else: []
  end

  defp trigger(_run), do: []

  # access/1 is what a run with the harness members `harness` may do on its target: the
  # level its harness walk resolved, lowered by its stage entry: `read`, `write-no-push`
  # (a writable checkout that has no push credential) or `write`. A run with no harness
  # members, a prebuild or an explore run with no workflow, reads. The work credential of
  # a `write-no-push` run has read access (`Apiary.Runs.RunCredentials`).
  @doc false
  @spec access(harness | nil) :: String.t()
  def access(%{access: :write_no_push}), do: "write-no-push"
  def access(%{access: level}) when level in [:read, :write], do: Atom.to_string(level)
  def access(_none), do: "read"

  # time/1 is `at` in UTC to the whole second.
  @doc false
  @spec time(DateTime.t()) :: String.t()
  def time(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
