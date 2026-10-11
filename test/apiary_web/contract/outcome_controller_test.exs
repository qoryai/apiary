defmodule ApiaryWeb.Contract.OutcomeControllerTest do
  # A run's outcome, as its starter gives it: `POST /v1/runs/<run_id>/outcome`, under any
  # active key of the run's node. It sets the run's state whenever it arrives, the exit's
  # facts kept beside it; each run gets one. Until the run's exit arrives, every answer to
  # its batches carries it as `end`.
  #
  # The window's edge is tested at exactly 300 seconds, under the contract's clock pinned
  # to one second (`pin_clock/0`), so a second ticking over between the test and the server
  # moves nothing. The clock is the application's environment, so this module is not async.
  use ApiaryWeb.ConnCase, async: false

  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures
  import Ecto.Query

  alias Apiary.{AccessKeys, Repo}
  alias Apiary.Contract.SignedMessage
  alias Apiary.Runs.{Projector, Run}
  alias ApiaryWeb.Contract.{Configuration, RawBody}

  @answer ~s({"version":1})
  @unauthorized %{"error" => "unauthorized"}

  setup do
    %{scope: scope} = sign_up_fixture()
    %{access_key: key, secret: secret, node: node} = contract_key_fixture(scope)
    %{access_key: second, secret: second_secret} = contract_key_fixture(scope, node: node)
    %{access_key: other, secret: other_secret} = contract_key_fixture(scope)

    run_id = Ecto.UUID.generate()

    assert signed_register(build_conn(), key.key_id, secret, Jason.encode!(registration(run_id))).status ==
             200

    %{
      scope: scope,
      run_id: run_id,
      key: {key, secret},
      second: {second, second_secret},
      other: {other, other_secret}
    }
  end

  # Pins the contract's clock (`ApiaryWeb.Contract.SignedRequest.now/0`) to this second
  # until the test ends: the test's times and the server's check read the same second.
  defp pin_clock do
    now = System.os_time(:second)
    Application.put_env(:apiary, :contract_now, fn -> now end)
    on_exit(fn -> Application.delete_env(:apiary, :contract_now) end)
  end

  defp now_z(offset \\ 0) do
    (ApiaryWeb.Contract.SignedRequest.now() + offset)
    |> DateTime.from_unix!()
    |> DateTime.to_iso8601()
  end

  defp outcome(attrs \\ %{}) do
    %{"version" => 1, "state" => "succeeded", "reason" => "all_checks_passed", "time" => now_z()}
    |> Map.merge(Map.new(attrs))
    |> Map.reject(fn {_name, value} -> is_nil(value) end)
    |> Jason.encode!()
  end

  defp give({key, secret}, run_id, body, opts \\ []) do
    target = "/v1/runs/#{run_id}/outcome"
    defaults = [target: target, content_type: "application/json", delivery: nil]
    signed_post(build_conn(), key.key_id, secret, body, Keyword.merge(defaults, opts))
  end

  defp deliver({key, secret}, events), do: signed_post(build_conn(), key.key_id, secret, events)

  defp run(run_id), do: Repo.one!(from r in Run, where: r.run_id == ^run_id)

  defp started(run_id) do
    {_subject, [started]} = first_events(run_id)
    started
  end

  defp exited(run_id, sequence, data),
    do: wire_event(run_id, sequence, "run.exited", data)

  describe "an outcome" do
    test "is answered 200 {\"version\":1}, signed, and sets the run's state at once", ctx do
      conn = give(ctx.key, ctx.run_id, outcome())

      assert response(conn, 200) == @answer
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
      {key, _secret} = ctx.key
      assert get_resp_header(conn, "x-qory-configuration") == [Configuration.digest(key)]
      assert signed_answer?(conn)

      run = run(ctx.run_id)
      assert run.state == "completed"
      assert run.reason == "all_checks_passed"
      assert run.outcome_state == "succeeded"
      assert run.outcome_reason == "all_checks_passed"
      assert %DateTime{} = run.outcome_time
      assert %DateTime{} = run.outcome_received_at
      assert byte_size(run.outcome_digest) == 32
      # No exit yet: nothing of one is recorded.
      assert run.exited_at == nil
      assert run.exit_state == nil
      refute Run.refused?(%{run | state: "failed"})
    end

    test "before the run's exit decides its state; the exit's facts are kept beside it", ctx do
      assert deliver(ctx.key, [started(ctx.run_id)]) |> response(202) == ""
      assert response(give(ctx.key, ctx.run_id, outcome()), 200) == @answer

      exit = exited(ctx.run_id, 3, %{"state" => "failed", "exit_code" => 1, "reason" => "oom"})
      assert deliver(ctx.key, [exit]) |> response(202) == ""

      run = run(ctx.run_id)
      assert run.state == "completed"
      assert run.reason == "all_checks_passed"
      assert run.exit_state == "failed"
      assert run.exit_reason == "oom"
      assert run.exit_code == 1
      assert %DateTime{} = run.exited_at
      assert Run.outcome_differs?(run)
    end

    test "after the run's exit decides its state all the same; the exit's facts are kept", ctx do
      exit = exited(ctx.run_id, 3, %{"state" => "succeeded", "exit_code" => 0})
      assert deliver(ctx.key, [started(ctx.run_id), exit]) |> response(202) == ""
      assert run(ctx.run_id).state == "completed"

      body = outcome(%{"state" => "failed", "reason" => "checks_failed"})
      assert response(give(ctx.second, ctx.run_id, body), 200) == @answer

      run = run(ctx.run_id)
      assert run.state == "failed"
      assert run.reason == "checks_failed"
      assert run.exit_state == "completed"
      assert run.exit_reason == nil
      assert run.exit_code == 0
      assert Run.outcome_differs?(run)
    end

    test "after a run the runtime lost makes it not lost", ctx do
      exit = exited(ctx.run_id, 3, %{"state" => "failed", "reason" => "session_lost"})
      assert deliver(ctx.key, [started(ctx.run_id), exit]) |> response(202) == ""
      assert %Run{state: "lost", lost_at: %DateTime{}} = run(ctx.run_id)

      assert response(give(ctx.key, ctx.run_id, outcome(%{"state" => "cancelled"})), 200) ==
               @answer

      assert %Run{state: "cancelled", lost_at: nil, exit_state: "lost"} = run(ctx.run_id)
    end

    test "that agrees with the exit reads as the exit", ctx do
      exit = exited(ctx.run_id, 3, %{"state" => "succeeded", "exit_code" => 0})
      assert deliver(ctx.key, [started(ctx.run_id), exit]) |> response(202) == ""
      assert response(give(ctx.key, ctx.run_id, outcome()), 200) == @answer
      refute Run.outcome_differs?(run(ctx.run_id))
    end

    test "with no state is cancelled with the reason stopped, whatever reason it gave", ctx do
      body = outcome(%{"state" => nil, "reason" => "no_longer_needed"})
      assert response(give(ctx.key, ctx.run_id, body), 200) == @answer

      assert %Run{state: "cancelled", reason: "stopped", outcome_state: "cancelled"} =
               run(ctx.run_id)
    end

    test "drops a reason that is Forager's own or not a code, and keeps the outcome", ctx do
      for {reason, index} <-
            Enum.with_index(["timeout", "Not A Code", 42, String.duplicate("a", 65)]) do
        run_id = Ecto.UUID.generate()
        {key, secret} = ctx.key

        assert signed_register(
                 build_conn(),
                 key.key_id,
                 secret,
                 Jason.encode!(registration(run_id))
               ).status ==
                 200

        body = outcome(%{"state" => "failed", "reason" => reason})
        assert response(give(ctx.key, run_id, body), 200) == @answer, "#{index}"
        assert %Run{state: "failed", reason: nil, outcome_reason: nil} = run(run_id)
      end
    end
  end

  describe "the same outcome again" do
    test "under the same key or the node's second key is given the same answer", ctx do
      body = outcome()
      assert response(give(ctx.key, ctx.run_id, body), 200) == @answer
      received_at = run(ctx.run_id).outcome_received_at

      for holder <- [ctx.key, ctx.second] do
        conn = give(holder, ctx.run_id, body)
        assert response(conn, 200) == @answer
        assert signed_answer?(conn)
      end

      assert run(ctx.run_id).outcome_received_at == received_at
    end

    test "under another node's key is 404", ctx do
      body = outcome()
      assert response(give(ctx.key, ctx.run_id, body), 200) == @answer

      conn = give(ctx.other, ctx.run_id, body)
      assert json_response(conn, 404) == %{"error" => "not_found"}
      assert signed_answer?(conn)
    end
  end

  describe "the same state and reason again, in other bytes" do
    # What the row holds of an outcome: none of it changes on a repeat.
    defp held(run_id) do
      run_id
      |> run()
      |> Map.take(~w(state reason outcome_state outcome_reason outcome_time
                     outcome_received_at outcome_digest updated_at)a)
    end

    test "with a new time is the stored 200, under either key of the node, the row unchanged",
         ctx do
      assert response(give(ctx.key, ctx.run_id, outcome()), 200) == @answer
      first = held(ctx.run_id)

      for {holder, offset} <- [{ctx.key, 1}, {ctx.second, 2}, {ctx.second, -3}] do
        conn = give(holder, ctx.run_id, outcome(%{"time" => now_z(offset)}))
        assert response(conn, 200) == @answer
        assert signed_answer?(conn)
      end

      assert held(ctx.run_id) == first
    end

    test "with a reason the rules drop is the same as one with none", ctx do
      assert response(give(ctx.key, ctx.run_id, outcome(%{"reason" => nil})), 200) == @answer
      first = held(ctx.run_id)

      for reason <- ["timeout", "Not A Code", 42] do
        body = outcome(%{"reason" => reason, "time" => now_z(1)})
        assert response(give(ctx.second, ctx.run_id, body), 200) == @answer
      end

      assert held(ctx.run_id) == first
      assert %{outcome_state: "succeeded", outcome_reason: nil} = first
    end

    test "with no state, twice at different times, is the stored 200", ctx do
      body = outcome(%{"state" => nil, "reason" => nil})
      assert response(give(ctx.key, ctx.run_id, body), 200) == @answer
      first = held(ctx.run_id)
      assert %{state: "cancelled", reason: "stopped"} = first

      # A reason beside no state counts for nothing either.
      again = outcome(%{"state" => nil, "reason" => "no_longer_needed", "time" => now_z(5)})
      assert response(give(ctx.second, ctx.run_id, again), 200) == @answer
      assert held(ctx.run_id) == first

      # Given cancelled with stopped in so many words: a reason the rules drop, so not
      # the same outcome as cancelled with stopped.
      named = outcome(%{"state" => "cancelled", "reason" => "stopped", "time" => now_z(6)})
      assert json_response(give(ctx.key, ctx.run_id, named), 409) == %{"error" => "outcome_given"}
    end

    test "from another node's key is still 404", ctx do
      assert response(give(ctx.key, ctx.run_id, outcome()), 200) == @answer
      conn = give(ctx.other, ctx.run_id, outcome(%{"time" => now_z(1)}))
      assert json_response(conn, 404) == %{"error" => "not_found"}
    end

    test "outside the time window is 401, unsigned", ctx do
      pin_clock()
      assert response(give(ctx.key, ctx.run_id, outcome()), 200) == @answer
      conn = give(ctx.key, ctx.run_id, outcome(%{"time" => now_z(301)}))
      assert json_response(conn, 401) == @unauthorized
      assert unsigned_answer?(conn)
    end
  end

  describe "a different second outcome" do
    test "is 409 outcome_given, signed, and changes nothing", ctx do
      assert response(give(ctx.key, ctx.run_id, outcome()), 200) == @answer

      for body <- [
            outcome(%{"state" => "failed"}),
            # The same state with another reason, or with none.
            outcome(%{"reason" => "another_reason"}),
            outcome(%{"reason" => nil}),
            # No state: cancelled, stopped.
            outcome(%{"state" => nil})
          ] do
        conn = give(ctx.second, ctx.run_id, body)
        assert json_response(conn, 409) == %{"error" => "outcome_given"}
        assert signed_answer?(conn)
      end

      assert %Run{state: "completed", reason: "all_checks_passed"} = run(ctx.run_id)
    end
  end

  describe "refused" do
    test "for a run of another node, or one the workspace does not hold, 404, signed", ctx do
      for {holder, run_id} <- [
            {ctx.other, ctx.run_id},
            {ctx.key, Ecto.UUID.generate()},
            {ctx.key, "not-a-run"}
          ] do
        conn = give(holder, run_id, outcome())
        assert json_response(conn, 404) == %{"error" => "not_found"}
        assert signed_answer?(conn)
      end

      assert run(ctx.run_id).outcome_state == nil
    end

    test "for a run another node's batch opened, 404; its own node's key gives it", ctx do
      {subject, events} = first_events()
      assert deliver(ctx.other, events) |> response(202) == ""

      assert json_response(give(ctx.key, subject, outcome()), 404) == %{"error" => "not_found"}
      assert response(give(ctx.other, subject, outcome()), 200) == @answer
      assert run(subject).state == "completed"
    end

    test "for a run whose events retention has pruned, 404", ctx do
      Repo.update_all(from(r in Run, where: r.run_id == ^ctx.run_id),
        set: [events_pruned_at: DateTime.utc_now()]
      )

      assert json_response(give(ctx.key, ctx.run_id, outcome()), 404) == %{"error" => "not_found"}
    end

    test "with a time more than 300 seconds off, 401 unsigned, the run untouched", ctx do
      pin_clock()

      for offset <- [-301, 301] do
        conn = give(ctx.key, ctx.run_id, outcome(%{"time" => now_z(offset)}))
        assert json_response(conn, 401) == @unauthorized
        assert unsigned_answer?(conn)
      end

      for offset <- [-300, 300] do
        run_id = Ecto.UUID.generate()
        {key, secret} = ctx.key

        assert signed_register(
                 build_conn(),
                 key.key_id,
                 secret,
                 Jason.encode!(registration(run_id))
               ).status ==
                 200

        assert response(give(ctx.key, run_id, outcome(%{"time" => now_z(offset)})), 200) ==
                 @answer
      end

      assert run(ctx.run_id).outcome_state == nil
    end

    test "with a body the contract refuses, 400 invalid_request naming the member", ctx do
      for {body, name} <- [
            {"not json", "body"},
            {"[]", "body"},
            {outcome(%{"extra" => 1}), "body"},
            {outcome(%{"version" => 2}), "version"},
            {outcome(%{"state" => "lost"}), "state"},
            {outcome(%{"time" => "2026-10-11T12:30:00.5Z"}), "time"},
            {outcome(%{"time" => nil}), "time"}
          ] do
        conn = give(ctx.key, ctx.run_id, body)
        assert json_response(conn, 400) == %{"error" => "invalid_request", "names" => [name]}
        assert signed_answer?(conn)
      end
    end

    test "under a key that no longer verifies, 401 unsigned", ctx do
      {key, _secret} = ctx.second
      {:ok, _} = AccessKeys.revoke_access_key(ctx.scope, key)

      conn = give(ctx.second, ctx.run_id, outcome())
      assert json_response(conn, 401) == @unauthorized
      assert unsigned_answer?(conn)
      assert run(ctx.run_id).outcome_state == nil
    end

    test "with another content type, 415; with a body over 4 KiB, 413", ctx do
      conn = give(ctx.key, ctx.run_id, outcome(), content_type: "text/plain")
      assert json_response(conn, 415) == %{"error" => "unsupported_media_type"}

      big = String.duplicate(" ", RawBody.max_bytes(:outcome) + 1)
      conn = give(ctx.key, ctx.run_id, big)
      assert json_response(conn, 413) == %{"error" => "payload_too_large"}
    end
  end

  describe "the end" do
    test "is in every 2xx to the run's batches once an outcome is given, until its exit",
         ctx do
      # No outcome yet: an empty body, as always.
      assert deliver(ctx.key, [started(ctx.run_id)]) |> response(202) == ""

      assert response(give(ctx.key, ctx.run_id, outcome()), 200) == @answer
      beat = wire_event(ctx.run_id, 3, "run.heartbeat", %{"elapsed_seconds" => 30})

      for holder <- [ctx.key, ctx.second] do
        conn = deliver(holder, [beat])

        assert response(conn, 202) ==
                 ~s({"end":{"state":"succeeded","reason":"all_checks_passed"}})

        assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
        assert signed_answer?(conn)
      end

      # The batch that carries the exit has no end, and nor does any after it.
      exit = exited(ctx.run_id, 4, %{"state" => "succeeded", "exit_code" => 0})
      assert deliver(ctx.key, [exit]) |> response(202) == ""
      assert deliver(ctx.key, [beat]) |> response(202) == ""
    end

    test "leaves out the reason when the outcome gave none", ctx do
      assert response(give(ctx.key, ctx.run_id, outcome(%{"reason" => nil})), 200) == @answer
      conn = deliver(ctx.key, [started(ctx.run_id)])
      assert response(conn, 202) == ~s({"end":{"state":"succeeded"}})
    end

    test "is covered by the answer's signature: line 4 is the SHA-256 of the body", ctx do
      assert response(give(ctx.key, ctx.run_id, outcome()), 200) == @answer
      conn = deliver(ctx.key, [started(ctx.run_id)])
      body = response(conn, 202)
      assert body =~ ~s("end")
      assert signed_answer?(conn)

      [request_signature] = get_req_header(conn, "x-qory-signature-ed25519")
      configuration = hd(get_resp_header(conn, "x-qory-configuration"))
      message = SignedMessage.answer(202, request_signature, body, configuration, nil)
      line_4 = :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)
      assert message |> String.split("\n") |> Enum.at(3) == line_4

      # The same answer with no end, or with another one, does not verify.
      for other <- ["", ~s({"end":{"state":"failed"}})] do
        forged = %{conn | resp_body: other}
        refute signed_answer?(forged)
      end
    end
  end

  describe "a run refused at its start" do
    # Registered, refused, and given an outcome, in either order: it never started, and
    # its outcome says the state alone.
    defp registered({key, secret}) do
      run_id = Ecto.UUID.generate()
      body = Jason.encode!(registration(run_id))
      assert signed_register(build_conn(), key.key_id, secret, body).status == 200
      run_id
    end

    defp refuse(holder, run_id) do
      refused = wire_event(run_id, 2, "run.refused", %{"code" => "image_unknown"})
      assert deliver(holder, [refused]).status in [200, 202]
    end

    test "keeps its refusal under the outcome, in either order and after a rebuild", ctx do
      for {outcome, state, word} <- [
            {"succeeded", "completed", "Succeeded"},
            {"failed", "failed", "Failed"},
            {"cancelled", "cancelled", "Cancelled"}
          ],
          order <- [:refused_first, :outcome_first] do
        run_id = registered(ctx.key)
        body = outcome(%{"state" => outcome, "reason" => nil})

        if order == :refused_first, do: refuse(ctx.key, run_id)
        assert response(give(ctx.key, run_id, body), 200) == @answer
        if order == :outcome_first, do: refuse(ctx.key, run_id)

        before = run(run_id)
        assert %Run{state: ^state, reason: nil, exited_at: nil} = before
        assert %DateTime{} = before.refused_at
        refute Run.refused?(before)
        sentence = "#{word}, as its starter said"
        assert ApiaryWeb.RunComponents.outcome_sentence(before) == sentence, "#{order}"

        assert {:ok, _run} = Projector.rebuild(before)
        rebuilt = run(run_id)

        for field <- ~w(state reason refused_at exited_at outcome_state)a do
          assert Map.fetch!(rebuilt, field) == Map.fetch!(before, field), "#{field}"
        end

        assert ApiaryWeb.RunComponents.outcome_sentence(rebuilt) == sentence
      end
    end
  end

  describe "a rebuild" do
    test "gives the run the outcome's state again, from the events and the outcome", ctx do
      exit = exited(ctx.run_id, 3, %{"state" => "failed", "exit_code" => 1, "reason" => "oom"})
      assert deliver(ctx.key, [started(ctx.run_id), exit]) |> response(202) == ""
      assert response(give(ctx.key, ctx.run_id, outcome()), 200) == @answer

      before = run(ctx.run_id)
      assert {:ok, _run} = Projector.rebuild(before)
      after_rebuild = run(ctx.run_id)

      for field <- ~w(state reason exit_state exit_reason exit_code exited_at lost_at
                      outcome_state outcome_reason outcome_digest started_at)a do
        assert Map.fetch!(after_rebuild, field) == Map.fetch!(before, field), "#{field}"
      end
    end

    test "of a run given an outcome before any event keeps the outcome's state", ctx do
      assert response(give(ctx.key, ctx.run_id, outcome(%{"state" => "failed"})), 200) ==
               @answer

      assert {:ok, _run} = Projector.rebuild(run(ctx.run_id))
      assert %Run{state: "failed", reason: "all_checks_passed"} = run(ctx.run_id)
    end
  end
end
