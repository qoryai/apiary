defmodule ApiaryWeb.Contract.RunApi.ControllerTest do
  # The run API (`/v1/runs/<run_id>/...`): a run's reads of its work item and its
  # artifacts and its pushes, through its gateway, against the stubs of the workflow
  # model's modules (`ApiaryWeb.RunApiStubs`). The stubs and the features are the whole
  # node's, so the module is not async.
  #
  # A POST is sent with its raw body already kept, as `ApiaryWeb.Contract.RawBody` keeps
  # the body of the run endpoint's POSTs.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.SealedRunsFixtures

  alias Apiary.Repo
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Runs.Run
  alias ApiaryWeb.Contract.RunApi.Body
  alias ApiaryWeb.RunApiStubs

  @moduletag needs: [:factory, :secrets]

  setup {Apiary.DataCase, :without_registry}

  setup do
    :ok = RunApiStubs.install()
    %{scope: scope} = sign_up_fixture()
    fixture = sealed_run_fixture(scope)
    dispatch_run = Repo.get!(DispatchRun, fixture.run.dispatch_run_id)
    work_item = Repo.get!(Apiary.WorkItems.WorkItem, dispatch_run.work_item_id)

    %{
      scope: scope,
      run: fixture.run,
      key: fixture.secrets_key,
      dispatch_run: dispatch_run,
      work_item: work_item
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

    test "the routes belong to workflow_model where the instance lists it, else to factory" do
      expected =
        if :workflow_model in Apiary.Features.all(), do: :workflow_model, else: :factory

      assert ApiaryWeb.Contract.RunApi.Controller.__feature__() == expected
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
      RunApiStubs.put(:inputs, [
        %{type: "acceptance-criteria", required: true, version: %{id: "av_x", number: 2}}
      ])

      conn = read(ctx, "/work-item")
      assert signed_answer?(conn)
      body = json_response(conn, 200)

      assert body["version"] == 1
      assert body["work_item"]["id"] == ctx.work_item.public_id
      assert body["run"] == %{"id" => ctx.run.node_run_id, "workflow" => nil, "round" => nil}
      assert body["ticket"]["title"] == ctx.work_item.title
      assert is_list(body["comments"])
      assert body["comments_omitted"] == 0
      assert body["answers"] == []

      assert body["stage"] == %{
               "id" => "st_explore00000",
               "name" => "Explore",
               "round" => 1,
               "rounds" => 3,
               "state" => "running"
             }

      assert body["inputs"] == [
               %{
                 "type" => "acceptance-criteria",
                 "required" => true,
                 "version" => %{"id" => "av_x", "number" => 2}
               }
             ]

      assert body["outputs"] == [
               %{"type" => "proposal", "required" => true, "version" => nil, "check" => "missing"}
             ]

      assert body["verdict"] == nil
      assert body["notes"] == []
      refute Map.has_key?(body, "domain")
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
               "version" => %{"id" => newest.id, "number" => 2}
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
      [version] = Enum.filter(RunApiStubs.pushed(), &(&1.work_item_id == ctx.work_item.id))

      assert body == %{
               "version" => 1,
               "artifacts" => [
                 %{
                   "type" => "screenshot",
                   "name" => "main",
                   "stage_id" => nil,
                   "approved_version" => nil,
                   "newest_version" => 1,
                   "changed_after_approval" => false,
                   "versions" => [
                     %{
                       "id" => version.id,
                       "number" => 1,
                       "writer" => %{"kind" => "run", "run_id" => nil},
                       "stage_id" => nil,
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
      %{version: List.last(RunApiStubs.pushed())}
    end

    test "is the file as a download, with nosniff", ctx do
      conn = read(ctx, "/artifacts/#{ctx.version.id}/files/one.png")
      assert signed_answer?(conn)
      assert response(conn, 200) == "png"
      assert get_resp_header(conn, "content-type") == ["image/png"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

      assert get_resp_header(conn, "content-disposition") == [
               ~s(attachment; filename="one.png"; filename*=UTF-8''one.png)
             ]
    end

    test "serves HTML and SVG as plain bytes, never inline", ctx do
      conn = read(ctx, "/artifacts/#{ctx.version.id}/files/page.html")
      assert response(conn, 200) == "<b>"
      assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
      assert ["attachment; " <> _] = get_resp_header(conn, "content-disposition")

      svg =
        RunApiStubs.stored(ctx.work_item.id, "screenshot", [
          file("a b.svg", "image/svg+xml", "<svg/>")
        ])

      conn = read(ctx, "/artifacts/#{svg.id}/files/a%20b.svg")
      assert response(conn, 200) == "<svg/>"
      assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

      assert get_resp_header(conn, "content-disposition") == [
               ~s(attachment; filename="a_b.svg"; filename*=UTF-8''a%20b.svg)
             ]
    end

    test "another work item's version, an unknown one and a malformed id are the same 404",
         ctx do
      other = other_run()

      theirs =
        RunApiStubs.stored(other.work_item_id, "screenshot", [file("one.png", "image/png", "x")])

      answers =
        for path <- [
              "/artifacts/#{theirs.id}/files/one.png",
              "/artifacts/#{Apiary.PublicId.generate("av")}/files/one.png",
              "/artifacts/not-a-version/files/one.png",
              "/artifacts/#{ctx.version.id}/files/two.png"
            ] do
          conn = read(ctx, path)
          assert signed_answer?(conn)
          {conn.status, conn.resp_body}
        end

      assert Enum.uniq(answers) == [{404, ~s({"error":"not_found"})}]

      # The other run reads its version; this run's key does not.
      conn =
        read(ctx, "/artifacts/#{theirs.id}/files/one.png",
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
        conn = read(ctx, "/artifacts/#{ctx.version.id}/files/#{name}")
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
                 "version" => %{"id" => version.id, "number" => 1}
               }
             }

      assert version.work_item_id == ctx.work_item.id
      assert {:run, %DispatchRun{id: id}} = version.actor
      assert id == ctx.dispatch_run.id
      assert version.note == "After the fix."
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

    test "a file over the type's size limit is 422 with the type and the limit", ctx do
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
               "message" => "The artifact type screenshot takes files of at most 16 bytes."
             }

      assert length(RunApiStubs.pushed()) == 1
    end

    test "a body over the size is 413 before it is decoded", ctx do
      body = String.duplicate(" ", Body.max_bytes(:push) + 1)
      conn = write(ctx, "/artifacts", body)
      assert signed_answer?(conn)
      assert json_response(conn, 413) == %{"error" => "payload_too_large"}
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

    test "what the push returns is answered with the type and its limit, never its detail",
         ctx do
      cases = [
        {{:not_writable, "detail"}, 403,
         %{
           "error" => "type_not_writable",
           "type" => "explainer",
           "message" =>
             "Add the artifact type explainer to the writes list of the workflow, " <>
               "or push a type that the workflow writes."
         }},
        {{:too_large, "detail"}, 422,
         %{
           "error" => "too_large",
           "type" => "explainer",
           "limit" => 1000,
           "message" => "The artifact type explainer takes files of at most 1000 bytes."
         }},
        {{:invalid, "detail"}, 422,
         %{
           "error" => "invalid_artifact",
           "message" => "The files do not match the format of the artifact type."
         }},
        {{:unknown_type, "detail"}, 422,
         %{
           "error" => "unknown_type",
           "type" => "explainer",
           "message" =>
             "Define the artifact type explainer in the workspace's Artifact types, " <>
               "then run the round again."
         }}
      ]

      for {push_error, status, answer} <- cases do
        RunApiStubs.put(:push_error, push_error)
        conn = write(ctx, "/artifacts", push_body("explainer", [{"a.md", "text/markdown", "x"}]))
        assert json_response(conn, status) == answer
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

  describe "POST verdict" do
    test "stores the verdict as a verdict artifact", ctx do
      conn =
        write(ctx, "/verdict", %{"verdict" => "escalate", "gaps" => "The ticket has no steps."})

      assert signed_answer?(conn)
      [version] = RunApiStubs.pushed()

      assert json_response(conn, 201)["artifact"] == %{
               "type" => "verdict",
               "name" => "main",
               "version" => %{"id" => version.id, "number" => 1}
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
      RunApiStubs.put(:declaration, %{name: "review", writes: ["explainer"]})
      assert write(ctx, "/verdict", %{"verdict" => "passed"}).status == 201
    end
  end
end
