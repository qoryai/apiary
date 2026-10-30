defmodule Apiary.Runs.DiagnosticsTest do
  # The run diagnostics document (`Apiary.Runs.Diagnostics`): every document it builds is
  # valid under the vendored contract (`priv/contract/diagnostics/v1/`), whose fixtures
  # are checked first; what each reader reads; every text as stored, a secret too, and the
  # secrets listed; the events' and the log's bounds; the size cap; and a run whose events
  # or log the retention removed. Not async: a test of an instance admin hides the
  # instance's organisation, a row every test shares.
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
  @github "ghp_" <> String.duplicate("c", 36)

  setup_all do
    %{schema: DiagnosticsSchema.root()}
  end

  defp valid!(schema, document) do
    decoded = document |> Jason.encode!() |> Jason.decode!()
    assert DiagnosticsSchema.validate(schema, decoded) == :ok
    decoded
  end

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
      assert length(valid) == 4 and length(invalid) == 16

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
      document = valid!(schema, Diagnostics.document(run, :instance, now: now))

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

    test "leaves out the machine logs for a person who is no instance admin",
         %{schema: schema, scope: scope, run: run} do
      %{scope: member} = join_fixture(scope, user_fixture())
      refute Apiary.Access.instance_admin?(member)

      document = valid!(schema, Diagnostics.document(run, member))
      refute Map.has_key?(document, "machine_logs")
      assert Map.has_key?(document, "log") and Map.has_key?(document, "events")
    end

    test "reads a person's events as the edition narrows them, and a key's as the instance's",
         %{schema: schema, scope: scope, run: run} do
      events_fixture(run, [
        {1, "run.started", %{"token" => @github}},
        {2, "run.exited", %{"exit_code" => 0}}
      ])

      {:ok, run} = Apiary.Runs.Projector.project(run)
      :ok = Apiary.Edition.put_test_stub(__MODULE__.NarrowsPeople)

      person = valid!(schema, Diagnostics.document(run, scope))
      assert person["events"] == [] and person["events_omitted"] == 0
      # The secret is listed, without the value of an event the person does not read.
      assert [%{"place" => "event", "sequence" => 1} = leaked] = person["leaked_secrets"]
      refute Map.has_key?(leaked, "value")

      key = valid!(schema, Diagnostics.document(run, :instance))
      assert [%{"sequence" => 1}, %{"sequence" => 2}] = key["events"]
      assert key["events_omitted"] == 0
      assert [%{"place" => "event", "value" => @github}] = key["leaked_secrets"]
    end

    test "leaves out the log events, whose output is in the log, and counts none of them",
         %{schema: schema, run: run} do
      events_fixture(run, [
        {1, "run.log", %{"stream" => "terminal", "bytes" => Base.encode64("key #{@secret}\n")}},
        {2, "run.started", %{}},
        {3, "run.log", %{"stream" => "terminal", "bytes" => Base.encode64("again #{@secret}\n")}}
      ])

      chunk!(run, 1, "key #{@secret}\n")
      json = Jason.encode!(Diagnostics.document(run, :instance))
      document = valid!(schema, Jason.decode!(json))

      assert [%{"sequence" => 2}] = document["events"]
      assert document["events_omitted"] == 0
      refute json =~ binary_part(Base.encode64("key #{@secret}\n"), 4, 12)
      assert document["log"]["text"] == "key #{@secret}\n"
    end

    test "keeps every text as stored, a secret too, and replaces U+0000 and bytes outside UTF-8",
         %{schema: schema, run: run} do
      events_fixture(run, [
        {1, "run.started", %{"note" => "key #{@secret}", @run_key => [%{"code" => @code}, 1]}}
      ])

      chunk!(run, 2, "token #{@run_key} and #{@code}\n")
      chunk!(run, 3, <<"nul ", 0, " and ", 0xFF, " end">>)

      json = Diagnostics.document(run, :instance) |> Jason.encode!()
      document = valid!(schema, Diagnostics.document(run, :instance))

      for secret <- [@secret, @run_key, @code], do: assert(json =~ secret)

      assert [%{"data" => data}] = document["events"]
      assert data == %{"note" => "key #{@secret}", @run_key => [%{"code" => @code}, 1]}

      assert document["log"]["text"] ==
               "token #{@run_key} and #{@code}\nnul \u{FFFD} and \u{FFFD} end"
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

      document = valid!(schema, Diagnostics.document(run, :instance))
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
        valid!(schema, Diagnostics.document(run, :instance))

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

      document = Diagnostics.document(run, :instance)
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

      document = Diagnostics.document(run, :instance, max_bytes: 200_000)
      assert byte_size(Jason.encode!(document)) <= 200_000
      document = valid!(schema, document)

      assert document["log"]["truncated"] == true
      assert document["events"] == [] and document["events_omitted"] == 0
    end

    test "leaves out what the retention removed", %{schema: schema, run: run} do
      events_fixture(run, [{1, "run.heartbeat", %{}}])
      chunk!(run, 2, "line\n")

      log_pruned = run |> Ecto.Changeset.change(log_pruned_at: now()) |> Repo.update!()
      document = valid!(schema, Diagnostics.document(log_pruned, :instance))
      refute Map.has_key?(document, "log")
      assert [_event] = document["events"]

      pruned =
        log_pruned |> Ecto.Changeset.change(events_pruned_at: now()) |> Repo.update!()

      document = valid!(schema, Diagnostics.document(pruned, :instance))
      refute Map.has_key?(document, "log")
      refute Map.has_key?(document, "events")
      refute Map.has_key?(document, "events_omitted")
    end
  end

  defmodule NarrowsPeople do
    @moduledoc false
    # A person reads no event of a run; the instance reads every one
    # (`c:Apiary.Edition.client_reads/4`).
    import Ecto.Query, only: [where: 2]

    def client_reads(%Apiary.Accounts.Scope{user: %{}}, :run_events, _run, query),
      do: where(query, false)

    def client_reads(_scope, _kind, _run, subject), do: subject
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

    test "has the steps with their output as stored, and why it stopped",
         %{schema: schema, run: run} do
      document = valid!(schema, Diagnostics.document(run, :instance))

      assert %{
               "steps" => [
                 %{
                   "number" => 1,
                   "name" => "Fetch acme/shop",
                   "kind" => "fetch",
                   "state" => "succeeded",
                   "exit_code" => 0,
                   "duration_ms" => 100,
                   "output" => %{"text" => "Cloning with #{@secret}", "truncated" => false}
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
      Map.merge(handed, %{scope: scope, key: place.key, seed: place.seed, pool: place.pool})
    end

    test "lists the secrets the run and its machine log printed, the machine log's for the instance alone",
         %{schema: schema, scope: scope, run: run, dispatch: dispatch} = ctx do
      secret = "qak_" <> Base.url_encode64(ctx.seed, padding: false)

      events_fixture(run, [
        {1, "run.step_started", %{"step" => 1, "name" => "fetch acme/shop", "kind" => "fetch"}},
        {2, "run.log", step_log_data(1, "key #{secret}\n")},
        {3, "run.started", %{"note" => @github}}
      ])

      {:ok, run} = Apiary.Runs.Projector.project(run)

      :ok =
        Dispatches.upload_machine_log(ctx.key, dispatch.public_id, %{
          log: "booted with #{secret}\n",
          truncated: false
        })

      document = valid!(schema, Diagnostics.document(run, :instance))
      key_id = ctx.key.key_id
      dispatch_id = dispatch.public_id

      assert [
               %{
                 "kind" => "access_key",
                 "place" => "step",
                 "step" => 1,
                 "id" => ^key_id,
                 "value" => ^secret,
                 "message" =>
                   "This secret is compromised: it was printed into the run's log. Replace it."
               },
               %{"kind" => "github_token", "place" => "event", "sequence" => 3} = event,
               %{
                 "kind" => "access_key",
                 "place" => "machine_log",
                 "dispatch" => ^dispatch_id,
                 "id" => ^key_id,
                 "value" => ^secret,
                 "message" =>
                   "This secret is compromised: it was printed into the machine log. Replace it."
               } = machine_log
             ] = document["leaked_secrets"]

      refute Map.has_key?(event, "id")
      assert event["value"] == @github
      assert document["leaked_secrets_omitted"] == 0
      refute Map.has_key?(machine_log, "step") or Map.has_key?(machine_log, "sequence")

      # Every text is the stored text, the secret in it.
      assert [%{"output" => %{"text" => "key " <> ^secret}} | _] =
               document["preparation"]["steps"]

      assert [%{"text" => "booted with " <> _}] = document["machine_logs"]

      # A member reads no machine log, and the secret in it is neither listed nor counted.
      %{scope: member} = join_fixture(scope, user_fixture())
      document = valid!(schema, Jason.decode!(Diagnostics.encode(run, member)))
      refute Map.has_key?(document, "machine_logs")
      assert ["step", "event"] = Enum.map(document["leaked_secrets"], & &1["place"])
      assert document["leaked_secrets_omitted"] == 0
    end

    test "keeps a machine log's secrets for an instance admin once the retention deleted it, without their value",
         %{schema: schema, scope: scope, run: run, dispatch: dispatch} = ctx do
      :ok =
        Dispatches.upload_machine_log(ctx.key, dispatch.public_id, %{
          log: "token #{@github}\n",
          truncated: false
        })

      {1, _} =
        Repo.delete_all(
          from l in Apiary.Dispatches.MachineLog, where: l.dispatch_id == ^dispatch.id
        )

      assert Apiary.Access.instance_admin?(scope)
      document = valid!(schema, Jason.decode!(Diagnostics.encode(run, scope)))
      assert document["machine_logs"] == []
      dispatch_id = dispatch.public_id

      assert [%{"place" => "machine_log", "dispatch" => ^dispatch_id} = leaked] =
               document["leaked_secrets"]

      refute Map.has_key?(leaked, "value")
    end

    test "lists a secret in the release reason of a run whose start failed",
         %{schema: schema, scope: scope} = ctx do
      work_item = Apiary.WorkItemsFixtures.work_item_fixture(scope)
      {:ok, _queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
      {:ok, %{dispatch: dispatch}} = Dispatches.claim(ctx.key, Dispatches.now())

      assert :ok =
               Dispatches.release(ctx.key, dispatch.public_id, %{
                 reason: "Quota token #{@github} refused"
               })

      run = Repo.one!(from r in Run, where: r.dispatch_id == ^dispatch.id)
      document = valid!(schema, Diagnostics.document(run, :instance))
      dispatch_id = dispatch.public_id

      assert [
               %{
                 "kind" => "github_token",
                 "place" => "release_reason",
                 "dispatch" => ^dispatch_id,
                 "value" => @github,
                 "message" => message
               } = leaked
             ] = document["leaked_secrets"]

      refute Map.has_key?(leaked, "id")
      assert message =~ "This secret is compromised"
    end

    test "has its dispatch, its queue row, its variables by name and its machine log",
         %{schema: schema, scope: scope, run: run, dispatch: dispatch} = ctx do
      run =
        run
        |> Ecto.Changeset.change(
          registration_variables: %{"API_TOKEN" => "variable-value-7f3a", "LEVEL" => "1"}
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

      assert [%{"dispatch" => ^id, "truncated" => false, "text" => "booted with #{@code}\n"}] =
               document["machine_logs"]

      refute json =~ "variable-value-7f3a"

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

    test "a run whose start failed has the dispatch it keeps, with the release reason",
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

      document = valid!(schema, Diagnostics.document(run, :instance))

      assert [%{"id" => id, "release_reason" => "Quota key #{@secret} refused"}] =
               document["dispatches"]

      assert id == dispatch.public_id
      refute Map.has_key?(document, "queue")

      # Why the preparation stopped, as the run page's Prepare machine section says it.
      assert %{"cause" => "machine_not_made", "text" => text} =
               document["preparation"]["stopped"]

      assert text =~ "No machine was made: Quota key #{@secret} refused."
      refute Map.has_key?(document["preparation"]["stopped"], "step")
    end

    test "has no dispatch claimed after the run was registered",
         %{schema: schema, run: run, dispatch: dispatch} do
      earlier = DateTime.add(dispatch.claimed_at, -60, :second)

      {1, _} =
        Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [inserted_at: earlier])

      run = Repo.get!(Run, run.id)

      document = valid!(schema, Diagnostics.document(run, :instance))
      assert document["dispatches"] == []
    end
  end

  defp now, do: DateTime.utc_now()
end
