defmodule ApiaryWeb.Contract.CancelRunTest do
  # What a member's cancel of a running run (`Apiary.Runs.Cancel`) changes for the run's
  # requests, from the press: the `end` in each `202` to its batches, a direct run's
  # outcome, and its pushes and verdict through the run API, at the controller and under
  # the work item's lock. Its reads stay. Not async: the run API's stubs and the features
  # are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.SealedRunsFixtures
  import Ecto.Query, only: [from: 2]

  alias Apiary.{Repo, Runs}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Runs.Run
  alias Apiary.WorkItems.WorkItem
  alias ApiaryWeb.RunApiStubs

  @cancel_end ~s({"end":{"state":"cancelled","reason":"cancelled_by_member"}})
  @cancelled %{
    "error" => "run_ended",
    "message" => "The run was cancelled, so it can no longer push artifacts or give a verdict."
  }

  defp run(run_id), do: Repo.one!(from r in Run, where: r.node_run_id == ^run_id)

  describe "a direct run" do
    @describetag needs: :observability

    setup do
      %{scope: scope} = sign_up_fixture()
      %{access_key: key, secret: secret} = contract_key_fixture(scope)
      run_id = Ecto.UUID.generate()
      registration = Jason.encode!(registration(run_id))
      assert signed_register(build_conn(), key.key_id, secret, registration).status == 200
      {_subject, [started]} = first_events(run_id)
      deliver = &signed_post(build_conn(), key.key_id, secret, &1)
      assert deliver.([started]) |> response(202) == ""

      %{scope: scope, run_id: run_id, key: {key, secret}, deliver: deliver}
    end

    test "each 202 to its batches has the cancel's end until its exit", ctx do
      beat = wire_event(ctx.run_id, 3, "run.heartbeat", %{"elapsed_seconds" => 30})
      assert ctx.deliver.([beat]) |> response(202) == ""

      {:ok, _cancelled} = Runs.cancel(ctx.scope, run(ctx.run_id))

      conn =
        ctx.deliver.([wire_event(ctx.run_id, 4, "run.heartbeat", %{"elapsed_seconds" => 60})])

      assert response(conn, 202) == @cancel_end
      assert signed_answer?(conn)

      # A repeat of a batch gets the same 202.
      assert ctx.deliver.([beat]) |> response(202) == @cancel_end

      # The 202 to the batch with the exit has no body, nor does the 202 to any after it.
      exit =
        wire_event(ctx.run_id, 5, "run.exited", %{
          "state" => "cancelled",
          "reason" => "cancelled_by_member",
          "exit_code" => -1,
          "signal" => "SIGTERM"
        })

      assert ctx.deliver.([exit]) |> response(202) == ""
      assert ctx.deliver.([beat]) |> response(202) == ""
      assert %Run{state: "cancelled", exit_reason: "cancelled_by_member"} = run(ctx.run_id)
    end

    test "its starter's outcome is 409 outcome_given from the press", ctx do
      {:ok, _cancelled} = Runs.cancel(ctx.scope, run(ctx.run_id))

      {key, secret} = ctx.key

      body =
        Jason.encode!(%{
          "version" => 1,
          "state" => "succeeded",
          "time" =>
            ApiaryWeb.Contract.SignedRequest.now()
            |> DateTime.from_unix!()
            |> DateTime.to_iso8601()
        })

      conn =
        signed_post(build_conn(), key.key_id, secret, body,
          target: "/v1/runs/#{ctx.run_id}/outcome",
          content_type: "application/json",
          delivery: nil
        )

      assert json_response(conn, 409) == %{"error" => "outcome_given"}
      assert %Run{outcome_state: nil, state: "running"} = run(ctx.run_id)
    end
  end

  describe "a run of a work item, through the run API" do
    @describetag needs: [:workflow_model, :factory, :secrets, :observability]
    @describetag :tmp_dir

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
      fixture = sealed_run_fixture(scope)
      dispatch_run = Repo.get!(DispatchRun, fixture.run.dispatch_run_id)

      # Running, as a member can cancel it: attached, and its agent started.
      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^fixture.run.id),
          set: [state: "running", started_at: DateTime.utc_now()]
        )

      %{
        scope: scope,
        run: fixture.run,
        key: fixture.secrets_key,
        dispatch_run: dispatch_run,
        work_item: Repo.get!(WorkItem, dispatch_run.work_item_id)
      }
    end

    defp write(ctx, path, body) do
      {key, seed} = ctx.key
      body = if is_binary(body), do: body, else: Jason.encode!(body)

      build_conn()
      |> Plug.Conn.assign(:raw_body, body)
      |> signed_post(key.key_id, seed, body,
        target: "/v1/runs/#{ctx.run.node_run_id}" <> path,
        content_type: "application/json",
        delivery: nil
      )
    end

    defp read(ctx, path) do
      {key, seed} = ctx.key
      signed_get(build_conn(), key.key_id, seed, "/v1/runs/#{ctx.run.node_run_id}" <> path)
    end

    defp walkthrough,
      do: %{
        "type" => "walkthrough",
        "files" => [
          %{
            "filename" => "a.md",
            "content_type" => "text/markdown",
            "content_base64" => Base.encode64("# A\n")
          }
        ]
      }

    test "a push and a verdict are 409 run_ended, saying the run was cancelled", ctx do
      assert write(ctx, "/artifacts", walkthrough()).status == 201

      {:ok, _cancelled} = Runs.cancel(ctx.scope, Repo.get!(Run, ctx.run.id))

      for conn <- [
            write(ctx, "/artifacts", walkthrough()),
            write(ctx, "/verdict", %{"verdict" => "passed"}),
            # Refused before the body is read: a body outside the contract is 409 too.
            write(ctx, "/verdict", %{"verdict" => "maybe"}),
            write(ctx, "/artifacts", "{")
          ] do
        assert json_response(conn, 409) == @cancelled
        assert signed_answer?(conn)
      end

      assert length(RunApiStubs.pushed()) == 1
      # It still reads its work item and its artifacts.
      assert read(ctx, "/work-item").status == 200
      assert read(ctx, "/artifacts").status == 200
    end

    test "a cancelled run lost after its attach and not lost for good stays refused", ctx do
      {:ok, _cancelled} = Runs.cancel(ctx.scope, Repo.get!(Run, ctx.run.id))
      now = DateTime.utc_now()

      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id),
          set: [
            state: "lost",
            lost_at: DateTime.add(now, -300, :second),
            backstop_at: DateTime.add(now, 3600, :second)
          ]
        )

      # Refused at the controller, before the body is read: a body outside the contract
      # is 409 too, not 400.
      for conn <- [
            write(ctx, "/artifacts", walkthrough()),
            write(ctx, "/verdict", %{"verdict" => "passed"}),
            write(ctx, "/verdict", %{"verdict" => "maybe"}),
            write(ctx, "/artifacts", "{")
          ] do
        assert json_response(conn, 409) == @cancelled
      end

      assert RunApiStubs.pushed() == []
    end

    test "a push already past the controller's check reads the mark under the lock", ctx do
      {:ok, _cancelled} = Runs.cancel(ctx.scope, Repo.get!(Run, ctx.run.id))

      file = %{filename: "a.md", content_type: "text/markdown", binary: "# A\n"}

      assert {:error, :run_cancelled} =
               Apiary.Artifacts.push(
                 {:run, ctx.dispatch_run},
                 ctx.work_item,
                 "walkthrough",
                 [file],
                 name: "main"
               )

      assert {:error, :run_cancelled} =
               Apiary.Stages.Artifacts.push_json(
                 {:run, ctx.dispatch_run},
                 ctx.work_item,
                 "verdict",
                 %{"verdict" => "passed"},
                 []
               )

      assert Apiary.Artifacts.list(ctx.work_item) == []
    end
  end
end
