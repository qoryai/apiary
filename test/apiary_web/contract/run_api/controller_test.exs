defmodule ApiaryWeb.Contract.RunApi.ControllerTest do
  # The run API (`/v1/runs/<run_id>/...`): a run's reads of its work item and its
  # artifacts and its pushes, through its gateway, against the stage runner
  # (`Apiary.Stages`) and the stubs of `Apiary.Artifacts`, the declarations and the
  # feature (`ApiaryWeb.RunApiStubs`). The stubs and the features are the whole node's,
  # so the module is not async.
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
  alias Apiary.Dispatches.{DispatchRun, Inputs}
  alias Apiary.Runs.Run
  alias Apiary.Stages.{Check, GateDecision}
  alias Apiary.WorkItems.WorkItem
  alias ApiaryWeb.Contract.RawBody
  alias ApiaryWeb.Contract.RunApi.Body
  alias ApiaryWeb.RunApiStubs

  @moduletag needs: [:workflow_model, :factory, :secrets]

  # Explore, the first stage of the software process (`Apiary.Processes`).
  @explore "st_r79kph11eg"

  setup {Apiary.DataCase, :without_registry}

  setup do
    :ok = RunApiStubs.install()
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
    %{run: fixture.run, key: fixture.secrets_key, work_item_id: dispatch_run.work_item_id}
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

  defp end_run!(ctx) do
    {1, _rows} =
      Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id),
        set: [state: "completed", exited_at: DateTime.utc_now()]
      )
  end

  describe "the feature" do
    test "off: a verified request is the 404 of a path the router does not know, signed", ctx do
      RunApiStubs.put(:flag, false)

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
    test "is the work item's snapshot: ticket, stage, outputs, verdict and answers", ctx do
      place!(ctx)
      conn = read(ctx, "/work-item")
      assert signed_answer?(conn)
      body = json_response(conn, 200)

      assert body["version"] == 1
      assert body["work_item"]["id"] == ctx.work_item.public_id
      # The take in placed the work item in Explore and started its first round.
      assert body["run"] == %{
               "id" => ctx.run.node_run_id,
               "workflow" => "explore-a-ticket",
               "round" => 1
             }

      assert body["ticket"]["title"] == ctx.work_item.title
      assert is_list(body["comments"])
      assert body["comments_omitted"] == 0
      assert body["answers"] == []

      assert body["stage"] == %{
               "id" => @explore,
               "name" => "Explore",
               "round" => 1,
               "rounds" => 3,
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

      {:ok, version} =
        RunApiStubs.Artifacts.push(
          {:run, ctx.dispatch_run},
          ctx.work_item,
          "screenshot",
          [
            file("one.png", "image/png", "png")
          ],
          stage_id: @explore
        )

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
                 "kind" => "request_changes",
                 "stage_id" => @explore,
                 "by" => %{"name" => name},
                 "note" => "Add the empty cart.",
                 "artifact_version_id" => version.public_id,
                 "at" => at(first.inserted_at)
               },
               %{
                 "kind" => "move",
                 "stage_id" => @explore,
                 "by" => %{"name" => name},
                 "note" => "Back to Explore.",
                 "artifact_version_id" => nil,
                 "at" => at(second.inserted_at)
               },
               %{
                 "kind" => "check",
                 "stage_id" => @explore,
                 "by" => nil,
                 "note" => "proposal: no version of this stage.",
                 "artifact_version_id" => nil,
                 "at" => at(check.inserted_at)
               }
             ]
    end

    test "has the newest verdict with its gaps", ctx do
      assert write(ctx, "/verdict", %{"verdict" => "changes-requested", "gaps" => "No test."}).status ==
               201

      assert write(ctx, "/verdict", %{"verdict" => "passed"}).status == 201

      body = json_response(read(ctx, "/work-item"), 200)
      newest = List.last(RunApiStubs.pushed())

      assert body["verdict"] == %{
               "verdict" => "passed",
               "gaps" => nil,
               "version" => %{"id" => newest.public_id, "number" => 2}
             }
    end
  end

  describe "GET artifacts" do
    test "is the work item's index, without the files' contents", ctx do
      assert write(ctx, "/artifacts", push_body("screenshot", [{"one.png", "image/png", "png"}])).status ==
               201

      other = other_run()

      RunApiStubs.stored(other.work_item_id, "explainer", [
        file("theirs.md", "text/markdown", "x")
      ])

      conn = read(ctx, "/artifacts")
      assert signed_answer?(conn)
      body = json_response(conn, 200)

      [version] =
        Enum.filter(RunApiStubs.pushed(), &(&1.artifact.work_item_id == ctx.work_item.id))

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
                       "stage_id" => @explore,
                       "note" => nil,
                       "at" =>
                         version.inserted_at
                         |> DateTime.truncate(:second)
                         |> DateTime.to_iso8601(),
                       "files" => [
                         %{
                           "filename" => "one.png",
                           "content_type" => "image/png",
                           "size" => 3,
                           "sha256" => Base.encode16(:crypto.hash(:sha256, "png"), case: :lower)
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

      for content <- ["a", "b"] do
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
                 "stage_id" => @explore,
                 "at" => at(approval.inserted_at)
               }
             ]
    end
  end

  defp file(filename, content_type, binary),
    do: %{filename: filename, content_type: content_type, binary: binary}

  describe "GET artifacts/:version_id/files/:filename" do
    setup ctx do
      body =
        push_body("screenshot", [
          {"one.png", "image/png", "png"},
          {"page.html", "text/html", "<b>"}
        ])

      assert write(ctx, "/artifacts", body).status == 201
      %{version: List.last(RunApiStubs.pushed()).public_id}
    end

    test "is the file as a download, with nosniff", ctx do
      conn = read(ctx, "/artifacts/#{ctx.version}/files/one.png")
      assert signed_answer?(conn)
      assert response(conn, 200) == "png"
      assert get_resp_header(conn, "content-type") == ["image/png"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

      assert get_resp_header(conn, "content-disposition") == [
               ~s(attachment; filename="one.png"; filename*=UTF-8''one.png)
             ]
    end

    test "serves HTML and SVG as plain bytes, never inline", ctx do
      conn = read(ctx, "/artifacts/#{ctx.version}/files/page.html")
      assert response(conn, 200) == "<b>"
      assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
      assert ["attachment; " <> _] = get_resp_header(conn, "content-disposition")

      svg =
        RunApiStubs.stored(ctx.work_item.id, "screenshot", [
          file("a b.svg", "image/svg+xml", "<svg/>")
        ])

      conn = read(ctx, "/artifacts/#{svg.public_id}/files/a%20b.svg")
      assert response(conn, 200) == "<svg/>"
      assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

      assert get_resp_header(conn, "content-disposition") == [
               ~s(attachment; filename="a_b.svg"; filename*=UTF-8''a%20b.svg)
             ]
    end

    test "a filename that is not ASCII has one _ per character in its plain name", ctx do
      version =
        RunApiStubs.stored(ctx.work_item.id, "screenshot", [
          file("caf\u00e9 \u00fc.png", "image/png", "png")
        ])

      conn = read(ctx, "/artifacts/#{version.public_id}/files/caf%C3%A9%20%C3%BC.png")
      assert response(conn, 200) == "png"

      assert get_resp_header(conn, "content-disposition") == [
               ~s(attachment; filename="caf___.png"; filename*=UTF-8''caf%C3%A9%20%C3%BC.png)
             ]
    end

    test "another work item's version, an unknown one and a malformed id are the same 404",
         ctx do
      other = other_run()

      theirs =
        RunApiStubs.stored(other.work_item_id, "screenshot", [file("one.png", "image/png", "x")])

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

      assert response(conn, 200) == "x"
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
        push_body("screenshot", [{"one.png", "image/png", "png"}], %{
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
      assert version.opts[:writes] == :any
      assert version.opts[:stage_id] == ctx.dispatch_run.stage_id
      assert [%{filename: "one.png", content_type: "image/png", content: "png"}] = version.files
    end

    test "a body the contract refuses is 400 with the member", ctx do
      cases = [
        {"not json", "body"},
        {"[]", "body"},
        {%{"files" => []}, "type"},
        {push_body("screenshot", []), "files"},
        {push_body("screenshot", [{"a.png", "image/png", "x"}], %{"extra" => 1}), "extra"},
        {push_body("screenshot", [{"a.png", "image/png", "x"}], %{"name" => "../x"}), "name"},
        {push_body("screenshot", [{"a.png", "image/png", "x"}], %{
           "note" => "a" <> String.duplicate("\u0301", 4001)
         }), "note"},
        {push_body("screenshot", [{"a.png", "image/png", "x"}], %{"note" => "a\u0085b"}), "note"},
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

    test "a filename with a path or a control character is 400", ctx do
      for name <- ["..", ".", "../x.png", "a/b.png", "a\\b.png", "a\u0000.png", "a\n.png", ""] do
        conn = write(ctx, "/artifacts", push_body("screenshot", [{name, "image/png", "x"}]))

        assert json_response(conn, 400) == %{
                 "error" => "invalid_request",
                 "names" => ["files[0].filename"]
               },
               inspect(name)
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
      files = for n <- 1..3, do: {"#{n}.png", "image/png", "x"}
      conn = write(ctx, "/artifacts", push_body("screenshot", files))

      assert json_response(conn, 422) == %{
               "error" => "too_many_files",
               "type" => "screenshot",
               "limit" => 2,
               "message" => "The artifact type screenshot takes at most 2 files in one version."
             }

      assert RunApiStubs.pushed() == []
    end

    test "files over the type's size limit together are 422 with the type and the limit",
         ctx do
      assert write(
               ctx,
               "/artifacts",
               push_body("screenshot", [{"a.png", "image/png", String.duplicate("x", 16)}])
             ).status ==
               201

      conn =
        write(
          ctx,
          "/artifacts",
          push_body("screenshot", [{"a.png", "image/png", String.duplicate("x", 17)}])
        )

      assert json_response(conn, 422) == %{
               "error" => "too_large",
               "type" => "screenshot",
               "limit" => 16,
               "message" =>
                 "The files of one version of the artifact type screenshot take at most " <>
                   "16 bytes together."
             }

      assert length(RunApiStubs.pushed()) == 1

      # Two files of 8 and 9 bytes: each within 16, together over it.
      conn =
        write(
          ctx,
          "/artifacts",
          push_body("screenshot", [
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

    test "what the push returns is answered with the type, its limit and the member",
         ctx do
      cases = [
        {{:not_writable, "explainer"}, 403,
         %{
           "error" => "type_not_writable",
           "type" => "explainer",
           "message" =>
             "Add the artifact type explainer to the writes list of the workflow " <>
               "explore-a-ticket, " <>
               "or push a type that the workflow writes."
         }},
        {{:too_large, 900}, 422,
         %{
           "error" => "too_large",
           "type" => "explainer",
           "limit" => 900,
           "message" =>
             "The files of one version of the artifact type explainer take at most " <>
               "900 bytes together."
         }},
        {{:too_many_files, 1}, 422,
         %{
           "error" => "too_many_files",
           "type" => "explainer",
           "limit" => 1,
           "message" => "The artifact type explainer takes at most 1 file in one version."
         }},
        {{:invalid, {:format, 0}}, 422,
         %{
           "error" => "invalid_artifact",
           "names" => ["files[0]"],
           "message" => "The files do not match the format of the artifact type."
         }},
        {{:invalid, :no_video}, 422,
         %{
           "error" => "invalid_artifact",
           "names" => ["files"],
           "message" => "The files do not match the format of the artifact type."
         }},
        {{:invalid, {:filename, 0}}, 400,
         %{"error" => "invalid_request", "names" => ["files[0].filename"]}},
        {{:invalid, :note}, 400, %{"error" => "invalid_request", "names" => ["note"]}},
        {{:unknown_type, "explainer"}, 422,
         %{
           "error" => "unknown_type",
           "type" => "explainer",
           "message" =>
             "Define the artifact type explainer in the workspace's Artifact types, " <>
               "then run the round again."
         }},
        {:not_found, 404, %{"error" => "not_found"}},
        {:store_unavailable, 503, %{"error" => "unavailable"}}
      ]

      for {push_error, status, answer} <- cases do
        RunApiStubs.put(:push_error, push_error)
        conn = write(ctx, "/artifacts", push_body("explainer", [{"a.md", "text/markdown", "x"}]))
        assert signed_answer?(conn)
        assert json_response(conn, status) == answer, inspect(push_error)
      end
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

    test "a run whose run of the queue ended is 409 run_ended", ctx do
      {1, _rows} =
        Repo.update_all(from(d in DispatchRun, where: d.id == ^ctx.dispatch_run.id),
          set: [state: :ended, end_cause: :run_ended]
        )

      assert json_response(write(ctx, "/verdict", %{"verdict" => "passed"}), 409)["error"] ==
               "run_ended"
    end
  end

  describe "the workflow's writes list" do
    defp set_workflow!(ctx, workflow) do
      {1, _rows} =
        Repo.update_all(from(d in DispatchRun, where: d.id == ^ctx.dispatch_run.id),
          set: [workflow: workflow]
        )
    end

    test "a type outside it is 403 type_not_writable, with the workflow's name", ctx do
      set_workflow!(ctx, "capture-demo")
      RunApiStubs.put(:declaration, %{name: "capture-demo", writes: ["screenshot"]})

      conn = write(ctx, "/artifacts", push_body("explainer", [{"a.md", "text/markdown", "x"}]))
      assert signed_answer?(conn)

      assert json_response(conn, 403) == %{
               "error" => "type_not_writable",
               "type" => "explainer",
               "message" =>
                 "Add the artifact type explainer to the writes list of the workflow " <>
                   "capture-demo, or push a type that the workflow writes."
             }

      assert RunApiStubs.get(:declared) == "capture-demo"
      assert RunApiStubs.pushed() == []

      conn = write(ctx, "/artifacts", push_body("screenshot", [{"a.png", "image/png", "x"}]))
      assert conn.status == 201
      assert [%{opts: opts}] = RunApiStubs.pushed()
      assert opts[:writes] == ["screenshot"]

      assert write(
               ctx,
               "/artifacts",
               push_body("questions", [{"q.json", "application/json", "{}"}])
             ).status == 201
    end

    test "Apiary.Processes's declaration, whose writes list is nil: any type", ctx do
      RunApiStubs.install([:processes])
      set_workflow!(ctx, "explore-a-ticket")

      assert %{name: "explore-a-ticket", writes: nil} =
               Apiary.Processes.workflow_declaration(ctx.work_item_workspace, "explore-a-ticket")

      conn = write(ctx, "/artifacts", push_body("explainer", [{"a.md", "text/markdown", "x"}]))
      assert conn.status == 201

      # A workflow the harness does not declare: any type too.
      set_workflow!(ctx, "capture-demo")
      assert Apiary.Processes.workflow_declaration(ctx.work_item_workspace, "capture-demo") == nil
      conn = write(ctx, "/artifacts", push_body("explainer", [{"b.md", "text/markdown", "x"}]))
      assert conn.status == 201
      assert [%{opts: first}, %{opts: second}] = RunApiStubs.pushed()
      assert first[:writes] == :any
      assert second[:writes] == :any
    end
  end

  describe "POST verdict" do
    test "stores the verdict as a verdict artifact", ctx do
      conn =
        write(ctx, "/verdict", %{"verdict" => "escalate", "gaps" => "The ticket has no steps."})

      assert signed_answer?(conn)
      [version] = RunApiStubs.pushed()

      assert json_response(conn, 201)["artifact"] == %{
               "type" => "verdict",
               "name" => "main",
               "version" => %{"id" => version.public_id, "number" => 1}
             }

      assert [%{filename: "verdict.json", content_type: "application/json", content: content}] =
               version.files

      assert Jason.decode!(content) == %{
               "verdict" => "escalate",
               "gaps" => "The ticket has no steps."
             }
    end

    test "a verdict that is not one of the three, or a member it does not define, is 400", ctx do
      for {body, member} <- [
            {%{"verdict" => "approved"}, "verdict"},
            {%{}, "verdict"},
            {%{"verdict" => "passed", "gaps" => 3}, "gaps"},
            {%{"verdict" => "passed", "gaps" => "a\u009Bb"}, "gaps"},
            {%{"verdict" => "passed", "type" => "verdict"}, "type"}
          ] do
        conn = write(ctx, "/verdict", body)
        assert json_response(conn, 400) == %{"error" => "invalid_request", "names" => [member]}
      end

      assert RunApiStubs.pushed() == []
    end

    test "a body over 64 KiB is 413", ctx do
      gaps = String.duplicate("x", Body.max_bytes(:verdict))
      conn = write(ctx, "/verdict", %{"verdict" => "passed", "gaps" => gaps})
      assert json_response(conn, 413) == %{"error" => "payload_too_large"}
    end

    test "is written whatever the workflow's writes list", ctx do
      set_workflow!(ctx, "review")
      RunApiStubs.put(:declaration, %{name: "review", writes: ["explainer"]})

      conn = write(ctx, "/verdict", %{"verdict" => "passed"})
      assert json_response(conn, 201)["artifact"]["type"] == "verdict"
      assert [%{opts: opts}] = RunApiStubs.pushed()
      assert opts[:writes] == :any

      # The same declaration keeps a push of another type out.
      conn = write(ctx, "/artifacts", push_body("screenshot", [{"a.png", "image/png", "x"}]))
      assert json_response(conn, 403)["error"] == "type_not_writable"
      assert RunApiStubs.get(:declared) == "review"
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
      body = Jason.encode!(push_body("screenshot", [{"one.png", "image/png", "png"}]))
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
      RunApiStubs.put(:types, %{
        "explainer" => %{name: "explainer", size_limit: 200_000, max_files: 1}
      })

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
  end
end
