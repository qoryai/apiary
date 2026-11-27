defmodule Apiary.Runs.WorkCredential do
  # The value of a run's work entry, push entry or harness entries
  # (`Apiary.Runs.RunCredentials`, `work-1`, `push-1` and `harness-<n>`), for a secrets
  # request that names it (`Apiary.Runs.SecretsRequest`):
  # `issue_all/5` asks the adapter for the credentials, one call
  # for each entry, all at the same time, and checks the answers; the caller seals them,
  # then keeps its apply items (`keep/1`) and writes its Activity entry (`record_issued/3`)
  # in one transaction. The adapter's call is the same for the work and the push entry,
  # with the purpose `work`: only the access differs, `read` for the work entry and `write`
  # for the push entry. A harness entry's call has the purpose `harness`, the access
  # `read`, the entry's grant's `grant_ref` and its resources, and no connection.
  #
  # The caller makes every check that needs no token first, the model key's read
  # included, so that a credential the adapter issued fails only at a step that needs it.
  #
  # For each entry, `issue_all/5` asks `Apiary.Access` first: `run_credential.issue` on
  # the run, for the gateway's key. A refusal is `{:error, :not_found}`, with a log line, no call and no
  # Activity entry, since nothing was attempted. A work entry with access `write` is
  # refused next, `{:error, :credential_unavailable}`, with a log line that has the entry's
  # name, no call and no Activity entry: only a push entry writes. Then, in this order, it
  # stops at the first refusal:
  #
  #   1. The entry's connection is connected, of the run's organisation and of the
  #      entry's adapter (`:connection_gone`), and the adapter is not deleted and has an
  #      access key in use (`:adapter_key_missing`). Otherwise no call is made. For a
  #      harness entry, its grant is live, of a connected connection of the entry's
  #      adapter, and the run may use it now: a grant of the run's organisation, or one of
  #      the instance's organisation with an assignment still in force for each source of
  #      the entry, under an adapter whose `credential_scope` is `resource`
  #      (`:connection_gone`).
  #   2. The call (`Apiary.Adapters.Calls.run_credential/3`), with the purpose `work`, also
  #      for a push entry: the connection's public id, the one resource the entry has, the
  #      collection's ref as the adapter listed it, and the entry's access, with no
  #      `grant_ref`. A failed call
  #      has the cause of `Apiary.Adapters.CallFailure`, and `:call_failed` for an
  #      exception on the call path, whose message is never read.
  #   3. The answer's check against the entry (`Apiary.Runs.RunCredentialIssue.check/3`),
  #      with its causes.
  #   4. The run, read again, is still live (`Apiary.Runs.Sender.live?/2`): pending or
  #      running, or lost after its attach and not lost for good, with no exit and no
  #      pruned events (`:run_not_live`).
  #
  # `record_issued/3` asks `Apiary.Access` again, as the credential goes out. After the
  # seal, `keep/1` keeps the answer's apply items on the entry
  # (`issued_apply`) when none are kept, and compares them with those kept otherwise, as
  # JSON values: the items in their order, the members of each in any order. Other items
  # are `:apply_moved`, because the gateway refuses a renewal whose items differ from
  # those at the run's start. The caller's transaction rolls back when a later write
  # fails, so the entry keeps only the items of a credential sealed and recorded.
  #
  # Each attempt writes one Activity entry, `run_credential.issue`, in the run's
  # organisation, about the run, by the gateway's key, unless the write fails: `issued`,
  # written last before the answer, or the cause of the refusal, with `:seal_failed` and
  # `:not_recorded` for a seal or a write that failed after the call, and
  # `:other_credential_failed` for a credential issued, or a call cancelled, when another
  # entry's of the same request failed, so it was not sent (`refused/4`). Its
  # details: the run's id, the connection's, the adapter's and the collection's public
  # ids, the target's path, the access, the purpose, the entry's name, the expiry when
  # issued and the outcome. A harness entry's has the run's id, the adapter's public id,
  # the sources it reads as shown, or `harness_hidden` and no source for a hidden
  # harness, and no grant, connection or collection. Every detail comes from the entry,
  # the connection, the adapter, the collection and the walk, and the expiry from the
  # checked answer: nothing of the token, and no word of the adapter.
  #
  # A refusal is `:unavailable` for a call that timed out or reached no one and for an
  # entry that could not be written, `:gone` for a run no longer live, and
  # `:credential_unavailable` for every other cause. On a pending run, a failed call with
  # a cause of `Apiary.Adapters.CallFailure`, a failed check and other apply items are
  # written on its run of the queue as well (`Apiary.Adapters.Calls.record_failure/3`); a
  # failed check and other apply items count as an invalid answer there. Every refusal
  # has a log line: the run's id, the connection's and the adapter's public ids and the
  # cause. No log line has a body, a header, a decode error or an exception message.
  #
  # The token stays in the checked credential (`Apiary.Runs.RunCredentialIssue`), whose
  # `inspect` hides it, until `value/2` builds the sealed value. Nothing here writes it
  # to the database or a log. No database transaction is open during the call.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Apiary.{Access, AccessKeys, Audit, Edition, Gateways, Harnesses, Repo}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{CallFailure, Calls, Collection, Connection, Grant}
  alias Apiary.Harnesses.RunHarness
  alias Apiary.Stacks.Document
  alias Apiary.Adapters.RunCredential, as: Answer
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Organisation
  alias Apiary.Runs.{Run, RunCredential, RunCredentialIssue, Sender}

  @typedoc "Why a work credential was not issued."
  @type cause ::
          :connection_gone
          | :adapter_key_missing
          | :call_failed
          | CallFailure.cause()
          | RunCredentialIssue.cause()
          | :run_not_live
          | :seal_failed
          | :apply_moved
          | :not_recorded
          | :other_credential_failed

  @typedoc """
  A credential `issue_all/5` issued and checked, with the entry it was issued for and the
  rows its Activity entry is made from.
  """
  @type t :: %{issued: RunCredentialIssue.t(), row: RunCredential.t(), place: map}

  @doc false
  # causes/0 is every cause an Activity entry's `outcome` may have, besides `issued`.
  @spec causes() :: [cause]
  def causes do
    [:connection_gone, :adapter_key_missing, :call_failed] ++
      CallFailure.causes() ++
      RunCredentialIssue.causes() ++
      [:run_not_live, :seal_failed, :apply_moved, :not_recorded, :other_credential_failed]
  end

  @doc false
  # sealable_to?/2 is whether a work credential of a run in the workspace `workspace_id`
  # of the organisation `organisation_id` may be sealed for `gateway`: a gateway of the
  # run's organisation, or the instance's gateway. A gateway made in a workspace
  # (`Apiary.Gateways.level/1`) only for a run of that workspace, whoever made it. False
  # for a run map without both `organisation_id` and `workspace_id`.
  @spec sealable_to?(Node.t(), %{organisation_id: Ecto.UUID.t(), workspace_id: Ecto.UUID.t()}) ::
          boolean
  def sealable_to?(
        %Node{kind: :gateway} = gateway,
        %{organisation_id: organisation_id, workspace_id: workspace_id}
      )
      when is_binary(organisation_id) do
    (is_nil(gateway.workspace_id) or gateway.workspace_id == workspace_id) and
      (Gateways.level(gateway) == :instance or gateway.organisation_id == organisation_id)
  end

  def sealable_to?(_gateway, _run), do: false

  @doc false
  # entry_sealable_to?/3 is whether the credential of the entry `row` of `run` may be
  # sealed for `gateway`: `sealable_to?/2`, and for a harness entry whose grant is of
  # another organisation than the run's, one that an assignment lets the run use, only
  # for a run on a machine that Qory Apiary provides (`assigned_machine?/2`, with the
  # run's pool): neither a gateway nor a pool that the run's organisation controls ever
  # receives a token from another organisation's grant. False for a harness entry whose
  # grant is gone.
  @spec entry_sealable_to?(Node.t(), Run.t(), RunCredential.t()) :: boolean
  def entry_sealable_to?(gateway, %Run{} = run, %RunCredential{purpose: :harness} = row) do
    case row.grant_id && Repo.get(Grant, row.grant_id) do
      %Grant{organisation_id: id} when id == run.organisation_id ->
        sealable_to?(gateway, run)

      %Grant{} ->
        sealable_to?(gateway, run) and
          assigned_machine?(gateway, run.node_id && Repo.get(Node, run.node_id))

      nil ->
        false
    end
  end

  def entry_sealable_to?(gateway, %Run{} = run, %RunCredential{}), do: sealable_to?(gateway, run)

  @doc false
  # assigned_machine?/2 is whether a run whose gateway is `gateway` and whose pool is
  # `pool` runs on a machine that Qory Apiary provides: the gateway is at the instance's
  # level (`Apiary.Gateways.level/1`) and the pool belongs to no organisation and no
  # workspace. The run's machine reaches the gateway's stack proxy with the run key, so a
  # read token from another organisation's grant goes only to such a run. False for no
  # pool.
  @spec assigned_machine?(Node.t(), Node.t() | nil) :: boolean
  def assigned_machine?(%Node{kind: :gateway} = gateway, pool) do
    Gateways.level(gateway) == :instance and
      match?(%Node{organisation_id: nil, workspace_id: nil}, pool)
  end

  def assigned_machine?(_gateway, _pool), do: false

  # How long past `until` the request waits for a call that has not ended: the call ends
  # itself at `until` (`Apiary.Adapters.Calls`), so only a call that fails to will wait.
  @grace 500

  @doc false
  # issue_all/5 is the credentials for `rows`, the entries of `run` in the order of the
  # run configuration, asked for by the gateway's `access_key` at `now` (Unix seconds):
  # `{:ok, [work]}` in the order of `rows`, with nothing written yet, or `{:error, refusal}`,
  # after the refusal's log line and its attempt at the Activity entry; `{:error,
  # :unavailable}` also where that entry cannot be written; `{:error, :not_found}` where
  # `Apiary.Access` refuses the key the action, with no call and no entry. Each entry is first checked in that order, with no call
  # (`:connection_gone`, `:adapter_key_missing`): the first that fails is the refusal, and
  # no call is made, and an entry checked before it gets no call and no Activity entry.
  # Then every call is made at the same time, each ending at the latest
  # at `until`, a time of the monotonic clock in milliseconds that the caller sets for the
  # whole request, and each answer is checked (`RunCredentialIssue.check/3`) in a process of
  # its entry, so one request takes the time of its slowest call, not the sum.
  #
  # The request stops at the first call or check that fails, or at `until`, and the calls
  # still running are cancelled. An entry whose call or check failed is refused for its
  # cause, in the order of `rows`; once `until` has passed, every entry still running is
  # refused as timed out, since all share the deadline. Every other entry, its credential
  # issued or its call cancelled before `until`, is refused as `:other_credential_failed`:
  # it is not sent. The refusal returned is the first failed entry's in the order of `rows`.
  # An adapter call that was sent cannot be recalled: a cancelled call ends at `until`.
  @spec issue_all(Run.t(), [RunCredential.t()], AccessKey.t(), integer, integer) ::
          {:ok, [t]} | {:error, :not_found | :unavailable | :gone | :credential_unavailable}
  def issue_all(%Run{} = run, rows, %AccessKey{} = access_key, now, until)
      when is_list(rows) and is_integer(now) and is_integer(until) do
    with {:ok, entries} <- prepare(run, rows, access_key) do
      entries
      |> request_all(now, until)
      |> settle(run, access_key)
    end
  end

  # The entries in order, each with its place, or the refusal of the first that fails.
  defp prepare(run, rows, access_key) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, entries} ->
      case prepare_one(run, row, access_key) do
        {:ok, entry} -> {:cont, {:ok, entries ++ [entry]}}
        {:error, _refusal} = error -> {:halt, error}
      end
    end)
  end

  defp prepare_one(run, %RunCredential{purpose: purpose, access: access} = row, access_key)
       when purpose in [:work, :push, :harness] do
    case may_issue(access_key, run) do
      :ok when purpose == :work and access == :write ->
        # A work entry is for the run's sessions and reads: only the push entry gets a write
        # credential.
        Logger.warning(
          "a work credential for the run #{run.node_run_id} was not issued: " <>
            "the entry #{row.name} has write access"
        )

        {:error, :credential_unavailable}

      :ok ->
        place = place(row)

        case live(place, run, row) do
          :ok -> {:ok, %{row: row, place: place, keys: Calls.answer_keys(place.adapter)}}
          {:error, cause, failure} -> refusal(access_key, run, row, place, cause, failure)
        end

      {:error, _reason} ->
        Logger.warning(
          "a work credential for the run #{run.node_run_id} was not issued: " <>
            "Apiary.Access refused run_credential.issue"
        )

        {:error, :not_found}
    end
  end

  # The call and the check of each entry, one process each. `{entry, result}` in the order
  # of `entries`, the result `{:ok, issued}`, `{:error, cause, failure}` or `:cancelled`.
  # The processes are not linked to the request's process (`async_nolink`): if it is
  # killed, their calls end by `until`, at most 8 seconds from the start of the request,
  # and write nothing. Each process takes the request's Logger metadata, for its log lines.
  defp request_all(entries, now, until) do
    metadata = Logger.metadata()

    tasks =
      for entry <- entries do
        Task.Supervisor.async_nolink(Apiary.Runs.TaskSupervisor, fn ->
          Logger.metadata(metadata)
          request(entry, now, until)
        end)
      end

    pending = tasks |> Enum.with_index() |> Map.new(fn {task, index} -> {task.ref, index} end)
    stop = until + @grace

    {done, _stopped?} = collect(pending, %{}, stop)
    late = cancel(tasks, done)

    # A call that is cancelled is a timeout only when the deadline has passed: a call that
    # fails with `timeout` before it (a call time too far from the clock, for one) does not
    # make its sibling one.
    timed_out? = System.monotonic_time(:millisecond) >= until

    entries
    |> Enum.with_index()
    |> Enum.map(fn {entry, index} ->
      result =
        case {Map.fetch(done, index), Map.fetch(late, index)} do
          {{:ok, result}, _late} ->
            result

          {:error, {:ok, :cancelled}} when timed_out? ->
            {:error, :timeout, timeout_failure(entry)}

          {:error, {:ok, result}} ->
            result
        end

      {entry, result}
    end)
  end

  # The call and the check of the answer. An exception or a throw in either is
  # `:call_failed`, with no message: it may contain the answer.
  defp request(%{place: place, row: row, keys: keys}, now, until) do
    with {:ok, answer} <- call(place, row, until, keys) do
      checked(row, answer, now)
    end
  rescue
    _exception -> {:error, :call_failed, nil}
  catch
    _kind, _reason -> {:error, :call_failed, nil}
  end

  # The results as they arrive, until each call has one, one has failed, or `stop`, a time
  # of the monotonic clock in milliseconds, has passed: `{results by index, whether `stop`
  # was reached}`. The failures that arrived together with the first are kept, so the
  # outcome does not depend on which of them was read first.
  defp collect(pending, done, _stop) when map_size(pending) == 0, do: {done, false}

  defp collect(pending, done, stop) do
    receive do
      {ref, result} when is_map_key(pending, ref) ->
        Process.demonitor(ref, [:flush])
        arrived(pending, done, ref, result, stop)

      {:DOWN, ref, :process, _pid, _reason} when is_map_key(pending, ref) ->
        arrived(pending, done, ref, {:error, :call_failed, nil}, stop)
    after
      max(stop - System.monotonic_time(:millisecond), 0) -> {done, true}
    end
  end

  defp arrived(pending, done, ref, result, stop) do
    {index, pending} = Map.pop!(pending, ref)
    done = Map.put(done, index, result)

    if match?({:ok, _issued}, result),
      do: collect(pending, done, stop),
      else: drain(pending, done)
  end

  # What has arrived already, without waiting: the stop is at hand.
  defp drain(pending, done) do
    receive do
      {ref, result} when is_map_key(pending, ref) ->
        Process.demonitor(ref, [:flush])
        {index, pending} = Map.pop!(pending, ref)
        drain(pending, Map.put(done, index, result))

      {:DOWN, ref, :process, _pid, _reason} when is_map_key(pending, ref) ->
        {index, pending} = Map.pop!(pending, ref)
        drain(pending, Map.put(done, index, {:error, :call_failed, nil}))
    after
      0 -> {done, false}
    end
  end

  # The processes that have no result are stopped. `%{index => result}`, the result
  # `:cancelled`, or the one that arrived while the process was stopped.
  defp cancel(tasks, done) do
    for {task, index} <- Enum.with_index(tasks), not is_map_key(done, index), into: %{} do
      case Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> {index, result}
        _none -> {index, :cancelled}
      end
    end
  end

  defp timeout_failure(%{place: %{adapter: %Node{} = adapter}}) do
    %CallFailure{
      adapter_id: adapter.id,
      adapter_public_id: adapter.public_id,
      adapter_name: adapter.name,
      path: "run-credential",
      cause: :timeout
    }
  end

  defp timeout_failure(_entry), do: nil

  # The refusals, and the credentials where none failed. A credential whose run is no
  # longer live after the calls is the failure of its entry (`:run_not_live`).
  defp settle(results, run, access_key) do
    results =
      if Enum.any?(results, &match?({_, {:error, _cause, _failure}}, &1)),
        do: results,
        else: Enum.map(results, &live_after(&1, run))

    failed = for {entry, {:error, cause, failure}} <- results, do: {entry, cause, failure}

    if failed == [] do
      {:ok,
       for(
         {%{row: row, place: place}, {:ok, issued}} <- results,
         do: %{issued: issued, row: row, place: place}
       )}
    else
      # The failed entries first, each for its cause; then the others, not sent.
      refusals =
        for {entry, cause, failure} <- failed do
          refusal(access_key, run, entry.row, entry.place, cause, failure)
        end

      for {%{row: row, place: place}, result} <- results, not match?({:error, _, _}, result) do
        refusal(access_key, run, row, place, :other_credential_failed, nil)
      end

      hd(refusals)
    end
  end

  defp live_after({entry, {:ok, _issued} = result}, run) do
    case still_live(run) do
      :ok -> {entry, result}
      {:error, cause, failure} -> {entry, {:error, cause, failure}}
    end
  end

  defp live_after(other, _run), do: other

  defp may_issue(%AccessKey{} = access_key, %Run{} = run),
    do: Access.check(Scope.for_access_key(access_key), :"run_credential.issue", run)

  @doc false
  # refused/4 writes the refusal of `work`, issued by `issue_all/5`, for `cause`, a step after
  # the call that failed: its log line, on a pending run its run of the queue for other
  # apply items, and its Activity entry. `{:error, :credential_unavailable}` for
  # `:apply_moved` and `:seal_failed`, `{:error, :unavailable}` for `:not_recorded` and
  # where the Activity entry cannot be written.
  @spec refused(
          AccessKey.t(),
          Run.t(),
          t,
          :seal_failed | :apply_moved | :not_recorded | :other_credential_failed
        ) :: {:error, :unavailable | :credential_unavailable}
  def refused(%AccessKey{} = access_key, %Run{} = run, %{row: row, place: place}, cause)
      when cause in [:seal_failed, :apply_moved, :not_recorded, :other_credential_failed] do
    refusal(access_key, run, row, place, cause, nil)
  end

  @doc false
  # keep/1 keeps the apply items of `work` on its entry, where none are kept, or compares
  # them with those kept: `:ok`, or `{:error, :apply_moved}` for other items. Inside the
  # caller's transaction, after the seal's records, which take the run's row first
  # (`Apiary.Runs.SecretsRequest`).
  @spec keep(t) :: :ok | {:error, :apply_moved}
  def keep(%{row: %RunCredential{id: id}, issued: %RunCredentialIssue{apply: apply}}) do
    query =
      from c in RunCredential,
        where: c.id == ^id,
        where: is_nil(c.issued_apply) or c.issued_apply == fragment("?::jsonb", ^apply)

    case Repo.update_all(query, set: [issued_apply: apply]) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, :apply_moved}
    end
  end

  @doc false
  # record_issued/3 writes the Activity entry of `work`, issued and sealed, inside the
  # caller's transaction, as its last write before the answer: `:ok`, or
  # `{:error, :not_recorded}`, also where `Apiary.Access` refuses the key the action.
  @spec record_issued(AccessKey.t(), Run.t(), t) :: :ok | {:error, :not_recorded}
  def record_issued(%AccessKey{} = access_key, %Run{} = run, %{issued: issued} = work) do
    with :ok <- may_issue(access_key, run),
         :ok <- record(access_key, run, work.row, work.place, "issued", issued.expires_at) do
      :ok
    else
      {:error, _reason} -> {:error, :not_recorded}
    end
  end

  @doc false
  # value/2 is the value of the credential `name` in the sealed plaintext of the Forager
  # contract, from `issued`: `credential`, `value`, then `expires_at` in UTC where the
  # answer has one, and `apply`, the answer's items.
  @spec value(String.t(), RunCredentialIssue.t()) :: map
  def value(name, %RunCredentialIssue{expires_at: expires_at, apply: apply} = issued) do
    %{"credential" => name, "value" => RunCredentialIssue.value(issued), "apply" => apply}
    |> then(
      &if(expires_at, do: Map.put(&1, "expires_at", DateTime.to_iso8601(expires_at)), else: &1)
    )
  end

  ## The connection and its adapter

  defp place(%RunCredential{purpose: :harness} = row) do
    grant = row.grant_id && Repo.get(Grant, row.grant_id)

    %{
      grant: grant,
      connection: grant && Repo.get(Connection, grant.connection_id),
      adapter: Repo.get(Node, row.adapter_id),
      collection: nil
    }
  end

  defp place(%RunCredential{} = row) do
    collection_id =
      case row.resources do
        [%{"collection_id" => id} | _] when is_binary(id) -> id
        _other -> nil
      end

    %{
      connection: Repo.get(Connection, row.connection_id),
      adapter: Repo.get(Node, row.adapter_id),
      collection: collection_id && Repo.get(Collection, collection_id)
    }
  end

  # A harness entry's grant is live, of a connected connection of the entry's adapter, and
  # the run may use it now: a grant of the run's organisation, or of the instance's
  # organisation with an assignment in force for each source the entry reads, under an
  # adapter whose credential reaches only the resources of the call
  # (`Apiary.Harnesses.allowed?/3`, `credential_scope` `resource`; an adapter that has not
  # said its scope since it started counts as `grant`). Else `:connection_gone`.
  defp live(%{grant: grant, connection: connection, adapter: adapter} = place, run, %{
         purpose: :harness,
         resources: resources
       }) do
    if match?(%Grant{ended_at: nil}, grant) and
         match?(%Connection{state: :connected}, connection) and
         grant.adapter_id == adapter_id(adapter) and connection.adapter_id == grant.adapter_id and
         harness_allowed?(grant, adapter, run, resources),
       do: adapter_live(place),
       else: {:error, :connection_gone, nil}
  end

  defp live(%{connection: connection, adapter: adapter} = place, %Run{} = run, _row) do
    if not match?(%Connection{state: :connected}, connection) or
         connection.organisation_id != run.organisation_id or
         connection.adapter_id != adapter_id(adapter),
       do: {:error, :connection_gone, nil},
       else: adapter_live(place)
  end

  defp harness_allowed?(%Grant{organisation_id: id}, _adapter, %Run{organisation_id: id}, _r),
    do: true

  defp harness_allowed?(%Grant{} = grant, adapter, %Run{} = run, resources) do
    sources = Enum.flat_map(resources, &List.wrap(&1["sources"]))

    grant.organisation_id == Edition.instance_organisation_id() and
      match?(%Node{credential_scope: :resource}, adapter) and sources != [] and
      Enum.all?(sources, &Harnesses.allowed?(run.organisation_id, grant.organisation_id, &1))
  end

  # The entry's adapter is not deleted and has an access key in use.
  defp adapter_live(%{adapter: adapter}) do
    if match?(%Node{kind: :adapter, deleted_at: nil}, adapter) and
         AccessKeys.active_keys(adapter) != [],
       do: :ok,
       else: {:error, :adapter_key_missing, nil}
  end

  defp adapter_id(%Node{id: id}), do: id
  defp adapter_id(nil), do: nil

  ## The call

  defp call(place, %RunCredential{} = row, until, keys) do
    request = request(place, row)
    adapter = place.adapter

    case Calls.run_credential(adapter, request, until: until, answer_keys: keys) do
      {:ok, %Answer{} = answer} -> {:ok, answer}
      {:error, %CallFailure{cause: cause} = failure} -> {:error, cause, failure}
    end
  rescue
    # An exception's message may contain the answer: only that one happened is kept.
    _exception -> {:error, :call_failed, nil}
  catch
    _kind, _reason -> {:error, :call_failed, nil}
  end

  # A harness entry's call is under its grant, for the resources the entry has, read
  # only, with no connection; a work or push entry's under its connection, for its one
  # collection.
  defp request(%{grant: %Grant{grant_ref: grant_ref}}, %RunCredential{purpose: :harness} = row),
    do: %{
      grant_ref: grant_ref,
      resources: Enum.map(row.resources, & &1["resource_ref"]),
      access: :read,
      purpose: :harness
    }

  defp request(%{connection: connection}, %RunCredential{} = row) do
    [%{"external_ref" => ref} | _] = row.resources
    %{connection_id: connection.public_id, resources: [ref], access: row.access, purpose: :work}
  end

  ## The answer

  defp checked(%RunCredential{} = row, %Answer{document: document}, now) do
    entry =
      %{"name" => row.name, "purpose" => Atom.to_string(row.purpose), "apply" => row.apply}
      |> then(&if(row.placeholders, do: Map.put(&1, "placeholders", row.placeholders), else: &1))

    case RunCredentialIssue.check(entry, document, DateTime.from_unix!(now)) do
      {:ok, issued} -> {:ok, issued}
      {:error, cause} -> {:error, cause, nil}
    end
  end

  # The run, read again after the call, on the clock read then.
  defp still_live(%Run{id: id}) do
    case Repo.get(Run, id) do
      %Run{} = run ->
        if Sender.live?(run, DateTime.utc_now()),
          do: :ok,
          else: {:error, :run_not_live, nil}

      nil ->
        {:error, :run_not_live, nil}
    end
  end

  ## What a refusal writes

  # The refusal's log line, its write on a pending run, its Activity entry, and its code.
  # An Activity entry that cannot be written makes the code `:unavailable`.
  defp refusal(access_key, run, row, place, cause, failure) do
    :ok = noted(cause, failure, run, row, place)

    case record(access_key, run, row, place, Atom.to_string(cause), nil) do
      :ok -> {:error, code(cause)}
      {:error, :unavailable} -> {:error, :unavailable}
    end
  end

  defp code(cause) when cause in [:timeout, :unreachable, :not_recorded], do: :unavailable
  defp code(:run_not_live), do: :gone
  defp code(_cause), do: :credential_unavailable

  defp noted(cause, failure, %Run{} = run, %RunCredential{} = row, place) do
    Logger.warning(
      "a #{kind(row)} credential for the run #{run.node_run_id} was not issued " <>
        "connection=#{public_id(place.connection)} adapter=#{public_id(place.adapter)} " <>
        "credential=#{row.name} cause=#{cause}"
    )

    failure = failure || answer_failure(cause, place.adapter)

    # A run of the queue that is gone has nothing to write on.
    if match?(%CallFailure{}, failure) and run.state == "pending" and
         is_binary(run.dispatch_run_id),
       do: Calls.record_failure(Repo, %DispatchRun{id: run.dispatch_run_id}, failure)

    :ok
  end

  # A failed check, or other apply items, as the run's page shows an adapter's failure: an
  # invalid answer to the call.
  defp answer_failure(cause, %Node{kind: :adapter} = adapter) do
    if cause in RunCredentialIssue.causes() or cause == :apply_moved do
      %CallFailure{
        adapter_id: adapter.id,
        adapter_public_id: adapter.public_id,
        adapter_name: adapter.name,
        path: "run-credential",
        cause: :invalid_answer,
        status: 200
      }
    end
  end

  defp answer_failure(_cause, _adapter), do: nil

  defp kind(%RunCredential{purpose: :harness}), do: "harness"
  defp kind(%RunCredential{}), do: "work"

  defp public_id(%{public_id: public_id}), do: public_id
  defp public_id(nil), do: "none"

  ## The Activity entry

  defp record(access_key, %Run{} = run, %RunCredential{} = row, place, result, expires_at) do
    details =
      row
      |> details(run, place, result)
      |> then(
        &if(expires_at, do: Map.put(&1, "expires_at", DateTime.to_iso8601(expires_at)), else: &1)
      )

    with %Organisation{} = organisation <- Repo.get(Organisation, run.organisation_id),
         scope = Scope.key_in_organisation(Scope.for_access_key(access_key), organisation),
         {:ok, _entry} <-
           Audit.record(Repo, scope, :"run_credential.issue", run, %{details: details}) do
      :ok
    else
      _failed ->
        Logger.error(
          "the Activity entry of a #{kind(row)} credential for the run #{run.node_run_id} " <>
            "could not be written"
        )

        {:error, :unavailable}
    end
  end

  # A harness entry's details: the run, the adapter, the sources the entry reads, each once
  # as `Apiary.Stacks.Document.shown/1` writes it, and `harness_hidden`, true and no
  # sources, for a run whose harness is hidden. No grant or connection: either may be of
  # another organisation.
  defp details(%RunCredential{purpose: :harness} = row, run, place, result) do
    base = %{
      "run_id" => run.node_run_id,
      "adapter_id" => public_id_or_nil(place.adapter),
      "access" => Atom.to_string(row.access),
      "purpose" => "harness",
      "credential" => row.name,
      "outcome" => result
    }

    if harness_hidden?(run) do
      Map.put(base, "harness_hidden", true)
    else
      sources =
        for resource <- row.resources,
            %{"git" => git} <- List.wrap(resource["sources"]),
            is_binary(git),
            uniq: true,
            do: Document.shown(git)

      Map.put(base, "sources", sources)
    end
  end

  defp details(%RunCredential{} = row, run, place, result) do
    %{
      "run_id" => run.node_run_id,
      "connection_id" => public_id_or_nil(place.connection),
      "adapter_id" => public_id_or_nil(place.adapter),
      "collection_id" => public_id_or_nil(place.collection),
      "target_path" => target_path(row),
      "access" => Atom.to_string(row.access),
      "purpose" => Atom.to_string(row.purpose),
      "credential" => row.name,
      "outcome" => result
    }
  end

  # Whether the harness walk of the run's run of the queue hid the run's harness. A run
  # with no walk found hides it, so no source shows.
  defp harness_hidden?(%Run{dispatch_run_id: id}) when is_binary(id) do
    Repo.one(from h in RunHarness, where: h.dispatch_run_id == ^id, select: h.harness_hidden) !=
      false
  end

  defp harness_hidden?(_run), do: true

  defp public_id_or_nil(%{public_id: public_id}), do: public_id
  defp public_id_or_nil(nil), do: nil

  defp target_path(%RunCredential{resources: [%{"path" => path} | _]}) when is_binary(path),
    do: path

  defp target_path(_row), do: nil
end
