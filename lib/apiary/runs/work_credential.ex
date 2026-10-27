defmodule Apiary.Runs.WorkCredential do
  # The value of a run's work entry (`Apiary.Runs.RunCredentials`, `work-1`), for a secrets
  # request that names it (`Apiary.Runs.SecretsRequest`): `issue/4` asks the adapter for a
  # credential and checks the answer; the caller seals it, then keeps its apply items
  # (`keep/1`) and writes its Activity entry (`record_issued/3`) in one transaction.
  #
  # The caller makes every check that needs no token first, the model key's read
  # included, so that a credential the adapter issued fails only at a step that needs it.
  #
  # `issue/4`, in this order, stops at the first refusal:
  #
  #   1. The entry's connection is connected, of the run's organisation and of the
  #      entry's adapter (`:connection_gone`), and the adapter is not deleted and has an
  #      access key in use (`:adapter_key_missing`). Otherwise no call is made.
  #   2. The call (`Apiary.Adapters.Calls.run_credential/3`), with the purpose `work`: the
  #      connection's public id, the one resource the entry has, the collection's ref as
  #      the adapter listed it, and the entry's access, with no `grant_ref`. A failed call
  #      has the cause of `Apiary.Adapters.CallFailure`, and `:call_failed` for an
  #      exception on the call path, whose message is never read.
  #   3. The answer's check against the entry (`Apiary.Runs.RunCredentialIssue.check/3`),
  #      with its causes.
  #   4. The run, read again, is still live: pending or running, its sending not ended
  #      (`:run_not_live`).
  #
  # After the seal, `keep/1` keeps the answer's apply items on the entry
  # (`issued_apply`) when none are kept, and compares them with those kept otherwise, as
  # JSON values: the items in their order, the members of each in any order. Other items
  # are `:apply_moved`, because the gateway refuses a renewal whose items differ from
  # those at the run's start. The caller's transaction rolls back when a later write
  # fails, so the entry keeps only the items of a credential sealed and recorded.
  #
  # Each attempt writes one Activity entry, `run_credential.issue`, in the run's
  # organisation, about the run, by the gateway's key, unless the write fails: `issued`,
  # written last before the answer, or the cause of the refusal, with `:seal_failed` and
  # `:not_recorded` for a seal or a write that failed after the call (`refused/4`). Its
  # details: the run's id, the connection's, the adapter's and the collection's public
  # ids, the target's path, the access, the purpose, the entry's name, the expiry when
  # issued and the outcome. Every detail comes from the entry, the connection, the
  # adapter and the collection, and the expiry from the checked answer: nothing of the
  # token, and no word of the adapter.
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

  alias Apiary.{AccessKeys, Audit, Gateways, Repo}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{CallFailure, Calls, Collection, Connection}
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

  @typedoc """
  A credential `issue/4` issued and checked, with the entry it was issued for and the
  rows its Activity entry is made from.
  """
  @type t :: %{issued: RunCredentialIssue.t(), row: RunCredential.t(), place: map}

  @doc false
  # causes/0 is every cause an Activity entry's `outcome` may have, besides `issued`.
  @spec causes() :: [cause]
  def causes do
    [:connection_gone, :adapter_key_missing, :call_failed] ++
      CallFailure.causes() ++
      RunCredentialIssue.causes() ++ [:run_not_live, :seal_failed, :apply_moved, :not_recorded]
  end

  @doc false
  # sealable_to?/2 is whether a work credential of a run of `run_organisation_id` may be
  # sealed for `gateway`: a gateway of the run's organisation, the instance's gateway, or
  # a gateway of an organisation whose gateways serve the run's
  # (`Apiary.Gateways.serving_organisations/1`). The last is more than a model key of the
  # organisation's chain may reach (`Apiary.Runs.ProviderCredential.sealable_to?/3`).
  @spec sealable_to?(Node.t(), Ecto.UUID.t()) :: boolean
  def sealable_to?(%Node{kind: :gateway} = gateway, run_organisation_id)
      when is_binary(run_organisation_id) do
    Gateways.level(gateway) == :instance or
      gateway.organisation_id == run_organisation_id or
      gateway.organisation_id in Gateways.serving_organisations(run_organisation_id)
  end

  def sealable_to?(_gateway, _run_organisation_id), do: false

  @doc false
  # issue/4 is the work credential for `run`'s entry `row`, asked for by the gateway's
  # `access_key` at `now` (Unix seconds): `{:ok, work}`, with nothing written yet, or
  # `{:error, :unavailable | :gone | :credential_unavailable}`, after the refusal's log
  # line and its attempt at the Activity entry; `{:error, :unavailable}` also where that
  # entry cannot be written.
  @spec issue(Run.t(), RunCredential.t(), AccessKey.t(), integer) ::
          {:ok, t} | {:error, :unavailable | :gone | :credential_unavailable}
  def issue(%Run{} = run, %RunCredential{purpose: :work} = row, %AccessKey{} = access_key, now)
      when is_integer(now) do
    place = place(row)

    outcome =
      with :ok <- live(place, run),
           {:ok, answer} <- call(place, row),
           {:ok, issued} <- checked(row, answer, now),
           :ok <- still_live(run) do
        {:ok, issued}
      end

    case outcome do
      {:ok, issued} -> {:ok, %{issued: issued, row: row, place: place}}
      {:error, cause, failure} -> refusal(access_key, run, row, place, cause, failure)
    end
  end

  @doc false
  # refused/4 writes the refusal of `work`, issued by `issue/4`, for `cause`, a step after
  # the call that failed: its log line, on a pending run its run of the queue for other
  # apply items, and its Activity entry. `{:error, :credential_unavailable}` for
  # `:apply_moved` and `:seal_failed`, `{:error, :unavailable}` for `:not_recorded` and
  # where the Activity entry cannot be written.
  @spec refused(AccessKey.t(), Run.t(), t, :seal_failed | :apply_moved | :not_recorded) ::
          {:error, :unavailable | :credential_unavailable}
  def refused(%AccessKey{} = access_key, %Run{} = run, %{row: row, place: place}, cause)
      when cause in [:seal_failed, :apply_moved, :not_recorded] do
    refusal(access_key, run, row, place, cause, nil)
  end

  @doc false
  # keep/1 keeps the apply items of `work` on its entry, where none are kept, or compares
  # them with those kept: `:ok`, or `{:error, :apply_moved}` for other items. Inside the
  # caller's transaction, after the seal.
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
  # `{:error, :not_recorded}`.
  @spec record_issued(AccessKey.t(), Run.t(), t) :: :ok | {:error, :not_recorded}
  def record_issued(%AccessKey{} = access_key, %Run{} = run, %{issued: issued} = work) do
    case record(access_key, run, work.row, work.place, "issued", issued.expires_at) do
      :ok -> :ok
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

  defp live(%{connection: connection, adapter: adapter}, %Run{} = run) do
    cond do
      not match?(%Connection{state: :connected}, connection) or
        connection.organisation_id != run.organisation_id or
          connection.adapter_id != adapter_id(adapter) ->
        {:error, :connection_gone, nil}

      not match?(%Node{kind: :adapter, deleted_at: nil}, adapter) or
          AccessKeys.active_keys(adapter) == [] ->
        {:error, :adapter_key_missing, nil}

      true ->
        :ok
    end
  end

  defp adapter_id(%Node{id: id}), do: id
  defp adapter_id(nil), do: nil

  ## The call

  defp call(%{connection: connection, adapter: adapter}, %RunCredential{} = row) do
    [%{"external_ref" => ref} | _] = row.resources

    request = %{
      connection_id: connection.public_id,
      resources: [ref],
      access: row.access,
      purpose: :work
    }

    case Calls.run_credential(adapter, request) do
      {:ok, %Answer{} = answer} -> {:ok, answer}
      {:error, %CallFailure{cause: cause} = failure} -> {:error, cause, failure}
    end
  rescue
    # An exception's message may contain the answer: only that one happened is kept.
    _exception -> {:error, :call_failed, nil}
  catch
    _kind, _reason -> {:error, :call_failed, nil}
  end

  ## The answer

  defp checked(%RunCredential{} = row, %Answer{document: document}, now) do
    entry =
      %{"name" => row.name, "purpose" => "work", "apply" => row.apply}
      |> then(&if(row.placeholders, do: Map.put(&1, "placeholders", row.placeholders), else: &1))

    case RunCredentialIssue.check(entry, document, DateTime.from_unix!(now)) do
      {:ok, issued} -> {:ok, issued}
      {:error, cause} -> {:error, cause, nil}
    end
  end

  # The run, read again after the call.
  defp still_live(%Run{id: id}) do
    case Repo.get(Run, id) do
      %Run{} = run ->
        if run.state in Run.alive_states() and not Sender.sending_ended?(run),
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
    :ok = noted(cause, failure, run, place)

    case record(access_key, run, row, place, Atom.to_string(cause), nil) do
      :ok -> {:error, code(cause)}
      {:error, :unavailable} -> {:error, :unavailable}
    end
  end

  defp code(cause) when cause in [:timeout, :unreachable, :not_recorded], do: :unavailable
  defp code(:run_not_live), do: :gone
  defp code(_cause), do: :credential_unavailable

  defp noted(cause, failure, %Run{} = run, place) do
    Logger.warning(
      "a work credential for the run #{run.node_run_id} was not issued " <>
        "connection=#{public_id(place.connection)} adapter=#{public_id(place.adapter)} " <>
        "cause=#{cause}"
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

  defp public_id(%{public_id: public_id}), do: public_id
  defp public_id(nil), do: "none"

  ## The Activity entry

  defp record(access_key, %Run{} = run, %RunCredential{} = row, place, result, expires_at) do
    details =
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
          "the Activity entry of a work credential for the run #{run.node_run_id} could " <>
            "not be written"
        )

        {:error, :unavailable}
    end
  end

  defp public_id_or_nil(%{public_id: public_id}), do: public_id
  defp public_id_or_nil(nil), do: nil

  defp target_path(%RunCredential{resources: [%{"path" => path} | _]}) when is_binary(path),
    do: path

  defp target_path(_row), do: nil
end
