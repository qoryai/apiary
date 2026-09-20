defmodule ApiaryWeb.RunLogControllerTest do
  use ApiaryWeb.ConnCase, async: true

  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures

  alias Apiary.Runs.Projector

  defp run_with_log(scope) do
    run = run_fixture(scope)
    events_fixture(run, record())
    {:ok, run} = Projector.project(run)
    run
  end

  describe "GET /hive/runs/:run_id/log" do
    setup :register_and_log_in_user

    test "streams the decoded bytes in sequence order and names the last sequence", %{
      conn: conn,
      scope: scope
    } do
      run = run_with_log(scope)
      conn = get(conn, ~p"/hive/runs/#{run.run_id}/log")

      assert conn.status == 200
      assert conn.state == :chunked
      assert conn.resp_body == "building\n" <> <<255, 0, 10>>
      assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
      assert get_resp_header(conn, "x-qory-log-through") == ["9"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
      assert get_resp_header(conn, "content-disposition") == []
    end

    test "after, limit and stream", %{conn: conn, scope: scope} do
      run = run_with_log(scope)

      conn1 = get(conn, ~p"/hive/runs/#{run.run_id}/log?after=5")
      assert conn1.resp_body == <<255, 0, 10>>
      assert get_resp_header(conn1, "x-qory-log-through") == ["9"]

      conn2 = get(conn, ~p"/hive/runs/#{run.run_id}/log?limit=1")
      assert conn2.resp_body == "building\n"
      assert get_resp_header(conn2, "x-qory-log-through") == ["5"]

      conn3 = get(conn, ~p"/hive/runs/#{run.run_id}/log?stream=stderr")
      assert conn3.resp_body == <<255, 0, 10>>

      conn4 = get(conn, ~p"/hive/runs/#{run.run_id}/log?after=9")
      assert conn4.status == 200
      assert conn4.resp_body == ""
      assert get_resp_header(conn4, "x-qory-log-through") == ["9"]
    end

    test "download=1 is every chunk as an attachment named after the short id", %{
      conn: conn,
      scope: scope
    } do
      run = run_with_log(scope)
      conn = get(conn, ~p"/hive/runs/#{run.run_id}/log?download=1&limit=1")

      assert conn.resp_body == "building\n" <> <<255, 0, 10>>

      assert get_resp_header(conn, "content-disposition") ==
               [~s(attachment; filename="#{String.slice(run.run_id, 0, 8)}.log")]
    end

    test "a parameter that is not what it should be is a 400", %{conn: conn, scope: scope} do
      run = run_with_log(scope)

      for query <- [
            "after=-1",
            "after=abc",
            "after=1e3",
            "limit=x",
            "stream=stdin",
            "after=99999999999"
          ] do
        conn = get(conn, "/hive/runs/#{run.run_id}/log?" <> query)
        assert conn.status == 400, query
      end
    end

    test "a run of another hive is not found, like one that does not exist", %{conn: conn} do
      theirs = run_with_log(scope_fixture())

      assert get(conn, ~p"/hive/runs/#{theirs.run_id}/log").status == 404
      assert get(conn, ~p"/hive/runs/#{Ecto.UUID.generate()}/log").status == 404
      assert get(conn, ~p"/hive/runs/not-a-uuid/log").status == 404
      # The row id is not the address either.
      assert get(conn, ~p"/hive/runs/#{theirs.id}/log").status == 404
    end
  end

  test "signed out, the log redirects to the log-in page", %{conn: conn} do
    conn = get(conn, ~p"/hive/runs/#{Ecto.UUID.generate()}/log")
    assert redirected_to(conn) == ~p"/users/log-in"
  end
end
