defmodule ApiaryWeb.Contract.RunCodeTest do
  # A run handed over with a run code, through the endpoints alone: the handover's `200`
  # has `version`, `revision`, `run_id`, `run_code` and `step` alone; the enrolment's `201`
  # to the code has the run's id, its run key and the instance's keys, signed over the
  # request's proof; a retry by the same public key is the same members, byte for byte for
  # the same request; another public key, an expired code, a code of a run that ended and a
  # proof that does not verify are refused as an enrolment code is; and a code redeemed at
  # minute 14 is answered a run key the gateway attaches with. Minutes pass by moving the run's
  # and the dispatch's times back. Not async, as the other contract tests of a pool: the
  # features are the whole node's.
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
  alias Apiary.Dispatches.{Dispatch, DispatchRun}
  alias Apiary.Runs.{Run, RunKey}
  alias ApiaryWeb.Contract.SignedRequest

  @moduletag needs: :factory

  @path "/.well-known/qory-enrolment"

  setup do
    %{scope: scope} = sign_up_fixture()
    {:ok, _rule} = Policy.allow(scope, nil, %{host: "api.example"})
    ctx = Map.put(handover_place_fixture(scope), :scope, scope)

    work_item = work_item_fixture(scope)
    {:ok, queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    {:ok, %{dispatch: dispatch}} = Dispatches.claim(ctx.key, Dispatches.now())
    assert pool_post(ctx, dispatch, "dispatched", %{}).status == 204

    handover = pool_post(ctx, dispatch, "handover", %{"run_code" => true})
    assert handover.status == 200
    assert signed_answer?(handover)

    Map.merge(ctx, %{
      queued: queued,
      dispatch: dispatch,
      handover: handover,
      code: Jason.decode!(handover.resp_body)["run_code"]
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
      contract_version: "3"
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

  defp enrol(body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-qory-contract-version", "1")
    |> post(@path, body)
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

  # The handover `seconds` earlier: the run's and the dispatch's times moved back, as the
  # clock would have them that long after the handover.
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

  test "the handover answers version, revision, run_id, run_code and step alone", ctx do
    run_id = ctx.queued.run_id

    assert ctx.handover.resp_body ==
             Jason.encode!(
               Jason.OrderedObject.new([
                 {"version", 1},
                 {"revision", 3},
                 {"run_id", run_id},
                 {"run_code", ctx.code},
                 {"step", "explore"}
               ])
             )

    assert ctx.code =~ ~r/\Aqecr_[0-9A-HJKMNP-TV-Z]{26}\.[A-Za-z0-9_-]{22}\z/
    assert run!(ctx).run_key_payload == nil
  end

  test "a handover with run_code false answers the run key, as one without it", ctx do
    work_item = work_item_fixture(ctx.scope)
    {:ok, _queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    {:ok, %{dispatch: dispatch}} = Dispatches.claim(ctx.key, Dispatches.now())
    assert pool_post(ctx, dispatch, "dispatched", %{}).status == 204

    answer = json_response(pool_post(ctx, dispatch, "handover", %{"run_code" => false}), 200)
    assert %{"run_key" => "qrk_" <> _rest, "domain" => "software", "inputs" => %{}} = answer
    refute Map.has_key?(answer, "run_code")
  end

  test "a handover with a run_code that is not a boolean is refused", ctx do
    work_item = work_item_fixture(ctx.scope)
    {:ok, _queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    {:ok, %{dispatch: dispatch}} = Dispatches.claim(ctx.key, Dispatches.now())
    assert pool_post(ctx, dispatch, "dispatched", %{}).status == 204

    conn = pool_post(ctx, dispatch, "handover", %{"run_code" => "true"})
    assert json_response(conn, 400) == %{"error" => "invalid_request"}
  end

  describe "the redemption" do
    test "answers 201, signed, the run's id, its run key and the instance's keys, and makes no access key",
         ctx do
      keys = Repo.aggregate(AccessKey, :count)
      pair = ed25519_key_pair()
      body = body(ctx.code, pair)

      conn = enrol(body)
      assert conn.status == 201
      answer = assert_signed(conn, body)

      run_id = ctx.queued.run_id

      assert %{
               "version" => 1,
               "run_id" => ^run_id,
               "run_key" => run_key,
               "apiary_public_key" => apiary_public_key
             } = answer

      assert map_size(answer) == 4
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

    test "a retry by the same public key is the same answer, byte for byte for the same request, signed over a new one's proof",
         ctx do
      pair = ed25519_key_pair()
      body = body(ctx.code, pair)
      first = enrol(body)
      assert first.status == 201

      again = enrol(body)
      assert again.status == 201
      assert again.resp_body == first.resp_body

      assert get_resp_header(again, "x-qory-signature-ed25519") ==
               get_resp_header(first, "x-qory-signature-ed25519")

      later = body(ctx.code, pair, timestamp: System.os_time(:second) + 5)
      newer = enrol(later)
      assert newer.status == 201
      assert newer.resp_body == first.resp_body
      assert_signed(newer, later)

      refute get_resp_header(newer, "x-qory-signature-ed25519") ==
               get_resp_header(first, "x-qory-signature-ed25519")
    end

    test "another public key after the first is 401, unsigned, and changes nothing", ctx do
      assert enrol(body(ctx.code, ed25519_key_pair())).status == 201
      run = run!(ctx)

      assert_refused(enrol(body(ctx.code, ed25519_key_pair())), 401, "unauthorized")
      assert run!(ctx) == run
    end

    test "a proof that does not verify is 409 key_invalid, unsigned, and the code stays outstanding",
         ctx do
      pair = ed25519_key_pair()
      forged = ctx.code |> body(pair) |> Jason.decode!() |> Map.put("name", "run-02")

      assert_refused(enrol(Jason.encode!(forged)), 409, "key_invalid")
      assert run!(ctx).run_code_public_key == nil
      assert enrol(body(ctx.code, pair)).status == 201
    end

    test "at minute 14 is answered a run key the gateway attaches with", ctx do
      back!(ctx, 14 * 60)
      Dispatches.sweep(Dispatches.now())
      assert %DispatchRun{state: :handed_over} = Repo.get!(DispatchRun, ctx.queued.id)

      conn = enrol(body(ctx.code, ed25519_key_pair()))
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
      assert_refused(enrol(body(ctx.code, ed25519_key_pair())), 401, "unauthorized")
      assert run!(ctx).run_key_payload == nil
    end

    test "of a run that ended is 401, unsigned", ctx do
      body = %{"version" => 1, "time" => now_time(), "reason" => "stopped", "retry" => false}

      released =
        signed_post(build_conn(), ctx.key.key_id, ctx.seed, body,
          target: "/v1/dispatches/#{ctx.dispatch.public_id}/release",
          content_type: "application/json",
          delivery: nil,
          contract_version: "3"
        )

      assert released.status in 200..299
      assert_refused(enrol(body(ctx.code, ed25519_key_pair())), 401, "unauthorized")
    end

    test "with a node's prefix on the code's characters is 401, unsigned", ctx do
      other = String.replace_prefix(ctx.code, "qecr_", "qecn_")
      assert_refused(enrol(body(other, ed25519_key_pair())), 401, "unauthorized")
      assert run!(ctx).run_key_payload == nil
    end
  end
end
