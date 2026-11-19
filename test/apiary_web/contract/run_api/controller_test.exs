defmodule ApiaryWeb.Contract.RunApi.ControllerTest do
  # The run API (`/v1/runs/<run_id>/...`): a run's reads of its work item and its
  # artifacts and its pushes, through its gateway, against the stage runner
  # (`Apiary.Stages`) and `Apiary.Artifacts`, with its files in a store in a folder of the
  # test, and the stubs of the declarations and the feature, and a record of each push
  # (`ApiaryWeb.RunApiStubs`). The stubs and the features are the whole node's, so the
  # module is not async.
  #
  # A POST is sent with its raw body already kept, as `ApiaryWeb.Contract.RawBody` keeps
  # the body of the run endpoint's POSTs, but in "through the whole endpoint", where
  # `ApiaryWeb.Contract.RawBody` reads it.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.SealedRunsFixtures

  alias Apiary.Repo
  alias Apiary.Artifacts.ArtifactFile
  alias Apiary.Dispatches.{DispatchRun, Inputs}
  alias Apiary.Runs.Run
  alias Apiary.Stages.{Check, GateDecision}
  alias Apiary.WorkItems.WorkItem
  alias Apiary.SigningKey
  alias ApiaryWeb.Contract.{RawBody, SignedAnswer}
  alias ApiaryWeb.Contract.RunApi.Body
  alias ApiaryWeb.RunApiStubs

  @moduletag needs: [:workflow_model, :factory, :secrets]
  @moduletag :tmp_dir

  # Explore, the first stage of the software process (`Apiary.Processes`).
  @explore "st_r79kph11eg"

  # What the format check takes as a PNG, and as an SVG (`Apiary.Artifacts.Format`).
  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR">>
  @svg ~s(<svg xmlns="http://www.w3.org/2000/svg"/>)

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

    work_item =
      Apiary.WorkItems.WorkItem
      |> Repo.get!(dispatch_run.work_item_id)
      |> Repo.preload(:workspace)

    %{
      scope: scope,
      run: fixture.run,
      key: fixture.secrets_key,
      dispatch_run: dispatch_run,
      work_item: work_item,
      work_item_workspace: work_item.workspace
    }
  end

  defp other_run do
    %{scope: scope} = sign_up_fixture()
    fixture = sealed_run_fixture(scope)
    dispatch_run = Repo.get!(DispatchRun, fixture.run.dispatch_run_id)

    %{
      run: fixture.run,
      key: fixture.secrets_key,
      dispatch_run: dispatch_run,
      work_item: Repo.get!(WorkItem, dispatch_run.work_item_id)
    }
  end

  # A version stored for `ctx`'s work item by its run, outside the run API.
  defp store!(ctx, type, files, opts \\ []) do
    {:ok, version} =
      Apiary.Artifacts.push({:run, ctx.dispatch_run}, ctx.work_item, type, files, opts)

    version
  end

  # A custom type of the workspace: `base_view` `file`, which takes any bytes.
  defp file_type!(ctx, name, size_limit, max_files) do
    {:ok, type} =
      Apiary.Artifacts.create_type(ctx.scope, ctx.work_item_workspace, %{
        "name" => name,
        "base_view" => "file",
        "size_limit" => size_limit,
        "max_files" => max_files
      })

    type
  end

  defp read(ctx, path, opts \\ []) do
    {key, seed} = Keyword.get(opts, :key, ctx.key)
    run_id = Keyword.get(opts, :run_id, ctx.run.node_run_id)
    target = "/v1/runs/#{run_id}" <> path
    signed_get(build_conn(), key.key_id, Keyword.get(opts, :seed, seed), target)
  end

  defp write(ctx, path, body, opts \\ []) do
    {key, seed} = Keyword.get(opts, :key, ctx.key)
    body = if is_binary(body), do: body, else: Jason.encode!(body)
    target = "/v1/runs/#{Keyword.get(opts, :run_id, ctx.run.node_run_id)}" <> path

    build_conn()
    |> Plug.Conn.assign(:raw_body, body)
    |> signed_post(key.key_id, seed, body,
      target: target,
      content_type: "application/json",
      delivery: nil
    )
  end

  defp push_body(type, files, extra \\ %{}) do
    Map.merge(
      %{
        "type" => type,
        "files" =>
          for {filename, content_type, content} <- files do
            %{
              "filename" => filename,
              "content_type" => content_type,
              "content_base64" => Base.encode64(content)
            }
          end
      },
      extra
    )
  end

  # The work item placed in Explore, its first round running, as the stage runner places
  # it.
  defp place!(ctx) do
    {1, _rows} =
      Repo.update_all(from(w in WorkItem, where: w.id == ^ctx.work_item.id),
        set: [stage_id: @explore, stage_state: :running, stage_round: 1, stage_entry: 0]
      )
  end

  defp decide!(ctx, kind, fields) do
    work_item = Repo.get!(WorkItem, ctx.work_item.id)

    Repo.insert!(
      struct!(
        GateDecision,
        [
          organisation_id: work_item.organisation_id,
          workspace_id: work_item.workspace_id,
          work_item_id: work_item.id,
          process_version_id: Apiary.Processes.version_for(work_item).id,
          user_id: ctx.scope.user.id,
          stage_id: @explore,
          kind: kind,
          inserted_at: DateTime.utc_now()
        ] ++ fields
      )
    )
  end

  defp at(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  # The features the run kept when it was claimed (`Apiary.Runs.Run`, `features`).
  defp keep_features!(ctx, recorded) do
    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id), set: [features: recorded])
  end

  defp end_run!(ctx) do
    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id),
        set: [state: "completed", exited_at: DateTime.utc_now()]
      )
  end

  # The run, attached, as the lost-run check leaves it 300 seconds after its loss, its
  # backstop ahead, with whatever else `changes` sets.
  defp lost!(ctx, changes) do
    now = DateTime.utc_now()

    # Each call starts again from a lost run with no end, whatever an earlier call set.
    set = [
      state: "lost",
      lost_at: DateTime.add(now, -300, :second),
      backstop_at: DateTime.add(now, 3600, :second),
      silenced_at: nil,
      exited_at: nil,
      exit_state: nil,
      events_pruned_at: nil
    ]

    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id),
        set: Keyword.merge(set, changes)
      )
  end

  # The run lost for good: the lost-run check ended it for its silence a minute ago.
  defp silenced!(ctx), do: lost!(ctx, silenced_at: DateTime.add(DateTime.utc_now(), -60, :second))

  describe "the feature" do
    test "off: a verified request is the 404 of a path the router does not know, signed", ctx do
      RunApiStubs.put(:flag, false)
      keep_features!(ctx, Apiary.Features.recorded() -- ["workflow_model"])

      for conn <- [
            read(ctx, "/work-item"),
            read(ctx, "/artifacts"),
            write(ctx, "/verdict", %{"verdict" => "passed"})
          ] do
        assert conn.status == 404
        assert ["text/html" <> _] = get_resp_header(conn, "content-type")
        assert signed_answer?(conn)
      end

      assert RunApiStubs.pushed() == []
    end

    test "off for the instance, on for a run that kept it at its claim: the run is served",
         ctx do
      RunApiStubs.put(:flag, false)
      keep_features!(ctx, Enum.uniq(Apiary.Features.recorded() ++ ["workflow_model"]))

      assert read(ctx, "/work-item").status == 200
    end

    test "off for the instance, kept by a run that has ended: a verified request is the 404",
         ctx do
      RunApiStubs.put(:flag, false)
      keep_features!(ctx, Enum.uniq(Apiary.Features.recorded() ++ ["workflow_model"]))
      end_run!(ctx)

      for conn <- [read(ctx, "/work-item"), read(ctx, "/artifacts")] do
        assert conn.status == 404
        assert signed_answer?(conn)
      end
    end

    test "on for the instance, off for a run claimed without it: a verified request is the 404",
         ctx do
      keep_features!(ctx, Apiary.Features.recorded() -- ["workflow_model"])

      conn = read(ctx, "/work-item")
      assert conn.status == 404
      assert ["text/html" <> _] = get_resp_header(conn, "content-type")
      assert signed_answer?(conn)
    end

    test "the routes belong to workflow_model" do
      assert ApiaryWeb.Contract.RunApi.Controller.__feature__() == :workflow_model
    end
  end

  describe "authentication" do
    test "an unsigned request is 401, unsigned", ctx do
      conn = get(build_conn(), "/v1/runs/#{ctx.run.node_run_id}/work-item")
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
      assert get_resp_header(conn, "x-qory-signature-ed25519") == []
    end

    test "a request signed with the wrong key is 401, unsigned", ctx do
      conn = read(ctx, "/work-item", seed: :crypto.strong_rand_bytes(32))
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
      assert get_resp_header(conn, "x-qory-signature-ed25519") == []

      body = Jason.encode!(%{"verdict" => "passed"})

      conn =
        build_conn()
        |> Plug.Conn.assign(:raw_body, body)
        |> signed_post(elem(ctx.key, 0).key_id, :crypto.strong_rand_bytes(32), body,
          target: "/v1/runs/#{ctx.run.node_run_id}/verdict",
          content_type: "application/json",
          delivery: nil
        )

      assert json_response(conn, 401) == %{"error" => "unauthorized"}
      assert RunApiStubs.pushed() == []
    end

    test "another run's key, another run and an unknown run are the same 404", ctx do
      other = other_run()

      answers =
        for conn <- [
              read(ctx, "/work-item", key: other.key),
              read(ctx, "/work-item", run_id: other.run.node_run_id),
              read(ctx, "/work-item", run_id: Ecto.UUID.generate()),
              read(ctx, "/work-item", run_id: "not-a-run"),
              read(ctx, "/artifacts", key: other.key),
              write(ctx, "/verdict", %{"verdict" => "passed"}, key: other.key),
              write(ctx, "/artifacts", push_body("explainer", [{"a.md", "text/markdown", "x"}]),
                run_id: other.run.node_run_id
              )
            ] do
          assert signed_answer?(conn)
          {conn.status, conn.resp_body}
        end

      assert Enum.uniq(answers) == [{404, ~s({"error":"not_found"})}]
      assert RunApiStubs.pushed() == []
    end
  end

  describe "GET work-item" do
    test "is signed over its body, as every answer but a file's", ctx do
      conn = read(ctx, "/work-item")
      [request_signature] = get_req_header(conn, "x-qory-signature-ed25519")
      refute Map.has_key?(conn.private, :qory_body_sha256)

      {_cache, expected} =
        SignedAnswer.headers(
          200,
          request_signature,
          conn.resp_body,
          List.first(get_resp_header(conn, "x-qory-configuration")),
          List.first(get_resp_header(conn, "x-qory-run-configuration")),
          SigningKey.current()
        )

      assert get_resp_header(conn, "x-qory-signature-ed25519") == [expected]
    end

    test "is the work item's snapshot: ticket, stage, outputs and verdict", ctx do
      place!(ctx)
      conn = read(ctx, "/work-item")
      assert signed_answer?(conn)
      body = json_response(conn, 200)

      assert body["version"] == 1
      assert body["work_item"]["id"] == ctx.work_item.public_id
      # The take in placed the work item in Explore and started its first round.
      assert body["run"] == %{
               "id" => ctx.run.node_run_id,
               "number" => ctx.run.number,
               "workflow" => "explore-a-ticket",
               "round" => 1
             }

      assert is_integer(ctx.run.number)

      ordered = Jason.decode!(conn.resp_body, objects: :ordered_objects)
      assert Enum.map(ordered["run"].values, &elem(&1, 0)) == ~w(id number workflow round)

      assert body["ticket"]["title"] == ctx.work_item.title
      assert is_list(body["comments"])
      assert body["comments_omitted"] == 0
      refute Map.has_key?(body, "answers")

      assert body["stage"] == %{
               "id" => @explore,
               "name" => "Explore",
               "round" => 1,
               "rounds" => nil,
               "state" => "running"
             }

      assert body["inputs"] == []

      assert body["outputs"] == [
               %{"type" => "proposal", "required" => true, "version" => nil, "check" => "missing"}
             ]

      assert body["verdict"] == nil
      assert body["gaps"] == nil
      assert body["notes"] == []
      refute Map.has_key?(body, "domain")
    end

    test "lists, after a move back, a version of the stage left, marked from move", ctx do
      shape = "st_p9w5cvh311"
      build = "st_6ns22c4pav"
      people = %{"inputs" => [], "sequence" => [], "outputs" => []}
      gate = %{"kind" => "person", "approvers" => "members"}

      stages = [
        Map.merge(people, %{"id" => @explore, "name" => "Explore", "gate" => gate}),
        Map.merge(people, %{
          "id" => shape,
          "name" => "Shape",
          "gate" => gate,
          "inputs" => [%{"type" => "proposal", "required" => true}]
        }),
        Map.merge(people, %{
          "id" => build,
          "name" => "Build",
          "gate" => gate,
          "outputs" => [%{"type" => "screenshot", "required" => false}]
        })
      ]

      document = %{"schema" => "qory.process/v1", "machine" => "default", "stages" => stages}
      {:ok, version} = Apiary.Processes.save(ctx.scope, ctx.work_item_workspace, document)
      version = Repo.get!(Apiary.Processes.Version, version.id)

      screenshot =
        store!(ctx, "screenshot", [file("one.png", "image/png", @png)], stage_id: build)

      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^ctx.work_item.id),
          set: [
            process_version_id: version.id,
            stage_id: shape,
            stage_state: :at_gate,
            stage_round: 0,
            stage_entry: 0,
            stage_entered_at: DateTime.utc_now()
          ]
        )

      work_item = Repo.get!(WorkItem, ctx.work_item.id)

      assert [] =
               json_response(read(ctx, "/work-item"), 200)["inputs"] |> Enum.filter(& &1["from"])

      decide!(ctx, :move,
        stage_id: build,
        to_stage_id: shape,
        take_in: work_item.take_in,
        left_stage_entered_at: DateTime.add(DateTime.utc_now(), -60, :second),
        inserted_at: DateTime.add(DateTime.utc_now(), 60, :second)
      )

      conn = read(ctx, "/work-item")
      body = json_response(conn, 200)

      assert body["inputs"] == [
               %{"type" => "proposal", "required" => true, "version" => nil},
               %{
                 "type" => "screenshot",
                 "required" => false,
                 "version" => %{"id" => screenshot.public_id, "number" => 1},
                 "from" => "move"
               }
             ]

      ordered = Jason.decode!(conn.resp_body, objects: :ordered_objects)
      [_unmarked, marked] = ordered["inputs"]
      assert Enum.map(marked.values, &elem(&1, 0)) == ~w(type required version from)
    end

    test "lists, after a return, Verify's newest verdict and verification, marked from return",
         ctx do
      build = "st_6ns22c4pav"
      verify = "st_m1mqbeywdg"
      people = %{"inputs" => [], "sequence" => [], "outputs" => []}
      gate = %{"kind" => "person", "approvers" => "members"}

      {:ok, _type} =
        Apiary.Artifacts.create_type(ctx.scope, ctx.work_item_workspace, %{
          "name" => "verification",
          "base_view" => "document"
        })

      stages = [
        Map.merge(people, %{"id" => @explore, "name" => "Explore", "gate" => gate}),
        Map.merge(people, %{"id" => build, "name" => "Build", "gate" => gate}),
        Map.merge(people, %{"id" => verify, "name" => "Verify", "gate" => gate})
      ]

      document = %{"schema" => "qory.process/v1", "machine" => "default", "stages" => stages}
      {:ok, version} = Apiary.Processes.save(ctx.scope, ctx.work_item_workspace, document)

      verification =
        store!(ctx, "verification", [file("v.md", "text/markdown", "# Criterion 2 fails")],
          stage_id: verify
        )

      {:ok, verdict} =
        Apiary.Stages.Artifacts.push_json(
          {:run, ctx.dispatch_run},
          ctx.work_item,
          "verdict",
          %{"verdict" => "changes-requested"},
          stage_id: verify
        )

      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^ctx.work_item.id),
          set: [
            process_version_id: version.id,
            stage_id: build,
            stage_state: :running,
            stage_round: 1,
            stage_entry: 0,
            stage_entered_at: DateTime.utc_now()
          ]
        )

      # The run of Verify that ended and returned the work item to Build.
      {1, _rows} =
        Repo.update_all(from(d in DispatchRun, where: d.id == ^ctx.dispatch_run.id),
          set: [stage_id: verify, returned_to: build, returned_at: DateTime.utc_now()]
        )

      conn = read(ctx, "/work-item")
      body = json_response(conn, 200)

      assert body["inputs"] == [
               %{
                 "type" => "verdict",
                 "required" => false,
                 "version" => %{"id" => verdict.public_id, "number" => 1},
                 "from" => "return"
               },
               %{
                 "type" => "verification",
                 "required" => false,
                 "version" => %{"id" => verification.public_id, "number" => 1},
                 "from" => "return"
               }
             ]

      ordered = Jason.decode!(conn.resp_body, objects: :ordered_objects)
      [marked, _verification] = ordered["inputs"]
      assert Enum.map(marked.values, &elem(&1, 0)) == ~w(type required version from)
      assert body["notes"] == []
    end

    test "leaves out the move that resolved an escalation, and lists the escalation", ctx do
      place!(ctx)
      work_item = Repo.get!(WorkItem, ctx.work_item.id)
      now = DateTime.utc_now()

      escalation =
        Repo.insert!(%Apiary.Stages.Escalation{
          organisation_id: work_item.organisation_id,
          workspace_id: work_item.workspace_id,
          work_item_id: work_item.id,
          process_version_id: Apiary.Processes.version_for(work_item).id,
          stage_id: @explore,
          round: 1,
          cause: :run_stopped,
          points: [],
          resolution: :move_back,
          note: "Start again.",
          resolved_by_id: ctx.scope.user.id,
          resolved_at: now,
          inserted_at: now
        })

      decide!(ctx, :move, escalation_id: escalation.id, to_stage_id: @explore)
      decide!(ctx, :move, note: "Back to Explore.")

      assert [%{"kind" => "escalation", "note" => "Start again."}, %{"kind" => "move"} = move] =
               json_response(read(ctx, "/work-item"), 200)["notes"]

      assert move["note"] == "Back to Explore."
    end

    test "lists, after a switch of track, the escalation in the notes and not the switch", ctx do
      shape = "st_p9w5cvh311"
      build = "st_6ns22c4pav"
      people = %{"inputs" => [], "sequence" => [], "outputs" => []}
      gate = %{"kind" => "person", "approvers" => "members"}

      stages = [
        Map.merge(people, %{
          "id" => @explore,
          "name" => "Explore",
          "gate" => Map.put(gate, "tracks", ["standard", "fast"])
        }),
        Map.merge(people, %{
          "id" => shape,
          "name" => "Shape",
          "gate" => gate,
          "when" => %{"track" => "standard"}
        }),
        Map.merge(people, %{"id" => build, "name" => "Build", "gate" => gate})
      ]

      document = %{
        "schema" => "qory.process/v1",
        "machine" => "default",
        "tracks" => [
          %{"id" => "standard", "name" => "Standard"},
          %{"id" => "fast", "name" => "Fast track"}
        ],
        "stages" => stages
      }

      {:ok, version} = Apiary.Processes.save(ctx.scope, ctx.work_item_workspace, document)
      version = Repo.get!(Apiary.Processes.Version, version.id)

      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^ctx.work_item.id),
          set: [
            process_version_id: version.id,
            stage_id: build,
            stage_state: :escalated,
            stage_round: 1,
            stage_entry: 0,
            stage_entered_at: DateTime.utc_now()
          ]
        )

      work_item = Repo.get!(WorkItem, ctx.work_item.id)
      decide!(ctx, :approve, track: "fast", take_in: work_item.take_in)
      now = DateTime.utc_now()

      Repo.insert!(%Apiary.Stages.Escalation{
        organisation_id: work_item.organisation_id,
        workspace_id: work_item.workspace_id,
        work_item_id: work_item.id,
        process_version_id: version.id,
        stage_id: build,
        round: 1,
        cause: :escalate,
        points: [%{"text" => "The change alters what the product does.", "action" => "run_again"}],
        inserted_at: now
      })

      assert {:ok, %WorkItem{stage_id: ^shape}} =
               Apiary.Stages.resolve_escalation(
                 ctx.scope,
                 work_item,
                 {:switch, "standard"},
                 "Write a spec first.",
                 expect_stage: build
               )

      assert [%{"kind" => "escalation", "note" => "Write a spec first."}] =
               json_response(read(ctx, "/work-item"), 200)["notes"]
    end

    test "a work item the stage runner has not placed has the run's stage id alone", ctx do
      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^ctx.work_item.id),
          set: [stage_id: nil, stage_state: nil, stage_round: nil, stage_entry: nil]
        )

      body = json_response(read(ctx, "/work-item"), 200)

      assert body["stage"] == %{
               "id" => @explore,
               "name" => nil,
               "round" => nil,
               "rounds" => nil,
               "state" => nil
             }

      assert body["inputs"] == []
      assert body["outputs"] == []
    end

    test "has the notes, oldest first, each person by name, a failed check by none", ctx do
      place!(ctx)

      version =
        store!(ctx, "screenshot", [file("one.png", "image/png", @png)], stage_id: @explore)

      first =
        decide!(ctx, :request_changes,
          note: "Add the empty cart.",
          artifact_version_id: version.public_id
        )

      second = decide!(ctx, :move, note: "Back to Explore.")
      work_item = Repo.get!(WorkItem, ctx.work_item.id)

      check =
        Repo.insert!(%Check{
          organisation_id: work_item.organisation_id,
          workspace_id: work_item.workspace_id,
          work_item_id: work_item.id,
          process_version_id: Apiary.Processes.version_for(work_item).id,
          stage_id: @explore,
          round: 2,
          gaps: "proposal: no version of this stage.",
          inserted_at: DateTime.utc_now()
        })

      body = json_response(read(ctx, "/work-item"), 200)
      name = Inputs.person_name(ctx.scope.user.id)

      assert body["notes"] == [
               %{
                 "id" => first.public_id,
                 "kind" => "request_changes",
                 "stage_id" => @explore,
                 "by" => %{"name" => name},
                 "note" => "Add the empty cart.",
                 "artifact_version_id" => version.public_id,
                 "at" => at(first.inserted_at)
               },
               %{
                 "id" => second.public_id,
                 "kind" => "move",
                 "stage_id" => @explore,
                 "by" => %{"name" => name},
                 "note" => "Back to Explore.",
                 "artifact_version_id" => nil,
                 "at" => at(second.inserted_at)
               },
               %{
                 "id" => nil,
                 "kind" => "check",
                 "stage_id" => @explore,
                 "by" => nil,
                 "note" => "proposal: no version of this stage.",
                 "artifact_version_id" => nil,
                 "at" => at(check.inserted_at)
               }
             ]
    end

    test "has only the open notes: a later approval of the stage closes them", ctx do
      place!(ctx)
      shape = "st_p9w5cvh311"
      time = fn seconds -> DateTime.add(DateTime.utc_now(), seconds - 60, :second) end

      # Explore's request and failed check, then Explore's approval.
      decide!(ctx, :request_changes, note: "Add the empty cart.", inserted_at: time.(1))
      work_item = Repo.get!(WorkItem, ctx.work_item.id)

      Repo.insert!(%Check{
        organisation_id: work_item.organisation_id,
        workspace_id: work_item.workspace_id,
        work_item_id: work_item.id,
        process_version_id: Apiary.Processes.version_for(work_item).id,
        stage_id: @explore,
        round: 2,
        gaps: "proposal: no version of this stage.",
        inserted_at: time.(1)
      })

      decide!(ctx, :approve, inserted_at: time.(2))
      # A move from Shape back to Explore, which Explore has not passed since.
      move =
        decide!(ctx, :move,
          stage_id: shape,
          to_stage_id: @explore,
          note: "Back to Explore.",
          inserted_at: time.(3)
        )

      # Shape's request, then the automatic approval of Shape's gate none.
      decide!(ctx, :request_changes, stage_id: shape, note: "Split it.", inserted_at: time.(4))

      decide!(ctx, :approve,
        stage_id: shape,
        user_id: nil,
        automatic: true,
        inserted_at: time.(5)
      )

      open = decide!(ctx, :request_changes, note: "Keep the coupon.", inserted_at: time.(6))

      body = json_response(read(ctx, "/work-item"), 200)
      name = Inputs.person_name(ctx.scope.user.id)

      assert body["notes"] == [
               %{
                 "id" => move.public_id,
                 "kind" => "move",
                 "stage_id" => shape,
                 "by" => %{"name" => name},
                 "note" => "Back to Explore.",
                 "artifact_version_id" => nil,
                 "at" => at(move.inserted_at)
               },
               %{
                 "id" => open.public_id,
                 "kind" => "request_changes",
                 "stage_id" => @explore,
                 "by" => %{"name" => name},
                 "note" => "Keep the coupon.",
                 "artifact_version_id" => nil,
                 "at" => at(open.inserted_at)
               }
             ]
    end

    test "keeps a move with no stage it went to open, whatever is approved after it", ctx do
      place!(ctx)
      shape = "st_p9w5cvh311"
      time = fn seconds -> DateTime.add(DateTime.utc_now(), seconds - 60, :second) end

      # A move kept before its stage was: no `to_stage_id`.
      decide!(ctx, :move, stage_id: shape, note: "Back to Explore.", inserted_at: time.(1))
      decide!(ctx, :approve, stage_id: shape, inserted_at: time.(2))
      decide!(ctx, :approve, inserted_at: time.(3))

      body = json_response(read(ctx, "/work-item"), 200)
      assert [%{"kind" => "move", "note" => "Back to Explore."}] = body["notes"]
    end

    test "keeps a note open beside an approval of its stage at the same time", ctx do
      place!(ctx)
      at = DateTime.add(DateTime.utc_now(), -60, :second)

      decide!(ctx, :request_changes, note: "Add the empty cart.", inserted_at: at)
      decide!(ctx, :approve, inserted_at: at)

      body = json_response(read(ctx, "/work-item"), 200)
      assert [%{"kind" => "request_changes", "note" => "Add the empty cart."}] = body["notes"]
    end

    test "the database refuses a stage it went to on a decision that is not a move", ctx do
      place!(ctx)

      assert_raise Ecto.ConstraintError, ~r/gate_decisions_to_stage_check/, fn ->
        decide!(ctx, :approve, to_stage_id: @explore)
      end
    end

    test "has the newest verdict with its points", ctx do
      assert write(ctx, "/verdict", %{"verdict" => "passed"}).status == 201

      body = json_response(read(ctx, "/work-item"), 200)
      [passed] = RunApiStubs.pushed()

      assert body["verdict"] == %{
               "verdict" => "passed",
               "points" => nil,
               "version" => %{"id" => passed.public_id, "number" => 1}
             }

      points = [
        %{"text" => "The ticket has no test steps.", "action" => "run_again"},
        %{
          "text" => "The ledger of the run is full.",
          "action" => "run_again",
          "fix" => "Close the work item, or take the ticket in again."
        }
      ]

      assert write(ctx, "/verdict", %{"verdict" => "escalate", "points" => points}).status == 201

      body = json_response(read(ctx, "/work-item"), 200)
      newest = List.last(RunApiStubs.pushed())

      assert body["verdict"] == %{
               "verdict" => "escalate",
               "points" => points,
               "version" => %{"id" => newest.public_id, "number" => 2}
             }

      # The stage's gaps come from failed checks alone, not from a verdict.
      assert body["gaps"] == nil
    end
  end

  describe "GET artifacts" do
    test "is the work item's index, without the files' contents", ctx do
      assert write(ctx, "/artifacts", push_body("screenshot", [{"one.png", "image/png", @png}])).status ==
               201

      store!(other_run(), "explainer", [file("theirs.md", "text/markdown", "x")])

      conn = read(ctx, "/artifacts")
      assert signed_answer?(conn)
      body = json_response(conn, 200)

      [version] = RunApiStubs.pushed()

      assert body == %{
               "version" => 1,
               "artifacts" => [
                 %{
                   "type" => "screenshot",
                   "name" => "main",
                   "stage_id" => @explore,
                   "approved_version" => nil,
                   "newest_version" => 1,
                   "changed_after_approval" => false,
                   "versions" => [
                     %{
                       "id" => version.public_id,
                       "number" => 1,
                       "writer" => %{"kind" => "run", "run_id" => ctx.dispatch_run.run_id},
                       "cancelled" => false,
                       "withdrawn" => false,
                       "stage_id" => @explore,
                       "note" => nil,
                       "decision" => nil,
                       "decision_at" => nil,
                       "at" =>
                         version.inserted_at
                         |> DateTime.truncate(:second)
                         |> DateTime.to_iso8601(),
                       "files" => [
                         %{
                           "filename" => "one.png",
                           "content_type" => "image/png",
                           "size" => byte_size(@png),
                           "sha256" => Base.encode16(:crypto.hash(:sha256, @png), case: :lower)
                         }
                       ],
                       "approvals" => []
                     }
                   ]
                 }
               ]
             }
    end

    test "has the approved version by its id, and who approved it", ctx do
      place!(ctx)

      for content <- [@png <> "a", @png <> "b"] do
        assert write(
                 ctx,
                 "/artifacts",
                 push_body("screenshot", [{"one.png", "image/png", content}])
               ).status ==
                 201
      end

      [first, second] = RunApiStubs.pushed()
      approval = decide!(ctx, :approve, versions: [first.public_id])

      [artifact] = json_response(read(ctx, "/artifacts"), 200)["artifacts"]
      assert artifact["approved_version"] == first.public_id
      assert artifact["newest_version"] == 2
      assert [newest, approved] = artifact["versions"]
      assert newest["id"] == second.public_id
      assert newest["approvals"] == []

      assert approved["approvals"] == [
               %{
                 "by" => %{"name" => Inputs.person_name(ctx.scope.user.id)},
                 "automatic" => false,
                 "stage_id" => @explore,
                 "at" => at(approval.inserted_at)
               }
             ]
    end

    test "has an approval a gate none recorded with no member as by null, automatic", ctx do
      place!(ctx)

      assert write(
               ctx,
               "/artifacts",
               push_body("screenshot", [{"one.png", "image/png", @png <> "auto"}])
             ).status == 201

      [pushed] = RunApiStubs.pushed()

      approval =
        decide!(ctx, :approve, versions: [pushed.public_id], user_id: nil, automatic: true)

      [artifact] = json_response(read(ctx, "/artifacts"), 200)["artifacts"]
      assert artifact["approved_version"] == pushed.public_id
      [version] = artifact["versions"]

      assert version["approvals"] == [
               %{
                 "by" => nil,
                 "automatic" => true,
                 "stage_id" => @explore,
                 "at" => at(approval.inserted_at)
               }
             ]
    end

    @tag needs: [:workflow_model, :factory, :secrets, :observability]
    test "marks each version that a run a member cancelled wrote", ctx do
      # Running, as a member can cancel it.
      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id),
          set: [state: "running", started_at: DateTime.utc_now()]
        )

      for content <- [@png <> "a", @png <> "b"] do
        assert write(
                 ctx,
                 "/artifacts",
                 push_body("screenshot", [{"one.png", "image/png", content}])
               ).status == 201
      end

      # A person, and another run of the work item that a claim registered and no
      # member cancelled, store a version each.
      other =
        Repo.insert!(%DispatchRun{
          organisation_id: ctx.dispatch_run.organisation_id,
          workspace_id: ctx.dispatch_run.workspace_id,
          work_item_id: ctx.work_item.id,
          run_id: Ecto.UUID.generate(),
          step: ctx.dispatch_run.step,
          take_in: ctx.dispatch_run.take_in,
          attempt: ctx.dispatch_run.attempt + 1,
          of: ctx.dispatch_run.of + 1,
          queued_at: Apiary.Dispatches.now()
        })

      registered =
        Apiary.RunEventsFixtures.run_fixture(ctx.scope, %{
          dispatch_run_id: other.id,
          state: "completed",
          started_at: DateTime.utc_now(),
          exited_at: DateTime.utc_now()
        })

      assert Run.registered?(registered)
      refute Run.cancel_requested?(registered)

      other_version =
        store!(%{ctx | dispatch_run: other}, "explainer", [
          file("notes.md", "text/markdown", "x")
        ])

      # The index reads the mark from that registered run, not from a run with none.
      assert %{run: %{run: %Run{id: registered_id}}} =
               Apiary.Artifacts.get_version!(other_version.public_id)

      assert registered_id == registered.id

      {:ok, _cancelled} = Apiary.Runs.cancel(ctx.scope, Repo.get!(Run, ctx.run.id))

      body = json_response(read(ctx, "/artifacts"), 200)
      by_type = Map.new(body["artifacts"], &{&1["type"], &1["versions"]})

      assert [
               %{"number" => 2, "cancelled" => true},
               %{"number" => 1, "cancelled" => true}
             ] = by_type["screenshot"]

      assert [%{"number" => 1, "writer" => %{"run_id" => run_id}, "cancelled" => false}] =
               by_type["explainer"]

      assert run_id == other.run_id
    end

    @tag needs: [:workflow_model, :factory, :secrets, :observability]
    test "newest_version and changed_after_approval leave out a cancelled run's versions",
         ctx do
      place!(ctx)

      assert write(
               ctx,
               "/artifacts",
               push_body("screenshot", [{"one.png", "image/png", @png <> "a"}])
             ).status == 201

      [first] = RunApiStubs.pushed()
      decide!(ctx, :approve, versions: [first.public_id])

      # Another run of the work item stores version 2 of the screenshot and the only
      # version of the explainer; the work item then moves on to another stage.
      other =
        Repo.insert!(%DispatchRun{
          organisation_id: ctx.dispatch_run.organisation_id,
          workspace_id: ctx.dispatch_run.workspace_id,
          work_item_id: ctx.work_item.id,
          run_id: Ecto.UUID.generate(),
          step: ctx.dispatch_run.step,
          take_in: ctx.dispatch_run.take_in,
          attempt: ctx.dispatch_run.attempt + 1,
          of: ctx.dispatch_run.of + 1,
          queued_at: Apiary.Dispatches.now()
        })

      registered =
        Apiary.RunEventsFixtures.run_fixture(ctx.scope, %{
          dispatch_run_id: other.id,
          state: "running",
          started_at: DateTime.utc_now()
        })

      for {type, filename, content_type, binary} <- [
            {"screenshot", "one.png", "image/png", @png <> "b"},
            {"explainer", "notes.md", "text/markdown", "x"}
          ] do
        store!(%{ctx | dispatch_run: other}, type, [file(filename, content_type, binary)],
          stage_id: @explore
        )
      end

      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^ctx.work_item.id),
          set: [stage_id: "st_p9w5cvh311"]
        )

      by_type = fn ->
        body = json_response(read(ctx, "/artifacts"), 200)
        Map.new(body["artifacts"], &{&1["type"], &1})
      end

      assert %{"newest_version" => 2, "changed_after_approval" => true} =
               by_type.()["screenshot"]

      assert %{"newest_version" => 1} = by_type.()["explainer"]

      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^registered.id),
          set: [cancel_requested_at: DateTime.utc_now()]
        )

      artifacts = by_type.()

      assert %{"newest_version" => 1, "changed_after_approval" => false} =
               artifacts["screenshot"]

      assert %{"newest_version" => nil, "changed_after_approval" => false} =
               artifacts["explainer"]
    end
  end

  defp file(filename, content_type, binary),
    do: %{filename: filename, content_type: content_type, binary: binary}

  describe "GET artifacts/:version_id/files/:filename" do
    setup ctx do
      body = push_body("screenshot", [{"one.png", "image/png", @png}])
      assert write(ctx, "/artifacts", body).status == 201
      %{version: List.last(RunApiStubs.pushed()).public_id}
    end

    test "is the file as a download, with nosniff and a sandbox policy", ctx do
      conn = read(ctx, "/artifacts/#{ctx.version}/files/one.png")
      assert signed_answer?(conn)
      assert response(conn, 200) == @png
      assert get_resp_header(conn, "content-type") == ["image/png"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      [policy] = get_resp_header(conn, "content-security-policy")
      assert String.starts_with?(policy, "default-src 'self'")
      assert String.ends_with?(policy, "; sandbox")

      assert get_resp_header(conn, "content-disposition") == [
               ~s(attachment; filename="one.png"; filename*=UTF-8''one.png)
             ]
    end

    test "serves a Markdown file with the type its bytes show, the charset included", ctx do
      version = store!(ctx, "explainer", [file("notes.md", "text/plain", "# Notes\n")])

      conn = read(ctx, "/artifacts/#{version.public_id}/files/notes.md")
      assert response(conn, 200) == "# Notes\n"
      assert get_resp_header(conn, "content-type") == ["text/markdown; charset=utf-8"]
    end

    test "stores the type the bytes show, never the content_type of the push", ctx do
      body = push_body("screenshot", [{"two.png", "image/gif", @png}], %{"name" => "two"})
      assert write(ctx, "/artifacts", body).status == 201

      version = List.last(RunApiStubs.pushed())
      assert [%{content_type: "image/png"}] = version.files

      conn = read(ctx, "/artifacts/#{version.public_id}/files/two.png")
      assert get_resp_header(conn, "content-type") == ["image/png"]
    end

    test "serves HTML and SVG as plain bytes, never inline", ctx do
      file_type!(ctx, "page-file", 64, 1)
      body = push_body("page-file", [{"page.html", "text/html", "<b>"}])
      assert write(ctx, "/artifacts", body).status == 201

      version = List.last(RunApiStubs.pushed())
      conn = read(ctx, "/artifacts/#{version.public_id}/files/page.html")
      assert response(conn, 200) == "<b>"
      assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
      assert ["attachment; " <> _] = get_resp_header(conn, "content-disposition")

      svg = store!(ctx, "screenshot", [file("a b.svg", "image/svg+xml", @svg)], name: "svg")

      conn = read(ctx, "/artifacts/#{svg.public_id}/files/a%20b.svg")
      assert response(conn, 200) == @svg
      assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

      assert get_resp_header(conn, "content-disposition") == [
               ~s(attachment; filename="a_b.svg"; filename*=UTF-8''a%20b.svg)
             ]
    end

    test "a stored type that is not a plain safe type is served as plain bytes", ctx do
      version = store!(ctx, "screenshot", [file("kept.png", "image/png", @png)], name: "kept")
      [stored] = version.files

      for type <- [
            "text/html",
            "text/html; charset=utf-8",
            "application/xhtml+xml",
            "text/javascript; charset=utf-8",
            "text/plain; boundary=x",
            "text/plain\r\nX-Evil: 1"
          ] do
        {1, _rows} =
          Repo.update_all(from(f in ArtifactFile, where: f.id == ^stored.id),
            set: [content_type: type]
          )

        conn = read(ctx, "/artifacts/#{version.public_id}/files/kept.png")
        assert get_resp_header(conn, "content-type") == ["application/octet-stream"], type
      end
    end

    test "a note with a carriage return, U+200C or U+200D is stored", ctx do
      body =
        push_body("screenshot", [{"note.png", "image/png", @png}], %{
          "name" => "note",
          "note" => "a\r\nb\u200Cc\u200Dd"
        })

      assert write(ctx, "/artifacts", body).status == 201
      assert List.last(RunApiStubs.pushed()).note == "a\nb\u200Cc\u200Dd"
    end

    test "a file of several MiB is sent from disk byte for byte, signed, with every header",
         ctx do
      file_type!(ctx, "big-file", 8 * 1024 * 1024, 1)
      content = :crypto.strong_rand_bytes(5 * 1024 * 1024)
      version = store!(ctx, "big-file", [file("big.bin", "application/octet-stream", content)])

      conn = read(ctx, "/artifacts/#{version.public_id}/files/big.bin")
      # `send_file`: the response is the file on disk, never a binary of it.
      assert conn.state == :file
      assert response(conn, 200) == content
      assert signed_answer?(conn)
      assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      [policy] = get_resp_header(conn, "content-security-policy")
      assert String.ends_with?(policy, "; sandbox")

      assert get_resp_header(conn, "content-disposition") == [
               ~s(attachment; filename="big.bin"; filename*=UTF-8''big.bin)
             ]
    end

    test "the signature is byte for byte the one made over the whole body", ctx do
      conn = read(ctx, "/artifacts/#{ctx.version}/files/one.png")
      [request_signature] = get_req_header(conn, "x-qory-signature-ed25519")

      {_cache, expected} =
        SignedAnswer.headers(
          200,
          request_signature,
          @png,
          nil,
          nil,
          SigningKey.current()
        )

      assert get_resp_header(conn, "x-qory-signature-ed25519") == [expected]
    end

    test "a stored file whose bytes no longer match its digest fails the gateway's check",
         ctx do
      version = Apiary.Artifacts.get_version!(ctx.version)
      [stored] = version.files
      {:ok, path} = Apiary.Artifacts.open_file(stored)
      changed = binary_part(@png, 0, byte_size(@png) - 1) <> "!"
      File.chmod!(path, 0o600)
      File.write!(path, changed)

      conn = read(ctx, "/artifacts/#{ctx.version}/files/one.png")
      assert response(conn, 200) == changed
      refute signed_answer?(conn)
    end

    test "a store that returns a stream is sent in chunks, signed over the stored digest",
         ctx do
      previous = Application.fetch_env(:apiary, Apiary.Artifacts.Store)
      Application.put_env(:apiary, Apiary.Artifacts.Store, adapter: __MODULE__.StreamStore)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:apiary, Apiary.Artifacts.Store, value)
          :error -> Application.delete_env(:apiary, Apiary.Artifacts.Store)
        end
      end)

      file_type!(ctx, "chunked-file", 1024 * 1024, 1)
      content = :crypto.strong_rand_bytes(300_000)
      version = store!(ctx, "chunked-file", [file("c.bin", "application/octet-stream", content)])

      conn = read(ctx, "/artifacts/#{version.public_id}/files/c.bin")
      assert conn.state == :chunked
      assert response(conn, 200) == content
      assert signed_answer?(conn)
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert ["attachment; " <> _] = get_resp_header(conn, "content-disposition")
    end

    test "a filename that is not ASCII has one _ per character in its plain name", ctx do
      version =
        store!(ctx, "screenshot", [file("caf\u00e9 \u00fc.png", "image/png", @png)], name: "cafe")

      conn = read(ctx, "/artifacts/#{version.public_id}/files/caf%C3%A9%20%C3%BC.png")
      assert response(conn, 200) == @png

      assert get_resp_header(conn, "content-disposition") == [
               ~s(attachment; filename="caf___.png"; filename*=UTF-8''caf%C3%A9%20%C3%BC.png)
             ]
    end

    test "another work item's version, an unknown one and a malformed id are the same 404",
         ctx do
      other = other_run()

      theirs = store!(other, "screenshot", [file("one.png", "image/png", @png)])

      answers =
        for path <- [
              "/artifacts/#{theirs.public_id}/files/one.png",
              "/artifacts/#{Apiary.PublicId.generate("av")}/files/one.png",
              "/artifacts/not-a-version/files/one.png",
              "/artifacts/#{ctx.version}/files/two.png"
            ] do
          conn = read(ctx, path)
          assert signed_answer?(conn)
          {conn.status, conn.resp_body}
        end

      assert Enum.uniq(answers) == [{404, ~s({"error":"not_found"})}]

      # The other run reads its version; this run's key does not.
      conn =
        read(ctx, "/artifacts/#{theirs.public_id}/files/one.png",
          key: other.key,
          run_id: other.run.node_run_id
        )

      assert response(conn, 200) == @png
    end

    test "a filename is compared, never used as a path", ctx do
      for name <- [
            "..",
            "%2E%2E",
            "..%2Fone.png",
            "%2E%2E%2F%2E%2E%2Fetc%2Fpasswd",
            "one.png%00",
            "ONE.PNG"
          ] do
        conn = read(ctx, "/artifacts/#{ctx.version}/files/#{name}")
        assert conn.status == 404, name
      end
    end
  end

  describe "POST artifacts" do
    test "stores a version as the run, for its work item", ctx do
      body =
        push_body("screenshot", [{"one.png", "image/png", @png}], %{
          "name" => "checkout",
          "note" => "After the fix."
        })

      conn = write(ctx, "/artifacts", body)
      assert signed_answer?(conn)
      [version] = RunApiStubs.pushed()

      assert json_response(conn, 201) == %{
               "version" => 1,
               "artifact" => %{
                 "type" => "screenshot",
                 "name" => "checkout",
                 "version" => %{"id" => version.public_id, "number" => 1}
               }
             }

      assert version.artifact.work_item_id == ctx.work_item.id
      assert {:run, %DispatchRun{id: id}} = version.opts[:actor]
      assert id == ctx.dispatch_run.id
      assert version.note == "After the fix."
      assert version.opts[:stage_id] == ctx.dispatch_run.stage_id
      assert [%{filename: "one.png", content_type: "image/png", content: @png}] = version.files
    end

    test "a body the contract refuses is 400 with the member", ctx do
      cases = [
        {"not json", "body"},
        {"[]", "body"},
        {%{"files" => []}, "type"},
        {push_body("screenshot", []), "files"},
        {push_body("screenshot", [{"a.png", "image/png", "x"}], %{"extra" => 1}), "extra"},
        {push_body("screenshot", [{"a.png", "image/png", "x"}], %{"name" => "../x"}), "name"},
        {push_body("screenshot", [{"a.png", "image/png", "x"}], %{"name" => "Check_out"}),
         "name"},
        {push_body("Screenshot", [{"a.png", "image/png", "x"}]), "type"},
        {push_body("screenshot", [{"a.png", "image/png", "x"}], %{
           "note" => "a" <> String.duplicate("\u0301", 4001)
         }), "note"},
        {push_body("screenshot", [{"a.png", "image/png", "x"}], %{"note" => "a\u0085b"}), "note"},
        {push_body("screenshot", [{"a.png", "image/png", @png}], %{"note" => "a\u202Eb"}),
         "note"},
        {push_body("screenshot", [{"a.png", "image/png", "x"}], %{
           String.duplicate("k", 65) => 1
         }), "body"},
        {push_body("screenshot", [{"a.png", "not a type", "x"}]), "files[0].content_type"},
        {push_body("screenshot", [{"a.png", "image/png", "x"}, {"a.png", "image/png", "y"}]),
         "files[1].filename"}
      ]

      for {body, member} <- cases do
        conn = write(ctx, "/artifacts", body)
        assert signed_answer?(conn)
        assert json_response(conn, 400) == %{"error" => "invalid_request", "names" => [member]}
      end

      assert RunApiStubs.pushed() == []
    end

    test "a filename outside the rule of Apiary.Artifacts.Filename is 400", ctx do
      for name <- [
            "..",
            ".",
            "../x.png",
            "a/b.png",
            "a\\b.png",
            "a\u0000.png",
            "a\n.png",
            "a\u202Eb.png",
            ""
          ] do
        conn = write(ctx, "/artifacts", push_body("screenshot", [{name, "image/png", @png}]))

        assert json_response(conn, 400) == %{
                 "error" => "invalid_request",
                 "names" => ["files[0].filename"]
               },
               inspect(name)
      end

      # The checks of the body run before those of the type.
      for {body, member} <- [
            {push_body("no-such-type", [{"a.png", "image/png", @png}], %{"note" => "a\u202Eb"}),
             "note"},
            {push_body("no-such-type", [{"a.png", "image/png", @png}], %{"note" => "a\u2028b"}),
             "note"},
            {push_body("no-such-type", [{"a\u202Eb.png", "image/png", @png}]),
             "files[0].filename"},
            {push_body("no-such-type", [{"a\u2029b.png", "image/png", @png}]),
             "files[0].filename"}
          ] do
        assert json_response(write(ctx, "/artifacts", body), 400) == %{
                 "error" => "invalid_request",
                 "names" => [member]
               }
      end

      long = String.duplicate("a", 256)
      conn = write(ctx, "/artifacts", push_body("screenshot", [{long, "image/png", "x"}]))
      assert json_response(conn, 400)["names"] == ["files[0].filename"]
      assert RunApiStubs.pushed() == []
    end

    test "content that is not strict base64 is 400", ctx do
      for content <- ["not base64!", "eA", "eA==\n"] do
        body = %{
          "type" => "screenshot",
          "files" => [
            %{"filename" => "a.png", "content_type" => "image/png", "content_base64" => content}
          ]
        }

        conn = write(ctx, "/artifacts", body)

        assert json_response(conn, 400) == %{
                 "error" => "invalid_request",
                 "names" => ["files[0].content_base64"]
               }
      end

      assert RunApiStubs.pushed() == []
    end

    test "more files than the type takes is 422 with the type and the limit", ctx do
      files = for n <- 1..11, do: {"#{n}.png", "image/png", @png}
      conn = write(ctx, "/artifacts", push_body("screenshot", files))

      assert json_response(conn, 422) == %{
               "error" => "too_many_files",
               "type" => "screenshot",
               "limit" => 10,
               "message" => "Push at most 10 files in one version of screenshot."
             }

      assert RunApiStubs.pushed() == []
    end

    test "files over the type's size limit together are 422 with the type and the limit",
         ctx do
      file_type!(ctx, "small-file", 16, 2)

      assert write(
               ctx,
               "/artifacts",
               push_body("small-file", [{"a.png", "image/png", String.duplicate("x", 16)}])
             ).status ==
               201

      conn =
        write(
          ctx,
          "/artifacts",
          push_body("small-file", [{"a.png", "image/png", String.duplicate("x", 17)}])
        )

      assert json_response(conn, 422) == %{
               "error" => "too_large",
               "type" => "small-file",
               "limit" => 16,
               "message" =>
                 "Shrink the files of one version of small-file to at most 16 bytes together."
             }

      assert length(RunApiStubs.pushed()) == 1

      # Two files of 8 and 9 bytes: each within 16, together over it.
      conn =
        write(
          ctx,
          "/artifacts",
          push_body("small-file", [
            {"a.png", "image/png", String.duplicate("x", 8)},
            {"b.png", "image/png", String.duplicate("x", 9)}
          ])
        )

      assert json_response(conn, 422)["error"] == "too_large"
      assert length(RunApiStubs.pushed()) == 1
    end

    test "a body over 32 MiB is 413 before it is decoded or verified", ctx do
      body = String.duplicate(" ", Body.max_bytes(:push) + 1)
      conn = write(ctx, "/artifacts", body)
      # `ApiaryWeb.Contract.RawBody` stops reading it, before the signature is checked.
      refute signed_answer?(conn)
      assert json_response(conn, 413) == %{"error" => "payload_too_large"}
      assert RunApiStubs.pushed() == []
    end

    test "a type the workspace does not have is 422 unknown_type", ctx do
      conn =
        write(ctx, "/artifacts", push_body("demo-findings", [{"a.md", "text/markdown", "x"}]))

      assert json_response(conn, 422) == %{
               "error" => "unknown_type",
               "type" => "demo-findings",
               "message" =>
                 "Define the artifact type demo-findings in the workspace's Artifact types, " <>
                   "then run the round again."
             }
    end

    test "a standard type the workspace hides is 422 unknown_type, with the step to switch it on",
         ctx do
      {1, _rows} =
        Repo.update_all(
          from(w in Apiary.Organisations.Workspace, where: w.id == ^ctx.work_item_workspace.id),
          set: [shown_standard_types: ["explainer"]]
        )

      conn = write(ctx, "/artifacts", push_body("mockup", [{"a.png", "image/png", "x"}]))

      assert signed_answer?(conn)

      assert json_response(conn, 422) == %{
               "error" => "unknown_type",
               "type" => "mockup",
               "message" =>
                 "Switch on the artifact type mockup in the workspace's Artifact types, " <>
                   "then run the round again."
             }

      assert RunApiStubs.pushed() == []
    end

    test "a submission.json the type's schema takes is stored as a version of submission",
         ctx do
      submission = %{
        "ref" => "qory/wi_example",
        "verdict" => "passed",
        "repositories" => [
          %{
            "system" => "forge.example.com",
            "path" => "example/shop",
            "commit" => String.duplicate("a", 40),
            "draft" => %{
              "number" => 4,
              "url" => "https://forge.example.com/example/shop/pull/4",
              "title" => "Gift cards",
              "state" => "draft",
              "action" => "opened"
            }
          }
        ],
        "text" => %{"title" => "Gift cards", "description" => "Adds gift cards to checkout."}
      }

      bytes = Jason.encode!(submission)
      body = push_body("submission", [{"submission.json", "application/json", bytes}])
      conn = write(ctx, "/artifacts", body)

      assert %{"artifact" => %{"type" => "submission", "version" => %{"id" => id, "number" => 1}}} =
               json_response(conn, 201)

      assert Apiary.Artifacts.newest(ctx.work_item, "submission", "main").public_id == id
      assert [%{files: [%{filename: "submission.json", content: ^bytes}]}] = RunApiStubs.pushed()

      # A submission with no verdict fails the type's schema.
      bytes = Jason.encode!(Map.delete(submission, "verdict"))
      body = push_body("submission", [{"submission.json", "application/json", bytes}])
      conn = write(ctx, "/artifacts", body)
      assert json_response(conn, 422)["error"] == "invalid_artifact"
      assert length(RunApiStubs.pushed()) == 1
    end

    test "change is no standard type: a push of it is 422 unknown_type", ctx do
      file = {"change.json", "application/json", ~s({"url":"https://forge.example.com/pr/4"})}
      conn = write(ctx, "/artifacts", push_body("change", [file]))

      assert json_response(conn, 422) == %{
               "error" => "unknown_type",
               "type" => "change",
               "message" =>
                 "Define the artifact type change in the workspace's Artifact types, " <>
                   "then run the round again."
             }

      assert RunApiStubs.pushed() == []
    end

    test "a submission to a workspace without the type is 422 unknown_type, with the step " <>
           "to define it",
         ctx do
      {1, _rows} =
        Repo.delete_all(
          from t in Apiary.Artifacts.Type,
            where: t.workspace_id == ^ctx.work_item_workspace.id and t.name == "submission"
        )

      file = {"submission.json", "application/json", ~s({"ref":"qory/wi_example"})}
      conn = write(ctx, "/artifacts", push_body("submission", [file]))

      assert signed_answer?(conn)

      assert json_response(conn, 422) == %{
               "error" => "unknown_type",
               "type" => "submission",
               "message" =>
                 "Define the artifact type submission in the workspace's Artifact types, " <>
                   "then run the round again."
             }

      assert RunApiStubs.pushed() == []
    end

    test "what the push returns is answered with the type, its limit and the member",
         ctx do
      cases = [
        {{:too_large, 900}, 422,
         %{
           "error" => "too_large",
           "type" => "explainer",
           "limit" => 900,
           "message" =>
             "Shrink the files of one version of explainer to at most 900 bytes together."
         }},
        {{:too_many_files, 1}, 422,
         %{
           "error" => "too_many_files",
           "type" => "explainer",
           "limit" => 1,
           "message" => "Push at most 1 file in one version of explainer."
         }},
        {{:invalid, {:format, 0}}, 422,
         %{
           "error" => "invalid_artifact",
           "names" => ["files[0]"],
           "message" =>
             "Fix a.md to match the format of explainer: " <>
               "a document is a Markdown file of UTF-8 text."
         }},
        {{:invalid, {:extension, 0}}, 422,
         %{
           "error" => "invalid_artifact",
           "names" => ["files[0]"],
           "message" =>
             "Fix a.md to match the format of explainer: " <>
               "the filename of a document ends in .md."
         }},
        {{:invalid, {:schema, 0, %{path: "#/summary", error: "value is not of type string"}}},
         422,
         %{
           "error" => "invalid_artifact",
           "names" => ["files[0]"],
           "message" =>
             "Fix a.md to match the format of explainer: " <>
               "at #/summary, value is not of type string."
         }},
        {{:invalid, {:unreadable, 0}}, 422,
         %{
           "error" => "invalid_artifact",
           "names" => ["files[0]"],
           "message" => "Push a.md again: Qory Apiary could not read it after it was received."
         }},
        {{:invalid, :no_video}, 422,
         %{
           "error" => "invalid_artifact",
           "names" => ["files"],
           "message" =>
             "Add an MP4 or WebM video to the version of explainer: " <>
               "a WebVTT file goes with a video."
         }},
        {{:invalid, {:filename, 0}}, 400,
         %{"error" => "invalid_request", "names" => ["files[0].filename"]}},
        {{:invalid, :note}, 400, %{"error" => "invalid_request", "names" => ["note"]}},
        {{:unknown_type, "explainer"}, 422,
         %{
           "error" => "unknown_type",
           "type" => "explainer",
           "message" =>
             "Switch on the artifact type explainer in the workspace's Artifact types, " <>
               "then run the round again."
         }},
        {:not_found, 404, %{"error" => "not_found"}},
        {:store_unavailable, 503, %{"error" => "unavailable"}},
        # A run that ended after the check before the push, found ended under the work
        # item's lock.
        {:run_ended, 409,
         %{
           "error" => "run_ended",
           "message" => "The run has ended, so it can no longer push artifacts or give a verdict."
         }}
      ]

      for {push_error, status, answer} <- cases do
        RunApiStubs.put(:push_error, push_error)
        conn = write(ctx, "/artifacts", push_body("explainer", [{"a.md", "text/markdown", "x"}]))
        assert signed_answer?(conn)
        assert json_response(conn, status) == answer, inspect(push_error)
      end
    end

    test "a proposal is one Markdown file with images and sources.json, and each refusal says why",
         ctx do
      md = {"proposal.md", "text/markdown", "# Gift cards\n\n![Checkout](checkout.svg)\n"}
      sources = {"sources.json", "application/json", ~s({"sources": []})}
      svg = {"checkout.svg", "image/svg+xml", @svg}
      png = {"cart.png", "image/png", @png}

      conn = write(ctx, "/artifacts", push_body("proposal", [md, svg, png, sources]))
      assert %{"artifact" => %{"type" => "proposal"}} = json_response(conn, 201)

      unsafe = ~s(<svg xmlns="http://www.w3.org/2000/svg"><a href="https://example.com/"/></svg>)
      escaped = ~s(<svg xmlns="http://www.w3.org/2000/svg"><rect fill="\\0"/></svg>)
      iframe = ~s(<svg xmlns="http://www.w3.org/2000/svg"><iframe/></svg>)

      big_svg =
        ~s(<svg xmlns="http://www.w3.org/2000/svg"><desc>#{String.duplicate("a", 524_288)}</desc></svg>)

      cases = [
        {[md, {"notes.txt", "text/plain", "Gift cards."}], ["files[1]"],
         "Fix notes.txt to match the format of proposal: a proposal is one Markdown file " <>
           "(.md) with PNG, JPEG, GIF, WebP or SVG images and an optional sources.json."},
        {[md, {"cart.png", "image/gif", "GIF89a" <> <<1>>}], ["files[1]"],
         "Replace cart.png with an image of the type its name ends in."},
        {[md, {"checkout.svg", "image/svg+xml", @png}], ["files[1]"],
         "Replace checkout.svg with an image of the type its name ends in."},
        {[{"proposal.md", "text/markdown", <<0xFF>>}], ["files[0]"],
         "Fix proposal.md to match the format of proposal: " <>
           "a document is a Markdown file of UTF-8 text."},
        {[md, {"other.md", "text/markdown", "# Other"}], ["files"],
         "Push one Markdown file (.md) in each version of proposal."},
        {[png], ["files"], "Push one Markdown file (.md) in each version of proposal."},
        {[{"proposal.md", "text/markdown", String.duplicate("a", 262_145)}], ["files[0]"],
         "Shrink proposal.md to at most 262144 bytes."},
        {[md, {"checkout.svg", "image/svg+xml", unsafe}], ["files[1]"],
         "Remove the href attribute from checkout.svg. An SVG in a proposal uses only the " <>
           "elements and attributes the run API document lists, with no script, HTML or " <>
           "reference outside the file."},
        {[md, {"checkout.svg", "image/svg+xml", escaped}], ["files[1]"],
         "Remove a backslash in the fill attribute from checkout.svg. An SVG in a proposal " <>
           "uses only the elements and attributes the run API document lists, with no " <>
           "script, HTML or reference outside the file."},
        {[md, {"checkout.svg", "image/svg+xml", iframe}], ["files[1]"],
         "Remove the iframe element from checkout.svg. An SVG in a proposal uses only the " <>
           "elements and attributes the run API document lists, with no script, HTML or " <>
           "reference outside the file."},
        {[md, {"checkout.svg", "image/svg+xml", "<svg><rect></svg>"}], ["files[1]"],
         "Make checkout.svg a well-formed SVG file in UTF-8 with an svg root element."},
        {[md, {"checkout.svg", "image/svg+xml", "<svg/>"}], ["files[1]"],
         ~s(Set xmlns="http://www.w3.org/2000/svg" on the svg root element of checkout.svg.)},
        {[md, {"checkout.svg", "image/svg+xml", ~s(<svg xmlns="urn:example:x"/>)}], ["files[1]"],
         ~s(Set xmlns="http://www.w3.org/2000/svg" on the svg root element of checkout.svg.)},
        {[md, {"checkout.svg", "image/svg+xml", big_svg}], ["files[1]"],
         "Shrink checkout.svg to at most 524288 bytes."},
        {[md, {"checkout.svg", "image/svg+xml", "<!DOCTYPE svg>" <> @svg}], ["files[1]"],
         "Remove the DOCTYPE from checkout.svg. An SVG in a proposal uses only the elements " <>
           "and attributes the run API document lists, with no script, HTML or reference " <>
           "outside the file."},
        {[md, {"sources.json", "application/json", "{"}], ["files[1]"],
         "Make sources.json valid JSON. The file does not parse as JSON."},
        {[md, {"sources.json", "application/json", String.duplicate(" ", 1_048_577)}],
         ["files[1]"], "Shrink sources.json to at most 1048576 bytes."},
        {[md, {"sources.json", "application/json", ~s({"items": []})}], ["files[1]"],
         "Fix sources.json to match the format of proposal sources: " <>
           "at #, additional properties are not allowed but found property 'items'."},
        {[md, {"sources.json", "application/json", ~s({"sources": [], "sources": []})}],
         ["files[1]"],
         "Fix sources.json to match the format of proposal sources: " <>
           "at #, the object has the key sources twice."}
      ]

      for {files, names, message} <- cases do
        conn = write(ctx, "/artifacts", push_body("proposal", files))

        assert json_response(conn, 422) == %{
                 "error" => "invalid_artifact",
                 "names" => names,
                 "message" => message
               },
               message
      end

      assert [_one] = RunApiStubs.pushed()
    end

    test "a mockup with screens.json is checked as pages, and each refusal has its cause", ctx do
      page = fn title, body ->
        ~s(<!doctype html><html><head><meta charset="utf-8"><title>#{title}</title></head>) <>
          "<body>#{body}</body></html>"
      end

      index =
        Jason.encode!(%{
          "start" => "home",
          "screens" => [
            %{
              "id" => "home",
              "title" => "Home",
              "file" => "home.html",
              "criteria" => ["ac-1"],
              "links" => []
            }
          ]
        })

      screens = {"screens.json", "application/json", index}
      home = {"home.html", "text/html", page.("Home", "<p>Hello</p>")}

      conn = write(ctx, "/artifacts", push_body("mockup", [screens, home]))
      assert %{"artifact" => %{"type" => "mockup"}} = json_response(conn, 201)

      # Pictures, with no screens.json, are a mockup of images as before.
      conn = write(ctx, "/artifacts", push_body("mockup", [{"form.png", "image/png", @png}]))
      assert %{"artifact" => %{"type" => "mockup"}} = json_response(conn, 201)

      cases = [
        {[screens, {"home.html", "text/html", page.("Home", "<script>x()</script>")}],
         ["files[1]"],
         "Remove the `<script>` element from `home.html` (screen `home`): a mockup page " <>
           "runs no script."},
        {[screens], ["files"],
         "Add `home.html` to the version: it is the page of screen `home` in `screens.json`."},
        {[screens, home, {"form.png", "image/png", @png}], ["files[2]"],
         "Remove `form.png` from the version: a mockup version has `screens.json` and one " <>
           "page per screen, and no other file."},
        {[{"screens.json", "application/json", ~s({"start": "home"})}, home], ["files[0]"],
         "Fix screens.json to match the format of mockup: " <>
           "at #, property 'screens' is required."}
      ]

      for {files, names, message} <- cases do
        conn = write(ctx, "/artifacts", push_body("mockup", files))

        assert json_response(conn, 422) == %{
                 "error" => "invalid_artifact",
                 "names" => names,
                 "message" => message
               },
               message
      end

      assert [_pages, _images] = RunApiStubs.pushed()
    end

    test "a proposal takes 10 files and 5 MiB together, and no more", ctx do
      md = {"proposal.md", "text/markdown", "# Gift cards"}
      images = for n <- 1..10, do: {"#{n}.png", "image/png", @png}
      conn = write(ctx, "/artifacts", push_body("proposal", [md | images]))

      assert json_response(conn, 422) == %{
               "error" => "too_many_files",
               "type" => "proposal",
               "limit" => 10,
               "message" => "Push at most 10 files in one version of proposal."
             }

      large = @png <> :binary.copy("a", 5_242_880)
      conn = write(ctx, "/artifacts", push_body("proposal", [md, {"a.png", "image/png", large}]))

      assert json_response(conn, 422) == %{
               "error" => "too_large",
               "type" => "proposal",
               "limit" => 5_242_880,
               "message" =>
                 "Shrink the files of one version of proposal to at most 5242880 bytes together."
             }

      assert RunApiStubs.pushed() == []
    end

    test "a run's version of questions or review comments that changes what members wrote is 422",
         ctx do
      cases = [
        {"questions", :id_dropped,
         "Keep every question of the newest version of questions in questions.json: " <>
           "the id of a question is missing."},
        {"questions", :answer_changed,
         "Leave each answer in questions.json as the newest version of questions has it: " <>
           "members write the answers."},
        {"questions", :history_changed,
         "Leave the history of each question in questions.json as the newest version of " <>
           "questions has it, and give a new question no history."},
        {"questions", :reopen_not_kept,
         "Move the answer of a question you reopen, unchanged, to the end of its history " <>
           "in questions.json."},
        {"questions", :asked_changed,
         "Leave asked of each question in questions.json as the newest version of " <>
           "questions has it."},
        {"questions", :reopened_run,
         "Set reopened.run in the history of each question you reopen in questions.json " <>
           "to this run's number."},
        {"questions", :answered_changed,
         "Leave question, context, options and criterion of each answered question in " <>
           "questions.json as the newest version of questions has them, set or absent."},
        {"questions", :follows_changed,
         "Leave follows of each question in questions.json as the newest version of " <>
           "questions has it."},
        {"questions", :order_changed,
         "Keep the questions of the newest version of questions first in questions.json, " <>
           "in the same order, and add new questions after them."},
        {"questions", :follows_unknown,
         "Set follows of each question you add in questions.json to ids of questions " <>
           "before it in questions.json."},
        {"questions", :new_not_open,
         "Add each question in questions.json as open, with no decision, or as decided, " <>
           "with its decision."},
        {"questions", :asked_run,
         "Set asked.run of each question you add in questions.json to this run's number."},
        {"questions", :decision_option,
         "Set decision.option of each question in questions.json to the title of one of " <>
           "the question's options."},
        {"questions", :decided_not_new,
         "Record each decision in questions.json on a question you add, and set no " <>
           "question already in it to decided."},
        {"questions", :decided_changed,
         "Leave question and options of each question with a decision in questions.json " <>
           "as the newest version of questions has them, and its context and criterion " <>
           "while it stays decided or answered: to change them, withdraw the question and " <>
           "add a new one."},
        {"questions", :decision_changed,
         "Leave the decision of each question in questions.json as the newest version of " <>
           "questions has it, and add none: only the run that adds a question records " <>
           "its decision."},
        {"questions", :decision_run,
         "Set decision.run of each question in questions.json to the question's asked.run: " <>
           "only the run that asked a question records a decision on it."},
        {"review-comments", :id_dropped,
         "Keep every review comment of the newest version of review-comments in " <>
           "review-comments.json: the id of a review comment is missing."},
        {"review-comments", :comment_added,
         "Remove the review comment you added in review-comments.json: " <>
           "members write review comments."},
        {"review-comments", :comment_changed,
         "Leave on, text, by and at of each review comment in review-comments.json as the " <>
           "newest version of review-comments has them."},
        {"review-comments", :reply_changed,
         "Leave each earlier reply in review-comments.json as the newest version of " <>
           "review-comments has it."},
        {"review-comments", :reply_not_run,
         "Set by.run of your reply in review-comments.json to this run's number."},
        {"review-comments", :replies_added,
         "Add at most one reply to each review comment in review-comments.json."},
        {"review-comments", :not_open,
         "Reply in review-comments.json only to review comments that are open."},
        {"review-comments", :not_closed,
         "Close each review comment you reply to in review-comments.json."},
        {"review-comments", :state_changed,
         "Change the state of a review comment in review-comments.json only by closing an " <>
           "open one with your reply."},
        {"review-comments", :question_unknown,
         "Push the question you asked first, then review-comments.json: the question of a " <>
           "reply with the outcome asked is the id of a question in the newest version of " <>
           "questions."}
      ]

      for {type, reason, message} <- cases do
        RunApiStubs.put(:push_error, {:invalid, {:kept, 0, reason}})

        conn =
          write(ctx, "/artifacts", push_body(type, [{"#{type}.json", "application/json", "{}"}]))

        assert signed_answer?(conn)

        assert json_response(conn, 422) == %{
                 "error" => "invalid_artifact",
                 "names" => ["files[0]"],
                 "message" => message
               },
               inspect({type, reason})
      end

      # Every reason of each check has its message.
      assert Enum.sort(for {"questions", reason, _} <- cases, do: reason) ==
               Enum.sort(Apiary.Explore.Questions.reasons())

      assert Enum.sort(for {"review-comments", reason, _} <- cases, do: reason) ==
               Enum.sort(Apiary.Explore.ReviewComments.reasons())
    end

    test "a run that has ended is 409 run_ended, for a push and a verdict", ctx do
      end_run!(ctx)

      for conn <- [
            write(ctx, "/artifacts", push_body("explainer", [{"a.md", "text/markdown", "x"}])),
            write(ctx, "/verdict", %{"verdict" => "passed"})
          ] do
        assert signed_answer?(conn)

        assert json_response(conn, 409) == %{
                 "error" => "run_ended",
                 "message" =>
                   "The run has ended, so it can no longer push artifacts or give a verdict."
               }
      end

      assert RunApiStubs.pushed() == []
      # It still reads its work item.
      assert read(ctx, "/work-item").status == 200
    end

    test "a run lost after its attach and not lost for good pushes and gives a verdict",
         ctx do
      lost!(ctx, [])

      push = write(ctx, "/artifacts", push_body("explainer", [{"a.md", "text/markdown", "x"}]))
      assert push.status == 201
      assert write(ctx, "/verdict", %{"verdict" => "passed"}).status == 201
      assert length(RunApiStubs.pushed()) == 2
    end

    test "a run lost for good is 409 run_ended, for a push and a verdict", ctx do
      silenced!(ctx)

      for conn <- [
            write(ctx, "/artifacts", push_body("explainer", [{"a.md", "text/markdown", "x"}])),
            write(ctx, "/verdict", %{"verdict" => "passed"})
          ] do
        assert json_response(conn, 409)["error"] == "run_ended"
      end

      assert RunApiStubs.pushed() == []
    end

    test "a run whose run of the queue ended is 409 run_ended", ctx do
      {1, _rows} =
        Repo.update_all(from(d in DispatchRun, where: d.id == ^ctx.dispatch_run.id),
          set: [state: :ended, end_cause: :run_ended]
        )

      assert json_response(write(ctx, "/verdict", %{"verdict" => "passed"}), 409)["error"] ==
               "run_ended"
    end

    test "a run of Explore with no stage pushes into Explore's stage, so Exists passes",
         ctx do
      # Queued before the workflow model was on: the run and its work item have no stage.
      {1, _rows} =
        Repo.update_all(from(d in DispatchRun, where: d.id == ^ctx.dispatch_run.id),
          set: [stage_id: nil, workflow: nil, step: "explore"]
        )

      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^ctx.work_item.id),
          set: [stage_id: nil, stage_state: nil, stage_round: nil, stage_entry: nil]
        )

      refute Apiary.Artifacts.exists?(ctx.work_item, @explore, "proposal")

      body = push_body("proposal", [{"proposal.md", "text/markdown", "# Proposal\n"}])
      assert write(ctx, "/artifacts", body).status == 201

      assert [%{stage_id: @explore, opts: opts}] = RunApiStubs.pushed()
      assert opts[:stage_id] == @explore
      assert Apiary.Artifacts.exists?(ctx.work_item, @explore, "proposal")

      # A run of another workflow with no stage has none; a run with a stage keeps it.
      dispatch_run = Repo.get!(DispatchRun, ctx.dispatch_run.id)

      assert Apiary.Stages.run_stage_id(
               %{dispatch_run | workflow: "build", explore: false},
               ctx.work_item
             ) == nil

      assert Apiary.Stages.run_stage_id(%{dispatch_run | stage_id: "st_other"}, ctx.work_item) ==
               "st_other"
    end
  end

  describe "POST artifacts with a decision (A-20)" do
    test "stores the id of a person's note; the index has it with the note's time", ctx do
      place!(ctx)
      note = decide!(ctx, :request_changes, note: "Cover the empty cart.")
      assert "gd_" <> _random = note.public_id

      body =
        push_body("screenshot", [{"one.png", "image/png", @png}], %{
          "decision" => note.public_id
        })

      assert json_response(write(ctx, "/artifacts", body), 201)
      [version] = RunApiStubs.pushed()
      assert version.decision_id == note.public_id
      assert version.opts[:decision] == note.public_id

      [artifact] = json_response(read(ctx, "/artifacts"), 200)["artifacts"]

      assert [%{"decision" => decision, "decision_at" => decision_at}] = artifact["versions"]
      assert decision == note.public_id
      assert decision_at == at(note.inserted_at)
    end

    test "an id that is not a person's note on this work item is 422 unknown_decision", ctx do
      place!(ctx)
      approval = decide!(ctx, :approve, versions: [])
      theirs = other_run()

      elsewhere =
        decide!(Map.merge(ctx, %{work_item: theirs.work_item}), :request_changes, note: "Theirs.")

      for id <- [
            approval.public_id,
            elsewhere.public_id,
            "gd_0000000000000000",
            "es_0000000000000000",
            "AC-2"
          ] do
        body = push_body("screenshot", [{"one.png", "image/png", @png}], %{"decision" => id})
        conn = write(ctx, "/artifacts", body)
        assert signed_answer?(conn)

        assert json_response(conn, 422) == %{
                 "error" => "unknown_decision",
                 "message" =>
                   "Set decision to the id of a person's note on this work item, from notes " <>
                     "in GET work-item, or leave decision out."
               }
      end

      assert RunApiStubs.pushed() == []
    end

    test "a decision that is not text is 400 invalid_request", ctx do
      for value <- [1, true, %{"id" => "gd_0000000000000000"}] do
        body = push_body("screenshot", [{"one.png", "image/png", @png}], %{"decision" => value})

        assert json_response(write(ctx, "/artifacts", body), 400) == %{
                 "error" => "invalid_request",
                 "names" => ["decision"]
               }
      end

      # A null decision is none.
      body = push_body("screenshot", [{"one.png", "image/png", @png}], %{"decision" => nil})
      assert json_response(write(ctx, "/artifacts", body), 201)
      assert [%{decision_id: nil}] = RunApiStubs.pushed()
    end
  end

  describe "POST artifacts with withdraw" do
    defp withdrawal(type, name, extra \\ %{}),
      do: Map.merge(%{"type" => type, "name" => name, "withdraw" => true}, extra)

    defp screenshot(name, content) do
      push_body("screenshot", [{"one.png", "image/png", content}], %{"name" => name})
    end

    test "stores a version with no files, which the index marks withdrawn", ctx do
      assert write(
               ctx,
               "/artifacts",
               push_body("screenshot", [{"one.png", "image/png", @png}], %{"name" => "scenario-2"})
             ).status == 201

      conn =
        write(
          ctx,
          "/artifacts",
          withdrawal("screenshot", "scenario-2", %{"note" => "Shape removed scenario-2."})
        )

      assert signed_answer?(conn)
      [_pushed, withdrawn] = RunApiStubs.pushed()

      assert json_response(conn, 201) == %{
               "version" => 1,
               "artifact" => %{
                 "type" => "screenshot",
                 "name" => "scenario-2",
                 "version" => %{"id" => withdrawn.public_id, "number" => 2}
               }
             }

      assert withdrawn.withdrawn
      assert withdrawn.files == []
      assert withdrawn.writer == :run
      assert withdrawn.note == "Shape removed scenario-2."
      assert {:run, %DispatchRun{id: id}} = withdrawn.opts[:actor]
      assert id == ctx.dispatch_run.id
      assert withdrawn.opts[:stage_id] == ctx.dispatch_run.stage_id
      refute Repo.exists?(from f in ArtifactFile, where: f.version_id == ^withdrawn.id)

      [artifact] = json_response(read(ctx, "/artifacts"), 200)["artifacts"]
      assert artifact["newest_version"] == 2

      assert [
               %{
                 "number" => 2,
                 "withdrawn" => true,
                 "files" => [],
                 "note" => "Shape removed scenario-2."
               },
               %{"number" => 1, "withdrawn" => false, "files" => [_png]}
             ] = artifact["versions"]
    end

    test "stores the decision of a withdrawal, which the index lists with its time", ctx do
      place!(ctx)
      note = decide!(ctx, :request_changes, note: "Drop scenario-2.")
      store!(ctx, "screenshot", [file("one.png", "image/png", @png)], name: "scenario-2")

      body = withdrawal("screenshot", "scenario-2", %{"decision" => note.public_id})
      assert json_response(write(ctx, "/artifacts", body), 201)

      [withdrawn] = RunApiStubs.pushed()
      assert withdrawn.withdrawn
      assert withdrawn.decision_id == note.public_id

      [artifact] = json_response(read(ctx, "/artifacts"), 200)["artifacts"]

      assert [%{"withdrawn" => true, "decision" => decision, "decision_at" => decision_at}, _] =
               artifact["versions"]

      assert decision == note.public_id
      assert decision_at == at(note.inserted_at)
    end

    test "refuses a decision that is not a person's note with 422 unknown_decision", ctx do
      place!(ctx)
      approval = decide!(ctx, :approve, versions: [])
      store!(ctx, "screenshot", [file("one.png", "image/png", @png)], name: "scenario-2")

      body = withdrawal("screenshot", "scenario-2", %{"decision" => approval.public_id})
      conn = write(ctx, "/artifacts", body)

      assert json_response(conn, 422)["error"] == "unknown_decision"
      assert RunApiStubs.pushed() == []

      [artifact] = json_response(read(ctx, "/artifacts"), 200)["artifacts"]
      assert [%{"number" => 1, "withdrawn" => false}] = artifact["versions"]
    end

    test "takes files as an empty list, and withdraw only as true, false or null", ctx do
      store!(ctx, "screenshot", [file("one.png", "image/png", @png)], name: "scenario-2")

      conn = write(ctx, "/artifacts", withdrawal("screenshot", "scenario-2", %{"files" => []}))
      assert %{"artifact" => %{"version" => %{"number" => 2}}} = json_response(conn, 201)

      conn = write(ctx, "/artifacts", withdrawal("screenshot", "scenario-2", %{"withdraw" => 1}))
      assert json_response(conn, 400) == %{"error" => "invalid_request", "names" => ["withdraw"]}

      # Without withdraw, a push needs files as before.
      for withdraw <- [false, nil] do
        conn =
          write(
            ctx,
            "/artifacts",
            withdrawal("screenshot", "scenario-2", %{"withdraw" => withdraw})
          )

        assert json_response(conn, 400) == %{"error" => "invalid_request", "names" => ["files"]}
      end

      assert [%{number: 2}] = RunApiStubs.pushed()
    end

    test "refuses a name with no version, files and a withdrawal", ctx do
      conn = write(ctx, "/artifacts", withdrawal("screenshot", "scenario-2"))
      assert signed_answer?(conn)

      assert json_response(conn, 409) == %{
               "error" => "no_version",
               "type" => "screenshot",
               "message" =>
                 "Withdraw only a stored artifact. screenshot/scenario-2 has no version outside cancelled runs."
             }

      store!(ctx, "screenshot", [file("one.png", "image/png", @png)], name: "scenario-2")

      conn =
        write(
          ctx,
          "/artifacts",
          push_body("screenshot", [{"scenario-2.png", "image/png", @png}], %{
            "name" => "scenario-2",
            "withdraw" => true
          })
        )

      assert json_response(conn, 422) == %{
               "error" => "withdrawal_with_files",
               "type" => "screenshot",
               "message" =>
                 "Push either files or a withdrawal. A withdrawal of screenshot/scenario-2 " <>
                   "stores no files, and the push has 1 file."
             }

      assert write(ctx, "/artifacts", withdrawal("screenshot", "scenario-2")).status == 201
      conn = write(ctx, "/artifacts", withdrawal("screenshot", "scenario-2"))

      assert json_response(conn, 409) == %{
               "error" => "already_withdrawn",
               "type" => "screenshot",
               "message" =>
                 "Leave screenshot/scenario-2 as it is. Its newest version, v2, is already a " <>
                   "withdrawal."
             }

      # Only the one withdrawal was stored.
      assert [%{number: 2, withdrawn: true}] = RunApiStubs.pushed()

      numbers =
        for artifact <- json_response(read(ctx, "/artifacts"), 200)["artifacts"],
            into: %{},
            do: {artifact["name"], artifact["newest_version"]}

      assert numbers == %{"scenario-2" => 2}
    end

    test "refuses each type Qory Apiary reads itself, before the files", ctx do
      for type <- ~w(questions review-comments verdict proposal) do
        for body <- [
              withdrawal(type, "main"),
              push_body(type, [{"a.json", "application/json", "{}"}], %{"withdraw" => true})
            ] do
          conn = write(ctx, "/artifacts", body)
          assert signed_answer?(conn)

          assert json_response(conn, 422) == %{
                   "error" => "type_not_withdrawable",
                   "type" => type,
                   "message" =>
                     "Push a new version of #{type} instead. Qory Apiary reads questions, " <>
                       "review-comments, verdict and proposal itself, so a run cannot " <>
                       "withdraw them."
                 }
        end
      end

      assert RunApiStubs.pushed() == []
    end

    test "refuses a custom type with withdrawable false, before the files", ctx do
      {:ok, _type} =
        Apiary.Artifacts.insert_template_type(ctx.scope, ctx.work_item_workspace, %{
          "name" => "demo-script",
          "base_view" => "file",
          "withdrawable" => false
        })

      store!(ctx, "demo-script", [file("one.txt", "text/plain", "a")], name: "scenario-2")

      for body <- [
            withdrawal("demo-script", "scenario-2"),
            push_body("demo-script", [{"a.txt", "text/plain", "a"}], %{
              "name" => "scenario-2",
              "withdraw" => true
            })
          ] do
        conn = write(ctx, "/artifacts", body)
        assert signed_answer?(conn)

        assert json_response(conn, 422) == %{
                 "error" => "type_not_withdrawable",
                 "type" => "demo-script",
                 "message" =>
                   "Push a new version of demo-script instead. The artifact type " <>
                     "demo-script has withdrawable set to false, so a run cannot withdraw " <>
                     "its names."
               }
      end

      assert RunApiStubs.pushed() == []
    end

    # The run's process version has the submit step `submit`, as a template's does.
    defp submits!(ctx, submit) do
      version = Apiary.Processes.version_for(ctx.work_item)

      {1, _rows} =
        Repo.update_all(from(v in Apiary.Processes.Version, where: v.id == ^version.id),
          set: [template: %{"commit" => String.duplicate("a", 40), "submit" => submit}]
        )

      {1, _rows} =
        Repo.update_all(from(d in DispatchRun, where: d.id == ^ctx.dispatch_run.id),
          set: [process_version_id: version.id]
        )

      :ok
    end

    test "refuses the type in submit.type of the run's process version, before the files",
         ctx do
      file_type!(ctx, "demo-submission", 1000, 2)
      submits!(ctx, %{"type" => "demo-submission", "send" => "end_of_run"})

      store!(ctx, "demo-submission", [file("one.txt", "text/plain", "a")], name: "main")

      for body <- [
            withdrawal("demo-submission", "main"),
            push_body("demo-submission", [{"a.txt", "text/plain", "a"}], %{
              "name" => "main",
              "withdraw" => true
            })
          ] do
        conn = write(ctx, "/artifacts", body)
        assert signed_answer?(conn)

        assert json_response(conn, 422) == %{
                 "error" => "type_not_withdrawable",
                 "type" => "demo-submission",
                 "message" =>
                   "Push a new version of demo-submission instead. Qory Apiary reads its " <>
                     "newest version as the run's submission, so a run cannot withdraw it."
               }
      end

      assert RunApiStubs.pushed() == []
    end

    test "withdraws a name of another custom type when the process has a submit type", ctx do
      file_type!(ctx, "demo-submission", 1000, 2)
      file_type!(ctx, "demo-script", 1000, 2)
      submits!(ctx, %{"type" => "demo-submission", "send" => "end_of_run"})

      store!(ctx, "demo-script", [file("one.txt", "text/plain", "a")], name: "scenario-2")

      conn = write(ctx, "/artifacts", withdrawal("demo-script", "scenario-2"))
      assert %{"artifact" => %{"version" => %{"number" => 2}}} = json_response(conn, 201)
    end

    test "withdraws a name of a type that a process with no submit does not name", ctx do
      file_type!(ctx, "demo-submission", 1000, 2)
      store!(ctx, "demo-submission", [file("one.txt", "text/plain", "a")], name: "main")

      conn = write(ctx, "/artifacts", withdrawal("demo-submission", "main"))
      assert %{"artifact" => %{"version" => %{"number" => 2}}} = json_response(conn, 201)
    end

    test "refuses a standard type its template sets withdrawable false for", ctx do
      store!(ctx, "mockup", [file("one.png", "image/png", @png)], name: "home")

      # Before the lock, a run withdraws the name; a lock on another name leaves it.
      {1, _rows} =
        Repo.update_all(
          from(w in Apiary.Organisations.Workspace, where: w.id == ^ctx.work_item.workspace_id),
          set: [locked_standard_types: ["screenshot"]]
        )

      assert write(ctx, "/artifacts", withdrawal("mockup", "home")).status == 201
      store!(ctx, "mockup", [file("two.png", "image/png", @png)], name: "home")

      {1, _rows} =
        Repo.update_all(
          from(w in Apiary.Organisations.Workspace, where: w.id == ^ctx.work_item.workspace_id),
          set: [locked_standard_types: ["mockup"]]
        )

      conn = write(ctx, "/artifacts", withdrawal("mockup", "home"))
      assert signed_answer?(conn)

      assert json_response(conn, 422) == %{
               "error" => "type_not_withdrawable",
               "type" => "mockup",
               "message" =>
                 "Push a new version of mockup instead. The artifact type mockup has " <>
                   "withdrawable set to false, so a run cannot withdraw its names."
             }
    end

    test "withdraws a name of a custom type that sets no withdrawable", ctx do
      file_type!(ctx, "demo-script", 1000, 2)
      store!(ctx, "demo-script", [file("one.txt", "text/plain", "a")], name: "scenario-2")

      conn = write(ctx, "/artifacts", withdrawal("demo-script", "scenario-2"))
      assert %{"artifact" => %{"version" => %{"number" => 2}}} = json_response(conn, 201)
    end

    test "refuses a name whose newest version a person approved, before the other 409s",
         ctx do
      version =
        store!(ctx, "screenshot", [file("one.png", "image/png", @png)], name: "scenario-2")

      decide!(ctx, :approve, versions: [version.public_id])

      conn = write(ctx, "/artifacts", withdrawal("screenshot", "scenario-2"))
      assert signed_answer?(conn)

      assert json_response(conn, 422) == %{
               "error" => "type_not_withdrawable",
               "type" => "screenshot",
               "message" =>
                 "Push a new version of screenshot/scenario-2 instead. A member approved its " <>
                   "newest version, v1, so a run cannot withdraw the name."
             }

      # A name with no version is still 409 no_version.
      conn = write(ctx, "/artifacts", withdrawal("screenshot", "scenario-3"))
      assert json_response(conn, 409)["error"] == "no_version"
      assert RunApiStubs.pushed() == []
    end

    test "withdraws a name whose approval is automatic or of an older version", ctx do
      automatic = store!(ctx, "screenshot", [file("a.png", "image/png", @png)], name: "auto")
      decide!(ctx, :approve, versions: [automatic.public_id], user_id: nil, automatic: true)

      assert write(ctx, "/artifacts", withdrawal("screenshot", "auto")).status == 201

      older = store!(ctx, "screenshot", [file("b.png", "image/png", @png)], name: "older")
      decide!(ctx, :approve, versions: [older.public_id])
      store!(ctx, "screenshot", [file("b.png", "image/png", @png <> "b")], name: "older")

      conn = write(ctx, "/artifacts", withdrawal("screenshot", "older"))
      assert %{"artifact" => %{"version" => %{"number" => 3}}} = json_response(conn, 201)
    end

    test "withdraws a name when a person only requested changes", ctx do
      version = store!(ctx, "screenshot", [file("a.png", "image/png", @png)], name: "asked")
      decide!(ctx, :request_changes, versions: [version.public_id])

      assert write(ctx, "/artifacts", withdrawal("screenshot", "asked")).status == 201
    end

    test "a withdrawal by a run that ended or that a member cancelled is 409 run_ended",
         ctx do
      store!(ctx, "screenshot", [file("one.png", "image/png", @png)], name: "scenario-2")

      # Running, as a member can cancel it, then cancelled.
      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id),
          set: [state: "running", started_at: DateTime.utc_now()]
        )

      {:ok, _cancelled} = Apiary.Runs.cancel(ctx.scope, Repo.get!(Run, ctx.run.id))
      conn = write(ctx, "/artifacts", withdrawal("screenshot", "scenario-2"))

      assert json_response(conn, 409) == %{
               "error" => "run_ended",
               "message" =>
                 "The run was cancelled, so it can no longer push artifacts or give a verdict."
             }

      # Ended, with no cancel.
      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id),
          set: [cancel_requested_at: nil, cancel_requested_by_id: nil]
        )

      end_run!(ctx)
      conn = write(ctx, "/artifacts", withdrawal("screenshot", "scenario-2"))

      assert json_response(conn, 409) == %{
               "error" => "run_ended",
               "message" =>
                 "The run has ended, so it can no longer push artifacts or give a verdict."
             }

      assert RunApiStubs.pushed() == []
    end

    test "a type the workspace does not have is refused before the files", ctx do
      conn =
        write(
          ctx,
          "/artifacts",
          push_body("demo-findings", [{"a.json", "application/json", "{}"}], %{
            "withdraw" => true
          })
        )

      assert %{"error" => "unknown_type", "type" => "demo-findings"} = json_response(conn, 422)
    end

    test "the stage's output leaves out a withdrawn name; a push of files lists it again",
         ctx do
      # Explore, on a process version whose Explore has the output screenshot too.
      document = Apiary.Processes.default_document("software")
      [explore | rest] = document["stages"]

      explore =
        Map.update!(explore, "outputs", &(&1 ++ [%{"type" => "screenshot", "required" => false}]))

      {:ok, version} =
        Apiary.Processes.save(ctx.scope, ctx.work_item_workspace, %{
          document
          | "stages" => [explore | rest]
        })

      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^ctx.work_item.id),
          set: [process_version_id: version.id]
        )

      place!(ctx)

      outputs = fn ->
        Enum.filter(
          json_response(read(ctx, "/work-item"), 200)["outputs"],
          &(&1["type"] == "screenshot")
        )
      end

      assert write(ctx, "/artifacts", screenshot("a", @png <> "a")).status == 201
      assert write(ctx, "/artifacts", screenshot("b", @png <> "b")).status == 201
      [a, b] = RunApiStubs.pushed()

      assert [%{"type" => "screenshot", "version" => %{"id" => id}, "check" => "passed"}] =
               outputs.()

      assert id == b.public_id

      # b withdrawn: the output is a's version.
      assert write(ctx, "/artifacts", withdrawal("screenshot", "b")).status == 201
      assert [%{"version" => %{"id" => id}, "check" => "passed"}] = outputs.()
      assert id == a.public_id

      # Both withdrawn: no version, and the Exists check fails.
      assert write(ctx, "/artifacts", withdrawal("screenshot", "a")).status == 201
      assert [%{"version" => nil, "check" => "missing"}] = outputs.()

      # A push of files lists b again.
      assert write(ctx, "/artifacts", screenshot("b", @png <> "c")).status == 201
      again = List.last(RunApiStubs.pushed())
      assert again.number == 3

      assert [%{"version" => %{"id" => id, "number" => 3}, "check" => "passed"}] = outputs.()
      assert id == again.public_id
    end
  end

  describe "the types a run pushes" do
    defp set_workflow!(ctx, workflow) do
      {1, _rows} =
        Repo.update_all(from(d in DispatchRun, where: d.id == ^ctx.dispatch_run.id),
          set: [workflow: workflow]
        )
    end

    defp stored?(ctx, type, version),
      do: Apiary.Artifacts.newest(ctx.work_item, type, "main").public_id == version

    test "a run with a declared workflow pushes a type that no list names, and it is stored",
         ctx do
      set_workflow!(ctx, "explore-a-ticket")

      assert %{name: "explore-a-ticket"} =
               Apiary.Processes.workflow_declaration(ctx.work_item_workspace, "explore-a-ticket")

      conn = write(ctx, "/artifacts", push_body("explainer", [{"a.md", "text/markdown", "x"}]))
      version = json_response(conn, 201)["artifact"]["version"]["id"]
      assert stored?(ctx, "explainer", version)
    end

    test "a run of a workflow the harness does not declare stores the type too", ctx do
      set_workflow!(ctx, "capture-demo")
      assert Apiary.Processes.workflow_declaration(ctx.work_item_workspace, "capture-demo") == nil

      conn = write(ctx, "/artifacts", push_body("explainer", [{"a.md", "text/markdown", "x"}]))
      version = json_response(conn, 201)["artifact"]["version"]["id"]
      assert stored?(ctx, "explainer", version)
    end
  end

  describe "POST verdict" do
    test "stores the verdict as a verdict artifact", ctx do
      points = [%{"text" => "The ticket has no steps.", "action" => "run_again"}]
      conn = write(ctx, "/verdict", %{"verdict" => "escalate", "points" => points})

      assert signed_answer?(conn)
      [version] = RunApiStubs.pushed()

      assert json_response(conn, 201)["artifact"] == %{
               "type" => "verdict",
               "name" => "main",
               "version" => %{"id" => version.public_id, "number" => 1}
             }

      assert [%{filename: "verdict.json", content_type: "application/json", content: content}] =
               version.files

      assert Jason.decode!(content) == %{"verdict" => "escalate", "points" => points}
    end

    test "a verdict that is not one of the three, or a member it does not define, is 400", ctx do
      for {body, member} <- [
            {%{"verdict" => "approved"}, "verdict"},
            {%{}, "verdict"},
            {%{"verdict" => "passed", "gaps" => "No test."}, "gaps"},
            {%{"verdict" => "passed", "type" => "verdict"}, "type"}
          ] do
        conn = write(ctx, "/verdict", body)
        assert json_response(conn, 400) == %{"error" => "invalid_request", "names" => [member]}
      end

      assert RunApiStubs.pushed() == []
    end

    test "a changes-requested verdict with run_again points is stored with them", ctx do
      points = [%{"text" => "The ticket has no steps.", "action" => "run_again"}]
      body = %{"verdict" => "changes-requested", "points" => points}
      assert write(ctx, "/verdict", body).status == 201
      assert [%{files: [%{content: content}]}] = RunApiStubs.pushed()
      assert Jason.decode!(content) == body
    end

    test "a fix on an answer point is 422 invalid_artifact", ctx do
      points = [
        %{
          "text" => "Which basket gets the sale?",
          "action" => "answer",
          "question" => "q2",
          "fix" => "Answer it on the Explore tab."
        }
      ]

      conn = write(ctx, "/verdict", %{"verdict" => "escalate", "points" => points})

      assert json_response(conn, 422) == %{
               "error" => "invalid_artifact",
               "names" => ["files[0]"],
               "message" =>
                 "Fix verdict.json to match the format of verdict: at #/points/0, " <>
                   "property 'fix' is not allowed."
             }

      assert RunApiStubs.pushed() == []
    end

    test "a verdict without points is stored without the member, as its schema takes it",
         ctx do
      assert write(ctx, "/verdict", %{"verdict" => "passed"}).status == 201
      assert [%{files: [%{content: content}]}] = RunApiStubs.pushed()
      assert Jason.decode!(content) == %{"verdict" => "passed"}
    end

    test "a full_suite is stored in the verdict's file as the run sent it", ctx do
      suite = %{
        "state" => "failed",
        "passed" => 9,
        "failed" => 2,
        "skipped" => 0,
        "minutes" => 12.5
      }

      assert write(ctx, "/verdict", %{"verdict" => "passed", "full_suite" => suite}).status ==
               201

      assert [%{files: [%{content: content}]}] = RunApiStubs.pushed()
      assert Jason.decode!(content) == %{"verdict" => "passed", "full_suite" => suite}

      # Minutes alone are a result: the counts come all three or not at all.
      only_minutes = %{"state" => "passed", "minutes" => 3}

      assert write(ctx, "/verdict", %{"verdict" => "passed", "full_suite" => only_minutes}).status ==
               201

      assert [_first, %{files: [%{content: content}]}] = RunApiStubs.pushed()
      assert Jason.decode!(content) == %{"verdict" => "passed", "full_suite" => only_minutes}

      # A null is stored as no member.
      assert write(ctx, "/verdict", %{"verdict" => "passed", "full_suite" => nil}).status == 201
      assert [_first, _second, %{files: [%{content: content}]}] = RunApiStubs.pushed()
      assert Jason.decode!(content) == %{"verdict" => "passed"}
    end

    test "a full_suite the schema refuses is 422 invalid_artifact", ctx do
      counts = %{"passed" => 1, "failed" => 0, "skipped" => 0, "minutes" => 1}

      for suite <- [
            %{"state" => "not_run"},
            %{"state" => "not_run", "reason" => "No test command.", "passed" => 1},
            Map.merge(counts, %{"state" => "passed", "passed" => -1}),
            Map.merge(counts, %{"state" => "passed", "reason" => "x"}),
            %{"state" => "passed", "minutes" => 1, "passed" => 1, "failed" => 0},
            %{"state" => "unknown"},
            "passed"
          ] do
        conn = write(ctx, "/verdict", %{"verdict" => "passed", "full_suite" => suite})

        assert %{"error" => "invalid_artifact", "names" => ["files[0]"], "message" => message} =
                 json_response(conn, 422)

        assert message =~ "Fix verdict.json to match the format of verdict: at #/full_suite"
      end

      assert RunApiStubs.pushed() == []
    end

    test "a pushed verdict artifact whose value is not one of the three is 422, as Apiary.Artifacts refuses it",
         ctx do
      body =
        push_body("verdict", [
          {"verdict.json", "application/json", ~s({"verdict":"approved"})}
        ])

      conn = write(ctx, "/artifacts", body)

      assert json_response(conn, 422) == %{
               "error" => "invalid_artifact",
               "names" => ["files[0]"],
               "message" =>
                 "Fix verdict.json to match the format of verdict: at #/verdict, " <>
                   ~s(value must be one of the enum values: "passed", "changes-requested" or ) <>
                   ~s("escalate".)
             }

      assert RunApiStubs.pushed() == []

      body =
        push_body("verdict", [
          {"verdict.json", "application/json", ~s({"verdict":"changes-requested"})}
        ])

      assert write(ctx, "/artifacts", body).status == 201
    end

    test "a pushed verdict artifact with points null is 422, as Apiary.Artifacts refuses it",
         ctx do
      body =
        push_body("verdict", [
          {"verdict.json", "application/json", ~s({"verdict":"passed","points":null})}
        ])

      conn = write(ctx, "/artifacts", body)
      assert json_response(conn, 422)["error"] == "invalid_artifact"
      assert RunApiStubs.pushed() == []
    end

    test "a body over 64 KiB is 413", ctx do
      text = String.duplicate("x", Body.max_bytes(:verdict))
      points = [%{"text" => text, "action" => "run_again"}]
      conn = write(ctx, "/verdict", %{"verdict" => "escalate", "points" => points})
      assert json_response(conn, 413) == %{"error" => "payload_too_large"}
    end

    test "points the schema refuses are 422 invalid_artifact", ctx do
      run_again = %{"text" => "The ticket has no steps.", "action" => "run_again"}

      for body <- [
            %{"verdict" => "escalate"},
            %{"verdict" => "passed", "points" => [run_again]},
            %{"verdict" => "escalate", "points" => []},
            %{"verdict" => "escalate", "points" => 3},
            %{"verdict" => "escalate", "points" => List.duplicate(run_again, 21)},
            %{"verdict" => "escalate", "points" => [%{run_again | "text" => ""}]},
            %{"verdict" => "escalate", "points" => [%{run_again | "text" => "a\u202Eb"}]},
            %{"verdict" => "escalate", "points" => [%{run_again | "text" => "a\nb"}]},
            %{
              "verdict" => "escalate",
              "points" => [%{run_again | "text" => String.duplicate("x", 501)}]
            },
            %{"verdict" => "escalate", "points" => [%{run_again | "action" => "answer"}]},
            %{"verdict" => "escalate", "points" => [Map.put(run_again, "question", "q1")]},
            %{"verdict" => "escalate", "points" => [Map.put(run_again, "note", "x")]},
            %{
              "verdict" => "changes-requested",
              "points" => [%{"text" => "Which basket?", "action" => "answer", "question" => "q1"}]
            }
          ] do
        conn = write(ctx, "/verdict", body)
        assert json_response(conn, 422)["error"] == "invalid_artifact", inspect(body)
      end

      assert RunApiStubs.pushed() == []
    end

    test "an answer point is taken only about a question open in the current take in", ctx do
      answer =
        &%{"text" => "The ticket names two baskets.", "action" => "answer", "question" => &1}

      run_again = %{"text" => "The ticket has no steps.", "action" => "run_again"}

      not_open = fn point, question ->
        "Push the questions first, or point at an open question in verdict.json: " <>
          "point #{point} is about question #{question}, which is not open."
      end

      # With no questions pushed, no question is open.
      conn = write(ctx, "/verdict", %{"verdict" => "escalate", "points" => [answer.("q1")]})
      assert %{"error" => "invalid_artifact", "message" => message} = json_response(conn, 422)
      assert message == not_open.(1, "q1")

      questions = %{
        "questions" => [
          %{
            "id" => "q1",
            "question" => "Which basket gets the sale?",
            "options" => [],
            "state" => "open",
            "asked" => %{"run" => ctx.run.number, "at" => "2026-11-08T10:00:00Z"}
          }
        ]
      }

      conn =
        write(
          ctx,
          "/artifacts",
          push_body("questions", [
            {"questions.json", "application/json", Jason.encode!(questions)}
          ])
        )

      assert conn.status == 201

      conn =
        write(ctx, "/verdict", %{"verdict" => "escalate", "points" => [run_again, answer.("q1")]})

      assert conn.status == 201

      # An id that is no question of the newest version is not open either.
      conn =
        write(ctx, "/verdict", %{"verdict" => "escalate", "points" => [run_again, answer.("q7")]})

      assert %{"error" => "invalid_artifact", "message" => message} = json_response(conn, 422)
      assert message == not_open.(2, "q7")
    end
  end

  describe "POST verdict with a track (A-23)" do
    @tracks [
      %{"id" => "standard", "name" => "Standard"},
      %{"id" => "fast-track", "name" => "Fast track"}
    ]
    @track %{"id" => "fast-track", "reason" => "The change touches one file."}

    # The run placed in Explore, whose gate offers the tracks `ids` of the process.
    defp offering!(ctx, ids) do
      document =
        "software"
        |> Apiary.Processes.default_document()
        |> Map.put("tracks", @tracks)
        |> ApiaryWeb.StagesLive.Draft.update_stage(@explore, fn stage ->
          %{stage | "gate" => Map.put(stage["gate"], "tracks", ids)}
        end)

      {:ok, version} = Apiary.Processes.save(ctx.scope, ctx.work_item_workspace, document)

      {1, _rows} =
        Repo.update_all(from(r in DispatchRun, where: r.id == ^ctx.dispatch_run.id),
          set: [process_version_id: version.id, stage_id: @explore]
        )

      # The gate is the one of the work item's version.
      {1, _rows} =
        Repo.update_all(from(w in WorkItem, where: w.id == ^ctx.work_item.id),
          set: [process_version_id: version.id]
        )
    end

    test "stores a track the gate offers in the verdict's file", ctx do
      offering!(ctx, ["standard", "fast-track"])
      conn = write(ctx, "/verdict", %{"verdict" => "passed", "track" => @track})

      assert conn.status == 201
      [version] = RunApiStubs.pushed()
      assert [%{content: content}] = version.files
      assert Jason.decode!(content) == %{"verdict" => "passed", "track" => @track}
    end

    test "a track the gate does not offer is 422 invalid_artifact for track, the fix first",
         ctx do
      offering!(ctx, ["standard"])
      conn = write(ctx, "/verdict", %{"verdict" => "passed", "track" => @track})

      assert %{"error" => "invalid_artifact", "names" => ["track"], "message" => message} =
               json_response(conn, 422)

      assert message ==
               "Set track.id to a track that the gate of Explore offers (standard), or leave track out of the verdict. The track fast-track is not offered."

      assert RunApiStubs.pushed() == []
    end

    test "a gate that offers no track, and a run in no stage, refuse a track", ctx do
      offering!(ctx, [])
      conn = write(ctx, "/verdict", %{"verdict" => "passed", "track" => @track})

      assert %{"names" => ["track"], "message" => message} = json_response(conn, 422)
      assert message == "Leave track out of the verdict: the gate of Explore offers no track."

      # A stage the version does not have offers no track.
      {1, _rows} =
        Repo.update_all(from(r in DispatchRun, where: r.id == ^ctx.dispatch_run.id),
          set: [stage_id: "st_zzzzzzzzzz"]
        )

      conn = write(ctx, "/verdict", %{"verdict" => "passed", "track" => @track})

      assert %{
               "message" =>
                 "Leave track out of the verdict: the gate of the run's stage offers no track."
             } =
               json_response(conn, 422)

      # A run with no stage is a run of Explore: its gate is Explore's.
      {1, _rows} =
        Repo.update_all(from(r in DispatchRun, where: r.id == ^ctx.dispatch_run.id),
          set: [stage_id: nil]
        )

      conn = write(ctx, "/verdict", %{"verdict" => "passed", "track" => @track})
      assert %{"message" => message} = json_response(conn, 422)
      assert message == "Leave track out of the verdict: the gate of Explore offers no track."
    end

    test "a verdict pushed as an artifact is checked as POST verdict is", ctx do
      offering!(ctx, ["standard"])

      file = fn track ->
        {"verdict.json", "application/json",
         Jason.encode!(%{"verdict" => "passed", "track" => track})}
      end

      conn = write(ctx, "/artifacts", push_body("verdict", [file.(@track)]))

      assert %{"error" => "invalid_artifact", "names" => ["track"], "message" => message} =
               json_response(conn, 422)

      assert message ==
               "Set track.id to a track that the gate of Explore offers (standard), or leave track out of the verdict. The track fast-track is not offered."

      assert RunApiStubs.pushed() == []

      offered = %{"id" => "standard", "reason" => "The usual change."}
      assert write(ctx, "/artifacts", push_body("verdict", [file.(offered)])).status == 201
    end

    test "a track the schema refuses is the schema's, with no id echoed", ctx do
      offering!(ctx, ["standard"])
      long = String.duplicate("a", 5_000)

      for id <- [long, "Fast Track", 7] do
        conn =
          write(ctx, "/verdict", %{
            "verdict" => "passed",
            "track" => %{"id" => id, "reason" => "x"}
          })

        assert %{"names" => names, "message" => message} = json_response(conn, 422)
        assert message =~ "verdict.json"
        refute message =~ long
        assert names == ["files[0]"]
      end
    end

    test "a verdict file that is not JSON is 422 invalid_artifact, as before", ctx do
      offering!(ctx, ["standard"])

      conn =
        write(
          ctx,
          "/artifacts",
          push_body("verdict", [{"verdict.json", "application/json", "{not json"}])
        )

      assert %{"error" => "invalid_artifact", "names" => ["files[0]"]} = json_response(conn, 422)
      assert RunApiStubs.pushed() == []
    end

    test "a null track is no track, and is stored without the member", ctx do
      offering!(ctx, ["standard"])
      assert write(ctx, "/verdict", %{"verdict" => "passed", "track" => nil}).status == 201
      [version] = RunApiStubs.pushed()
      assert [%{content: content}] = version.files
      assert Jason.decode!(content) == %{"verdict" => "passed"}
    end

    test "a verdict with no track is stored as before where the gate offers tracks", ctx do
      offering!(ctx, ["standard", "fast-track"])
      assert write(ctx, "/verdict", %{"verdict" => "passed"}).status == 201
      [version] = RunApiStubs.pushed()
      assert [%{content: content}] = version.files
      assert Jason.decode!(content) == %{"verdict" => "passed"}
    end

    test "a track of another form is the schema's to refuse, at files[0]", ctx do
      offering!(ctx, ["standard", "fast-track"])

      for track <- [
            %{"id" => "fast-track"},
            %{"id" => "fast-track", "reason" => ""},
            %{"id" => "fast-track", "reason" => "ok", "value" => 1},
            "fast-track"
          ] do
        conn = write(ctx, "/verdict", %{"verdict" => "passed", "track" => track})

        assert %{"error" => "invalid_artifact", "names" => ["files[0]"]} =
                 json_response(conn, 422)
      end
    end
  end

  describe "GET resume/transcript" do
    @transcript_path "~/.claude/projects/-workspace/5f2c9a1e.jsonl"

    # The paused run that `ctx`'s run continues: a registered run of `:scope` (`ctx`'s by
    # default), of `ctx`'s work item, take in and stage unless `:same_item` is false, then
    # of another work item of that scope, ended Paused, with the transcript chunks
    # `chunks`, each `{sequence, offset, bytes}`. `ctx`'s run becomes its second attempt,
    # with the `resume` its claim stores (`Apiary.Runs.Transcript.resume_at_claim/1`).
    defp paused!(ctx, chunks, opts \\ []) do
      scope = Keyword.get(opts, :scope, ctx.scope)

      work_item =
        if Keyword.get(opts, :same_item, true),
          do: ctx.work_item,
          else: Apiary.WorkItemsFixtures.work_item_fixture(scope)

      {1, _rows} =
        Repo.update_all(from(d in DispatchRun, where: d.id == ^ctx.dispatch_run.id),
          set: [attempt: 2, of: ctx.dispatch_run.of + 1]
        )

      paused =
        %DispatchRun{
          organisation_id: work_item.organisation_id,
          workspace_id: work_item.workspace_id
        }
        |> DispatchRun.queue_changeset(%{
          work_item_id: work_item.id,
          step: ctx.dispatch_run.step,
          take_in: work_item.take_in || ctx.dispatch_run.take_in,
          attempt: 1,
          of: ctx.dispatch_run.of,
          queued_at: ctx.dispatch_run.queued_at
        })
        |> Ecto.Changeset.change(
          state: :ended,
          end_cause: :run_ended,
          stage_id: ctx.dispatch_run.stage_id
        )
        |> Repo.insert!()

      {1, _rows} =
        Repo.update_all(from(d in DispatchRun, where: d.id == ^ctx.dispatch_run.id),
          set: [continues_id: paused.id]
        )

      run =
        Apiary.RunEventsFixtures.run_fixture(scope, %{
          dispatch_run_id: paused.id,
          projected_sequence: 1,
          registered_at: DateTime.utc_now(),
          registration_labels: %{},
          registration_about: %{},
          registration_digest: :crypto.hash(:sha256, "registration"),
          registration_interval_seconds: 30,
          registration_answer_digest: Apiary.Policy.Render.digest(~s({"version":1})),
          state: "paused",
          exit_state: "paused",
          exit_reason: "model_key_limit",
          exited_at: DateTime.utc_now()
        })

      for {sequence, offset, bytes} <- chunks do
        Repo.insert!(%Apiary.Runs.SessionChunk{
          organisation_id: run.organisation_id,
          workspace_id: run.workspace_id,
          run_id: run.id,
          sequence: sequence,
          session: 1,
          session_id: "5f2c9a1e",
          path: @transcript_path,
          offset: offset,
          bytes: bytes
        })
      end

      resume = %{
        "run_id" => run.node_run_id,
        "session_id" => "5f2c9a1e",
        "path" => @transcript_path
      }

      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id), set: [resume: resume])

      Repo.get!(Run, run.id)
    end

    @lines [{3, 0, ~s({"a":1}\n)}, {5, 8, ~s({"b":2}\n)}]

    test "is the paused run's transcript, signed, as NDJSON", ctx do
      paused!(ctx, @lines)
      conn = read(ctx, "/resume/transcript")

      assert response(conn, 200) == ~s({"a":1}\n{"b":2}\n)
      assert signed_answer?(conn)
      assert get_resp_header(conn, "content-type") == ["application/x-ndjson"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end

    # The route belongs to the run endpoint's feature, as `run.url` does, so a run that
    # registered reads its transcript whether `workflow_model` is on or off.
    test "belongs to observability, and answers with workflow_model off", ctx do
      assert ApiaryWeb.Contract.TranscriptController.__feature__() == :observability
      RunApiStubs.put(:flag, false)
      paused!(ctx, @lines)

      assert response(read(ctx, "/resume/transcript"), 200) == ~s({"a":1}\n{"b":2}\n)
    end

    test "an unsigned request is 401, with no transcript", ctx do
      paused!(ctx, @lines)
      conn = get(build_conn(), "/v1/runs/#{ctx.run.node_run_id}/resume/transcript")
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "another run's key, another run's id and the paused run are the same 404", ctx do
      paused = paused!(ctx, @lines)
      other = other_run()

      answers =
        for conn <- [
              read(ctx, "/resume/transcript", key: other.key),
              read(ctx, "/resume/transcript", run_id: other.run.node_run_id),
              read(ctx, "/resume/transcript", run_id: paused.node_run_id),
              read(ctx, "/resume/transcript", run_id: Ecto.UUID.generate())
            ] do
          assert signed_answer?(conn)
          {conn.status, conn.resp_body}
        end

      assert Enum.uniq(answers) == [{404, ~s({"error":"not_found"})}]
    end

    test "an error while the chunks are sent ends the answer, with one log line", ctx do
      paused!(ctx, [{3, 0, ~s({"a":1}\n)}, {5, 8, ~s({"b":2}\n)}, {7, 16, ~s({"c":3}\n)}])

      # The second chunk's read raises (`ApiaryWeb.TranscriptStub`).
      ApiaryWeb.TranscriptStub.fail_at(1)

      {conn, log} = ExUnit.CaptureLog.with_log(fn -> read(ctx, "/resume/transcript") end)

      # The status went with the first chunk; the answer stops at the failure, and the
      # chunk after it is not taken.
      assert conn.status == 200
      assert conn.halted
      assert conn.resp_body == ~s({"a":1}\n)
      assert_received {:transcript_pulled, ~s({"a":1}\n)}
      refute_received {:transcript_pulled, _bytes}
      assert log =~ "a transcript stopped while it was sent: RuntimeError"
      refute log =~ ~s({"a":1})
    end

    test "a run that Apiary.Access does not let the key post for is 404", ctx do
      paused!(ctx, @lines)
      assert read(ctx, "/resume/transcript").status == 200

      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ServesNoRun)
      conn = read(ctx, "/resume/transcript")
      assert conn.status == 404
      assert conn.resp_body == ~s({"error":"not_found"})
    end

    test "a run whose claim stored no resume is 404, though it continues a paused run", ctx do
      paused!(ctx, @lines)
      {1, _rows} = Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id), set: [resume: nil])
      assert read(ctx, "/resume/transcript").status == 404
    end

    test "a run that continues no paused run is 404", ctx do
      assert read(ctx, "/resume/transcript").resp_body == ~s({"error":"not_found"})
      assert read(ctx, "/resume/transcript").status == 404
    end

    test "a paused run of another organisation is 404", ctx do
      %{scope: other} = sign_up_fixture()
      paused!(ctx, @lines, scope: other, same_item: false)
      assert read(ctx, "/resume/transcript").status == 404
    end

    test "a paused run of another work item, the one that did not queue this run, is 404",
         ctx do
      paused!(ctx, @lines, same_item: false)
      assert read(ctx, "/resume/transcript").status == 404
    end

    test "a run that ended without model_key_limit is 404", ctx do
      paused = paused!(ctx, @lines)

      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^paused.id),
          set: [state: "cancelled", exit_reason: "stopped"]
        )

      assert read(ctx, "/resume/transcript").status == 404
    end

    test "a continuation lost after its attach and not lost for good reads it", ctx do
      paused!(ctx, @lines)
      lost!(ctx, [])
      assert response(read(ctx, "/resume/transcript"), 200) == ~s({"a":1}\n{"b":2}\n)
    end

    test "a continuation lost for good is 404", ctx do
      paused!(ctx, @lines)
      silenced!(ctx)
      assert read(ctx, "/resume/transcript").status == 404
    end

    test "a continuation that ended is 404", ctx do
      paused!(ctx, @lines)
      end_run!(ctx)
      assert read(ctx, "/resume/transcript").status == 404
    end

    test "a gap in the offsets is 404, and the log has no byte of the transcript", ctx do
      paused!(ctx, [{3, 0, "first-line-xq7\n"}, {5, 99, "second-line-xq7\n"}])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn = read(ctx, "/resume/transcript")
          assert conn.status == 404
          refute conn.resp_body =~ "xq7"
        end)

      assert log =~ "reason=gap"
      refute log =~ "xq7"
    end

    test "a transcript over 64 MiB is 404", ctx do
      paused = paused!(ctx, [])
      bytes = :binary.copy("x", 32_768)
      count = div(Apiary.Runs.Transcript.max_file(), 32_768) + 1

      for batch <- Enum.chunk_every(1..count, 128) do
        Repo.insert_all(
          Apiary.Runs.SessionChunk,
          for n <- batch do
            %{
              id: Ecto.UUID.generate(),
              organisation_id: paused.organisation_id,
              workspace_id: paused.workspace_id,
              run_id: paused.id,
              sequence: n,
              session: 1,
              session_id: "5f2c9a1e",
              path: @transcript_path,
              offset: (n - 1) * 32_768,
              bytes: bytes
            }
          end
        )
      end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert read(ctx, "/resume/transcript").status == 404
        end)

      assert log =~ "reason=too_large"
    end
  end

  describe "through the whole endpoint" do
    # The body is sent as the gateway sends it: `ApiaryWeb.Contract.RawBody` reads it, and
    # nothing is assigned by hand.
    defp sent(ctx, path, body) do
      {key, seed} = ctx.key
      target = "/v1/runs/#{ctx.run.node_run_id}" <> path

      signed_post(build_conn(), key.key_id, seed, body,
        target: target,
        content_type: "application/json",
        delivery: nil
      )
    end

    test "a signed push and a signed verdict are stored", ctx do
      body = Jason.encode!(push_body("screenshot", [{"one.png", "image/png", @png}]))
      conn = sent(ctx, "/artifacts", body)
      assert signed_answer?(conn)
      assert json_response(conn, 201)["artifact"]["type"] == "screenshot"

      conn = sent(ctx, "/verdict", Jason.encode!(%{"verdict" => "passed"}))
      assert signed_answer?(conn)
      assert json_response(conn, 201)["artifact"]["type"] == "verdict"

      assert [%{artifact: %{type: "screenshot"}}, %{artifact: %{type: "verdict"}}] =
               RunApiStubs.pushed()
    end

    test "a signed push over 64 KiB is read for a gateway's key id", ctx do
      content = String.duplicate("x", 100_000)
      body = Jason.encode!(push_body("explainer", [{"a.md", "text/markdown", content}]))
      assert byte_size(body) > RawBody.max_bytes(:unauthenticated)

      conn = sent(ctx, "/artifacts", body)
      assert json_response(conn, 201)["artifact"]["type"] == "explainer"
      assert [%{files: [%{content: ^content}]}] = RunApiStubs.pushed()
    end
  end

  describe "a large body without a gateway's key id" do
    test "a Content-Length over 32 MiB is 413 before a byte is read", ctx do
      conn =
        build_conn(:post, "/v1/runs/#{ctx.run.node_run_id}/artifacts", "{}")
        |> put_req_header("content-length", Integer.to_string(RawBody.max_bytes(:run_api) + 1))
        |> RawBody.call([])

      assert conn.halted
      assert json_response(conn, 413) == %{"error" => "payload_too_large"}
      # The body is still unread.
      assert {:ok, "{}", _conn} = Plug.Conn.read_body(conn)
    end

    test "is cut off after 64 KiB, the rest left unread", ctx do
      body = String.duplicate("x", 1_000_000)

      for headers <- [
            [],
            [{"x-qory-access-key-id", "ak_unknown"}],
            [{"x-qory-signature-ed25519", "AAAA"}]
          ] do
        conn =
          Enum.reduce(
            headers,
            build_conn(:post, "/v1/runs/#{ctx.run.node_run_id}/verdict", body),
            fn {name, value}, conn -> put_req_header(conn, name, value) end
          )
          |> RawBody.call([])

        assert conn.halted
        assert json_response(conn, 413) == %{"error" => "payload_too_large"}
        assert {_state, rest, _conn} = Plug.Conn.read_body(conn, length: 2_000_000)
        assert byte_size(rest) > 900_000
        refute conn.assigns[:raw_body]
      end

      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/v1/runs/#{ctx.run.node_run_id}/artifacts", body)

      assert json_response(conn, 413) == %{"error" => "payload_too_large"}
      assert RunApiStubs.pushed() == []
    end

    test "a key id that is not of the form of a key id is 413, never looked up", ctx do
      body = String.duplicate("x", 1_000_000)
      nul = "ak_" <> <<0>> <> String.duplicate("a", 15)
      assert byte_size(nul) == 19

      for key_id <- [<<0xFF>>, nul], path <- ["artifacts", "verdict"] do
        conn =
          build_conn(:post, "/v1/runs/#{ctx.run.node_run_id}/#{path}", body)
          |> put_req_header("x-qory-access-key-id", key_id)
          |> RawBody.call([])

        assert conn.halted, inspect({key_id, path})
        assert json_response(conn, 413) == %{"error" => "payload_too_large"}
        assert {_state, rest, _conn} = Plug.Conn.read_body(conn, length: 2_000_000)
        assert byte_size(rest) > 900_000
        refute conn.assigns[:raw_body]
      end
    end
  end

  defmodule StreamStore do
    @moduledoc "The volume store, but `open/1` returns a stream of 64 KiB chunks."
    @behaviour Apiary.Artifacts.Store
    alias Apiary.Artifacts.Store.Volume

    @impl true
    defdelegate stage(source, limit), to: Volume
    @impl true
    defdelegate commit(staged), to: Volume
    @impl true
    defdelegate discard(staged), to: Volume

    @impl true
    def open(key) do
      with {:ok, path} <- Volume.open(key), do: {:ok, File.stream!(path, 65_536)}
    end
  end
end
