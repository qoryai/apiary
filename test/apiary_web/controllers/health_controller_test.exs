defmodule ApiaryWeb.HealthControllerTest do
  # Not async: the tests of `set_up` hide the suite's instance organisation, a row every
  # test shares. The tests that set the revision restore it.
  use ApiaryWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Apiary.OrganisationsFixtures

  describe "GET /health" do
    test "returns 200 with the version when the database answers", %{conn: conn} do
      conn = get(conn, ~p"/health")

      # A build without APIARY_REVISION, as the tests are, has no revision. The suite's
      # instance is set up.
      assert %{
               "status" => "ok",
               "database" => "ok",
               "version" => version,
               "revision" => nil,
               "set_up" => true
             } = json_response(conn, 200)

      assert version == to_string(Application.spec(:apiary, :vsn))
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "returns the revision in the release's file", %{conn: conn} do
      revision = String.duplicate("4f2a9c1e0b", 4)

      path =
        Path.join(
          System.tmp_dir!(),
          "apiary-revision-#{System.pid()}-#{System.unique_integer([:positive])}"
        )

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

    test "reads no revision when the release has no file, or an empty one" do
      path =
        Path.join(
          System.tmp_dir!(),
          "apiary-revision-#{System.pid()}-#{System.unique_integer([:positive])}"
        )

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

    test "returns 503 without set_up when the database does not answer", %{conn: conn} do
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

    test "returns set_up false before the set-up and true after it", %{conn: conn} do
      Apiary.EditionKit.hide_instance_organisation()

      assert %{"status" => "ok", "set_up" => false} =
               conn |> get(~p"/health") |> json_response(200)

      # The fixture sets the instance up with its set-up code (`Apiary.Setup.set_up/3`).
      sign_up_fixture()

      assert %{"status" => "ok", "set_up" => true} =
               build_conn() |> get(~p"/health") |> json_response(200)
    end

    test "returns 200 without set_up when the set-up lookup fails", %{conn: conn} do
      # `SELECT 1` needs no table, the lookup of the instance's organisation does: with no
      # schema on the search path of this test's transaction, only the lookup fails.
      Apiary.Repo.query!("SET LOCAL search_path TO apiary_health_test_no_schema")

      {body, log} = with_log(fn -> conn |> get(~p"/health") |> json_response(200) end)

      assert %{"status" => "ok", "database" => "ok"} = body
      refute Map.has_key?(body, "set_up")

      # One warning, which ends with the exception's module: nothing of the error's text,
      # whichever table the edition reads.
      assert [line] = log |> String.split("\n") |> Enum.filter(&(&1 =~ "set-up lookup"))

      assert line =~
               ~r/\[warning\] GET \/health left out set_up: the set-up lookup failed with Postgrex\.Error$/
    end

    test "needs no session and sets no cookie", %{conn: conn} do
      conn = get(conn, ~p"/health")

      assert get_resp_header(conn, "set-cookie") == []
    end
  end
end
