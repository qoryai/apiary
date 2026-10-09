defmodule ApiaryWeb.HealthControllerTest do
  # Async with the other modules: the tests that set the revision restore it, and no other
  # module reads it.
  use ApiaryWeb.ConnCase, async: true

  describe "GET /health" do
    test "answers 200 with the version when the database answers", %{conn: conn} do
      conn = get(conn, ~p"/health")

      # A build without APIARY_REVISION, as the tests are, has no revision.
      assert %{"status" => "ok", "database" => "ok", "version" => version, "revision" => nil} =
               json_response(conn, 200)

      assert version == to_string(Application.spec(:apiary, :vsn))
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "answers the revision the release's file holds", %{conn: conn} do
      revision = String.duplicate("4f2a9c1e0b", 4)
      path = Path.join(System.tmp_dir!(), "apiary-revision-#{System.unique_integer([:positive])}")
      File.write!(path, revision <> "\n")
      previous = Apiary.Revision.get()

      on_exit(fn ->
        File.rm(path)
        Application.put_env(:apiary, :revision, previous)
      end)

      assert Apiary.Revision.boot!(path) == revision

      assert %{"status" => "ok", "revision" => ^revision} =
               conn |> get(~p"/health") |> json_response(200)

      Apiary.Repo.put_dynamic_repo(:apiary_unreachable_repo_for_health_test)

      assert %{"status" => "degraded", "revision" => ^revision} =
               conn |> get(~p"/health") |> json_response(503)
    end

    test "answers no revision when the release has no file, or an empty one" do
      path = Path.join(System.tmp_dir!(), "apiary-revision-#{System.unique_integer([:positive])}")
      previous = Apiary.Revision.get()

      on_exit(fn ->
        File.rm(path)
        Application.put_env(:apiary, :revision, previous)
      end)

      assert Apiary.Revision.boot!(path) == nil
      File.write!(path, "\n")
      assert Apiary.Revision.boot!(path) == nil
      assert Apiary.Revision.get() == nil
    end

    test "answers 503 when the database does not answer", %{conn: conn} do
      # The controller runs in the test process, so pointing this process at a repo
      # that was never started makes the health query fail without touching Postgres.
      Apiary.Repo.put_dynamic_repo(:apiary_unreachable_repo_for_health_test)

      conn = get(conn, ~p"/health")

      assert json_response(conn, 503) == %{
               "status" => "degraded",
               "database" => "error",
               "version" => to_string(Application.spec(:apiary, :vsn)),
               "revision" => nil
             }

      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "needs no session and sets no cookie", %{conn: conn} do
      conn = get(conn, ~p"/health")

      assert get_resp_header(conn, "set-cookie") == []
    end
  end
end
