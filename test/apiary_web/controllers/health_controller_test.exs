defmodule ApiaryWeb.HealthControllerTest do
  use ApiaryWeb.ConnCase, async: true

  describe "GET /health" do
    test "answers 200 with the version when the database answers", %{conn: conn} do
      conn = get(conn, ~p"/health")

      assert %{"status" => "ok", "database" => "ok", "version" => version} =
               json_response(conn, 200)

      assert version == to_string(Application.spec(:apiary, :vsn))
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "answers 503 when the database does not answer", %{conn: conn} do
      # The controller runs in the test process, so pointing this process at a repo
      # that was never started makes the health query fail without touching Postgres.
      Apiary.Repo.put_dynamic_repo(:apiary_unreachable_repo_for_health_test)

      conn = get(conn, ~p"/health")

      assert json_response(conn, 503) == %{"status" => "degraded", "database" => "error"}
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "needs no session and sets no cookie", %{conn: conn} do
      conn = get(conn, ~p"/health")

      assert get_resp_header(conn, "set-cookie") == []
    end
  end
end
