defmodule ApiaryWeb.ProcessExportControllerTest do
  # `GET /:org/:workspace/settings/stages/process.yaml`: the file for an owner or an admin,
  # with its headers, and `404` for everyone else and on an instance without the features.
  #
  # Not async: each test sets the instance's features, which are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Apiary.OrganisationsFixtures

  alias Apiary.Harnesses.Reader
  alias Apiary.Processes

  @moduletag with_features: Apiary.Features.all()

  setup :register_and_log_in_user

  defp path(scope), do: ~p"/#{scope.organisation}/#{scope.workspace}/settings/stages/process.yaml"

  # The status of a request the feature's gate answers, as a response or as an error.
  defp status(conn, path) do
    get(conn, path).status
  rescue
    _error -> elem(assert_error_sent(:not_found, fn -> get(conn, path) end), 0)
  end

  test "an owner gets the file as an attachment", %{conn: conn, scope: scope} do
    conn = get(conn, path(scope))

    assert conn.status == 200
    assert conn.resp_body == Processes.export(scope.workspace)
    assert {:ok, _template} = Reader.template(conn.resp_body)
    assert get_resp_header(conn, "content-type") == ["application/yaml; charset=utf-8"]

    assert get_resp_header(conn, "content-disposition") ==
             [~s(attachment; filename="process.yaml")]

    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end

  test "an admin gets the file", %{scope: scope} do
    %{user: admin} = member_fixture(scope, :admin)

    assert build_conn() |> log_in_user(admin) |> get(path(scope)) |> Map.fetch!(:status) == 200
  end

  test "a member without process.edit gets 404", %{scope: scope} do
    %{user: member} = member_fixture(scope)

    conn = build_conn() |> log_in_user(member) |> get(path(scope))

    assert conn.status == 404
    assert conn.resp_body == "not found"
  end

  test "a person of another organisation gets 404", %{scope: scope} do
    %{user: stranger} = sign_up_fixture()

    assert build_conn() |> log_in_user(stranger) |> status(path(scope)) == 404
  end

  test "a request with no session is sent to sign in", %{scope: scope} do
    assert build_conn() |> get(path(scope)) |> Map.fetch!(:status) == 302
  end

  describe "with workflow_model off" do
    @describetag with_features: Apiary.Features.all() -- [:workflow_model]

    test "the route is not found", %{conn: conn, scope: scope} do
      assert status(conn, path(scope)) == 404
    end
  end

  describe "with factory off" do
    @describetag with_features: Apiary.Features.all() -- [:factory, :workflow_model]

    test "the route is not found", %{conn: conn, scope: scope} do
      assert status(conn, path(scope)) == 404
    end
  end
end
