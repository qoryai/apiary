defmodule Apiary.Stages.StopCause do
  # StopCause is why a run of a stage stopped, as an escalation's gaps show it
  # (`Apiary.Stages`): for a run that ended before it started, two lines, the cause, then
  # who fixes it and on which page. The text is written once, when the run ends, from what
  # the end left: the run of the queue, its work item, and, for a run a claim ended, the
  # claim's gateway and that gateway's keys (`context`).
  @moduledoc false

  import Ecto.Query

  alias Apiary.Adapters.Collection
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Gateways
  alias Apiary.Harnesses.{RunHarness, Walk}
  alias Apiary.Integrations.ApplyTemplates
  alias Apiary.Lingo.Domain
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Repo
  alias Apiary.Runs.{Run, Target}
  alias Apiary.Targets
  alias Apiary.WorkItems.WorkItem

  @prebuild "prebuild"

  # The walk failures whose fix is on the set-up step Harness.
  @harness_step_failures ~w(no_harness scp_form credential_in_address too_many)

  @typedoc "What a claim knew when it ended a run: its gateway and the gateway's keys."
  @type context :: %{optional(:gateway) => Node.t(), optional(:keys) => [map]}

  # text/3 is why `run` stopped: one line for a run that started, two for one that ended
  # before it started.
  @doc false
  @spec text(DispatchRun.t(), WorkItem.t(), context) :: String.t()
  def text(run, work_item, context \\ %{})

  def text(%DispatchRun{end_cause: :run_ended, result_outcome: :refused}, _work_item, _context),
    do: "The run's result does not match the explore result schema."

  def text(%DispatchRun{end_cause: :run_ended, result_outcome: :error}, _work_item, _context),
    do: "The run ended with an error."

  def text(%DispatchRun{end_cause: :run_ended}, _work_item, _context),
    do: "The run ended without a result."

  def text(%DispatchRun{end_cause: :lost}, _work_item, _context),
    do: "The run stopped reporting and was marked lost."

  def text(%DispatchRun{} = run, %WorkItem{} = work_item, context) do
    {cause, fix} = lines(run, work_item |> names() |> Map.put(:run, run), context)
    cause <> "\n" <> fix
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
        join: r in Run,
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

  defp lines(%DispatchRun{end_cause: :ticket_gone}, _n, _ctx),
    do:
      {"The run did not start, because the work item's ticket is no longer in Qory Apiary.",
       "Close the work item, or take the ticket in again."}

  defp lines(%DispatchRun{end_cause: :inputs_invalid}, _n, _ctx),
    do:
      {"The run did not start, because a value in the ticket or the work item breaks a rule for the agent's input, such as its size limit.",
       "Whoever can edit the ticket where it comes from shortens or corrects it, then takes it in again."}

  defp lines(%DispatchRun{end_cause: :provider_gone}, n, _ctx),
    do:
      {"The run did not start, because the model provider of its model choice was removed, or no longer applies to #{n.workspace}.",
       "Owners and admins of #{n.workspace} choose another model provider in Workspace settings › Model."}

  defp lines(%DispatchRun{end_cause: :runtime_unserved}, n, _ctx),
    do:
      {"The run did not start, because the chosen model provider no longer serves the chosen runtime.",
       "Owners and admins of #{n.workspace} choose another runtime or model provider in Workspace settings › Model."}

  defp lines(%DispatchRun{end_cause: :key_gone}, n, _ctx),
    do:
      {"The run did not start, because the chosen model provider no longer has the chosen key.",
       "Owners and admins of #{n.workspace} choose another key on the set-up step Model."}

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

  defp lines(%DispatchRun{end_cause: cause}, n, _ctx),
    do: unknown("The run ended before it started.", "end cause", cause, n)

  defp unknown(first, kind, code, n),
    do: {"#{first} Qory Apiary has no description for its #{kind} (#{code}).", support(n)}

  # Contact support, with the reference the person can give: the registered run's public
  # id, or, for a run that ended before a claim registered it, the work item's number.
  # Support finds the details in the instance's log by either.
  defp support(%{run: %DispatchRun{id: id}} = n) when is_binary(id) do
    case Repo.one(from r in Run, where: r.dispatch_run_id == ^id, select: r.public_id) do
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
  # stored secrets, or the model key may not be sealed for it.
  defp secrets(n, %{gateway: %Node{} = gateway} = ctx) do
    cond do
      # The instance's gateway: the person sees neither it nor its keys.
      Gateways.level(gateway) == :instance ->
        secrets(n, %{})

      Enum.all?(Map.get(ctx, :keys, []), & &1.allow_secrets) ->
        {"The run did not start, because the model key of its model choice may not be sent to gateway #{gateway.name}, which belongs to another organisation.",
         "Owners and admins of #{n.workspace} choose a model provider of #{n.organisation} in Workspace settings › Model."}

      true ->
        {who, page} = gateway_fixer(gateway, n)

        {"The run did not start, because gateway #{gateway.name} is not allowed to receive the run's secrets.",
         "#{who} an access key for #{gateway.name} with stored secrets allowed, on #{page}."}
    end
  end

  defp secrets(n, _ctx),
    do:
      {"The run did not start, because its gateway is not allowed to receive the run's secrets.",
       support(n)}

  defp gateway_fixer(gateway, n) do
    case Gateways.level(gateway) do
      {:organisation, _id} ->
        {"Owners and admins of #{n.organisation} add", "Gateways › #{gateway.name} › Access key"}

      {:workspace, _id} ->
        {"Owners and admins of #{n.workspace} add", "Nodes › #{gateway.name} › Access key"}
    end
  end

  # A run variable that breaks its rule, found again from the work item's target as the
  # claim formed it (`Apiary.Dispatches.Handover`).
  defp variables(run, n) do
    case variable_rule(n) do
      :system_invalid ->
        integration =
          case reach(run, n) do
            {_state, title} -> "the integration " <> title
            nil -> "the integration that brings in target #{n.target}"
          end

        {"The run did not start, because its variable QORY_RUN_SYSTEM, the system #{n.work_item.target_system} of target #{n.target}, is not a host name: a-z, 0-9, dots and dashes, with no dot at either end and no two dots in a row.",
         "Owners and admins of #{n.organisation} check #{integration} in Organisation settings › Integrations."}

      nil ->
        {"The run did not start, because one of its variables breaks its rule.", support(n)}

      _repositories ->
        {"The run did not start, because its variable QORY_RUN_REPOSITORIES breaks its rule: each entry owner/name, all of the target's owner, none twice, and at most 256 bytes together.",
         "Owners and admins of #{n.workspace} correct the targets its runs also read, on the page of target #{n.target}, under Targets."}
    end
  end

  defp variable_rule(%{work_item: %WorkItem{target_system: system, target_path: path}} = n)
       when is_binary(system) do
    target = %{system: system, path: path}

    found =
      Repo.one(
        from t in Target,
          where: t.workspace_id == ^n.workspace_struct.id,
          where: t.system == ^system and t.path == ^path
      )

    picked =
      if found && Domain.paths_label(n.workspace_struct),
        do: Targets.further_repositories(found),
        else: []

    case Domain.run_variables(n.workspace_struct, target, picked) do
      {:error, rule} -> rule
      _ok -> nil
    end
  end

  defp variable_rule(_n), do: nil

  # A harness walk that failed: what Qory Apiary could not read, and why, then the fix.
  defp harness(%RunHarness{} = walk, n) do
    walk = Repo.preload(walk, :failed_adapter)
    source = walk.failed_source || "of #{n.workspace}"

    case harness_reason(walk.failure, walk, n) do
      {:line, cause, fix} -> {cause, fix}
      {reason, fix} -> {"Qory Apiary could not read the harness #{source} (#{reason}).", fix}
    end
  end

  defp harness(nil, n), do: harness(%RunHarness{failure: nil}, n)

  defp harness_reason("no_harness", _walk, n),
    do:
      {"the target has no harness file, and the workspace sets no harness",
       "Owners and admins of #{n.workspace} choose a harness on the set-up step Harness."}

  defp harness_reason("invalid", _walk, _n),
    do:
      {"it breaks the harness format",
       "Whoever maintains the harness corrects it where it is kept."}

  # In the words of the Workflow page's line for the same failure.
  defp harness_reason("not_covered", walk, n),
    do:
      {:line,
       "No integration of #{n.organisation} reaches #{walk.failed_source || "the harness of #{n.workspace}"}. Qory Apiary reads a harness only through an integration.",
       "Owners and admins of #{n.organisation} connect one in Organisation settings › Integrations."}

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

  defp harness_reason("walk_error", _walk, n),
    do: {"the harness walk stopped on an error in Qory Apiary", support(n)}

  defp harness_reason(code, _walk, n),
    do:
      {"a failure Qory Apiary has no description for#{if code, do: ", with the code #{code}", else: ""}",
       support(n)}

  ## Names

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
