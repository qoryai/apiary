defmodule Apiary.Runs.RunCodeTest do
  # A run's code (`Apiary.Runs.RunCode`): the claim registers the run with no run key, its
  # attach window the code's 15 minutes; the first redemption makes the run key, issued
  # then, its attach window 600 seconds from then, and hands over a dispatch not yet
  # handed over; a repeat by the same public key with a newer proof is the same run key,
  # and stores that proof's timestamp, so the same repeat again is refused; another key, an
  # expired code, a code of a claim whose lease lapsed or that its starter released, a
  # code of a run that ended, a node's code and the code's limit are refused. A
  # redemption at minute 14 finds the dispatch and the run in place, and a code never
  # redeemed leaves the run lost at minute 15. The clock is passed in as `now`.
  use Apiary.DataCase, async: true

  import Apiary.AccessKeysFixtures, only: [ed25519_key_pair: 0]
  import Apiary.DispatchedRunsFixtures, only: [handover_place_fixture: 1]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Repo, SigningKey}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode}
  alias Apiary.Contract.{Ed25519, Enrolment, SignedMessage}
  alias Apiary.Dispatches.{Dispatch, DispatchRun, Slots}
  alias Apiary.Runs.{Liveness, Run, RunCode, RunKey, Sender}

  @moduletag needs: :factory

  @body ~s({"version":3,"time":"2026-10-18T12:00:00Z"})

  # A run of a fresh work item, queued and claimed: the claim's answer, its run of the
  # queue, and the registered run.
  defp claimed!(ctx) do
    work_item = work_item_fixture(ctx.scope)
    {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    {:ok, %{dispatch: %Dispatch{}} = handed} = Dispatches.claim(ctx.key, Dispatches.now(), @body)
    %{queued: queued, dispatch: handed.dispatch, handed: handed, run: handed.registered}
  end

  # A run claimed, which registers it, and its machine started, which hands it over.
  setup do
    %{scope: scope} = sign_up_fixture()
    ctx = Map.put(handover_place_fixture(scope), :scope, scope)
    claimed = claimed!(ctx)
    :ok = Dispatches.dispatched(ctx.key, claimed.dispatch.public_id, %{external: nil})
    run = Repo.get!(Run, claimed.run.id)

    ctx
    |> Map.merge(claimed)
    |> Map.merge(%{run: run, claimed_at: run.run_key_issued_at})
  end

  # The enrolment request a machine sends with `code`, its proof under `pair`, at `at`.
  defp request(code, pair, at) do
    timestamp = DateTime.to_unix(at)
    message = SignedMessage.enrolment(code, pair.encoded, "run-01", timestamp)
    proof = :crypto.sign(:eddsa, :none, message, [pair.secret, :ed25519]) |> Ed25519.encode()

    {:ok, request} =
      Enrolment.decode(
        Jason.encode!(%{
          version: 1,
          code: code,
          name: "run-01",
          public_key: pair.encoded,
          timestamp: timestamp,
          proof: proof
        })
      )

    request
  end

  # Redeemed through the gateway the claim bound the code to: the relay's node.
  defp redeem(ctx, pair, at, opts \\ []) do
    opts = Keyword.merge([now: at, relayed_by: ctx.gateway.id], opts)
    RunCode.redeem(request(ctx.handed.run_code, pair, at), opts)
  end

  defp at(ctx, seconds), do: DateTime.add(ctx.claimed_at, seconds, :second)

  describe "the claim" do
    test "answers a run code and no run key, and registers the run with none", ctx do
      refute Map.has_key?(ctx.handed, :run_key)
      [head, fingerprint] = String.split(ctx.handed.run_code, ".")
      assert head =~ ~r/\Aqecr_[0-9A-HJKMNP-TV-Z]{26}\z/
      assert fingerprint == SigningKey.fingerprint()

      run = ctx.run
      assert run.run_code_sha256 == EnrolmentCode.hash(head)
      assert run.run_key_payload == nil
      assert run.run_key_signature == nil
      assert run.run_code_public_key == nil
      assert run.gateway_id == ctx.gateway.id
      assert run.state == "pending"
      assert run.run_key_issued_at.microsecond == {0, 6}
      assert run.run_code_expires_at == at(ctx, 900)
      assert run.attach_by == run.run_code_expires_at
      assert Run.through_gateway?(run)

      assert %{
               "run_id" => run_id,
               "gateway" => gateway,
               "gateway_public_keys" => [gateway_key],
               "instance_id" => run_id
             } = run.run_code_grant

      assert run_id == ctx.queued.run_id
      assert gateway == ctx.gateway.public_id
      {key, _seed} = ctx.gateway_key
      assert gateway_key == Ed25519.encode(key.public_key)

      assert %Dispatch{handed_over_at: %DateTime{}} = Repo.get!(Dispatch, ctx.dispatch.id)
      assert %DispatchRun{state: :handed_over} = Repo.get!(DispatchRun, ctx.queued.id)
    end

    test "leaves nobody to send for the run before its code is redeemed", ctx do
      {gateway_key, _seed} = ctx.gateway_key
      refute Sender.may_send?(ctx.run, ctx.key)
      refute Sender.may_send?(ctx.run, gateway_key)
      assert Sender.refusal(ctx.run) == :wrong_gateway
    end
  end

  describe "the first redemption" do
    test "makes the run key, issued then, its attach window 600 seconds from then", ctx do
      pair = ed25519_key_pair()
      now = at(ctx, 60)
      keys = Repo.aggregate(AccessKey, :count)

      assert {:ok, %{run_id: run_id, run_key: run_key}} = redeem(ctx, pair, now)
      assert run_id == ctx.queued.run_id

      assert {:ok, grant, payload} = RunKey.verify(run_key)
      assert grant.run_id == run_id
      assert grant.issued == DateTime.truncate(now, :second)
      assert grant.attach_by == DateTime.add(grant.issued, 600, :second)
      assert grant.gateway == ctx.gateway.public_id
      assert grant.node_id == ctx.pool.public_id
      assert grant.instance_id == run_id

      run = Repo.get!(Run, ctx.run.id)
      assert run.run_key_payload == payload
      assert RunKey.assemble(run.run_key_payload, run.run_key_signature) == run_key
      assert DateTime.compare(run.run_key_issued_at, grant.issued) == :eq
      assert DateTime.compare(run.attach_by, grant.attach_by) == :eq
      assert run.run_code_public_key == pair.public_key
      assert run.run_code_expires_at == ctx.run.run_code_expires_at

      # No access key is made.
      assert Repo.aggregate(AccessKey, :count) == keys
    end

    test "hands over a dispatch not yet handed over, within its lease", ctx do
      claimed = claimed!(ctx)
      now = DateTime.utc_now()

      assert {:ok, %{run_key: _run_key}} =
               RunCode.redeem(request(claimed.handed.run_code, ed25519_key_pair(), now),
                 relayed_by: ctx.gateway.id,
                 now: now
               )

      assert %Dispatch{handed_over_at: %DateTime{}, dispatched_at: nil} =
               Repo.get!(Dispatch, claimed.dispatch.id)

      assert %DispatchRun{state: :handed_over} = Repo.get!(DispatchRun, claimed.queued.id)

      # The `dispatched` that follows is recorded, the dispatch left as it was handed over.
      assert Dispatches.dispatched(ctx.key, claimed.dispatch.public_id, %{external: nil}) == :ok
      assert %Dispatch{dispatched_at: %DateTime{}} = Repo.get!(Dispatch, claimed.dispatch.id)
    end

    test "at minute 14 finds the dispatch handed over and the run waiting, and sets its attach window to 600 seconds from then",
         ctx do
      minute_14 = at(ctx, 14 * 60)

      # The dispatch's lease ended at minute 10 after its claim; a dispatch handed over
      # keeps no lease, so the sweep frees nothing, and the run is not lost.
      assert DateTime.compare(Repo.get!(Dispatch, ctx.dispatch.id).lease_until, minute_14) == :lt
      Dispatches.sweep(minute_14)
      assert Liveness.check(minute_14) == []
      assert %DispatchRun{state: :handed_over} = Repo.get!(DispatchRun, ctx.queued.id)
      assert %Dispatch{ended_at: nil, stale_at: nil} = Repo.get!(Dispatch, ctx.dispatch.id)
      assert Slots.held(ctx.pool.id) == 1

      assert {:ok, %{run_key: run_key}} = redeem(ctx, ed25519_key_pair(), minute_14)
      assert {:ok, %{attach_by: attach_by}, _payload} = RunKey.verify(run_key)
      assert attach_by == DateTime.add(DateTime.truncate(minute_14, :second), 600, :second)
      assert DateTime.compare(Repo.get!(Run, ctx.run.id).attach_by, attach_by) == :eq

      # Past the code's 15 minutes the run waits for its attach, until its attach_by.
      assert Liveness.check(DateTime.add(attach_by, -1, :second)) == []
      assert %Run{state: "pending"} = Repo.get!(Run, ctx.run.id)
      assert %DispatchRun{state: :handed_over} = Repo.get!(DispatchRun, ctx.queued.id)

      assert [%Run{state: "lost"}] = Liveness.check(DateTime.add(attach_by, 1, :second))
      assert %DispatchRun{state: :ended, end_cause: :lost} = Repo.get!(DispatchRun, ctx.queued.id)
    end
  end

  describe "a code never redeemed" do
    test "leaves the run lost at minute 15, its run of the queue ended and its slot freed",
         ctx do
      assert Liveness.check(at(ctx, 900)) == []
      assert %DispatchRun{state: :handed_over} = Repo.get!(DispatchRun, ctx.queued.id)

      assert [%Run{state: "lost"}] = Liveness.check(at(ctx, 901))
      assert %DispatchRun{state: :ended, end_cause: :lost} = Repo.get!(DispatchRun, ctx.queued.id)
      assert Slots.held(ctx.pool.id) == 0

      assert redeem(ctx, ed25519_key_pair(), at(ctx, 901)) == {:error, :unauthorized}
    end
  end

  describe "a repeat" do
    test "by the same public key with a newer proof is the same run key, and stores that proof's timestamp alone",
         ctx do
      pair = ed25519_key_pair()
      assert {:ok, first} = redeem(ctx, pair, at(ctx, 60))
      run = Repo.get!(Run, ctx.run.id)

      for seconds <- [61, 899] do
        assert redeem(ctx, pair, at(ctx, seconds)) == {:ok, first}
        retried = Repo.get!(Run, ctx.run.id)
        assert retried.run_code_proof_timestamp == DateTime.to_unix(at(ctx, seconds))

        assert %{retried | run_code_proof_timestamp: nil, updated_at: nil} ==
                 %{run | run_code_proof_timestamp: nil, updated_at: nil}
      end
    end

    test "by the same public key with the stored proof's timestamp, or an older one, is a replay, refused",
         ctx do
      pair = ed25519_key_pair()
      assert {:ok, first} = redeem(ctx, pair, at(ctx, 60))
      run = Repo.get!(Run, ctx.run.id)
      assert run.run_code_proof_timestamp == DateTime.to_unix(at(ctx, 60))

      assert redeem(ctx, pair, at(ctx, 60)) == {:error, :unauthorized}
      assert redeem(ctx, pair, at(ctx, 59)) == {:error, :unauthorized}
      assert Repo.get!(Run, ctx.run.id) == run

      # A newer retry is accepted, and its timestamp stored: the same retry sent again is
      # refused as a stale proof is, and so is one older than it, though newer than the
      # first.
      assert redeem(ctx, pair, at(ctx, 62)) == {:ok, first}
      retried = Repo.get!(Run, ctx.run.id)
      assert retried.run_code_proof_timestamp == DateTime.to_unix(at(ctx, 62))

      assert redeem(ctx, pair, at(ctx, 62)) == {:error, :unauthorized}
      assert redeem(ctx, pair, at(ctx, 61)) == {:error, :unauthorized}
      assert Repo.get!(Run, ctx.run.id) == retried

      assert redeem(ctx, pair, at(ctx, 63)) == {:ok, first}
    end

    test "by another public key is refused", ctx do
      assert {:ok, _first} = redeem(ctx, ed25519_key_pair(), at(ctx, 60))
      run = Repo.get!(Run, ctx.run.id)

      assert redeem(ctx, ed25519_key_pair(), at(ctx, 61)) == {:error, :unauthorized}
      assert Repo.get!(Run, ctx.run.id) == run
    end

    test "past the code's 15 minutes is refused", ctx do
      pair = ed25519_key_pair()
      assert {:ok, _first} = redeem(ctx, pair, at(ctx, 60))
      assert redeem(ctx, pair, at(ctx, 900)) == {:error, :unauthorized}
    end
  end

  describe "a refusal" do
    test "of a code at its expiry, and not a second before", ctx do
      assert redeem(ctx, ed25519_key_pair(), at(ctx, 900)) == {:error, :unauthorized}
      assert {:ok, _redeemed} = redeem(ctx, ed25519_key_pair(), at(ctx, 899))
    end

    test "of a code of a claim its starter released before its handover, the run failed",
         ctx do
      claimed = claimed!(ctx)
      :ok = Dispatches.release(ctx.key, claimed.dispatch.public_id, %{reason: "stopped"})
      now = DateTime.utc_now()

      assert RunCode.redeem(request(claimed.handed.run_code, ed25519_key_pair(), now),
               relayed_by: ctx.gateway.id,
               now: now
             ) ==
               {:error, :unauthorized}

      assert %Run{state: "failed", start_failure: "machine_not_made", dispatch_run_id: nil} =
               Repo.get!(Run, claimed.run.id)

      assert %DispatchRun{state: :waiting} = Repo.get!(DispatchRun, claimed.queued.id)
    end

    test "of a code of a claim whose lease lapsed before its handover", ctx do
      claimed = claimed!(ctx)
      past_lease = DateTime.add(claimed.dispatch.lease_until, 1, :second)
      request = request(claimed.handed.run_code, ed25519_key_pair(), past_lease)

      # Not yet swept: the lease is read at the redemption.
      assert RunCode.redeem(request, relayed_by: ctx.gateway.id, now: past_lease) ==
               {:error, :unauthorized}

      assert %Run{run_key_payload: nil} = Repo.get!(Run, claimed.run.id)
      assert %Dispatch{handed_over_at: nil} = Repo.get!(Dispatch, claimed.dispatch.id)

      # Swept: the run waits again, and its registered run failed, out of the run of the
      # queue: its code redeems no more.
      Dispatches.sweep(past_lease)

      assert %Run{state: "failed", start_failure: "lease_lapsed", dispatch_run_id: nil} =
               Repo.get!(Run, claimed.run.id)

      assert %DispatchRun{state: :waiting} = Repo.get!(DispatchRun, claimed.queued.id)

      assert RunCode.redeem(request, relayed_by: ctx.gateway.id, now: past_lease) ==
               {:error, :unauthorized}
    end

    test "of a code that carries another prefix, or another fingerprint", ctx do
      [head, fingerprint] = String.split(ctx.handed.run_code, ".")
      pair = ed25519_key_pair()
      now = at(ctx, 60)

      node_code = String.replace_prefix(head, "qecr_", "qecn_") <> "." <> fingerprint

      assert RunCode.redeem(request(node_code, pair, now), relayed_by: ctx.gateway.id, now: now) ==
               {:error, :unauthorized}

      assert Apiary.AccessKeys.enrol(request(node_code, pair, now), now: now) ==
               {:error, :unauthorized}

      other = head <> "." <> String.duplicate("A", 21) <> "A"

      assert RunCode.redeem(request(other, pair, now), relayed_by: ctx.gateway.id, now: now) ==
               {:error, :unauthorized}

      assert Repo.get!(Run, ctx.run.id).run_key_payload == nil
    end

    test "of a timestamp more than 300 seconds from the clock", ctx do
      pair = ed25519_key_pair()
      request = request(ctx.handed.run_code, pair, at(ctx, 60))

      assert RunCode.redeem(request, relayed_by: ctx.gateway.id, now: at(ctx, 361)) ==
               {:error, :unauthorized}
    end

    test "of a key the key checks refuse, or a proof that does not verify", ctx do
      pair = ed25519_key_pair()
      request = request(ctx.handed.run_code, pair, at(ctx, 60))

      assert RunCode.redeem(%{request | name: "run-02"},
               relayed_by: ctx.gateway.id,
               now: at(ctx, 60)
             ) ==
               {:error, :key_unproven}

      assert Repo.get!(Run, ctx.run.id).run_key_payload == nil
    end

    test "relayed by no gateway, or by another node than the gateway the claim bound it to, before the key's checks",
         ctx do
      other = Apiary.NodesFixtures.gateway_fixture(ctx.scope)
      pair = ed25519_key_pair()
      request = request(ctx.handed.run_code, pair, at(ctx, 60))
      unproven = %{request | name: "run-02"}

      for relayed_by <- [nil, other.id, ctx.pool.id], request <- [request, unproven] do
        assert RunCode.redeem(request, relayed_by: relayed_by, now: at(ctx, 60)) ==
                 {:error, :unauthorized}
      end

      assert RunCode.redeem(request, now: at(ctx, 60)) == {:error, :unauthorized}
      assert %Run{run_key_payload: nil, run_code_public_key: nil} = Repo.get!(Run, ctx.run.id)

      # The bound gateway redeems it after the refused tries.
      assert {:ok, %{run_key: _run_key}} = redeem(ctx, pair, at(ctx, 60))
    end

    test "past the code's limit", ctx do
      pair = ed25519_key_pair()
      limit = [code_limit: [rate: 1, burst: 1]]
      assert {:ok, _first} = redeem(ctx, pair, at(ctx, 60), limit)
      assert {:error, {:rate_limited, seconds}} = redeem(ctx, pair, at(ctx, 61), limit)
      assert seconds >= 1
    end
  end
end
