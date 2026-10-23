defmodule Apiary.Runs.Outcome do
  @moduledoc """
  A run's outcome, as its starter gives it: how the run went, in the starter's words,
  which sets the run's state whenever it arrives, before the run's exit or after it.

  `parse/1` reads the outcome's body, decoded: `version`, 1; `time`, a date and time in UTC
  to the whole second, `2026-10-11T12:30:00Z`, which is a real one; `state`, which may be
  left out, `succeeded`, `failed` or `cancelled`; and `reason`, which may be left out. A
  member the contract does not name is refused as `"body"`, and a body that breaks a rule
  is `{:error, :invalid_request, detail}`, where `detail` names the member and never
  repeats a value. Whether `time` is within `max_skew_seconds/0` of the server's clock is
  the caller's to ask (`fresh?/2`).

  `reason` is an open code: a lower-case letter, then lower-case letters, digits and `_`,
  64 at most. A reason that is not one, or that is one of the codes Forager or Qory keeps
  for itself (`reserved_reasons/0`), is dropped, and the outcome is kept without it. An
  outcome with no `state` is `cancelled` with the reason `stopped`.

  `give/4` stores it on the run. A key `Apiary.Access` does not let post
  (`run.post_events`) is `{:error, :not_found}`, and so is a run of a workspace's queue,
  which a node pool claimed (`dispatch_run_id`), whatever the key: such a run ends by its
  exit, its refusal or the lost-run check, never by an outcome. Then, the first that
  applies:

    1. a repeat: the same outcome again, under any active key of the node the run is
       bound to (`Apiary.Runs.Sender`), is given the same answer, nothing
       stored again. The same outcome is the same state and reason as `parse/1` reads
       them, whatever its bytes: a new `time`, a reason dropped by the rules above, and
       no state at all (cancelled, stopped) all count. The first outcome's `time`, when it
       arrived and its digest stay;
    2. a run id the key's workspace does not hold, a run of another node, and a run
       whose events retention has pruned are `{:error, :not_found}`;
    3. a run that was given another outcome, another state or reason, is
       `{:error, :outcome_given}`: each run gets one;
    4. else the outcome is stored on the run, with when it arrived and the SHA-256 of its
       bytes, and the run's state and reason are the outcome's at once
       (`Apiary.Runs.Fold.outcome/1`). What the run's exit said, its exit code, its signal
       and Forager's reason, stays beside them.

  The outcome is not folded from the run's events: a rebuild keeps it, and the fold applies
  it after every pass, so it decides the run's state whatever the order of the two. Until
  the run's `dev.qory.run.exited` arrives, each signed `2xx` to the run's batches carries
  `end` with the outcome's state and reason (`Apiary.Runs.Ingest`).
  """

  import Ecto.Query, warn: false

  require Logger

  alias Apiary.{Access, Repo, Runs}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.Scope
  alias Apiary.Runs.{Batch, Fold, Projector, Run, Sender}

  @version "version"
  @state "state"
  @reason "reason"
  @time "time"
  @members [@version, @state, @reason, @time]

  @document_version 1
  @states ~w(succeeded failed cancelled)
  @code ~r/\A[a-z][a-z0-9_]{0,63}\z/
  # The reasons Forager writes for itself in `dev.qory.run.exited`, and the old names it
  # never writes, and `released`, which Qory sets itself for a run its starter released
  # (`Apiary.Runs.Fold.settle/1`): a starter's outcome may not give one.
  @reserved ~w(
    timeout interrupted no_session quiet credential_expired stopped session_lost gateway_lost
    batch_refused credential_check_unreachable credential_check_invalid run_closed
    run_ended_at_issuer issuer_unreachable issuer_answer_invalid image_missing released
  )
  @max_skew_seconds 300
  @whole_seconds ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z/

  @typedoc "An outcome's body, as `parse/1` read it: the state and reason it stands for."
  @type t :: %__MODULE__{state: String.t(), reason: String.t() | nil, time: DateTime.t()}

  @enforce_keys [:state, :reason, :time]
  defstruct @enforce_keys

  @doc "The most seconds an outcome's `time` may be from the server's clock."
  def max_skew_seconds, do: @max_skew_seconds

  @doc """
  The reasons a starter may not give: Forager's reasons, the old names it never writes, and
  `released`, which Qory sets itself.
  """
  def reserved_reasons, do: @reserved

  @doc "Reads an outcome's decoded body: see the moduledoc for the rules."
  @spec parse(term) :: {:ok, t} | {:error, :invalid_request, String.t()}
  def parse(%{} = body) do
    with :ok <- check(Enum.all?(Map.keys(body), &(&1 in @members)), "body"),
         :ok <- check(body[@version] == @document_version, @version),
         {:ok, time} <- time(body[@time]),
         {:ok, state} <- state(body[@state]) do
      case state do
        nil -> {:ok, %__MODULE__{state: "cancelled", reason: "stopped", time: time}}
        state -> {:ok, %__MODULE__{state: state, reason: reason(body[@reason]), time: time}}
      end
    end
  end

  def parse(_body), do: invalid("body")

  @doc "Whether the outcome's `time` is within `max_skew_seconds/0` of `now`, either side."
  @spec fresh?(t, DateTime.t()) :: boolean
  def fresh?(%__MODULE__{time: time}, %DateTime{} = now \\ DateTime.utc_now()),
    do: abs(DateTime.diff(time, now, :microsecond)) <= @max_skew_seconds * 1_000_000

  defp check(true, _member), do: :ok
  defp check(_false, member), do: invalid(member)

  defp invalid(detail), do: {:error, :invalid_request, detail}

  defp time(value) do
    with true <- is_binary(value) and Regex.match?(@whole_seconds, value),
         {:ok, time} <- Batch.time(value) do
      {:ok, time}
    else
      _ -> invalid(@time)
    end
  end

  defp state(nil), do: {:ok, nil}
  defp state(state) when state in @states, do: {:ok, state}
  defp state(_state), do: invalid(@state)

  # A code that is not Forager's, or nothing: a reason that breaks the rule is dropped, and
  # the outcome kept.
  defp reason(reason) when is_binary(reason) do
    if Regex.match?(@code, reason) and reason not in @reserved, do: reason
  end

  defp reason(_reason), do: nil

  @doc """
  Gives the run `run_id` the outcome, for the key (an access key, or its scope), in the
  order the moduledoc gives. `body` is the outcome's bytes, whose SHA-256 is kept with the
  first outcome. `{:ok, %{run: run, repeated: boolean}}`, or `{:error, reason}` with
  `:not_found`, `:outcome_given` or `:unavailable`.
  """
  @spec give(AccessKey.t() | Scope.t(), term, t, binary) ::
          {:ok, %{run: Run.t(), repeated: boolean}}
          | {:error, :not_found | :outcome_given | :unavailable}
  def give(%Scope{access_key: %AccessKey{} = access_key}, run_id, outcome, body),
    do: give(access_key, run_id, outcome, body)

  def give(%AccessKey{} = access_key, run_id, %__MODULE__{} = outcome, body)
      when is_binary(body) do
    now = DateTime.utc_now()
    digest = :crypto.hash(:sha256, body)
    access_key = Repo.preload(access_key, [:workspace, :node])

    with :ok <- may_post(Scope.for_access_key(access_key)),
         true <- Batch.uuid?(run_id) || {:error, :not_found},
         %Run{} = held <- held(access_key, run_id) || {:error, :not_found},
         true <- is_nil(held.dispatch_run_id) || {:error, :not_found},
         {:ok, %{run: run, repeated: repeated}} <- store(held, access_key, outcome, digest, now) do
      if not repeated, do: Runs.broadcast_changed(run)
      {:ok, %{run: run, repeated: repeated}}
    end
  rescue
    exception ->
      Logger.error("an outcome could not be stored: #{inspect(exception.__struct__)}")
      {:error, :unavailable}
  end

  # A key's scope is never refused a role here; what can refuse it is a feature that is off.
  defp may_post(scope) do
    case Access.authorize(scope, :"run.post_events", Scope.key_place(scope)) do
      :ok -> :ok
      {:error, _reason} -> {:error, :not_found}
    end
  end

  # A key with no workspace, an organisation-level gateway's, holds no run of its own.
  defp held(%AccessKey{workspace_id: nil}, _run_id), do: nil

  defp held(access_key, run_id) do
    Repo.one(
      from r in Run,
        where: r.workspace_id == ^access_key.workspace_id and r.node_run_id == ^run_id,
        select: struct(r, [:id, :dispatch_run_id])
    )
  end

  # Under the run's projection lock and its row's, as a projection writes it, so a pass
  # and the outcome never write over each other: whichever comes second reads the other's.
  # A run of a workspace's queue never comes here (`give/4`), so nothing of the queue is
  # locked or ended.
  defp store(%Run{id: id}, access_key, outcome, digest, now) do
    Repo.transact(fn ->
      Projector.lock(id)
      run = Repo.one(from r in Run, where: r.id == ^id, lock: "FOR UPDATE")

      cond do
        is_nil(run) ->
          {:error, :not_found}

        not Sender.registered_by?(run, access_key) ->
          {:error, :not_found}

        same?(run, outcome) ->
          {:ok, %{run: run, repeated: true}}

        not is_nil(run.events_pruned_at) ->
          {:error, :not_found}

        not is_nil(run.outcome_state) ->
          {:error, :outcome_given}

        true ->
          {:ok, %{run: put(run, outcome, digest, now), repeated: false}}
      end
    end)
  end

  # The outcome the run holds, by its state and reason as stored: the bytes, the time and
  # whatever a reason dropped by the rules was do not tell two outcomes apart.
  defp same?(%Run{outcome_state: state, outcome_reason: reason}, %__MODULE__{} = outcome),
    do: is_binary(state) and state == outcome.state and reason == outcome.reason

  defp put(run, outcome, digest, now) do
    given = %{
      run
      | outcome_state: outcome.state,
        outcome_reason: outcome.reason,
        outcome_time: outcome.time,
        outcome_received_at: now,
        outcome_digest: digest
    }

    applied = Fold.outcome(given)

    run
    |> Ecto.Changeset.change(
      outcome_state: outcome.state,
      outcome_reason: outcome.reason,
      outcome_time: outcome.time,
      outcome_received_at: now,
      outcome_digest: digest,
      state: applied.state,
      reason: applied.reason,
      lost_at: applied.lost_at,
      updated_at: now
    )
    |> Repo.update!()
  end
end
