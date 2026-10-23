defmodule ApiaryWeb.Contract.RunCodeTest do
  # A run claimed with a run code, through the endpoints alone: the claim's `200` has the
  # code; the enrolment's `201` to the code has the run's id, its run key, its documents
  # as the claim stored them, byte for byte, and the instance's keys, signed over the
  # request's proof, and hands the dispatch over; a retry
  # by the same public key is the same members, byte for byte for the same request;
  # another public key, an expired code, a code of a claim whose lease lapsed or that was
  # released, a code of a run that ended and a proof that does not verify are refused as
  # an enrolment code is; and a code redeemed at minute 14 is answered a run key the
  # gateway attaches with; a code never redeemed ends its run lost at its expiry. Minutes
  # pass by moving the run's and the dispatch's times back.
  # Not async, as the other contract tests of a pool: the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.AccessKeysFixtures, only: [ed25519_key_pair: 0]
  import Apiary.ContractFixtures
  import Apiary.DispatchedRunsFixtures, only: [handover_place_fixture: 1]
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Dispatches, Policy, Repo, SigningKey}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Contract.{Ed25519, SignedMessage}
  alias Apiary.Dispatches.{Dispatch, DispatchRun, Slots}
  alias Apiary.Runs.{Liveness, Run, RunKey}
  alias ApiaryWeb.Contract.SignedRequest

  @moduletag needs: :factory

  @path "/.well-known/qory-enrolment"

  setup do
    %{scope: scope} = sign_up_fixture()
    {:ok, _rule} = Policy.allow(scope, nil, %{host: "api.example"})
    ctx = Map.put(handover_place_fixture(scope), :scope, scope)

    work_item = work_item_fixture(scope)
    {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)

    claim =
      signed_post(
        build_conn(),
        ctx.key.key_id,
        ctx.seed,
        %{"version" => 1, "time" => now_time(), "wait_seconds" => 0},
        target: "/v1/pools/claim",
        content_type: "application/json",
        delivery: nil,
        contract_version: "1"
      )

    assert %{"dispatch_id" => dispatch_id, "run_code" => code} = json_response(claim, 200)

    Map.merge(ctx, %{
      queued: queued,
      dispatch: Repo.get_by!(Dispatch, public_id: dispatch_id),
      code: code
    })
  end

  defp now_time,
    do: SignedRequest.now() |> DateTime.from_unix!() |> DateTime.to_iso8601()

  defp pool_post(ctx, dispatch, action, extra) do
    body = Map.merge(%{"version" => 1, "time" => now_time()}, extra)

    signed_post(build_conn(), ctx.key.key_id, ctx.seed, body,
      target: "/v1/dispatches/#{dispatch.public_id}/#{action}",
      content_type: "application/json",
      delivery: nil,
      contract_version: "1"
    )
  end

  # The request body a machine sends with `code`, its proof signed under `pair`.
  defp body(code, pair, opts \\ []) do
    timestamp = Keyword.get(opts, :timestamp, System.os_time(:second))
    message = SignedMessage.enrolment(code, pair.encoded, "run-01", timestamp)
    proof = :crypto.sign(:eddsa, :none, message, [pair.secret, :ed25519]) |> Ed25519.encode()

    Jason.encode!(%{
      version: 1,
      code: code,
      name: "run-01",
      public_key: pair.encoded,
      timestamp: timestamp,
      proof: proof
    })
  end

  # The enrolment as a gateway's relay sends it: the machine's body byte for byte, signed
  # as a POST under the access key `relay`, the bound gateway's by default. `relay: nil`
  # sends it with no relay headers, as a machine does; `signature:` sends that signature.
  defp enrol(ctx, body, opts \\ []) do
    case Keyword.get(opts, :relay, ctx.gateway_key) do
      nil ->
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-qory-contract-version", "1")
        |> post(@path, body)

      {key, seed} ->
        signed_post(
          build_conn(),
          key.key_id,
          seed,
          body,
          [target: @path, content_type: "application/json", delivery: nil] ++
            Keyword.take(opts, [:signature, :instance_id])
        )
    end
  end

  # The answer's signature verifies under the instance's key, as an enrolment answer, its
  # line 3 the request's proof.
  defp assert_signed(conn, body) do
    %{"proof" => proof} = Jason.decode!(body)
    assert [signature] = get_resp_header(conn, "x-qory-signature-ed25519")
    assert {:ok, signature} = Ed25519.decode(signature, 64)
    message = SignedMessage.enrolment_answer(conn.status, proof, conn.resp_body)
    assert Ed25519.verify(message, signature, SigningKey.public_key())
    assert get_resp_header(conn, "cache-control") == ["no-store, no-transform"]
    Jason.decode!(conn.resp_body)
  end

  defp assert_refused(conn, status, error) do
    assert conn.status == status
    assert get_resp_header(conn, "x-qory-signature-ed25519") == []
    assert Jason.decode!(conn.resp_body) == %{"error" => error}
  end

  defp run!(ctx), do: Repo.one!(from r in Run, where: r.dispatch_run_id == ^ctx.queued.id)

  # The claim `seconds` earlier: the run's and the dispatch's times moved back, as the
  # clock would have them that long after the claim.
  defp back!(ctx, seconds) do
    back = &(&1 && DateTime.add(&1, -seconds, :second))
    run = run!(ctx)

    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^run.id),
        set: [
          registered_at: back.(run.registered_at),
          inserted_at: back.(run.inserted_at),
          run_key_issued_at: back.(run.run_key_issued_at),
          attach_by: back.(run.attach_by),
          run_code_expires_at: back.(run.run_code_expires_at)
        ]
      )

    dispatch = Repo.get!(Dispatch, ctx.dispatch.id)

    {1, _rows} =
      Repo.update_all(from(d in Dispatch, where: d.id == ^dispatch.id),
        set: [
          claimed_at: back.(dispatch.claimed_at),
          lease_until: back.(dispatch.lease_until),
          dispatched_at: back.(dispatch.dispatched_at),
          handed_over_at: back.(dispatch.handed_over_at)
        ]
      )
  end

  defp attach(ctx, run_id, run_key) do
    {key, seed} = ctx.gateway_key
    signed_attach(build_conn(), key.key_id, seed, run_id, Jason.encode!(attach_body(run_key)))
  end

  describe "the redemption" do
    test "answers 201, signed, the run's id, its run key, its documents and the instance's keys, and makes no access key",
         ctx do
      keys = Repo.aggregate(AccessKey, :count)
      pair = ed25519_key_pair()
      body = body(ctx.code, pair)

      conn = enrol(ctx, body)
      assert conn.status == 201
      answer = assert_signed(conn, body)

      run_id = ctx.queued.run_id

      assert %{
               "version" => 1,
               "run_id" => ^run_id,
               "run_key" => run_key,
               "documents" => documents,
               "apiary_public_key" => apiary_public_key
             } = answer

      assert map_size(answer) == 5

      # The documents the claim stored, written as they are.
      stored = run!(ctx).run_documents
      assert String.ends_with?(conn.resp_body, ~s(}],"documents":) <> stored <> "}")
      assert %{"step" => "explore", "domain" => "software", "inputs" => %{}} = documents
      assert apiary_public_key == SigningKey.apiary_public_key()
      assert conn.resp_body =~ ~r/\A\{"version":1,"run_id":"[0-9a-f-]{36}","run_key":"qrk_/

      assert {:ok, grant, payload} = RunKey.verify(run_key)
      assert grant.run_id == run_id
      assert DateTime.diff(grant.attach_by, grant.issued) == 600

      run = run!(ctx)
      assert run.run_key_payload == payload
      assert run.run_code_public_key == pair.public_key
      assert Repo.aggregate(AccessKey, :count) == keys
    end

    test "a retry by the same public key with a newer proof is the same answer, signed over its proof; the same proof again is 401",
         ctx do
      pair = ed25519_key_pair()
      body = body(ctx.code, pair)
      first = enrol(ctx, body)
      assert first.status == 201

      # The same request again replays the first proof: refused, unsigned.
      again = enrol(ctx, body)
      assert again.status == 401
      assert json_response(again, 401) == %{"error" => "unauthorized"}
      assert get_resp_header(again, "x-qory-signature-ed25519") == []

      later = body(ctx.code, pair, timestamp: System.os_time(:second) + 5)
      newer = enrol(ctx, later)
      assert newer.status == 201
      assert newer.resp_body == first.resp_body
      assert_signed(newer, later)

      refute get_resp_header(newer, "x-qory-signature-ed25519") ==
               get_resp_header(first, "x-qory-signature-ed25519")

      # The retry's timestamp is stored: the same retry again is a replay, refused as the
      # first proof again is.
      assert answer(enrol(ctx, later)) == answer(again)
      assert run!(ctx).run_code_proof_timestamp == Jason.decode!(later)["timestamp"]
    end

    test "another public key after the first is 401, unsigned, and changes nothing", ctx do
      assert enrol(ctx, body(ctx.code, ed25519_key_pair())).status == 201
      run = run!(ctx)

      assert_refused(enrol(ctx, body(ctx.code, ed25519_key_pair())), 401, "unauthorized")
      assert run!(ctx) == run
    end

    test "a proof that does not verify is 409 key_invalid, unsigned, and the code stays outstanding",
         ctx do
      pair = ed25519_key_pair()
      forged = ctx.code |> body(pair) |> Jason.decode!() |> Map.put("name", "run-02")

      assert_refused(enrol(ctx, Jason.encode!(forged)), 409, "key_invalid")
      assert run!(ctx).run_code_public_key == nil
      assert enrol(ctx, body(ctx.code, pair)).status == 201
    end

    test "at minute 14 is answered a run key the gateway attaches with", ctx do
      assert pool_post(ctx, ctx.dispatch, "dispatched", %{}).status == 204
      back!(ctx, 14 * 60)
      Dispatches.sweep(Dispatches.now())
      assert %DispatchRun{state: :handed_over} = Repo.get!(DispatchRun, ctx.queued.id)

      conn = enrol(ctx, body(ctx.code, ed25519_key_pair()))
      assert conn.status == 201
      %{"run_id" => run_id, "run_key" => run_key} = Jason.decode!(conn.resp_body)

      run = run!(ctx)
      assert DateTime.compare(run.attach_by, DateTime.utc_now()) == :gt
      assert DateTime.diff(run.attach_by, run.run_key_issued_at) == 600

      attached = attach(ctx, run_id, run_key)
      assert attached.status == 200
      assert %Run{attached_at: %DateTime{}} = run!(ctx)
    end

    test "after the code's 15 minutes is 401, unsigned, and the run has no run key", ctx do
      back!(ctx, 15 * 60)
      assert_refused(enrol(ctx, body(ctx.code, ed25519_key_pair())), 401, "unauthorized")
      assert run!(ctx).run_key_payload == nil
    end

    test "before dispatched hands the dispatch over; a dispatched after it is 204", ctx do
      assert enrol(ctx, body(ctx.code, ed25519_key_pair())).status == 201

      assert %Dispatch{handed_over_at: %DateTime{}, dispatched_at: nil} =
               Repo.get!(Dispatch, ctx.dispatch.id)

      assert %DispatchRun{state: :handed_over} = Repo.get!(DispatchRun, ctx.queued.id)
      assert pool_post(ctx, ctx.dispatch, "dispatched", %{}).status == 204
      assert %Dispatch{dispatched_at: %DateTime{}} = Repo.get!(Dispatch, ctx.dispatch.id)
    end

    test "after the claim's lease lapsed before dispatched is 401, unsigned; the run waits again with no registered run",
         ctx do
      back!(ctx, 600)
      assert_refused(enrol(ctx, body(ctx.code, ed25519_key_pair())), 401, "unauthorized")

      Dispatches.sweep(Dispatches.now())
      assert %DispatchRun{state: :waiting} = Repo.get!(DispatchRun, ctx.queued.id)
      assert Repo.one(from r in Run, where: r.dispatch_run_id == ^ctx.queued.id) == nil
      assert_refused(enrol(ctx, body(ctx.code, ed25519_key_pair())), 401, "unauthorized")
    end

    test "of a claim released before dispatched is 401, unsigned", ctx do
      body = %{"version" => 1, "time" => now_time(), "reason" => "stopped"}

      released =
        signed_post(build_conn(), ctx.key.key_id, ctx.seed, body,
          target: "/v1/dispatches/#{ctx.dispatch.public_id}/release",
          content_type: "application/json",
          delivery: nil,
          contract_version: "1"
        )

      assert released.status == 204
      assert_refused(enrol(ctx, body(ctx.code, ed25519_key_pair())), 401, "unauthorized")
    end

    test "of a run that ended is 401, unsigned", ctx do
      assert pool_post(ctx, ctx.dispatch, "dispatched", %{}).status == 204

      {1, _rows} =
        Repo.update_all(from(r in DispatchRun, where: r.id == ^ctx.queued.id),
          set: [state: :ended, end_cause: :lost]
        )

      assert_refused(enrol(ctx, body(ctx.code, ed25519_key_pair())), 401, "unauthorized")
    end

    test "with a node's prefix on the code's characters is 401, unsigned", ctx do
      other = String.replace_prefix(ctx.code, "qecr_", "qecn_")
      assert_refused(enrol(ctx, body(other, ed25519_key_pair())), 401, "unauthorized")
      assert run!(ctx).run_key_payload == nil
    end
  end

  describe "the gateway's relay" do
    # What a code no run has is answered through the bound gateway's relay: the 401 every
    # refused relay must be, its status, its body and its headers, with the request's id
    # left out and the nonce of the content security policy, which every answer draws
    # anew, blanked.
    defp unknown_code(ctx) do
      [_head, fingerprint] = String.split(ctx.code, ".")
      code = "qecr_" <> String.duplicate("A", 26) <> "." <> fingerprint
      answer(enrol(ctx, body(code, ed25519_key_pair())))
    end

    defp answer(conn) do
      headers =
        conn.resp_headers
        |> List.keydelete("x-request-id", 0)
        |> Enum.map(fn {name, value} ->
          {name, String.replace(value, ~r/'nonce-[^']*'/, "'nonce-'")}
        end)
        |> Enum.sort()

      {conn.status, conn.resp_body, headers}
    end

    # The run's code outstanding: no public key, no run key.
    defp outstanding?(ctx) do
      run = run!(ctx)
      run.run_code_public_key == nil and run.run_key_payload == nil
    end

    test "under the bound gateway's key that replaces the one in use, redeems; a retry under the key in use is the same answer",
         ctx do
      %{access_key: next, secret: next_seed} =
        contract_key_fixture(ctx.scope, node: ctx.gateway)

      pair = ed25519_key_pair()
      first = enrol(ctx, body(ctx.code, pair), relay: {next, next_seed})
      assert first.status == 201

      later = body(ctx.code, pair, timestamp: System.os_time(:second) + 5)
      retry = enrol(ctx, later)
      assert retry.status == 201
      assert retry.resp_body == first.resp_body
      assert_signed(retry, later)

      # A retry needs the relay too.
      newest = body(ctx.code, pair, timestamp: System.os_time(:second) + 10)
      assert answer(enrol(ctx, newest, relay: nil)) == unknown_code(ctx)
    end

    test "under another gateway's key, or a node pool's, of the same organisation, is the unknown code's 401 and changes nothing",
         ctx do
      other = Apiary.NodesFixtures.gateway_fixture(ctx.scope)
      %{access_key: other_key, secret: other_seed} = contract_key_fixture(ctx.scope, node: other)
      assert other.organisation_id == ctx.gateway.organisation_id
      expected = unknown_code(ctx)
      pair = ed25519_key_pair()

      assert answer(enrol(ctx, body(ctx.code, pair), relay: {other_key, other_seed})) ==
               expected

      assert answer(enrol(ctx, body(ctx.code, pair), relay: {ctx.key, ctx.seed})) == expected
      assert outstanding?(ctx)

      # The bound gateway redeems it after the refused tries, for the same public key.
      assert enrol(ctx, body(ctx.code, pair)).status == 201
    end

    test "with no relay headers, no instance id, or a signature that does not verify, is the unknown code's 401 and changes nothing",
         ctx do
      expected = unknown_code(ctx)
      pair = ed25519_key_pair()
      body = body(ctx.code, pair)
      {key, seed} = ctx.gateway_key
      # A signature over a body one byte longer than the one sent.
      bad_signature = sign_request(seed, key.key_id, instance_id(), "POST", @path, body <> " ")

      assert answer(enrol(ctx, body, relay: nil)) == expected
      assert answer(enrol(ctx, body, instance_id: nil)) == expected
      assert answer(enrol(ctx, body, signature: bad_signature)) == expected
      assert answer(enrol(ctx, body, signature: "")) == expected

      # Before the proof's check: a proof that does not verify is 401, not 409.
      forged = ctx.code |> body(pair) |> Jason.decode!() |> Map.put("name", "run-02")
      assert answer(enrol(ctx, Jason.encode!(forged), relay: nil)) == expected
      assert outstanding?(ctx)

      # The bound gateway redeems it after the refused tries.
      assert enrol(ctx, body(ctx.code, pair)).status == 201
    end
  end

  describe "dispatched as a keep-alive" do
    # A `dispatched` whose `time` is `seconds` before the clock as the test's first
    # keep-alive read it, so each request is a new signed body: a time read from the clock
    # again for each request could repeat one, as the clock moves on a second between
    # them, and the replay guard refuses a repeated body with a 401.
    defp keep_alive(ctx, seconds) do
      unless Process.get(:keep_alive_base),
        do: Process.put(:keep_alive_base, SignedRequest.now())

      time =
        (Process.get(:keep_alive_base) - seconds)
        |> DateTime.from_unix!()
        |> DateTime.to_iso8601()

      pool_post(ctx, ctx.dispatch, "dispatched", %{"time" => time})
    end

    test "every 60 s is 204 while the dispatch lives, past its lease too, and 410 once it ends",
         ctx do
      assert keep_alive(ctx, 0).status == 204

      for n <- 1..11 do
        back!(ctx, 60)
        first = Repo.get!(Dispatch, ctx.dispatch.id).dispatched_at
        assert keep_alive(ctx, n).status == 204
        # A repeat records nothing.
        assert Repo.get!(Dispatch, ctx.dispatch.id).dispatched_at == first
      end

      # 11 minutes after the claim: past its lease, the dispatch handed over lives.
      assert DateTime.compare(Dispatches.now(), Repo.get!(Dispatch, ctx.dispatch.id).lease_until) ==
               :gt

      assert %Dispatch{stale_at: nil, ended_at: nil} = Repo.get!(Dispatch, ctx.dispatch.id)

      # The code never redeemed, the dispatch ends 15 minutes after the claim: 410.
      back!(ctx, 4 * 60 + 1)
      assert [%Run{state: "lost"}] = Liveness.check(Dispatches.now())
      conn = keep_alive(ctx, 12)
      assert conn.status == 410
      assert Jason.decode!(conn.resp_body) == %{"error" => "gone"}
    end

    test "a first one after lease_until is 204 when the code was redeemed before it", ctx do
      assert enrol(ctx, body(ctx.code, ed25519_key_pair())).status == 201
      back!(ctx, 600 + 1)

      assert keep_alive(ctx, 0).status == 204

      assert %Dispatch{dispatched_at: %DateTime{}, stale_at: nil} =
               Repo.get!(Dispatch, ctx.dispatch.id)

      # The redeemed dispatch never goes stale: the sweep past its lease leaves it.
      Dispatches.sweep(Dispatches.now())
      assert %Dispatch{stale_at: nil, ended_at: nil} = Repo.get!(Dispatch, ctx.dispatch.id)
      assert %DispatchRun{state: :handed_over} = Repo.get!(DispatchRun, ctx.queued.id)
    end

    test "a first one after lease_until with the code unredeemed is 409 lease_expired", ctx do
      back!(ctx, 600)

      conn = keep_alive(ctx, 0)
      assert conn.status == 409
      assert Jason.decode!(conn.resp_body) == %{"error" => "lease_expired"}

      assert %Dispatch{dispatched_at: nil, handed_over_at: nil} =
               Repo.get!(Dispatch, ctx.dispatch.id)
    end
  end

  describe "a code never redeemed" do
    test "ends its run lost at the code's expiry, 15 minutes after the claim, its slot freed",
         ctx do
      assert pool_post(ctx, ctx.dispatch, "dispatched", %{}).status == 204

      # The times are read back from the run's row, not from the clock: the claim kept its
      # second, and the code's expiry is 15 minutes after it.
      run = run!(ctx)
      expiry = run.run_code_expires_at
      assert run.attach_by == expiry
      assert DateTime.diff(expiry, run.run_key_issued_at) == 15 * 60

      # A second before the expiry, and at it, the run waits for its code.
      assert Liveness.check(DateTime.add(expiry, -1, :second)) == []
      assert Liveness.check(expiry) == []
      assert %DispatchRun{state: :handed_over} = Repo.get!(DispatchRun, ctx.queued.id)

      # A second after it, the run is lost.
      assert [%Run{state: "lost"}] = Liveness.check(DateTime.add(expiry, 1, :second))
      assert %DispatchRun{state: :ended, end_cause: :lost} = Repo.get!(DispatchRun, ctx.queued.id)

      assert %Dispatch{end_cause: :lost, ended_at: %DateTime{}, slot_freed_at: %DateTime{}} =
               Repo.get!(Dispatch, ctx.dispatch.id)

      assert Slots.held(ctx.pool.id) == 0
      assert_refused(enrol(ctx, body(ctx.code, ed25519_key_pair())), 401, "unauthorized")
    end
  end
end
