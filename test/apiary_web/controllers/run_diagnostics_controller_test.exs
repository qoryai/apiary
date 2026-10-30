defmodule ApiaryWeb.RunDiagnosticsControllerTest do
  # Copy diagnostics on the run page reads `GET /:org/:workspace/runs/:run_id/diagnostics`
  # (`ApiaryWeb.RunDiagnosticsController`): the run's diagnostics document, valid under the
  # vendored contract, built for the reader: never the machine logs for a reader who is no
  # instance admin; not found for a reader without the run's Terminal, and for a run of
  # another workspace.
  use ApiaryWeb.ConnCase, async: true

  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.{DiagnosticsSchema, Repo}
  alias Apiary.Runs.{LogChunk, Run}

  setup :register_and_log_in_user

  setup %{scope: scope} do
    run = run_fixture(scope, %{public_id: Run.new_public_id()})

    events_fixture(run, [
      {1, "run.started", %{"note" => "qak_AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA"}}
    ])

    Repo.insert!(%LogChunk{
      organisation_id: run.organisation_id,
      workspace_id: run.workspace_id,
      run_id: run.id,
      sequence: 2,
      stream: "terminal",
      bytes: "hello\n"
    })

    %{
      run: run,
      path: ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.public_id}/diagnostics"
    }
  end

  defp document(conn) do
    assert [<<"application/json", _::binary>>] = get_resp_header(conn, "content-type")
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    document = Jason.decode!(conn.resp_body)
    assert DiagnosticsSchema.validate(DiagnosticsSchema.root(), document) == :ok
    document
  end

  test "answers the run's document, as stored, with its log and no machine log", %{
    conn: conn,
    run: run,
    path: path
  } do
    conn = get(conn, path)
    assert conn.status == 200
    document = document(conn)

    assert document["run"]["id"] == run.public_id
    assert document["log"] == %{"text" => "hello\n", "truncated" => false}
    assert [%{"data" => %{"note" => "qak_" <> _}}] = document["events"]
    refute Map.has_key?(document, "machine_logs")
  end

  test "answers the request the run page's Copy diagnostics sends", %{conn: conn, path: path} do
    # fetch sends `accept: */*` unless told otherwise, and the hook sends no accept header:
    # the browser pipeline refuses `application/json`.
    hook = File.read!(Path.expand("../../../assets/js/hooks/copy_to_clipboard.js", __DIR__))
    refute hook =~ ~r/headers:\s*\{[^}]*accept/i

    conn = conn |> put_req_header("accept", "*/*") |> get(path)
    assert conn.status == 200
    assert document(conn)["version"] == 1
  end

  test "is not found for a reader from whom the run's Terminal is hidden", %{
    conn: conn,
    path: path
  } do
    :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.HidesNamed)
    :ok = Apiary.EditionStubs.HidesNamed.put([:"observability.terminal"])

    conn = get(conn, path)
    assert conn.status == 404
    assert conn.resp_body == "not found"
  end

  test "a run of another workspace, or no run, is not found", %{conn: conn, scope: scope} do
    theirs = run_fixture(scope_fixture(), %{public_id: Run.new_public_id()})
    base = ~p"/#{scope.organisation}/#{scope.workspace}/runs"

    for id <- [theirs.public_id, Run.new_public_id(), "not-a-run", theirs.id] do
      conn = get(conn, "#{base}/#{id}/diagnostics")
      assert conn.status == 404, id
      assert conn.resp_body == "not found"
    end
  end

  test "signed out, it redirects to the log-in page", %{path: path} do
    conn = get(build_conn(), path)
    assert redirected_to(conn) =~ "/users/log-in"
  end
end
