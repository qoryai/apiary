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

    test "has the newest verdict with its points", ctx do
      assert write(ctx, "/verdict", %{"verdict" => "passed"}).status == 201

      body = json_response(read(ctx, "/work-item"), 200)
      [passed] = RunApiStubs.pushed()

      assert body["verdict"] == %{
               "verdict" => "passed",
               "points" => nil,
               "version" => %{"id" => passed.public_id, "number" => 1}
             }

      points = [%{"text" => "The ticket has no test steps.", "action" => "run_again"}]
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
         "Leave question, context and options of each answered question in " <>
           "questions.json as the newest version of questions has them."},
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
           "as the newest version of questions has them, and its context while it stays " <>
           "decided or answered: to change them, withdraw the question and add a new one."},
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

    test "a verdict without points is stored without the member, as its schema takes it",
         ctx do
      assert write(ctx, "/verdict", %{"verdict" => "passed"}).status == 201
      assert [%{files: [%{content: content}]}] = RunApiStubs.pushed()
      assert Jason.decode!(content) == %{"verdict" => "passed"}
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
            %{"verdict" => "escalate", "points" => [Map.put(run_again, "note", "x")]}
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
