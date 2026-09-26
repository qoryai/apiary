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

  defp drawn(sequence, text),
    do: {sequence, "run.log", %{"stream" => "terminal", "bytes" => Base.encode64(text)}}

  # A run on a 120 by 40 terminal, resized twice: at 6, and at 10 with nothing drawn after.
  defp sized_run(scope) do
    run = run_fixture(scope)

    events_fixture(run, [
      {1, "run.started",
       started_data(%{"interactive" => true, "terminal" => %{"cols" => 120, "rows" => 40}})},
      drawn(2, "a"),
      drawn(3, "b"),
      drawn(4, "c"),
      {6, "run.resized", %{"cols" => 100, "rows" => 30}},
      drawn(7, "d"),
      drawn(8, "e"),
      {10, "run.resized", %{"cols" => 80, "rows" => 24}},
      {11, "run.exited", %{"state" => "succeeded", "exit_code" => 0, "duration_ms" => 1}}
    ])

    {:ok, run} = Projector.project(run)
    run
  end

  defp through(conn), do: conn |> get_resp_header("x-qory-log-through") |> List.first()
  defp size(conn), do: conn |> get_resp_header("x-qory-log-size") |> List.first()

  describe "GET /:org/:workspace/runs/:run_id/log" do
    setup :register_and_log_in_user

    test "streams the decoded bytes in sequence order and names the last sequence", %{
      conn: conn,
      scope: scope
    } do
      run = run_with_log(scope)
      conn = get(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/log")

      assert conn.status == 200
      assert conn.state == :chunked
      assert conn.resp_body == "building\n" <> <<255, 0, 10>>
      assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
      assert get_resp_header(conn, "x-qory-log-through") == ["9"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
      assert get_resp_header(conn, "content-disposition") == []
    end

    test "answers a browser's fetch, which accepts anything", %{conn: conn, scope: scope} do
      run = run_with_log(scope)

      conn =
        conn
        |> put_req_header("accept", "*/*")
        |> get(~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/log")

      assert conn.status == 200
      assert [_] = get_resp_header(conn, "x-qory-log-through")
    end

    test "after, limit and stream", %{conn: conn, scope: scope} do
      run = run_with_log(scope)

      conn1 =
        get(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/log?after=5")

      assert conn1.resp_body == <<255, 0, 10>>
      assert get_resp_header(conn1, "x-qory-log-through") == ["9"]

      conn2 =
        get(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/log?limit=1")

      assert conn2.resp_body == "building\n"
      assert get_resp_header(conn2, "x-qory-log-through") == ["5"]

      conn3 =
        get(
          conn,
          ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/log?stream=stderr"
        )

      assert conn3.resp_body == <<255, 0, 10>>

      conn4 =
        get(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/log?after=9")

      assert conn4.status == 200
      assert conn4.resp_body == ""
      assert get_resp_header(conn4, "x-qory-log-through") == ["9"]
    end

    test "a sized run is answered one size at a time, stopping short of each resize", %{
      conn: conn,
      scope: scope
    } do
      run = sized_run(scope)
      assert %{terminal_cols: 80, terminal_rows: 24} = Apiary.Repo.get!(Apiary.Runs.Run, run.id)
      path = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/log"

      # From the start: the chunks before the first resize, at the start's size, and the
      # answer reaches the resize itself.
      first = get(conn, path)
      assert {first.resp_body, through(first), size(first)} == {"abc", "6", "120x40"}

      # From the resize: its size, up to the next.
      second = get(conn, "#{path}?after=6")
      assert {second.resp_body, through(second), size(second)} == {"de", "10", "100x30"}

      # Past the last resize nothing follows: the reader stops here.
      third = get(conn, "#{path}?after=10")
      assert {third.resp_body, through(third), size(third)} == {"", "10", "80x24"}

      # A limit under the chunks before a resize stops at the chunk, not the resize.
      limited = get(conn, "#{path}?limit=2")
      assert {limited.resp_body, through(limited), size(limited)} == {"ab", "3", "120x40"}
      rest = get(conn, "#{path}?after=3&limit=2")
      assert {rest.resp_body, through(rest), size(rest)} == {"c", "6", "120x40"}

      # The size in force between two resizes, from any sequence.
      assert size(get(conn, "#{path}?after=7")) == "100x30"
      assert through(get(conn, "#{path}?after=7")) == "10"

      # The terminal stream by name is sized too; a download is every chunk, unsized.
      assert size(get(conn, "#{path}?stream=terminal")) == "120x40"
      download = get(conn, "#{path}?download=1")
      assert {download.resp_body, through(download), size(download)} == {"abcde", "8", nil}
    end

    test "a run without a size is answered as before: every chunk, no size", %{
      conn: conn,
      scope: scope
    } do
      run = run_with_log(scope)
      conn = get(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/log")
      assert {through(conn), size(conn)} == {"9", nil}
    end

    test "download=1 is every chunk as an attachment named after the short id", %{
      conn: conn,
      scope: scope
    } do
      run = run_with_log(scope)

      conn =
        get(
          conn,
          ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/log?download=1&limit=1"
        )

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
        conn = get(conn, "#{workspace_path(scope)}/runs/#{run.run_id}/log?" <> query)
        assert conn.status == 400, query
      end
    end

    test "a run of another workspace is not found, like one that does not exist", %{
      conn: conn,
      scope: scope
    } do
      theirs = run_with_log(scope_fixture())

      assert get(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{theirs.run_id}/log").status ==
               404

      assert get(
               conn,
               ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{Ecto.UUID.generate()}/log"
             ).status == 404

      assert get(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/not-a-uuid/log").status ==
               404

      # The row id is not the address either.
      assert get(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{theirs.id}/log").status ==
               404
    end

    test "a run of another organisation is not found by its own address", %{conn: conn} do
      theirs = scope_fixture()
      run = run_with_log(theirs)

      conn = get(conn, ~p"/#{theirs.organisation}/#{theirs.workspace}/runs/#{run.run_id}/log")

      assert conn.status == 404
      refute conn.resp_body =~ "building"
      assert get_resp_header(conn, "x-qory-log-through") == []
    end
  end

  test "signed out, the log redirects to the log-in page", %{conn: conn} do
    scope = scope_fixture()

    conn =
      get(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{Ecto.UUID.generate()}/log")

    assert redirected_to(conn) == ~p"/users/log-in"
  end
end
