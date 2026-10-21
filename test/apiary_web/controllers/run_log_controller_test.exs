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
      {1, "run.started", started_data()},
      {2, "session.started",
       session_started_data(%{
         "interactive" => true,
         "terminal" => %{"cols" => 120, "rows" => 40}
       })},
      drawn(3, "a"),
      drawn(4, "b"),
      drawn(5, "c"),
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
      conn = get(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.public_id}/log")

      assert conn.status == 200
      assert conn.state == :chunked
      assert conn.resp_body == "building\n" <> <<255, 0, 10>>
      assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
      assert get_resp_header(conn, "x-qory-log-through") == ["10"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
      assert get_resp_header(conn, "content-disposition") == []
    end

    test "answers a browser's fetch, which accepts anything", %{conn: conn, scope: scope} do
      run = run_with_log(scope)

      conn =
        conn
        |> put_req_header("accept", "*/*")
        |> get(~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.public_id}/log")

      assert conn.status == 200
      assert [_] = get_resp_header(conn, "x-qory-log-through")
    end

    test "after, limit and stream", %{conn: conn, scope: scope} do
      run = run_with_log(scope)

      conn1 =
        get(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.public_id}/log?after=6")

      assert conn1.resp_body == <<255, 0, 10>>
      assert get_resp_header(conn1, "x-qory-log-through") == ["10"]

      conn2 =
        get(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.public_id}/log?limit=1")

      assert conn2.resp_body == "building\n"
      assert get_resp_header(conn2, "x-qory-log-through") == ["6"]

      conn3 =
        get(
          conn,
          ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.public_id}/log?stream=stderr"
        )

      assert conn3.resp_body == <<255, 0, 10>>

      conn4 =
        get(
          conn,
          ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.public_id}/log?after=10"
        )

      assert conn4.status == 200
      assert conn4.resp_body == ""
      assert get_resp_header(conn4, "x-qory-log-through") == ["10"]
    end

    test "a sized run is answered one size at a time, stopping short of each resize", %{
      conn: conn,
      scope: scope
    } do
      run = sized_run(scope)
      assert %{terminal_cols: 80, terminal_rows: 24} = Apiary.Repo.get!(Apiary.Runs.Run, run.id)
      path = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.public_id}/log"

      # From the start: the chunks before the first resize, at the session's start's size,
      # and the answer reaches the resize itself.
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
      assert {limited.resp_body, through(limited), size(limited)} == {"ab", "4", "120x40"}
      rest = get(conn, "#{path}?after=4&limit=2")
      assert {rest.resp_body, through(rest), size(rest)} == {"c", "6", "120x40"}

      # The size in force between two resizes, from any sequence.
      assert size(get(conn, "#{path}?after=7")) == "100x30"
      assert through(get(conn, "#{path}?after=7")) == "10"

      # The terminal stream by name is sized too; a download is every chunk, unsized.
      assert size(get(conn, "#{path}?stream=terminal")) == "120x40"
      download = get(conn, "#{path}?download=1")
      assert {download.resp_body, through(download), size(download)} == {"abcde", "8", nil}
    end

    test "each session's start sets the size of the chunks after it", %{
      conn: conn,
      scope: scope
    } do
      run = run_fixture(scope)

      events_fixture(run, [
        {1, "run.started", started_data()},
        {2, "session.started",
         session_started_data(%{
           "session" => 1,
           "interactive" => true,
           "terminal" => %{"cols" => 120, "rows" => 40}
         })},
        drawn(3, "a"),
        drawn(4, "b"),
        drawn(5, "c"),
        {6, "session.exited",
         %{"session" => 1, "state" => "succeeded", "exit_code" => 0, "duration_ms" => 1}},
        {7, "session.started",
         session_started_data(%{
           "session" => 2,
           "interactive" => true,
           "terminal" => %{"cols" => 80, "rows" => 24}
         })},
        drawn(8, "d"),
        drawn(9, "e")
      ])

      {:ok, run} = Projector.project(run)
      path = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.public_id}/log"

      # Session 1's chunks at its size, up to session 2's start.
      first = get(conn, path)
      assert {first.resp_body, through(first), size(first)} == {"abc", "7", "120x40"}

      # From session 2's start: its size, to the end.
      second = get(conn, "#{path}?after=7")
      assert {second.resp_body, through(second), size(second)} == {"de", "9", "80x24"}

      # Between the two starts, the first session's size, stopping at the second.
      between = get(conn, "#{path}?after=4")
      assert {between.resp_body, through(between), size(between)} == {"c", "7", "120x40"}
    end

    test "a session on pipes between two on a terminal is answered without a size", %{
      conn: conn,
      scope: scope
    } do
      run = run_fixture(scope)

      on_terminal = fn session, cols, rows ->
        session_started_data(%{
          "session" => session,
          "interactive" => true,
          "terminal" => %{"cols" => cols, "rows" => rows}
        })
      end

      events_fixture(run, [
        {1, "run.started", started_data()},
        {2, "session.started", on_terminal.(1, 120, 40)},
        drawn(3, "a"),
        drawn(4, "b"),
        {5, "session.started", session_started_data(%{"session" => 2})},
        {6, "run.log", %{"stream" => "stdout", "bytes" => Base.encode64("p")}},
        {7, "run.log", %{"stream" => "stdout", "bytes" => Base.encode64("q")}},
        {8, "session.started", on_terminal.(3, 80, 24)},
        drawn(9, "c")
      ])

      {:ok, run} = Projector.project(run)
      path = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.public_id}/log"

      # Session 1 at its size, stopping at session 2's start.
      first = get(conn, path)
      assert {first.resp_body, through(first), size(first)} == {"ab", "5", "120x40"}

      # Session 2 is on pipes: its chunks have no size, up to session 3's start.
      second = get(conn, "#{path}?after=5")
      assert {second.resp_body, through(second), size(second)} == {"pq", "8", nil}

      # Session 3 at its size.
      third = get(conn, "#{path}?after=8")
      assert {third.resp_body, through(third), size(third)} == {"c", "9", "80x24"}
    end

    test "a run without a size is answered as before: every chunk, no size", %{
      conn: conn,
      scope: scope
    } do
      run = run_with_log(scope)
      conn = get(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.public_id}/log")
      assert {through(conn), size(conn)} == {"10", nil}
    end

    test "download=1 is every chunk as an attachment named after the short id", %{
      conn: conn,
      scope: scope
    } do
      run = run_with_log(scope)

      conn =
        get(
          conn,
          ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.public_id}/log?download=1&limit=1"
        )

      assert conn.resp_body == "building\n" <> <<255, 0, 10>>

      assert get_resp_header(conn, "content-disposition") ==
               [~s(attachment; filename="#{run.public_id}.log")]
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
        conn = get(conn, "#{workspace_path(scope)}/runs/#{run.public_id}/log?" <> query)
        assert conn.status == 400, query
      end
    end

    test "a run of another workspace is not found, like one that does not exist", %{
      conn: conn,
      scope: scope
    } do
      theirs = run_with_log(scope_fixture())

      assert get(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{theirs.public_id}/log").status ==
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

    test "an id of 16 bytes that are not UTF-8 is not found", %{conn: conn, scope: scope} do
      # `%FF` decodes to the byte 0xFF: with the 15 characters after it, 16 bytes after `rn_`.
      conn = get(conn, "#{workspace_path(scope)}/runs/rn_%FF123456789abcdef/log")
      assert conn.status == 404
      assert conn.resp_body == "not found"
    end

    test "where the run's Terminal is hidden from the reader, every stream and the download are not found",
         %{conn: conn, scope: scope} do
      run = sized_run(scope)
      path = ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.public_id}/log"

      queries =
        ~w(? ?stream=terminal ?stream=stdout ?stream=stderr ?download=1 ?after=3&limit=1
           ?download=1&stream=stdout)

      for query <- queries, do: assert(get(conn, path <> query).status == 200, query)

      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.HidesNamed)

      for hidden <- [[:"observability.terminal"], [:observability]], query <- queries do
        :ok = Apiary.EditionStubs.HidesNamed.put(hidden)
        conn = get(conn, path <> query)

        assert conn.status == 404, inspect({hidden, query})
        # The log endpoint's refusal, or the feature's gate before it.
        assert conn.resp_body in ["not found", "Not Found"]
        assert get_resp_header(conn, "x-qory-log-through") == []
        assert get_resp_header(conn, "x-qory-log-size") == []
        assert get_resp_header(conn, "content-disposition") == []
      end
    end

    test "a run of another organisation is not found by its own address", %{conn: conn} do
      theirs = scope_fixture()
      run = run_with_log(theirs)

      conn = get(conn, ~p"/#{theirs.organisation}/#{theirs.workspace}/runs/#{run.public_id}/log")

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

  test "a member removed from the organisation is not found, as a workspace that does not exist",
       %{conn: conn} do
    %{scope: owner} = sign_up_fixture()
    run = run_with_log(owner)
    %{user: user, membership: membership} = member_fixture(owner, :member)
    conn = log_in_user(conn, user)
    path = ~p"/#{owner.organisation}/#{owner.workspace}/runs/#{run.public_id}/log"

    assert conn |> get(path) |> response(200)

    {:ok, _} = Apiary.Organisations.remove_member(owner, membership.id)

    assert conn |> get(path) |> response(404)
  end
end
