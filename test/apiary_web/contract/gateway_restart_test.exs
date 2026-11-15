defmodule ApiaryWeb.Contract.GatewayRestartTest do
  # A run of a workspace's queue whose gateway restarts while it runs: the lost-run check
  # finds the run lost 90 seconds after its last heartbeat, and the run is lost for good
  # only at the end of its silence, 600 seconds, or at its backstop. Until then the
  # gateway that attached it, from the same instance, attaches it again and is served on
  # every route of the run, and its next heartbeat makes the run run again; a run a
  # member cancelled meanwhile gets the cancel's end then. A gateway of the previous
  # release, which does not attach again, still ends the run with its exit.
  # Not async: the run API's stubs and the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.SealedRunsFixtures

  alias Apiary.{ContractSchema, Repo}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Runs.{Liveness, Run}
  alias ApiaryWeb.Contract.SignedRequest
  alias ApiaryWeb.RunApiStubs

  @moduletag needs: [:workflow_model, :factory, :secrets, :observability]
  @moduletag :tmp_dir

  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR">>

  setup {Apiary.DataCase, :without_registry}

  setup %{tmp_dir: tmp_dir} do
    :ok = RunApiStubs.install()
    previous = Application.fetch_env(:apiary, :artifacts_dir)
    Application.put_env(:apiary, :artifacts_dir, Path.join(tmp_dir, "store"))

    on_exit(fn ->
      case previous do
        {:ok, dir} -> Application.put_env(:apiary, :artifacts_dir, dir)
        :error -> Application.delete_env(:apiary, :artifacts_dir)
      end
    end)

    %{scope: scope} = sign_up_fixture()
    {:ok, _rule} = Apiary.Policy.allow(scope, nil, %{host: "git.example"})
    scope |> sealed_run_fixture(attach: false) |> Map.put(:scope, scope)
  end

  defp run(ctx), do: Repo.get!(Run, ctx.run.id)

  defp dispatch_run(ctx), do: Repo.get!(DispatchRun, ctx.run.dispatch_run_id)

  defp signed(ctx, body, opts) do
    {key, seed} = ctx.secrets_key

    signed_post(
      build_conn(),
      key.key_id,
      seed,
      body,
      Keyword.merge([content_type: "application/json", delivery: nil], opts)
    )
  end

  defp attach(ctx, body),
    do: signed(ctx, Jason.encode!(body), target: "/v1/runs/#{ctx.run.node_run_id}/attach")

  defp deliver(ctx, events) do
    {key, seed} = ctx.secrets_key
    signed_post(build_conn(), key.key_id, seed, events)
  end

  defp secrets(ctx, body), do: signed(ctx, body, target: "/v1/secrets")

  defp model_keys(ctx, body),
    do: signed(ctx, body, target: "/v1/runs/#{ctx.run.node_run_id}/model-keys")

  defp push_artifact(ctx, body), do: write(ctx, "/artifacts", body)

  defp verdict(ctx, body), do: write(ctx, "/verdict", body)

  defp write(ctx, path, body) do
    {key, seed} = ctx.secrets_key
    body = Jason.encode!(body)

    build_conn()
    |> Plug.Conn.assign(:raw_body, body)
    |> signed_post(key.key_id, seed, body,
      target: "/v1/runs/#{ctx.run.node_run_id}" <> path,
      content_type: "application/json",
      delivery: nil
    )
  end

  defp wire_time(%DateTime{} = at),
    do: at |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

  defp started(ctx),
    do:
      wire_event(
        ctx.run.node_run_id,
        2,
        "run.started",
        %{
          "opened_by" => "run",
          "forager_version" => "0.7.0",
          "host" => "machine-1",
          "labels" => %{"forge" => "git.example.com", "repository" => "acme/shop"}
        },
        time: wire_time(DateTime.utc_now())
      )

  defp beat(ctx, sequence),
    do:
      wire_event(
        ctx.run.node_run_id,
        sequence,
        "run.heartbeat",
        %{"elapsed_seconds" => 30, "interval_seconds" => 30},
        time: wire_time(DateTime.utc_now())
      )

  defp exited(ctx, sequence, data),
    do:
      wire_event(ctx.run.node_run_id, sequence, "run.exited", data,
        time: wire_time(DateTime.utc_now())
      )

  defp digest(conn) do
    [digest] = get_resp_header(conn, "x-qory-run-configuration")
    digest
  end

  defp secrets_body(ctx, digest),
    do:
      secrets_request(
        ctx.run,
        digest,
        ["#{ctx.provider.public_id}-1"],
        SignedRequest.now()
      )

  defp report(ctx) do
    at = fn offset ->
      (SignedRequest.now() + offset) |> DateTime.from_unix!() |> DateTime.to_iso8601()
    end

    Jason.encode!(%{
      "version" => 1,
      "run_id" => ctx.run.node_run_id,
      "time" => at.(0),
      "keys" => [
        %{
          "credential" => "#{ctx.provider.public_id}-1",
          "window" => "five_hour",
          "status" => "allowed",
          "utilization" => 40,
          "resets_at" => at.(3600),
          "source" => "provider",
          "observed_at" => at.(-1)
        }
      ]
    })
  end

  # The lost-run check as it runs `seconds` from now: the run's heartbeats are older than
  # three of its intervals, and its silence has not reached 600 seconds.
  defp check_after!(seconds), do: Liveness.check(DateTime.add(DateTime.utc_now(), seconds))

  test "a restarted gateway attaches its lost run again and the run finishes", ctx do
    first = attach(ctx, attach_body(ctx.run_key))
    assert first.status == 200
    assert secrets(ctx, secrets_body(ctx, digest(first))).status == 200
    assert response(deliver(ctx, [started(ctx), beat(ctx, 3)]), 202) == ""
    assert run(ctx).state == "running"

    # The deploy stops the gateway: no heartbeat for 120 seconds.
    check_after!(120)
    assert %Run{state: "lost", silenced_at: nil} = run(ctx)

    # The new gateway, with the same instance id, attaches the run again: the stored
    # answer, nothing written.
    again = attach(ctx, attach_body(ctx.run_key))
    assert again.status == 200
    assert again.resp_body == first.resp_body
    assert digest(again) == digest(first)
    assert secrets(ctx, secrets_body(ctx, digest(again))).status == 200

    # Its next heartbeat makes the run run again, and the run ends with its exit.
    assert response(deliver(ctx, [beat(ctx, 4)]), 202) == ""
    assert %Run{state: "running", lost_at: nil} = run(ctx)

    exit = exited(ctx, 5, %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 9000})
    assert response(deliver(ctx, [exit]), 202) == ""
    assert %Run{state: "completed"} = run(ctx)
    assert %DispatchRun{state: :ended, end_cause: :run_ended} = dispatch_run(ctx)
  end

  test "a run cancelled before its gateway restarts gets end after the re-attach", ctx do
    first = attach(ctx, attach_body(ctx.run_key))
    assert first.status == 200
    assert secrets(ctx, secrets_body(ctx, digest(first))).status == 200
    assert response(deliver(ctx, [started(ctx), beat(ctx, 3)]), 202) == ""

    {:ok, _cancelled} = Apiary.Runs.cancel(ctx.scope, run(ctx))

    # The deploy stops the gateway before the next batch: no heartbeat for 120 seconds.
    # The run is lost, and the backstop its attach set is later, so it may still attach
    # again.
    check_after!(120)
    assert %Run{state: "lost", silenced_at: nil, backstop_at: %DateTime{} = backstop} = run(ctx)
    assert DateTime.compare(backstop, DateTime.add(DateTime.utc_now(), 120, :second)) == :gt
    assert Apiary.Runs.Cancel.cancelling?(run(ctx))

    # The new gateway, with the same instance id, attaches the run again, and the 202 to
    # its next batch has the cancel's end.
    again = attach(ctx, attach_body(ctx.run_key))
    assert again.status == 200
    assert again.resp_body == first.resp_body

    assert response(deliver(ctx, [beat(ctx, 4)]), 202)
           |> Jason.decode!() ==
             %{"end" => %{"state" => "cancelled", "reason" => "cancelled_by_member"}}

    # Its heartbeat makes the run run again, still cancelling until its exit.
    assert %Run{state: "running", lost_at: nil} = running = run(ctx)
    assert Apiary.Runs.Cancel.cancelling?(running)

    file = %{
      "filename" => "one.png",
      "content_type" => "image/png",
      "content_base64" => Base.encode64(@png)
    }

    for conn <- [
          push_artifact(ctx, %{"type" => "screenshot", "files" => [file]}),
          verdict(ctx, %{"verdict" => "passed"})
        ] do
      assert json_response(conn, 409) == %{
               "error" => "run_ended",
               "message" =>
                 "The run was cancelled, so it can no longer push artifacts or give a verdict."
             }
    end

    # Its secrets request is still served, so the run reaches its next batch and the end.
    assert secrets(ctx, secrets_body(ctx, digest(again))).status == 200
  end

  test "a member cancels a run lost while its gateway restarts, until it is lost for good",
       ctx do
    first = attach(ctx, attach_body(ctx.run_key))
    assert first.status == 200
    assert secrets(ctx, secrets_body(ctx, digest(first))).status == 200
    assert response(deliver(ctx, [started(ctx), beat(ctx, 3)]), 202) == ""

    # The deploy stops the gateway: the run is lost, and its run of the queue is still
    # handed over, as the run may still attach again.
    check_after!(120)
    assert %Run{state: "lost", silenced_at: nil} = lost = run(ctx)
    assert %DispatchRun{state: :handed_over} = dispatch_run(ctx)
    assert Apiary.Runs.Cancel.cancellable?(lost)

    assert {:ok, %Run{state: "lost"} = cancelled} = Apiary.Runs.cancel(ctx.scope, lost)
    assert Apiary.Runs.Cancel.cancelling?(cancelled)

    # The new gateway attaches the run again, and the 202 to its next batch has the
    # cancel's end.
    assert attach(ctx, attach_body(ctx.run_key)).status == 200

    assert response(deliver(ctx, [beat(ctx, 4)]), 202) |> Jason.decode!() ==
             %{"end" => %{"state" => "cancelled", "reason" => "cancelled_by_member"}}
  end

  test "a run lost for good at the end of its silence is not cancelled", ctx do
    first = attach(ctx, attach_body(ctx.run_key))
    assert first.status == 200
    assert response(deliver(ctx, [started(ctx), beat(ctx, 3)]), 202) == ""

    check_after!(120)
    assert Apiary.Runs.Cancel.cancellable?(run(ctx))

    # 600 seconds without a heartbeat: the check ends its run of the queue `lost`, and the
    # run is lost for good.
    check_after!(700)
    assert %DispatchRun{state: :ended, end_cause: :lost} = dispatch_run(ctx)
    assert %Run{state: "lost", silenced_at: %DateTime{}} = run(ctx)

    lost = run(ctx)
    refute Apiary.Runs.Cancel.cancellable?(lost)
    assert {:error, :not_running} = Apiary.Runs.cancel(ctx.scope, lost)
    refute Run.cancel_requested?(run(ctx))
  end

  describe "a gateway of the previous release" do
    @describetag :contract

    defp valid!(file, document) do
      schema = ContractSchema.schema!(contract_dir(), file)
      document = if is_binary(document), do: Jason.decode!(document), else: document
      assert {file, ContractSchema.validate(schema, document)} == {file, :ok}
    end

    test "is served until its restart, and its exit after the restart ends the run", ctx do
      body = attach_body(ctx.run_key)
      valid!("run-attach.schema.json", body)
      first = attach(ctx, body)
      valid!("run-attach-answer.schema.json", json_response(first, 200))

      request = secrets_body(ctx, digest(first))
      valid!("secrets-request.schema.json", request)
      conn = secrets(ctx, request)
      assert conn.status == 200
      valid!("secrets-answer.schema.json", conn.resp_body)

      batch = [started(ctx), beat(ctx, 3)]
      valid!("batch.schema.json", batch)
      assert response(deliver(ctx, batch), 202) == ""

      request = report(ctx)
      valid!("model-keys-report.schema.json", request)
      conn = model_keys(ctx, request)
      assert conn.status == 200
      valid!("model-keys-answer.schema.json", conn.resp_body)

      file = %{
        "filename" => "one.png",
        "content_type" => "image/png",
        "content_base64" => Base.encode64(@png)
      }

      assert push_artifact(ctx, %{"type" => "screenshot", "files" => [file]}).status == 201

      # The gateway restarts and attaches nothing again: the run is lost. Its session's
      # next request ends the run at the gateway, which posts the session's exit.
      check_after!(120)
      assert %Run{state: "lost"} = run(ctx)

      exit =
        exited(ctx, 4, %{
          "state" => "failed",
          "reason" => "run_closed",
          "exit_code" => -1,
          "duration_ms" => 130_000
        })

      valid!("batch.schema.json", [exit])
      assert response(deliver(ctx, [exit]), 202) == ""

      assert %Run{state: "failed", exit_reason: "run_closed"} = run(ctx)
      assert %DispatchRun{state: :ended, end_cause: :run_ended} = dispatch_run(ctx)
    end
  end
end
