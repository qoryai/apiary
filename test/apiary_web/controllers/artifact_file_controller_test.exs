defmodule ApiaryWeb.ArtifactFileControllerTest do
  # A version's file (`ApiaryWeb.ArtifactFileController`): served as an attachment with
  # its kept content type, nosniff and a sandbox policy, to a member who may read the
  # work item; a range of one span as 206; not found for another workspace's member,
  # another work item's version, an unknown file, and with `workflow_model` off.
  # Not async: the store's root is the application's setting.
  use ApiaryWeb.ConnCase, async: false

  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.Artifacts

  @moduletag :tmp_dir
  @moduletag needs: :workflow_model

  @svg ~s|<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>|
  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR">>

  setup %{tmp_dir: tmp_dir} = context do
    previous = Application.get_env(:apiary, :artifacts_dir)
    Application.put_env(:apiary, :artifacts_dir, Path.join(tmp_dir, "store"))
    on_exit(fn -> Application.put_env(:apiary, :artifacts_dir, previous) end)

    %{user: user, scope: scope} = sign_up_fixture()
    work_item = work_item_fixture(scope)
    %{dispatch_run: run} = explore_run_fixture(work_item, state: :handed_over)

    # Pushed as a run, which no feature gates, so the test with the feature off has it.
    {:ok, version} =
      Artifacts.push({:run, run}, work_item, "mockup", [
        %{filename: "Kasse übersicht.svg", binary: @svg},
        %{filename: "form.png", binary: @png}
      ])

    Map.merge(context, %{
      conn: log_in_user(build_conn(), user),
      scope: scope,
      work_item: work_item,
      version: version
    })
  end

  # The status a path answers: the instance's gate answers before the router, and a
  # page's gate raises a 404 exception.
  defp status(conn, path) do
    get(conn, path).status
  rescue
    error -> Plug.Exception.status(error)
  end

  defp path(scope, number, version_id, filename) do
    "/#{scope.organisation.slug}/#{scope.workspace.slug}/work/#{number}/artifacts/" <>
      "#{version_id}/files/#{URI.encode(filename, &URI.char_unreserved?/1)}"
  end

  test "serves an SVG as an attachment with its type, nosniff and a sandbox policy", ctx do
    conn =
      get(
        ctx.conn,
        path(ctx.scope, ctx.work_item.number, ctx.version.public_id, "Kasse übersicht.svg")
      )

    assert conn.status == 200
    assert conn.resp_body == @svg
    assert get_resp_header(conn, "content-type") == ["image/svg+xml"]

    assert get_resp_header(conn, "content-disposition") ==
             [
               ~s(attachment; filename="Kasse__bersicht.svg"; filename*=UTF-8''Kasse%20%C3%BCbersicht.svg)
             ]

    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "content-security-policy") == ["default-src 'none'; sandbox"]
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
  end

  test "answers a range of one span with 206", ctx do
    conn =
      ctx.conn
      |> put_req_header("range", "bytes=1-3")
      |> get(path(ctx.scope, ctx.work_item.number, ctx.version.public_id, "form.png"))

    assert conn.status == 206
    assert conn.resp_body == "PNG"
    assert get_resp_header(conn, "content-range") == ["bytes 1-3/#{byte_size(@png)}"]
    assert get_resp_header(conn, "content-disposition") |> hd() =~ "attachment"
  end

  test "answers a range that starts past the end with 416", ctx do
    conn =
      ctx.conn
      |> put_req_header("range", "bytes=#{byte_size(@png)}-")
      |> get(path(ctx.scope, ctx.work_item.number, ctx.version.public_id, "form.png"))

    assert conn.status == 416
    assert conn.resp_body == ""
    assert get_resp_header(conn, "content-range") == ["bytes */#{byte_size(@png)}"]
  end

  test "is not found for an unknown file, another work item's version, or a bad id", ctx do
    other = work_item_fixture(ctx.scope)

    for target <- [
          path(ctx.scope, ctx.work_item.number, ctx.version.public_id, "other.png"),
          path(ctx.scope, other.number, ctx.version.public_id, "form.png"),
          path(ctx.scope, ctx.work_item.number, "av_nope", "form.png"),
          path(ctx.scope, 999_999, ctx.version.public_id, "form.png")
        ] do
      assert status(ctx.conn, target) == 404, target
    end
  end

  test "is not found for a member of another workspace", ctx do
    %{user: stranger} = sign_up_fixture()
    conn = log_in_user(build_conn(), stranger)

    assert status(conn, path(ctx.scope, ctx.work_item.number, ctx.version.public_id, "form.png")) ==
             404
  end

  test "serves a member of the workspace", ctx do
    %{user: member} = member_fixture(ctx.scope, :member)
    conn = log_in_user(build_conn(), member)

    assert get(conn, path(ctx.scope, ctx.work_item.number, ctx.version.public_id, "form.png")).status ==
             200
  end

  test "sends a request with no session to sign in", ctx do
    conn =
      get(build_conn(), path(ctx.scope, ctx.work_item.number, ctx.version.public_id, "form.png"))

    assert redirected_to(conn) == ~p"/users/log-in"
  end

  describe "with workflow_model off" do
    @describetag with_features: Apiary.Features.all() -- [:workflow_model]

    test "the route is not found", ctx do
      assert status(
               ctx.conn,
               path(ctx.scope, ctx.work_item.number, ctx.version.public_id, "form.png")
             ) ==
               404
    end
  end

  test "disposition/1 keeps ASCII letters, digits, dots, hyphens and underscores" do
    assert ApiaryWeb.ArtifactFileController.disposition(~s(a"b;c.md)) ==
             ~s(attachment; filename="a_b_c.md"; filename*=UTF-8''a%22b%3Bc.md)
  end
end
