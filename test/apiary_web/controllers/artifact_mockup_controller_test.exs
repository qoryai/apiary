defmodule ApiaryWeb.ArtifactMockupControllerTest do
  # A screen of a mockup of pages (`ApiaryWeb.ArtifactMockupController`): its page with
  # the frame's headers to a member who may read the work item, by its id or its id and
  # `.html`; for anything else, a request with no session included, a 404 page of one
  # line under the same headers.
  # Not async: the store's root is the application's setting.
  use ApiaryWeb.ConnCase, async: false

  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.Artifacts

  @moduletag :tmp_dir
  @moduletag needs: :workflow_model

  @policy "default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:; " <>
            "base-uri 'none'; form-action 'none'; frame-ancestors 'self'; sandbox"
  @line "Reload the page to try again. This screen cannot be shown."
  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR">>

  @home ~s(<!doctype html><html><head><meta charset="utf-8"><title>Home</title></head>) <>
          ~s(<body><a href="cart.html">Cart</a></body></html>)
  @cart ~s(<!doctype html><html><head><meta charset="utf-8"><title>Cart</title></head>) <>
          ~s(<body><a href="home.html">Home</a></body></html>)

  setup %{tmp_dir: tmp_dir} = context do
    previous = Application.get_env(:apiary, :artifacts_dir)
    Application.put_env(:apiary, :artifacts_dir, Path.join(tmp_dir, "store"))
    on_exit(fn -> Application.put_env(:apiary, :artifacts_dir, previous) end)

    %{user: user, scope: scope} = sign_up_fixture()
    work_item = work_item_fixture(scope)
    %{dispatch_run: run} = explore_run_fixture(work_item, state: :handed_over)

    index =
      Jason.encode!(%{
        "start" => "home",
        "screens" => [
          %{
            "id" => "home",
            "title" => "Home",
            "file" => "home.html",
            "criteria" => [],
            "links" => [%{"to" => "cart", "label" => "Cart"}]
          },
          %{
            "id" => "cart",
            "title" => "Cart",
            "file" => "cart.html",
            "criteria" => [],
            "links" => [%{"to" => "home", "label" => "Home"}]
          }
        ]
      })

    {:ok, version} =
      Artifacts.push({:run, run}, work_item, "mockup", [
        %{filename: "screens.json", binary: index},
        %{filename: "home.html", binary: @home},
        %{filename: "cart.html", binary: @cart}
      ])

    {:ok, pictures} =
      Artifacts.push({:run, run}, work_item, "mockup", [%{filename: "form.png", binary: @png}],
        name: "pictures"
      )

    Map.merge(context, %{
      conn: log_in_user(build_conn(), user),
      scope: scope,
      work_item: work_item,
      version: version,
      pictures: pictures
    })
  end

  defp path(scope, number, version_id, screen) do
    "/#{scope.organisation.slug}/#{scope.workspace.slug}/work/#{number}/artifacts/" <>
      "#{version_id}/mockup/#{screen}"
  end

  defp assert_headers(conn) do
    assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
    assert get_resp_header(conn, "content-security-policy") == [@policy]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(conn, "content-disposition") == []
    assert get_resp_header(conn, "x-frame-options") == []
  end

  defp assert_not_found(conn) do
    assert conn.status == 404
    assert_headers(conn)
    assert conn.resp_body =~ "<p>#{@line}</p>"
    refute conn.resp_body =~ "<script"
  end

  test "serves a screen's page with the frame's headers, by its id or its file", ctx do
    for {screen, body} <- [{"home", @home}, {"cart", @cart}, {"cart.html", @cart}] do
      conn = get(ctx.conn, path(ctx.scope, ctx.work_item.number, ctx.version.public_id, screen))
      assert conn.status == 200
      assert conn.resp_body == body
      assert_headers(conn)
    end

    assert ApiaryWeb.ArtifactMockupController.policy() == @policy
  end

  test "serves a member of the workspace", ctx do
    %{user: member} = member_fixture(ctx.scope, :member)
    conn = log_in_user(build_conn(), member)
    path = path(ctx.scope, ctx.work_item.number, ctx.version.public_id, "home")
    assert get(conn, path).status == 200
  end

  test "is the frame's 404 for an unknown screen, a version of pictures or another's", ctx do
    other = work_item_fixture(ctx.scope)

    for target <- [
          path(ctx.scope, ctx.work_item.number, ctx.version.public_id, "gone"),
          path(ctx.scope, ctx.work_item.number, ctx.version.public_id, "screens.json"),
          path(ctx.scope, ctx.work_item.number, ctx.pictures.public_id, "form"),
          path(ctx.scope, other.number, ctx.version.public_id, "home"),
          path(ctx.scope, ctx.work_item.number, "av_nope", "home"),
          path(ctx.scope, 999_999, ctx.version.public_id, "home")
        ] do
      assert_not_found(get(ctx.conn, target))
    end
  end

  test "is the frame's 404 for a member of another workspace and with no session", ctx do
    %{user: stranger} = sign_up_fixture()
    path = path(ctx.scope, ctx.work_item.number, ctx.version.public_id, "home")

    assert_not_found(get(log_in_user(build_conn(), stranger), path))
    assert_not_found(get(build_conn(), path))
  end

  describe "with workflow_model off" do
    @describetag with_features: Apiary.Features.all() -- [:workflow_model]

    test "the route is not found", ctx do
      path = path(ctx.scope, ctx.work_item.number, ctx.version.public_id, "home")
      conn = get(ctx.conn, path)
      assert conn.status == 404
      refute conn.resp_body =~ "<p>Hello"
    end
  end
end
