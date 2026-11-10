defmodule Apiary.Runs.RunCode do
  @moduledoc false

  # A run code: what a node pool's claim answers in place of a run key
  # (`run_code` of the provisioner contract's claim answer, `Apiary.Dispatches.Handover`),
  # and what the machine redeems once at enrolment for that run key (the Forager
  # contract's `qecr_`, `ApiaryWeb.Contract.EnrolmentController`). The run key is never in
  # the start data a machine can read back; the code works once, for 15 minutes.
  #
  # **Its form.** `qecr_` and 26 upper-case Crockford base32 characters, 130 random bits
  # (`Apiary.AccessKeys.EnrolmentCode.generate/1`), then `.` and the fingerprint of the
  # server's key, as every enrolment code is given. The run keeps the code's SHA-256 alone
  # (`runs.run_code_sha256`), never the code.
  #
  # **At the claim** (`issue/2`) the run is registered with no run key: its
  # `run_key_issued_at` is the claim, its `attach_by` the code's expiry, `ttl_seconds/0`
  # after the claim, and what its run key will grant is kept (`run_code_grant`). The
  # lost-run check and liveness read `attach_by` as for any run through a gateway not yet
  # attached, so a run whose code is never redeemed is lost at the code's expiry. While
  # the claim holds, its registered run lives with it: a lease that lapses or a release
  # ends it failed (`Apiary.Dispatches.Handover.fail_start/3`), and a close ends it
  # cancelled, as a failed start leaves it (`Apiary.Dispatches.Queued`).
  #
  # **At the redemption** (`redeem/2`), in the order of every enrolment code:
  #
  #   1. a timestamp more than 300 seconds from the clock, a code that carries another
  #      fingerprint than the server key's or two, a request no gateway's relay signed
  #      (`relayed_by` nil), or a code no run has, of a workspace and an organisation in
  #      use, is `{:error, :unauthorized}`;
  #   2. then, in one transaction, under the lock of the run's run of the queue
  #      (`Apiary.Dispatches.RunEnd.lock/1`), its projection lock and its row
  #      `FOR UPDATE`: a run deleted meanwhile, a code relayed by another node than the
  #      gateway the claim bound it to (`runs.gateway_id`), checked before the code's
  #      state, a code at or past its expiry, or of a run that has ended (no longer
  #      `pending` or `running`, released, given its outcome or its events pruned), is
  #      `{:error, :unauthorized}`; so is a code whose run of the queue is neither handed
  #      over nor claimed, or claimed by a dispatch that ended,
  #      went stale, or whose `lease_until` the clock is at or past, and a code redeemed
  #      before by another public key;
  #   3. a key the key checks refuse, or a proof that does not verify under it, is
  #      `{:error, :key_unproven}`;
  #   4. past the code's limit, `{:error, {:rate_limited, seconds}}`;
  #   5. the first redemption makes the run key from the grant kept at the claim, issued
  #      at the redemption in whole seconds, its `attach_by` 600 seconds after, and writes
  #      the run key's payload, its signature, `run_key_issued_at`, `attach_by`, the
  #      public key and its proof's timestamp in one write; a claimed dispatch is handed
  #      over in the same transaction (`Apiary.Dispatches.Handover.hand_over/3`), and
  #      once it commits the run is broadcast as changed
  #      (`Apiary.Runs.broadcast_changed/1`). A retry
  #      by the same public key whose proof's timestamp is newer than the one stored is
  #      answered the run key the run has, byte for byte, and writes its proof's timestamp
  #      in place of the one stored, with `updated_at`, and nothing else; one whose
  #      timestamp is equal or older is a replayed proof, `{:error, :unauthorized}`, as
  #      step 2's refusals are. So the stored timestamp is the newest accepted
  #      redemption's, and a retry captured and sent again is refused as any replayed
  #      proof.
  #
  # So a code works from the claim until its expiry, and stops before then when the
  # claim's lease lapses before the handover, or when the dispatch ends, at a release
  # among others.
  #
  # **A late machine.** A code refused at step 2 because it expired, its run ended, or
  # its dispatch is stale, ended or past its lease, whose proof verifies, shows that a
  # machine came up for a dispatch that takes none: within the code's limit of step 4,
  # the dispatch the run was registered for, not handed over, locked `FOR UPDATE` after
  # the run, keeps the time
  # (`Apiary.Dispatches.Slots.late_machine/2`) and holds its slot of its pool's limit
  # until the machine is reported `gone`. That write commits, and the answer is still
  # `{:error, :unauthorized}`. A code redeemed after a close finds the run ended, and is
  # such a late machine, as after a release.
  #
  # The answer is `{:ok, %{run_id: run_id, run_key: run_key, documents: documents}}`, the
  # documents as the claim encoded them (`runs.run_documents`), the same bytes to every
  # redemption. No access key is made, and no public key enters the ledger of access keys. Nothing here logs the code, the proof, a key
  # or the run key.

  import Ecto.Query, only: [from: 2]

  alias Apiary.{AccessKeys, Repo, SigningKey}
  alias Apiary.AccessKeys.EnrolmentCode
  alias Apiary.Contract.{Ed25519, Enrolment}
  alias Apiary.Dispatches.{Dispatch, DispatchRun, Handover, RunEnd, Slots}
  alias Apiary.Organisations.Organisation
  alias Apiary.Runs.{Projector, Registration, Run, RateLimit, RunKey}

  # The attach window from the redemption, in seconds: the Forager contract's
  # `$defs/run_answer`.
  @attach_seconds 600
  # A run code's limit at enrolment, as `Apiary.Runs.RateLimit` counts it: requests a
  # second, and at once; an enrolment code's.
  @code_limit [rate: 1, burst: 5]

  # ttl_seconds/0 is how long a run code works after its claim: an enrolment code's 15
  # minutes.
  @doc false
  @spec ttl_seconds() :: pos_integer
  def ttl_seconds, do: AccessKeys.code_ttl_minutes() * 60

  # issue/2 is a fresh run code for a run claimed at `now`, whose run key will grant
  # `grant` (`Apiary.Runs.Registration.through_grant/3`): `%{code: code, through: fields}`,
  # the code as the machine is given it, with the fingerprint of the server's key, and the
  # run's fields that keep it: its SHA-256, its expiry `ttl_seconds/0` after `now` in whole
  # seconds, the grant, and `run_key_issued_at` and `attach_by`, the claim and the code's
  # expiry.
  @doc false
  @spec issue(map, DateTime.t()) :: %{code: String.t(), through: map}
  def issue(%{} = grant, %DateTime{} = now) do
    code = EnrolmentCode.generate(:run)
    issued = DateTime.truncate(now, :second)
    expires_at = usec(DateTime.add(issued, ttl_seconds(), :second))

    %{
      code: Enrolment.issued_code(code, SigningKey.fingerprint()),
      through: %{
        run_code_sha256: EnrolmentCode.hash(code),
        run_code_expires_at: expires_at,
        run_code_grant: dump(grant),
        run_key_issued_at: usec(issued),
        attach_by: expires_at
      }
    }
  end

  # redeem/2 redeems the run code of `request` for its run's run key: the moduledoc.
  #
  # `opts`: `now`, the time it is (the current time); `fingerprint`, the signing key's
  # fingerprint (`Apiary.SigningKey.fingerprint/0`); `code_limit`, the code's limit;
  # `relayed_by`, the id of the node whose access key signed the request as a gateway's
  # relay (`ApiaryWeb.Contract.SignedRequest.relayed/1`). Without it, every code is
  # `{:error, :unauthorized}`.
  @doc false
  @spec redeem(Enrolment.t(), keyword) ::
          {:ok, %{run_id: String.t(), run_key: String.t(), documents: binary | nil}}
          | {:error, :unauthorized | :key_unproven | {:rate_limited, pos_integer}}
  def redeem(%Enrolment{} = request, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    fingerprint = Keyword.get_lazy(opts, :fingerprint, &SigningKey.fingerprint/0)
    code_limit = Keyword.merge(@code_limit, Keyword.get(opts, :code_limit, []))
    relayed_by = Keyword.get(opts, :relayed_by)

    with true <- EnrolmentCode.run_code?(request.code_head) || {:error, :unauthorized},
         true <- Enrolment.fresh?(request, now) || {:error, :unauthorized},
         true <- Enrolment.issued_under?(request, fingerprint) || {:error, :unauthorized},
         true <- is_binary(relayed_by) || {:error, :unauthorized},
         %{id: _id} = found <- find_run(request.code_head) || {:error, :unauthorized} do
      Repo.transact(fn -> redeem_locked(found, request, relayed_by, now, code_limit) end)
      |> broadcast_redeemed()
    end
  end

  # Once the first redemption committed, the run is broadcast as changed, so its page
  # shows the machine's start at once (`Apiary.Dispatches.Handover.broadcast_run/1`). A
  # retry changes nothing the page shows, and is not broadcast.
  defp broadcast_redeemed({:ok, {answer, %Run{} = run}}) do
    Handover.broadcast_run({:ok, %{run: run}})
    {:ok, answer}
  end

  defp broadcast_redeemed({:ok, {answer, nil}}), do: {:ok, answer}
  defp broadcast_redeemed({:ok, :late_machine}), do: {:error, :unauthorized}
  defp broadcast_redeemed(refused), do: refused

  # The run whose code's SHA-256 is the code's, of a workspace and an organisation in use,
  # read without a lock, with its run of the queue: its locks are taken next.
  defp find_run(head) do
    in_use =
      from(o in Organisation, as: :organisation, select: o.id)
      |> Apiary.Edition.active_organisations(:organisation)

    Repo.one(
      from r in Run,
        join: w in assoc(r, :workspace),
        join: o in assoc(r, :organisation),
        where: r.run_code_sha256 == ^EnrolmentCode.hash(head),
        where: is_nil(w.deletion_marked_at) and is_nil(o.deletion_marked_at),
        where: o.id in subquery(in_use),
        select: %{id: r.id, dispatch_run_id: r.dispatch_run_id}
    )
  end

  # Under the lock of the run of the queue, which every path that ends one takes before
  # the registered run (`Apiary.Dispatches.RunEnd`), then the run's projection lock, then
  # its row `FOR UPDATE`, as an attach takes them. A run deleted meanwhile, with its code,
  # is no code; nor is a code relayed by another node than the run's gateway.
  defp redeem_locked(
         %{id: id, dispatch_run_id: dispatch_run_id},
         request,
         relayed_by,
         now,
         code_limit
       ) do
    dispatch_run = RunEnd.lock(dispatch_run_id)
    Projector.lock(id)

    with %Run{} = run <-
           Repo.one(from r in Run, where: r.id == ^id, lock: "FOR UPDATE") ||
             {:error, :unauthorized},
         true <- bound?(run, relayed_by) || {:error, :unauthorized},
         {:ok, state, dispatch} <- code_state(run, dispatch_run, request, now),
         {:ok, public_key} <- proven(request),
         :ok <- within_code_limit(run, code_limit) do
      case state do
        :outstanding ->
          {run_key, changed} = redeemed(run, public_key, request.timestamp, now)
          if dispatch, do: :ok = Handover.hand_over(dispatch_run, dispatch, now)

          {:ok,
           {%{run_id: run.node_run_id, run_key: run_key, documents: run.run_documents}, changed}}

        :redeemed ->
          :ok = retried(run, request.timestamp, now)

          {:ok,
           {%{run_id: run.node_run_id, run_key: given(run), documents: run.run_documents}, nil}}
      end
    else
      {:late, %Run{} = run} -> late_machine(run, request, now, code_limit)
      refused -> refused
    end
  end

  # A code refused as late whose proof verifies, within the code's limit: the dispatch the
  # run was registered for, not handed over, keeps the late machine (the moduledoc),
  # committed. The answer is `{:error, :unauthorized}` either way, past the limit too, so
  # the answer shows nothing about the code (`broadcast_redeemed/1`).
  defp late_machine(%Run{} = run, request, now, code_limit) do
    with {:ok, _public_key} <- proven(request),
         :ok <- within_code_limit(run, code_limit),
         %Dispatch{} = dispatch <- late_dispatch(run) do
      _held = Slots.late_machine(dispatch, now)
      {:ok, :late_machine}
    else
      _unproven_limited_or_none -> {:error, :unauthorized}
    end
  end

  # The dispatch whose claim registered the run, not handed over, locked `FOR UPDATE`: the
  # one its lapse or its release kept on the run (`dispatch_id`), or the newest of its run
  # of the queue, whose claim registered the run; none when that one was handed over.
  defp late_dispatch(%Run{dispatch_id: id}) when is_binary(id) do
    Repo.one(
      from d in Dispatch,
        where: d.id == ^id and is_nil(d.handed_over_at),
        lock: "FOR UPDATE"
    )
  end

  defp late_dispatch(%Run{dispatch_run_id: id}) when is_binary(id) do
    case Repo.one(
           from d in Dispatch,
             where: d.dispatch_run_id == ^id,
             order_by: [desc: d.claimed_at, desc: d.id],
             limit: 1,
             lock: "FOR UPDATE"
         ) do
      %Dispatch{handed_over_at: nil} = dispatch -> dispatch
      _handed_over_or_none -> nil
    end
  end

  defp late_dispatch(%Run{}), do: nil

  # Outstanding, or redeemed by the very public key the request carries (the repeat),
  # with the dispatch the first redemption hands over, nil for one handed over already;
  # anything else, a code expired, of a run that ended or of a claim whose lease lapsed
  # among it, is no code.
  defp code_state(%Run{} = run, dispatch_run, request, now) do
    with false <- DateTime.compare(run.run_code_expires_at, now) != :gt or ended?(run),
         {:ok, dispatch} <- live(dispatch_run, now) do
      cond do
        is_nil(run.run_code_public_key) -> {:ok, :outstanding, dispatch}
        retry?(run, request) -> {:ok, :redeemed, nil}
        true -> {:error, :unauthorized}
      end
    else
      _ended_or_lapsed -> {:late, run}
    end
  end

  # The node that relayed the code is the gateway the claim bound it to
  # (`Apiary.Dispatches.Handover`), under any key of that node live now, so a key that
  # replaced the claim's passes too. A run whose gateway's row was purged (nil) is bound
  # to no node.
  defp bound?(%Run{gateway_id: gateway_id}, relayed_by) when is_binary(gateway_id),
    do: gateway_id == relayed_by

  defp bound?(%Run{}, _relayed_by), do: false

  defp ended?(%Run{} = run) do
    run.state not in Run.alive_states() or not is_nil(run.released_at) or
      not is_nil(run.outcome_state) or not is_nil(run.events_pruned_at)
  end

  # The run of the queue the run is, locked: handed over, `{:ok, nil}`; claimed, its
  # dispatch, neither handed over, stale nor ended, while the clock is before its
  # `lease_until`, locked `FOR UPDATE`, which the first redemption hands over; any other,
  # or none, ends the code.
  defp live(%DispatchRun{state: :handed_over}, _now), do: {:ok, nil}

  defp live(%DispatchRun{state: :claimed, id: id}, now) do
    dispatch =
      Repo.one(
        from d in Dispatch,
          where: d.dispatch_run_id == ^id,
          where: is_nil(d.ended_at) and is_nil(d.stale_at) and is_nil(d.handed_over_at),
          lock: "FOR UPDATE"
      )

    if dispatch && DateTime.compare(now, dispatch.lease_until) == :lt,
      do: {:ok, dispatch},
      else: :lapsed
  end

  defp live(_waiting_ended_or_none, _now), do: :ended

  # The same public key as the first redemption's, with a proof made after the newest
  # accepted redemption's.
  defp retry?(%Run{run_code_public_key: stored, run_code_proof_timestamp: latest}, request),
    do: same_public_key?(stored, request.public_key) and newer?(request.timestamp, latest)

  defp newer?(timestamp, latest) when is_integer(latest), do: timestamp > latest
  defp newer?(_timestamp, nil), do: false

  defp same_public_key?(<<_::binary-size(32)>> = stored, encoded) do
    case Ed25519.decode(encoded, 32) do
      {:ok, sent} -> Plug.Crypto.secure_compare(stored, sent)
      :error -> false
    end
  end

  # The key checks first, then the proof under the key: either refused is one answer,
  # which the caller sends unsigned, as for every enrolment code.
  defp proven(request) do
    with {:ok, public_key} <- Ed25519.decode_public_key(request.public_key),
         true <- Enrolment.proof_verifies?(request, public_key) do
      {:ok, public_key}
    else
      _refused -> {:error, :key_unproven}
    end
  end

  # The code's limit, counted only for a request that came this far: a code accepted, a
  # key proven.
  defp within_code_limit(%Run{id: id}, code_limit) do
    case RateLimit.check({:run_code, id}, code_limit) do
      :ok -> :ok
      {:error, seconds} -> {:error, {:rate_limited, seconds}}
    end
  end

  # The first redemption: the run key made from the grant, issued at `now`, and the run's
  # run key fields and the public key written in one write. The grant passed a run key's
  # rules when the claim made the code, so the run key is made. Returns the run key and
  # the run's row as written.
  defp redeemed(%Run{id: id, run_code_grant: grant}, public_key, timestamp, now) do
    {:ok, %{run_key: run_key, through: through}} =
      Registration.issue_grant(load(grant), now, @attach_seconds)

    {1, [changed]} =
      Repo.update_all(from(r in Run, where: r.id == ^id, select: r),
        set:
          Map.to_list(through) ++
            [
              run_code_public_key: public_key,
              run_code_proof_timestamp: timestamp,
              updated_at: now
            ]
      )

    {run_key, changed}
  end

  # A retry accepted: its proof's timestamp stored in place of the one before, so the same
  # retry sent again is a replayed proof.
  defp retried(%Run{id: id}, timestamp, now) do
    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^id),
        set: [run_code_proof_timestamp: timestamp, updated_at: now]
      )

    :ok
  end

  # The run key the first redemption made, byte for byte.
  defp given(%Run{run_key_payload: payload, run_key_signature: signature}),
    do: RunKey.assemble(payload, signature)

  # The grant as the run keeps it: string keys, the gateway's public keys in base64url.
  defp dump(grant) do
    %{
      "run_id" => grant.run_id,
      "workspace" => grant.workspace,
      "node_id" => grant.node_id,
      "gateway" => grant.gateway,
      "gateway_url" => grant.gateway_url,
      "gateway_public_keys" => Enum.map(grant.gateway_public_keys, &Ed25519.encode/1),
      "instance_id" => grant.instance_id
    }
  end

  defp load(%{} = kept) do
    %{
      run_id: kept["run_id"],
      workspace: kept["workspace"],
      node_id: kept["node_id"],
      gateway: kept["gateway"],
      gateway_url: kept["gateway_url"],
      gateway_public_keys:
        Enum.map(kept["gateway_public_keys"], fn key ->
          {:ok, raw} = Ed25519.decode(key, 32)
          raw
        end),
      instance_id: kept["instance_id"]
    }
  end

  # A time to the second, as the column keeps microseconds.
  defp usec(%DateTime{} = time), do: %{time | microsecond: {0, 6}}
end
