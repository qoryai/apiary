defmodule Apiary.Runs.DiagnosticsTest do
  # The run diagnostics document (`Apiary.Runs.Diagnostics`): every document it builds is
  # valid under the vendored contract (`priv/contract/diagnostics/v1/`), whose fixtures
  # are checked first; what each reader reads; the secret filter on every text; the
  # events' and the log's bounds; the size cap; and a run whose events or log the
  # retention removed. Not async: a test of an instance admin hides the instance's
  # organisation, a row every test shares.
  use Apiary.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.AccountsFixtures, only: [user_fixture: 0]
  import Apiary.DispatchedRunsFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.{DiagnosticsSchema, Dispatches, Repo}
  alias Apiary.Runs.{Diagnostics, LogChunk, Run}

  @secret "qak_AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA"
  @code "qecn_7K3M9P2Q4R6S8T0V1W5X3Y9Z2A"
  @run_key "qrk_eyJ2ZXJzaW9uIjoxfQ.c2lnbmF0dXJlLWJ5dGVz"

  setup_all do
    %{schema: DiagnosticsSchema.root()}
  end

  defp valid!(schema, document) do
    decoded = document |> Jason.encode!() |> Jason.decode!()
    assert DiagnosticsSchema.validate(schema, decoded) == :ok
    decoded
  end

  defp everything, do: %{log: true, machine_logs: true}

  defp chunk!(%Run{} = run, sequence, bytes, step \\ nil) do
    Repo.insert!(%LogChunk{
      organisation_id: run.organisation_id,
      workspace_id: run.workspace_id,
      run_id: run.id,
      sequence: sequence,
      stream: "terminal",
      bytes: bytes,
      step: step
    })
  end

  describe "the contract's fixtures" do
    test "each document is valid, and each invalid one refused", %{schema: schema} do
      dir = DiagnosticsSchema.fixtures_dir()
      valid = Path.wildcard(Path.join(dir, "diagnostics/*.json"))
      invalid = Path.wildcard(Path.join(dir, "invalid/*.json"))
      assert length(valid) == 4 and length(invalid) == 9

      for file <- valid do
        assert DiagnosticsSchema.validate(schema, file |> File.read!() |> Jason.decode!()) ==
                 :ok,
               file
      end

      for file <- invalid do
        assert {:error, _} =
                 DiagnosticsSchema.validate(schema, file |> File.read!() |> Jason.decode!()),
               file
      end
    end
  end

  describe "a run registered without a claim" do
    setup do
      %{scope: scope} = sign_up_fixture()
      %{scope: scope, run: run_fixture(scope, %{public_id: Run.new_public_id()})}
    end

    test "is valid, with no dispatch and no queue, its members from its columns",
         %{schema: schema, scope: scope, run: run} do
      events_fixture(run, [
        {1, "run.started", %{"about" => %{"kind" => "note"}}},
        {2, "run.exited", %{"exit_code" => 0}}
      ])

      run =
        run
        |> Ecto.Changeset.change(
          state: "completed",
          exit_state: "completed",
          exit_code: 0,
          reason: "Not A Code",
          target_system: "forge.example.com",
          target_path: "acme/example",
          started_at: at(1),
          exited_at: at(2)
        )
        |> Repo.update!()

      now = ~U[2026-10-30 10:20:00.123456Z]
      document = valid!(schema, Diagnostics.document(run, everything(), now: now))

      assert document["version"] == 1
      assert document["time"] == "2026-10-30T10:20:00Z"
      assert document["instance"]["edition"] == "Qory Apiary"
      assert document["dispatches"] == []
      refute Map.has_key?(document, "queue")
      assert document["preparation"] == %{"steps" => []}
      assert document["machine_logs"] == []

      assert document["run"] == %{
               "id" => run.public_id,
               "state" => "completed",
               "exit_state" => "completed",
               "exit_code" => 0,
               "created_at" =>
                 run.inserted_at |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
               "started_at" => "2026-09-16T12:00:01Z",
               "exited_at" => "2026-09-16T12:00:02Z",
               "organisation" => %{"slug" => scope.organisation.slug},
               "workspace" => %{"id" => scope.workspace.public_id},
               "target" => %{"system" => "forge.example.com", "path" => "acme/example"}
             }

      assert [%{"sequence" => 1, "type" => "dev.qory.run.started"}, %{"sequence" => 2}] =
               document["events"]

      assert document["events"] |> hd() |> Map.fetch!("time") == "2026-09-16T12:00:01.000000Z"
      assert document["events_omitted"] == 0
      assert document["log"] == %{"text" => "", "truncated" => false}
    end

    test "leaves out the log and the machine logs for a reader without the rights",
         %{schema: schema, run: run} do
      document = valid!(schema, Diagnostics.document(run, %{log: false, machine_logs: false}))
      refute Map.has_key?(document, "log")
      refute Map.has_key?(document, "machine_logs")
      assert Map.has_key?(document, "events")
    end

    test "passes every text through the secret filter, and replaces U+0000 and bytes outside UTF-8",
         %{schema: schema, run: run} do
      events_fixture(run, [
        {1, "run.log", %{"note" => "key #{@secret}", @run_key => [%{"code" => @code}, 1]}}
      ])

      chunk!(run, 2, "token #{@run_key} and #{@code}\n")
      chunk!(run, 3, <<"nul ", 0, " and ", 0xFF, " end">>)

      json = Diagnostics.document(run, everything()) |> Jason.encode!()
      document = valid!(schema, Diagnostics.document(run, everything()))

      for secret <- ["qak_", "qrk_", "qecn_", "AQIDBAUG", "c2lnbmF0", "7K3M9P2Q"] do
        refute json =~ secret, secret
      end

      assert [%{"data" => data}] = document["events"]
      assert data == %{"note" => "key [FILTERED]", "[FILTERED]" => [%{"code" => "[FILTERED]"}, 1]}

      assert document["log"]["text"] ==
               "token [FILTERED] and [FILTERED]\nnul \u{FFFD} and \u{FFFD} end"
    end

    test "has the last events, as many as it holds, and counts the earlier ones",
         %{schema: schema, run: run} do
      max = Diagnostics.max_events()
      now = DateTime.utc_now()

      rows =
        for sequence <- 1..(max + 7) do
          %{
            id: Ecto.UUID.generate(),
            organisation_id: run.organisation_id,
            workspace_id: run.workspace_id,
            run_id: run.id,
            sequence: sequence,
            node_event_id: Ecto.UUID.generate(),
            type: "dev.qory.run.heartbeat",
            time: now,
            data: %{"n" => sequence},
            received_at: now
          }
        end

      for batch <- Enum.chunk_every(rows, 1_000), do: Repo.insert_all(Apiary.Runs.Event, batch)

      document = valid!(schema, Diagnostics.document(run, everything()))
      assert length(document["events"]) == max
      assert document["events_omitted"] == 7
      assert hd(document["events"])["sequence"] == 8
      assert List.last(document["events"])["sequence"] == max + 7
    end

    test "has the last MiB of the output that belongs to no step, and says it cut it",
         %{schema: schema, run: run} do
      mib = Diagnostics.max_log_bytes()
      chunk!(run, 1, String.duplicate("a", 600_000))
      chunk!(run, 2, "step output\n", 1)
      chunk!(run, 3, String.duplicate("b", 600_000))
      chunk!(run, 4, "é" <> String.duplicate("c", 99_999))

      %{"log" => %{"text" => text, "truncated" => true}} =
        valid!(schema, Diagnostics.document(run, everything()))

      assert byte_size(text) == mib
      refute text =~ "step output"
      assert String.ends_with?(text, "é" <> String.duplicate("c", 99_999))
      assert String.starts_with?(text, "a")
    end

    test "is at most 8 MiB: the oldest events are left out first",
         %{schema: schema, run: run} do
      now = DateTime.utc_now()
      big = String.duplicate("x", 4_000)

      rows =
        for sequence <- 1..3_000 do
          %{
            id: Ecto.UUID.generate(),
            organisation_id: run.organisation_id,
            workspace_id: run.workspace_id,
            run_id: run.id,
            sequence: sequence,
            node_event_id: Ecto.UUID.generate(),
            type: "dev.qory.run.heartbeat",
            time: now,
            data: %{"text" => big},
            received_at: now
          }
        end

      for batch <- Enum.chunk_every(rows, 500), do: Repo.insert_all(Apiary.Runs.Event, batch)
      chunk!(run, 3_001, String.duplicate("\e[1m", 200_000))

      document = Diagnostics.document(run, everything())
      assert byte_size(Jason.encode!(document)) <= Diagnostics.max_bytes()
      document = valid!(schema, document)

      kept = length(document["events"])
      assert kept > 0 and document["events_omitted"] == 3_000 - kept
      assert List.last(document["events"])["sequence"] == 3_000
      assert document["log"]["truncated"] == false
    end

    test "cuts the log's first part when the rest of the document is over the bound",
         %{schema: schema, run: run} do
      chunk!(run, 1, String.duplicate("\e", 100_000))

      document = Diagnostics.document(run, everything(), max_bytes: 200_000)
      assert byte_size(Jason.encode!(document)) <= 200_000
      document = valid!(schema, document)

      assert document["log"]["truncated"] == true
      assert document["events"] == [] and document["events_omitted"] == 0
    end

    test "leaves out what the retention removed", %{schema: schema, run: run} do
      events_fixture(run, [{1, "run.heartbeat", %{}}])
      chunk!(run, 2, "line\n")

      log_pruned = run |> Ecto.Changeset.change(log_pruned_at: now()) |> Repo.update!()
      document = valid!(schema, Diagnostics.document(log_pruned, everything()))
      refute Map.has_key?(document, "log")
      assert [_event] = document["events"]

      pruned =
        log_pruned |> Ecto.Changeset.change(events_pruned_at: now()) |> Repo.update!()

      document = valid!(schema, Diagnostics.document(pruned, everything()))
      refute Map.has_key?(document, "log")
      refute Map.has_key?(document, "events")
      refute Map.has_key?(document, "events_omitted")
    end
  end

  describe "a run's preparation" do
    setup do
      %{scope: scope} = sign_up_fixture()
      run = run_fixture(scope, %{public_id: Run.new_public_id()})

      events_fixture(run, [
        {1, "run.started", started_data()},
        {2, "run.step_started", %{"step" => 1, "name" => "fetch acme/shop", "kind" => "fetch"}},
        {3, "run.log", step_log_data(1, "Cloning with #{@secret}\n")},
        {4, "run.step_exited",
         %{"step" => 1, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 100}},
        {5, "run.step_started", %{"step" => 2, "name" => "setup", "kind" => "setup"}},
        {6, "run.step_exited",
         %{"step" => 2, "state" => "failed", "exit_code" => 2, "duration_ms" => 50}}
      ])

      {:ok, run} = Apiary.Runs.Projector.project(run)
      %{scope: scope, run: run}
    end

    test "has the steps with their output, filtered, and why it stopped",
         %{schema: schema, run: run} do
      document = valid!(schema, Diagnostics.document(run, everything()))

      assert %{
               "steps" => [
                 %{
                   "number" => 1,
                   "name" => "Fetch acme/shop",
                   "kind" => "fetch",
                   "state" => "succeeded",
                   "exit_code" => 0,
                   "duration_ms" => 100,
                   "output" => %{"text" => "Cloning with [FILTERED]", "truncated" => false}
                 },
                 %{"number" => 2, "state" => "failed", "exit_code" => 2}
               ],
               "stopped" => %{
                 "cause" => "step_failed",
                 "step" => 2,
                 "fixer" => "workspace_admin",
                 "text" => text
               }
             } = document["preparation"]

      assert text =~ "Setup failed with exit code 2."
      refute Jason.encode!(document) =~ "AQIDBAUG"
    end

    test "a reader without the log reads each step's output as empty and cut",
         %{schema: schema, run: run} do
      document = valid!(schema, Diagnostics.document(run, %{log: false, machine_logs: false}))

      for step <- document["preparation"]["steps"] do
        assert step["output"] == %{"text" => "", "truncated" => true}
      end
    end
  end

  describe "a run of a workspace's queue" do
    @describetag needs: :factory
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      before = Application.fetch_env(:apiary, :machine_logs_dir)
      Application.put_env(:apiary, :machine_logs_dir, Path.join(tmp_dir, "machine-logs"))

      on_exit(fn ->
        case before do
          {:ok, value} -> Application.put_env(:apiary, :machine_logs_dir, value)
          :error -> Application.delete_env(:apiary, :machine_logs_dir)
        end
      end)

      Apiary.EditionKit.hide_instance_organisation()
      %{scope: scope} = sign_up_fixture()
      place = handover_place_fixture(scope)
      handed = handed_over_fixture(scope, place.key)
      Map.merge(handed, %{scope: scope, key: place.key, pool: place.pool})
    end

    test "has its dispatch, its queue row, its variables by name and its machine log",
         %{schema: schema, scope: scope, run: run, dispatch: dispatch} = ctx do
      run =
        run
        |> Ecto.Changeset.change(
          registration_variables: %{"API_TOKEN" => @secret, "LEVEL" => "1"}
        )
        |> Repo.update!()

      :ok =
        Dispatches.upload_machine_log(ctx.key, dispatch.public_id, %{
          log: "booted with #{@code}\n",
          truncated: false
        })

      json = Diagnostics.encode(run, scope)
      document = valid!(schema, Jason.decode!(json))

      assert document["run"]["variables"] == ["API_TOKEN", "LEVEL"]
      assert document["run"]["step"] == ctx.dispatch_run.step
      assert document["run"]["work_item"] =~ ~r/\Awi_/
      assert document["run"]["gateway"] =~ ~r/\Ang_/
      assert document["queue"] == %{"state" => "handed_over"}

      assert [
               %{
                 "id" => id,
                 "pool" => pool,
                 "claimed_at" => _,
                 "lease_until" => _,
                 "dispatched_at" => _,
                 "handed_over_at" => _
               }
             ] = document["dispatches"]

      assert id == dispatch.public_id and pool == ctx.pool.public_id

      assert [%{"dispatch" => ^id, "truncated" => false, "text" => "booted with [FILTERED]\n"}] =
               document["machine_logs"]

      refute json =~ "AQIDBAUG"

      run_fields = Map.keys(document["run"])

      for redacted <- ~w(run_key run_key_payload run_code_sha256 registry_credential_sha256
                         provider_secret_id provider_value_id provider_api) do
        refute redacted in run_fields
      end
    end

    test "has no machine log for a member, who is no instance admin",
         %{schema: schema, scope: scope, run: run} do
      %{scope: member} = join_fixture(scope, user_fixture())
      refute Apiary.Access.instance_admin?(member)

      document = valid!(schema, Jason.decode!(Diagnostics.encode(run, member)))
      refute Map.has_key?(document, "machine_logs")
      assert Map.has_key?(document, "log")
    end

    test "a run whose start failed has the dispatch it keeps, with the release reason filtered",
         %{schema: schema, run: run, dispatch: dispatch} do
      {1, _} =
        Repo.update_all(from(d in Apiary.Dispatches.Dispatch, where: d.id == ^dispatch.id),
          set: [release_reason: "Quota key #{@secret} refused"]
        )

      run =
        run
        |> Ecto.Changeset.change(
          dispatch_run_id: nil,
          dispatch_id: dispatch.id,
          state: "failed",
          reason: "machine_not_made",
          start_failure: "machine_not_made",
          start_failed_at: now()
        )
        |> Repo.update!()

      document = valid!(schema, Diagnostics.document(run, everything()))

      assert [%{"id" => id, "release_reason" => "Quota key [FILTERED] refused"}] =
               document["dispatches"]

      assert id == dispatch.public_id
      refute Map.has_key?(document, "queue")
    end

    test "has no dispatch claimed after the run was registered",
         %{schema: schema, run: run, dispatch: dispatch} do
      earlier = DateTime.add(dispatch.claimed_at, -60, :second)

      {1, _} =
        Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [inserted_at: earlier])

      run = Repo.get!(Run, run.id)

      document = valid!(schema, Diagnostics.document(run, everything()))
      assert document["dispatches"] == []
    end
  end

  defp now, do: DateTime.utc_now()
end
