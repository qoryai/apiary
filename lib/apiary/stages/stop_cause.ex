defmodule Apiary.Stages.StopCause do
  # StopCause is why a run of a stage stopped, as an escalation's point shows it
  # (`Apiary.Stages.Points.run_stopped/2`): the cause and, where one exists, its fix; for a
  # run that ended before it started, two lines, the cause, then who fixes it and on which
  # page (`text/3`). The text is written once, when the run ends, from what
  # the end left: the run of the queue, its work item, and, for a run a claim ended, the
  # claim's gateway and that gateway's keys (`context`).
  @moduledoc false

  use Gettext, backend: ApiaryWeb.Gettext

  import Ecto.Query

  alias Apiary.Adapters.Collection
  alias Apiary.Connections.Connection
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Gateways
  alias Apiary.Harnesses.{Qory, RunHarness, Walk, WorkflowGap}
  alias Apiary.Integrations.ApplyTemplates
  alias Apiary.Lingo.Domain
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Processes
  alias Apiary.Processes.Version
  alias Apiary.Repo
  alias Apiary.Runs.{ReadNeeds, Run, RunVariables, Target, WriteNeeds}
  alias Apiary.Targets
  alias Apiary.Variables.Resolution
  alias Apiary.WorkItems.WorkItem

  @prebuild "prebuild"

  # Why a run stopped that sent no result, and a session of a shared run that failed or
  # was cancelled with no verdict (`no_result/0`).
  @no_result "The run ended without a result."

  # The walk failures whose fix is on the set-up step Harness.
  @harness_step_failures ~w(no_harness scp_form credential_in_address too_many ref_missing)

  @typedoc """
  What a claim knew when it ended a run: its gateway and the gateway's keys, as
  `Apiary.Dispatches.Handover.gateway/1` returns them, the gateway with the claim's workspace.
  """
  @type context :: %{
          optional(:gateway) => {Node.t(), Workspace.t() | nil},
          optional(:keys) => [map]
        }

  # text/3 is why `run` stopped: one line for a run that started, two for one that ended
  # before it started.
  @doc false
  @spec text(DispatchRun.t(), WorkItem.t(), context) :: String.t()
  def text(run, work_item, context \\ %{}) do
    case split(run, work_item, context) do
      {:one, cause} -> cause
      {:whole, line} -> line
      {:point, cause, _point} -> cause
      {:then, cause, fix} -> cause <> " " <> fix
      {:lines, cause, fix} -> cause <> "\n" <> fix
      {:fix_first, fix, cause} -> fix <> " " <> cause
    end
  end

  # parts/3 is why `run` stopped as an escalation's point takes it
  # (`Apiary.Stages.Points.stopped/1`): the cause after "The run stopped:", and what fixes
  # it, nil where only another round does; or `{:whole, line}`, a line that is the whole
  # point, with "The run stopped:" inside it.
  @doc false
  @spec parts(DispatchRun.t(), WorkItem.t(), context) ::
          {String.t(), String.t() | nil} | {:whole, String.t()}
  def parts(run, work_item, context \\ %{}) do
    case split(run, work_item, context) do
      {:one, cause} -> {cause, nil}
      {:whole, line} -> {:whole, line}
      {:point, _cause, point} -> {point, nil}
      {:then, cause, fix} -> {cause, fix}
      {:lines, cause, fix} -> {cause, fix}
      {:fix_first, fix, cause} -> {cause, fix}
    end
  end

  # The cause and its fix: `{:one, cause}` with no fix; `{:whole, line}` for a line that
  # has the fix first and "The run stopped:" inside it, as the stop line and as the whole
  # point, such as for a harness file with hooks and no `extends`; `{:point, cause, point}` with no
  # fix, where a point says the cause in other words after "The run stopped:";
  # `{:then, cause, fix}` for a cause whose second sentence follows on the same line;
  # `{:lines, cause, fix}` for a run that ended before it started; and
  # `{:fix_first, fix, cause}` for a read-only run that could not go on, or a run that writes
  # and has no wall, whose text has the fix first.
  #
  # A run a member cancelled (`Apiary.Runs.Cancel`) stopped because they did, whatever it
  # ended by: "<person> cancelled it.", after "The run stopped:".
  defp split(%DispatchRun{} = run, work_item, context) do
    case Apiary.Runs.Cancel.cancelled_run(run) do
      nil -> stopped_split(run, work_item, context)
      cancelled -> {:one, cancelled(cancelled)}
    end
  end

  # cancelled/1 is the cause of a run a member cancelled, in the default locale's words
  # (`ApiaryWeb.Lingo.default_locale/0`) whatever the calling process's locale, as the
  # escalation stores it.
  defp cancelled(run) do
    Gettext.with_locale(ApiaryWeb.Gettext, ApiaryWeb.Lingo.default_locale(), fn ->
      gettext("%{person} cancelled it.", person: Apiary.Runs.Cancel.canceller(run))
    end)
  end

  defp stopped_split(
         %DispatchRun{end_cause: :run_ended, result_outcome: :error},
         _work_item,
         _ctx
       ),
       do: {:one, "The run ended with an error."}

  # A run that sent no result: qory closed it with `workflow_not_in_harness` when the
  # harness it composed has no skill for the run's workflow (`Apiary.Harnesses.WorkflowGap`),
  # and with a `read_needs_*` reason when a read-only run could not go on
  # (`Apiary.Runs.ReadNeeds`), or `write_needs_wall` when a run that writes has no wall
  # (`Apiary.Runs.WriteNeeds`), or `timeout` when it reached its time limit.
  defp stopped_split(%DispatchRun{end_cause: :run_ended} = run, %WorkItem{} = work_item, _context) do
    case WorkflowGap.of_dispatch_run(run, work_item) do
      %{} = facts -> workflow_gap(facts, work_item)
      nil -> no_gap(run, work_item)
    end
  end

  defp stopped_split(%DispatchRun{end_cause: :run_ended}, _work_item, _context),
    do: {:one, @no_result}

  defp stopped_split(%DispatchRun{end_cause: :lost}, _work_item, _context),
    do:
      {:point, "The run stopped reporting and was marked lost.",
       "Qory Apiary got no report from it and marked it lost."}

  defp stopped_split(%DispatchRun{} = run, %WorkItem{} = work_item, context) do
    case lines(run, work_item |> names() |> Map.put(:run, run), context) do
      {:whole, line} -> {:whole, line}
      {cause, fix} -> {:lines, cause, fix}
    end
  end

  # no_result/0 is why a run stopped that ended without a result: the cause of a session
  # of a shared run that failed or was cancelled (`Apiary.Stages.next_session/2`), as for
  # a run that ended so.
  @doc false
  @spec no_result() :: String.t()
  def no_result, do: @no_result

  # failed_after_proposal/1 is why a run of Explore stopped whose registered run failed
  # after it pushed version `version` of its proposal: one line, in the default locale's
  # words (`ApiaryWeb.Lingo.default_locale/0`) whatever the calling process's locale, as
  # the escalation stores it.
  @doc false
  @spec failed_after_proposal(pos_integer) :: String.t()
  def failed_after_proposal(version) when is_integer(version) do
    Gettext.with_locale(ApiaryWeb.Gettext, ApiaryWeb.Lingo.default_locale(), fn ->
      gettext("The run failed after it wrote proposal version %{version}.", version: version)
    end)
  end

  # set_up_step/1 is the step of the workspace's set-up whose page has the fix for why
  # `run` stopped, `/:org/:workspace/set-up/<step>`, which the fix line names as "the
  # set-up step Harness", "the set-up step Model" or "the set-up step Destinations":
  # `:harness` for a harness walk that failed on the workspace's harness choice, `:model`
  # for a missing or removed model key, `:destinations` for a target path the access
  # rules refuse a part of; nil otherwise.
  @doc false
  @spec set_up_step(DispatchRun.t() | nil) :: :harness | :model | :destinations | nil
  def set_up_step(%DispatchRun{end_cause: :run_refused, end_detail: "model_key_missing"}),
    do: :model

  def set_up_step(%DispatchRun{end_cause: :key_gone}), do: :model

  def set_up_step(%DispatchRun{end_cause: :target_access_gone, work_item_id: id} = run)
      when is_binary(id) do
    case Repo.get(WorkItem, id) do
      %WorkItem{} = work_item ->
        case reach(run, %{work_item: work_item}) do
          {:path_refused, _integration} ->
            if ApplyTemplates.refused_in(work_item.target_path), do: :destinations

          _other ->
            nil
        end

      nil ->
        nil
    end
  end

  def set_up_step(%DispatchRun{end_cause: :harness_unresolved, id: id}) do
    case Repo.get_by(RunHarness, dispatch_run_id: id) do
      # The built-in harness is set on no step (`Apiary.Harnesses.Builtin`).
      %RunHarness{failure_rule: %{"values" => %{"builtin" => true}}} -> nil
      %RunHarness{failure: failure} when failure in @harness_step_failures -> :harness
      _other -> nil
    end
  end

  def set_up_step(_run), do: nil

  # build_run/1 is the public id of the newest registered run that built the environment
  # of the work item's target, whose page has the build's log; nil for none.
  @doc false
  @spec build_run(WorkItem.t()) :: String.t() | nil
  def build_run(%WorkItem{target_system: system, target_path: path} = work_item)
      when is_binary(system) and is_binary(path) do
    Repo.one(
      from d in DispatchRun,
        join: c in Collection,
        on: c.id == d.source_collection_id,
        join: r in subquery(Run.registered()),
        on: r.dispatch_run_id == d.id,
        where: d.workspace_id == ^work_item.workspace_id and d.step == ^@prebuild,
        where: c.target_system == ^system and c.target_path == ^path,
        order_by: [desc: d.updated_at, desc: d.id],
        limit: 1,
        select: r.public_id
    )
  end

  def build_run(%WorkItem{}), do: nil

  ## The causes

  # The registered run is read once; ReadNeeds and WriteNeeds read their facts from it.
  defp no_gap(run, work_item) do
    registered = registered_run(run)

    case ReadNeeds.of_run(registered) do
      %{} = facts -> read_needs(facts, work_item)
      nil -> no_read_needs(registered, run, work_item)
    end
  end

  defp no_read_needs(registered, run, work_item) do
    case WriteNeeds.of_run(registered) do
      %{} = facts -> write_needs(facts, work_item)
      nil -> timed_out_or_no_result(registered, run, work_item)
    end
  end

  # The reason and the node of the dispatch run's registered run; nil for none.
  defp registered_run(%DispatchRun{id: id}) do
    Repo.one(
      from r in Run.registered(),
        where: r.dispatch_run_id == ^id,
        select: map(r, [:reason, :node_id])
    )
  end

  # A run whose registered run ended with the reason `timeout` reached its time limit. The
  # words follow "Attempt 2 ended with an error, so Build has no result"
  # (`ApiaryWeb.WorkItemComponents`); no fix, only another round helps.
  defp timed_out_or_no_result(%{reason: "timeout"}, run, work_item),
    do:
      {:one,
       "Attempt #{run.attempt} reached its time limit, so #{stage_name(run, work_item)} has no result."}

  defp timed_out_or_no_result(_registered, _run, _work_item),
    do: {:one, @no_result}

  # The name of the stage the run was in, from the process version the run started under,
  # else the work item's; "the stage" for a run placed in no stage or no version. Only the
  # version's document is read.
  defp stage_name(run, work_item) do
    stage_id = run.stage_id || work_item.stage_id

    document =
      case run.process_version_id || work_item.process_version_id do
        id when is_binary(id) ->
          Repo.one(from v in Version, where: v.id == ^id, select: v.document)

        nil ->
          nil
      end

    case document && Processes.stage(document, stage_id) do
      %{"name" => name} when is_binary(name) and name != "" -> name
      _none -> "the stage"
    end
  end

  # The words of `read_needs_words/1` in `ApiaryWeb.WorkItemComponents`, stored once in
  # English, the fix first: the target is a repository in a software workspace. A person
  # in an organisation cannot edit the forager.yaml of the instance's pool, so that pool's
  # run has "Contact support." in place of the fix.
  defp read_needs(%{code: "read_needs_wall", installed: true}, _work_item),
    do:
      {:fix_first, "Contact support.", "A read-only run needs a wall, and this machine has none."}

  defp read_needs(%{code: "read_needs_wall"}, _work_item),
    do:
      {:fix_first, "Set a wall in the machine's forager.yaml, then start the run again.",
       "A read-only run needs a wall, and this machine has none."}

  defp read_needs(%{code: "read_needs_setup_outside", installed: true}, _work_item),
    do:
      {:fix_first, "Contact support.",
       "A read-only run cannot run its setup inside the agent's container."}

  defp read_needs(%{code: "read_needs_setup_outside"}, _work_item),
    do:
      {:fix_first,
       "Set wall.setup to outside in the machine's forager.yaml, or remove it, then start the run again.",
       "A read-only run cannot run its setup inside the agent's container."}

  defp read_needs(%{code: "read_needs_no_nested_docker"}, work_item) do
    word = Domain.target_noun(Repo.get!(Workspace, work_item.workspace_id))

    {:fix_first,
     "Choose an image without nested Docker in the #{word}'s environment, then start the run again.",
     "A read-only run cannot use an image with nested Docker."}
  end

  defp read_needs(%{code: "read_needs_setup_removed"}, _work_item),
    do:
      {:fix_first, "Start the run again.",
       "The setup container was not removed, so a process in it could still write the files."}

  # What a person does about a run that writes and has no wall. The target's copy has its
  # domain's word (`Apiary.Lingo.Domain.copy_noun/1`). A person in an organisation cannot
  # edit the forager.yaml of the instance's pool, so that pool's run has "Contact support.".
  defp write_needs(%{installed: installed}, work_item) do
    copy = Domain.copy_noun(Repo.get!(Workspace, work_item.workspace_id))
    cause = "A run that writes to the #{copy} needs a wall, and this machine has none."

    if installed,
      do: {:fix_first, "Contact support.", cause},
      else:
        {:fix_first, "Set a wall in the machine's forager.yaml, then start the run again.", cause}
  end

  # The words of `ApiaryWeb.HarnessComponents.workflow_gap_words/1`, stored once in
  # English: the target is a repository in a software workspace.
  defp workflow_gap(%{workflow: workflow, source: source}, work_item) do
    missing =
      if workflow,
        do: "The run's harness has no skill for the workflow #{workflow}.",
        else: "The run's harness has no skill for the run's workflow."

    case gap_source(source, work_item) do
      nil -> {:one, missing}
      from -> {:then, missing, from}
    end
  end

  defp gap_source({:target, target}, work_item) do
    word = Domain.target_noun(Repo.get!(Workspace, work_item.workspace_id))
    "The harness comes from the harness file at the root of #{word} #{target}."
  end

  defp gap_source({:repository, address, {:stack, stack}}, _work_item),
    do: "The harness comes from #{address}, stack #{stack}."

  defp gap_source({:repository, address, {:path, path}}, _work_item),
    do: "The harness comes from #{address}, folder #{path}."

  defp gap_source({:repository, address, nil}, _work_item),
    do: "The harness comes from #{address}."

  defp gap_source(:section, _work_item), do: "The harness is the workspace's harness."
  defp gap_source(:qory, _work_item), do: "The harness is the Qory harness."
  defp gap_source(nil, _work_item), do: nil

  defp lines(%DispatchRun{end_cause: :run_refused, end_detail: "model_key_missing"}, n, _ctx),
    do:
      {"The gateway did not start the run, because it had no model key for the run.",
       "Owners and admins of #{n.workspace} add a model key on the set-up step Model."}

  defp lines(%DispatchRun{end_cause: :run_refused, end_detail: code}, n, _ctx),
    do: unknown("The gateway did not start the run.", "refusal", code, n)

  defp lines(%DispatchRun{end_cause: :build_failed}, n, _ctx) do
    cause =
      "The run did not start, because the build of the environment for target #{n.target} failed."

    case build_run(n.work_item) do
      nil ->
        {cause,
         "Read why on the page of target #{n.target}, under Targets, then choose Rebuild there."}

      run ->
        {cause,
         "Read the build's log on the page of run #{run}, under Runs. Then choose Rebuild on the page of target #{n.target}, under Targets."}
    end
  end

  defp lines(%DispatchRun{end_cause: :harness_unresolved} = run, n, _ctx),
    do: harness(Repo.get_by(RunHarness, dispatch_run_id: run.id), n)

  defp lines(%DispatchRun{end_cause: :variables_invalid} = run, n, _ctx), do: variables(run, n)

  # A run of a stage with `shared_run: true` also ends `ticket_gone` or `inputs_invalid`
  # after a session, when the input of its next session cannot be formed
  # (`Apiary.Stages.next_session/2`); `Apiary.Stages.ended_after_session/1` is then the
  # session that ended.
  defp lines(%DispatchRun{end_cause: :ticket_gone} = run, _n, _ctx) do
    cause =
      case Apiary.Stages.ended_after_session(run) do
        nil ->
          "The run did not start, because the work item's ticket is no longer in Qory Apiary."

        session ->
          "The work item's ticket is no longer in Qory Apiary, so the run ended after session #{session}."
      end

    {cause, "Close the work item, or take the ticket in again."}
  end

  defp lines(%DispatchRun{end_cause: :inputs_invalid} = run, _n, _ctx) do
    cause =
      case Apiary.Stages.ended_after_session(run) do
        nil ->
          "The run did not start, because a value in the ticket or the work item breaks a rule for the agent's input, such as its size limit."

        session ->
          "A value in the ticket or the work item breaks a rule for the input of the next session, such as its size limit, so the run ended after session #{session}."
      end

    {cause,
     "Whoever can edit the ticket where it comes from shortens or corrects it, then takes it in again."}
  end

  defp lines(%DispatchRun{end_cause: :provider_gone}, n, _ctx),
    do:
      {"The run did not start, because the model provider of its model choice was removed, or no longer applies to #{n.workspace}.",
       "Owners and admins of #{n.workspace} choose another model provider in Workspace settings › Model."}

  # A run of a stage whose workflows share one run, whose model choices did not fit the
  # one run at its claim. While the fault remains, the fix has the values of the check run
  # again (`Apiary.Stages.shared_models/1`); once it is fixed, or the check finds the other
  # fault, the fix is to run the round again.
  defp lines(%DispatchRun{end_cause: cause} = run, _n, _ctx)
       when cause in [:model_choice_missing, :too_many_providers, :session_key_missing] do
    {stage, detail} = shared_models(run)
    {shared_models_cause(cause, stage), shared_models_fix(cause, detail)}
  end

  defp lines(%DispatchRun{end_cause: :runtime_unserved}, n, _ctx),
    do:
      {"The run did not start, because the chosen model provider no longer serves the chosen runtime.",
       "Owners and admins of #{n.workspace} choose another runtime or model provider in Workspace settings › Model."}

  defp lines(%DispatchRun{end_cause: :key_gone}, n, _ctx),
    do:
      {"The run did not start, because the chosen model provider has no key.",
       "Owners and admins of #{n.workspace} choose another provider on the set-up step Model, or add a key to that provider in Organisation settings › Model provider keys."}

  defp lines(%DispatchRun{end_cause: :model_gone}, n, _ctx),
    do:
      {"The run did not start, because the model provider has no model for the run, or no longer offers the chosen effort.",
       "Owners and admins of #{n.workspace} choose another model or effort in Workspace settings › Model."}

  defp lines(%DispatchRun{end_cause: :secrets_not_allowed}, n, ctx), do: secrets(n, ctx)

  defp lines(%DispatchRun{end_cause: :target_access_gone} = run, n, _ctx) do
    case reach(run, n) do
      {:path_refused, title} ->
        path_refused(n, title)

      {_gone, title} ->
        integration = "the integration " <> title

        {"The run did not start, because #{integration} no longer reaches target #{n.target}.",
         "Owners and admins of #{n.organisation} check #{integration} in Organisation settings › Integrations."}

      nil ->
        {"The run did not start, because no integration of #{n.organisation} reaches target #{n.target}.",
         "Owners and admins of #{n.organisation} connect one in Organisation settings › Integrations."}
    end
  end

  defp lines(%DispatchRun{end_cause: :write_without_work_item}, _n, _ctx),
    do:
      {"The run did not start, because it writes and has no work item to take its branch from.",
       "Contact support."}

  defp lines(%DispatchRun{end_cause: :shared_access_differs} = run, _n, _ctx) do
    {stage, detail} = shared_access(run)

    case detail do
      {:access, workflow, level, other} ->
        {"The run did not start, because the workflows of #{stage} mix access levels that cannot share one run. #{workflow} runs with #{level} access, because its harness sets #{level}.",
         shared_access_fix(workflow, other)}

      :access ->
        {"The run did not start, because the workflows of #{stage} mix access levels that cannot share one run.",
         "Move one of the workflows to a separate stage in Workspace settings › Workflows, then run the round again."}

      nil ->
        {"The run did not start, because the workflows of #{stage} mix access levels that cannot share one run.",
         "Run the round again."}
    end
  end

  defp lines(%DispatchRun{end_cause: cause}, n, _ctx),
    do: unknown("The run ended before it started.", "end cause", cause, n)

  defp unknown(first, kind, code, n),
    do: {"#{first} Qory Apiary has no description for its #{kind} (#{code}).", support(n)}

  # Contact support, with the reference the person can give: the registered run's public
  # id, or, for a run that ended before a claim registered it, the work item's number.
  # Support finds the details in the instance's log by either.
  defp support(%{run: %DispatchRun{id: id}} = n) when is_binary(id) do
    case Repo.one(
           from r in Run.registered(), where: r.dispatch_run_id == ^id, select: r.public_id
         ) do
      nil -> support(Map.delete(n, :run))
      public_id -> "Contact support with run #{public_id}."
    end
  end

  defp support(%{work_item: %WorkItem{number: number}}),
    do: "Contact support with work item ##{number}."

  # How the run reached its target, as the claim's work entry did
  # (`Apiary.Runs.RunCredentials.reach/3`), read when the run ends: the state, and the
  # title of the adapter of the collection the entry comes from; nil for no
  # collection.
  defp reach(run, %{work_item: work_item}) do
    target = %{system: work_item.target_system, path: work_item.target_path}

    case Apiary.Runs.RunCredentials.reach(run, work_item, target) do
      {state, %Node{} = adapter} -> {state, Apiary.Adapters.title(adapter)}
      nil -> nil
    end
  end

  # A target path the access rules do not take, by the first part of it they refuse
  # (`Apiary.Integrations.ApplyTemplates.refused_in/1`).
  defp path_refused(%{target: path} = n, _title) do
    fix = fn without ->
      "Whoever manages #{path} where it is kept renames it without #{without}, or owners and admins of #{n.workspace} remove it on the set-up step Destinations."
    end

    case ApplyTemplates.refused_in(path) do
      {:character, char} ->
        {"The run did not start, because target #{path} has the character #{shown(char)} in its path, which Qory Apiary does not put in an access rule.",
         fix.("that character")}

      {:sequence, sequence} ->
        words = if sequence == "..", do: "two dots in a row", else: "two slashes in a row"

        {"The run did not start, because target #{path} has #{words} in its path, which Qory Apiary does not put in an access rule.",
         fix.(words)}

      # The path has no refused part, so the adapter's apply items made a path out of
      # the grammar, which the check of its description refuses at its start.
      nil ->
        {"The run did not start, because Qory Apiary could not grant the run access to target #{path}.",
         support(n)}
    end
  end

  # A character as a text shows it: in quotes, or a space character by its code point.
  defp shown(<<code::utf8>> = char) do
    if Regex.match?(~r/\A[\x{21}-\x{7E}]\z/u, char),
      do: ~s("#{char}"),
      else: "U+" <> String.pad_leading(Integer.to_string(code, 16), 4, "0")
  end

  # A gateway that may not receive the run's secrets: one of its keys was made without
  # stored secrets, or the model key may not be sealed for it. The claim passes its keys;
  # the stage sweep reads them again when it acts on the end (`Apiary.Stages.claim_context/1`).
  # A gateway of the run's organisation, or one made in the run's workspace, may receive
  # the model key, so when every key of that gateway read now allows stored secrets, a key
  # changed after the claim.
  defp secrets(n, %{gateway: {%Node{} = gateway, _workspace}} = ctx) do
    cond do
      # The instance's gateway: the person sees neither it nor its keys.
      Gateways.level(gateway) == :instance ->
        secrets(n, %{})

      not Enum.all?(Map.get(ctx, :keys, []), & &1.allow_secrets) ->
        {who, page} = gateway_fixer(gateway, n)

        {"The run did not start, because gateway #{gateway.name} is not allowed to receive the run's secrets.",
         "#{who} an access key for #{gateway.name} with stored secrets allowed, on #{page}."}

      # A provider whose key is never sealed for a gateway: another round ends the same way.
      of_run?(gateway, n.run) and not organisation_chain?(n.run) ->
        secrets(n, %{})

      of_run?(gateway, n.run) ->
        {"The run did not start, because the access key of gateway #{gateway.name} changed after the run was claimed.",
         "Run another round. It then uses the current access key of #{gateway.name}."}

      true ->
        {"The run did not start, because the model key of its model choice may not be sent to gateway #{gateway.name}, which belongs to another organisation.",
         "Owners and admins of #{n.workspace} choose a model provider of #{n.organisation} in Workspace settings › Model."}
    end
  end

  defp secrets(n, _ctx),
    do:
      {"The run did not start, because its gateway is not allowed to receive the run's secrets.",
       support(n)}

  # Whether `gateway` lives at the organisation of `run`, the run of the queue, or at its
  # workspace.
  defp of_run?(gateway, %DispatchRun{organisation_id: organisation_id, workspace_id: workspace_id}),
       do:
         gateway.organisation_id == organisation_id and
           (is_nil(gateway.workspace_id) or gateway.workspace_id == workspace_id)

  # Whether every model provider of `run` that still exists is of the organisation's
  # chain, the only chain whose key may be sealed for a gateway of the organisation
  # (`Apiary.Runs.ProviderCredential.sealable_to?/3`).
  defp organisation_chain?(%DispatchRun{model_provider_ids: ids}) do
    not Repo.exists?(from c in Connection, where: c.id in ^ids and c.chain != "organisation")
  end

  defp gateway_fixer(gateway, n) do
    case Gateways.level(gateway) do
      {:organisation, _id} ->
        {"Owners and admins of #{n.organisation} add", "Gateways › #{gateway.name} › Access key"}

      {:workspace, _id} ->
        {"Owners and admins of #{n.workspace} add", "Machines › #{gateway.name} › Access key"}
    end
  end

  # A run variable that breaks its rule, found again from the work item's target as the
  # claim formed it (`Apiary.Dispatches.Handover`).
  defp variables(%DispatchRun{end_detail: "names_" <> count}, n),
    do: variables_over(count, n, &too_many_names/1)

  defp variables(%DispatchRun{end_detail: "bytes_" <> bytes}, n),
    do: variables_over(bytes, n, &too_large/1)

  defp variables(run, n) do
    case variable_rule(n) do
      {:system_invalid, target} ->
        integration =
          case reach(run, n) do
            {_state, title} -> "the integration " <> title
            nil -> "the integration that brings in target #{n.target}"
          end

        {"The run did not start, because its variable QORY_RUN_SYSTEM, the system #{target.system} of target #{target.path}, is not a host name: a-z, 0-9, dots and dashes, with no dot at either end and no two dots in a row.",
         "Owners and admins of #{n.organisation} check #{integration} in Organisation settings › Integrations."}

      nil ->
        {"The run did not start, because one of its variables breaks its rule.", support(n)}

      {:not_a_collection, _target} ->
        {in_domain_words(n, fn ->
           gettext(
             "The run did not start, because the runs of target %{target} also read a target that its integration does not list.",
             target: n.target
           )
         end), further_fix(n)}

      {:itself, _target} ->
        {in_domain_words(n, fn ->
           gettext(
             "The run did not start, because target %{target} is among the targets its runs also read.",
             target: n.target
           )
         end), further_fix(n)}

      {_repositories, _target} ->
        {"The run did not start, because its variable QORY_RUN_REPOSITORIES breaks its rule: each entry owner/name, all of the target's owner, none twice, and at most 256 bytes together.",
         further_fix(n)}
    end
  end

  # `fun` in English, in the words of the domain of the run's workspace: the text is
  # written once. The software catalogue (`priv/gettext/en@software`) has "repository"
  # where a source string has "target".
  defp in_domain_words(n, fun),
    do: Gettext.with_locale(ApiaryWeb.Gettext, "en@" <> Domain.name(n.workspace_struct), fun)

  defp further_fix(n),
    do:
      "Owners and admins of #{n.workspace} correct the targets its runs also read, on the page of target #{n.target}, under Targets."

  # The variables of the run's workspace and target that a run takes no more of: the
  # claim kept their count, or their size in bytes, as the end's detail
  # (`Apiary.Dispatches.Handover`); a detail that is no number reads as a rule broken.
  defp variables_over(number, n, words) do
    case Integer.parse(number) do
      {number, ""} when number > 0 ->
        {words.(number),
         "Owners and admins of #{n.workspace} remove variables on the Variables page of the workspace or its organisation, then start the run again."}

      _none ->
        {"The run did not start, because one of its variables breaks its rule.", support(n)}
    end
  end

  defp too_many_names(count),
    do:
      "The run did not start: it has #{count} variables, and a run takes at most #{RunVariables.max_resolved()}."

  # The size in whole KiB, rounded up, so a size over the limit never reads as the limit.
  defp too_large(bytes),
    do:
      "The run did not start: its variables take #{div(bytes + 1023, 1024)} KiB, and a run takes at most #{div(Resolution.max_bytes(), 1024)} KiB."

  # The rule a run variable of the work item's target breaks, with the target row it was
  # read from, nil for none: a work item without a target, or whose target has no
  # address, has no run variables to break one. As the claim does, the further paths are
  # checked first (`Apiary.Targets.further_collections/2`): `:not_a_collection` or
  # `:itself` where one of them breaks that check.
  defp variable_rule(%{work_item: %WorkItem{} = work_item} = n) do
    with %{} = target <- WorkItem.target(work_item) do
      found = Repo.one(Target.by_key(n.workspace_struct.id, target))

      picked =
        if found && Domain.paths_label(n.workspace_struct),
          do: Targets.further_repositories(found),
          else: []

      with :ok <- further_collections(found, picked),
           {:ok, _variables} <- Domain.run_variables(n.workspace_struct, target, picked) do
        nil
      else
        {:error, {rule, _n}} when rule in [:not_a_collection, :itself] -> {rule, target}
        {:error, rule} -> {rule, target}
      end
    end
  end

  defp variable_rule(_n), do: nil

  defp further_collections(_found, []), do: :ok

  defp further_collections(%Target{} = found, picked),
    do: Targets.further_collections(found, picked)

  # A harness walk that failed: what Qory Apiary could not read, and why, then the fix.
  defp harness(%RunHarness{} = walk, n) do
    walk = Repo.preload(walk, :failed_adapter)
    source = walk.failed_source || "of #{n.workspace}"

    case harness_reason(walk.failure, walk, n) do
      {:whole, line} -> {:whole, line}
      {:line, cause, fix} -> {cause, fix}
      {reason, fix} -> {"Qory Apiary could not read the harness #{source} (#{reason}).", fix}
    end
  end

  defp harness(nil, n), do: harness(%RunHarness{failure: nil}, n)

  defp harness_reason("no_harness", _walk, n),
    do:
      {"the target has no harness file, and the workspace sets no harness",
       "Owners and admins of #{n.workspace} choose a harness on the set-up step Harness."}

  # A harness file with hooks and no `extends`: the fix first, then the cause after "The
  # run stopped:", as one line of plain text.
  defp harness_reason(
         "invalid",
         %RunHarness{
           failure_rule: %{"rule" => "hooks_without_extends", "values" => %{"file" => file}}
         },
         _n
       ),
       do:
         {:whole,
          "Add extends: with the workspace's stack to #{file}. The run stopped: hooks run only in a harness file that extends a stack."}

  defp harness_reason("invalid", _walk, _n),
    do:
      {"it breaks the harness format",
       "Whoever maintains the harness corrects it where it is kept."}

  # Its host serves the source to no one, and no connection reaches it: a public source
  # is read with no integration, so both are the cause.
  defp harness_reason("not_covered", walk, n) do
    source = walk.failed_source || "the harness of #{n.workspace}"
    subject = walk.failed_source || "The harness of #{n.workspace}"

    {:line,
     "#{subject} is not public, or does not exist, and no connection of #{n.organisation} reaches it.",
     "Owners and admins of #{n.organisation} connect an integration that covers #{source} in Organisation settings › Integrations."}
  end

  defp harness_reason("not_allowed", _walk, n),
    do:
      {"another owner keeps it and has not assigned it to #{n.organisation}",
       "The owner of the harness assigns it to #{n.organisation}."}

  defp harness_reason("scp_form", _walk, n),
    do:
      {"its address has the form user@host:path, and Qory Apiary fetches harness sources over https only",
       "Owners and admins of #{n.workspace} write it as an https address on the set-up step Harness."}

  defp harness_reason("credential_in_address", _walk, n),
    do:
      {"its address contains a user name or a password",
       "Owners and admins of #{n.workspace} remove them from the address on the set-up step Harness."}

  defp harness_reason("too_many", _walk, n),
    do:
      {"it takes harness sources from more than #{Walk.max_links()} accounts",
       "Owners and admins of #{n.workspace} take the harness sources from at most #{Walk.max_links()} accounts, on the set-up step Harness."}

  defp harness_reason("adapter_unavailable", _walk, n),
    do: {"three calls to read it failed", support(n)}

  # The claim's read of the Qory harness, or of the built-in one, failed
  # (`Apiary.Dispatches.Handover`): the words of the run's page, cause first.
  defp harness_reason(
         "ref_missing",
         %RunHarness{failure_rule: %{"values" => %{"builtin" => true} = values}},
         _n
       ),
       do:
         {:line,
          "Reading the harness from #{values["url"]} failed: the repository has no branch #{values["ref"]}.",
          "Contact support."}

  defp harness_reason("ref_missing", %RunHarness{failure_rule: %{"values" => values}}, _n),
    do:
      {:line, "#{values["url"]} has no #{values["ref"]}.",
       "Set a branch, tag or commit that exists in the workspace's harness settings."}

  defp harness_reason("harness_unreadable", %RunHarness{failure_rule: %{"values" => values}}, _n),
    do:
      {:line,
       "Reading the harness from #{values["url"]} failed: #{Qory.cause_words(Qory.cause_of(values["cause"]))}.",
       "Start the run again later. If it fails again, contact support."}

  defp harness_reason("walk_error", _walk, n),
    do: {"the harness walk stopped on an error in Qory Apiary", support(n)}

  # A run with no workflow, ended when it was queued (`Apiary.Harnesses.WalkJob.queue/2`):
  # the words of the run's page.
  defp harness_reason("many_stacks", _walk, _n),
    do:
      {:whole,
       "No workflow to start: more than one stack has a workflow. Keep the workflow in one stack."}

  defp harness_reason("no_stage_run", _walk, _n),
    do:
      {:whole,
       "No workflow to start: no stage started this run, and no stack has a workflow. Add a workflow to a stack, or start the work item from a stage."}

  defp harness_reason("no_process", _walk, _n),
    do:
      {:whole,
       "No workflow to start: the workspace has no process. Set up a process for the workspace."}

  defp harness_reason("no_first_workflow", _walk, _n),
    do:
      {:whole,
       "No workflow to start: the first stage of the process has no workflow. Add a workflow to that stage."}

  defp harness_reason(code, _walk, n),
    do:
      {"a failure Qory Apiary has no description for#{if code, do: ", with the code #{code}", else: ""}",
       support(n)}

  ## Names

  # The name of the stage of `run`, a run whose stage's workflows would run with access
  # levels that one run cannot have, and the difference as the run's harness resolves the
  # levels (`Apiary.Stages.shared_access/1`); nil where the levels fit one run.
  defp shared_access(%DispatchRun{} = run) do
    case Apiary.Stages.shared_access(run) do
      {:error, %{stage: stage, detail: detail}} ->
        {stage, detail}

      :ok ->
        stage =
          run.process_version_id &&
            Apiary.Processes.stage(
              Apiary.Processes.get_version!(run.process_version_id),
              run.stage_id
            )

        {(stage && stage["name"]) || "the stage", nil}
    end
  end

  defp shared_models(%DispatchRun{} = run) do
    case Apiary.Stages.shared_models(run) do
      {:error, %{stage: stage, detail: detail}} -> {stage, detail}
      :ok -> {elem(shared_access(run), 0), nil}
    end
  end

  defp shared_models_cause(:model_choice_missing, stage),
    do:
      "The run did not start, because a workflow of #{stage} had no model, and that workflow's runtime could not use the provider that the run would start on."

  defp shared_models_cause(:session_key_missing, stage),
    do:
      "The run did not start, because a workflow of #{stage} would run on a provider that has no key in the run, or on a second API of a provider that an earlier workflow uses."

  defp shared_models_cause(:too_many_providers, stage),
    do:
      "The run did not start, because the workflows of #{stage} used more than 6 model providers."

  defp shared_models_fix(
         :model_choice_missing,
         {:model_choice_missing, workflow, runtime, provider}
       ),
       do:
         "Choose a model for workflow #{workflow}. Without one it runs on #{runtime}, and this stage's runs can start on #{provider}, which #{runtime} cannot use."

  defp shared_models_fix(:too_many_providers, {:too_many_providers, count, providers}),
    do:
      "Use at most 6 model providers in one stage. Its workflows use #{count}: #{Enum.join(providers, ", ")}."

  defp shared_models_fix(:session_key_missing, {:session_key_missing, :machine, first}),
    do:
      "Choose a model for workflow #{first}, or remove the model choices of the later workflows. Without a model, #{first} runs on the machine's local model provider credential, so later workflows get no model provider credential."

  defp shared_models_fix(
         :session_key_missing,
         {:session_key_missing, :no_key, workflow, provider}
       ),
       do:
         "Add a model key to #{provider}, or choose a model of another provider for workflow #{workflow}. #{provider} has no model key."

  defp shared_models_fix(
         :session_key_missing,
         {:session_key_missing, :other_api, workflow, api, provider, earlier}
       ),
       do:
         "Choose a model for workflow #{workflow} that uses the #{api} API of #{provider}, as workflow #{earlier} does, or a model of another provider. One run uses one API of each provider."

  defp shared_models_fix(_cause, _fixed_or_other), do: "Run the round again."

  # The fix for a run whose stage's workflows would run with access levels that one run
  # cannot have, because the harness sets `workflow` a lower level than `other`, the level
  # another workflow of the stage runs with.
  defp shared_access_fix(workflow, other),
    do:
      "Move #{workflow} to a separate stage in Workspace settings › Workflows, or ask whoever keeps the harness to give it #{other} access, then run the round again."

  defp names(%WorkItem{} = work_item) do
    workspace = Repo.get!(Workspace, work_item.workspace_id)
    organisation = Repo.get!(Organisation, work_item.organisation_id)

    %{
      work_item: work_item,
      workspace_struct: workspace,
      workspace: workspace.name,
      organisation: organisation.name,
      target: work_item.target_path || "of the work item"
    }
  end
end
