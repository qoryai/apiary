defmodule ApiaryWeb.ArtifactMockupControllerTest do
  # A screen of a mockup of pages (`ApiaryWeb.ArtifactMockupController`): its page with
  # the frame's headers for a token the version page signed, with no cookie; for
  # anything else, a cookie with no token included, a 404 page of one line under the same
  # headers.
  # Not async: the store's root is the application's setting.
  use ApiaryWeb.ConnCase, async: false

  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Accounts, Artifacts}
  alias ApiaryWeb.ArtifactMockupController

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

  @index Jason.encode!(%{
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

  defp pages(run, work_item, name \\ "main") do
    {:ok, version} =
      Artifacts.push(
        {:run, run},
        work_item,
        "mockup",
        [
          %{filename: "screens.json", binary: @index},
          %{filename: "home.html", binary: @home},
          %{filename: "cart.html", binary: @cart}
        ],
        name: name
      )

    version
  end

  setup %{tmp_dir: tmp_dir} = context do
    previous = Application.get_env(:apiary, :artifacts_dir)
    Application.put_env(:apiary, :artifacts_dir, Path.join(tmp_dir, "store"))
    on_exit(fn -> Application.put_env(:apiary, :artifacts_dir, previous) end)

    %{user: user, scope: scope} = sign_up_fixture()
    work_item = work_item_fixture(scope)
    %{dispatch_run: run} = explore_run_fixture(work_item, state: :handed_over)
    version = pages(run, work_item)

    {:ok, pictures} =
      Artifacts.push({:run, run}, work_item, "mockup", [%{filename: "form.png", binary: @png}],
        name: "pictures"
      )

    Map.merge(context, %{
      user: user,
      scope: scope,
      run: run,
      work_item: work_item,
      version: version,
      pictures: pictures
    })
  end

  # A session of `user`, as signing in makes one: its token and its record's id.
  defp session(user) do
    token = Accounts.generate_user_session_token(user)
    {token, Accounts.session_token_id(token)}
  end

  defp token(ctx, opts \\ []) do
    user = Keyword.get(opts, :user, ctx.user)

    data = %{
      version: Keyword.get(opts, :version, ctx.version.public_id),
      work_item: Keyword.get(opts, :work_item, ctx.work_item.id),
      user: user.id,
      session: Keyword.get_lazy(opts, :session, fn -> user |> session() |> elem(1) end)
    }

    ArtifactMockupController.token(ApiaryWeb.Endpoint, data, Keyword.take(opts, [:signed_at]))
  end

  defp frame_path(ctx, token, page, opts \\ []) do
    scope = Keyword.get(opts, :scope, ctx.scope)
    number = Keyword.get(opts, :number, ctx.work_item.number)
    version_id = Keyword.get(opts, :version_id, ctx.version.public_id)

    "/#{scope.organisation.slug}/#{scope.workspace.slug}/work/#{number}/artifacts/" <>
      "#{version_id}/mockup/#{token}/#{page}"
  end

  defp assert_headers(conn) do
    assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
    assert get_resp_header(conn, "content-security-policy") == [@policy]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    assert get_resp_header(conn, "content-disposition") == []
    assert get_resp_header(conn, "x-frame-options") == []
    assert get_resp_header(conn, "set-cookie") == []
  end

  defp assert_not_found(conn) do
    assert conn.status == 404
    assert_headers(conn)
    assert conn.resp_body =~ "<p>#{@line}</p>"
    refute conn.resp_body =~ "<script"
  end

  test "serves a screen's page with no cookie for a token that verifies", ctx do
    token = token(ctx)

    for {page, body} <- [{"home.html", @home}, {"cart.html", @cart}] do
      conn = get(build_conn(), frame_path(ctx, token, page))
      assert conn.status == 200
      assert conn.resp_body == body
      assert_headers(conn)
    end

    assert ArtifactMockupController.policy() == @policy
  end

  test "is the frame's 404 with a cookie and no token", ctx do
    conn = log_in_user(build_conn(), ctx.user)

    # A segment that is no token in the token's place, and the session's cookie.
    assert_not_found(get(conn, frame_path(ctx, "home.html", "home.html")))

    # With no token segment, the path is no route: not found, and no screen.
    no_token = frame_path(ctx, "", "home.html")
    conn = get(conn, no_token)
    assert conn.status == 404
    refute conn.resp_body =~ "Cart"
  end

  test "is the frame's 404 for an expired or a tampered token", ctx do
    expired = token(ctx, signed_at: System.system_time(:second) - 3601)
    assert_not_found(get(build_conn(), frame_path(ctx, expired, "home.html")))

    almost = token(ctx, signed_at: System.system_time(:second) - 3500)
    assert get(build_conn(), frame_path(ctx, almost, "home.html")).status == 200

    [protected, payload, signature] = String.split(token(ctx), ".")
    flipped = if String.first(signature) == "A", do: "B", else: "A"
    tampered = Enum.join([protected, payload, flipped <> String.slice(signature, 1..-1//1)], ".")
    assert_not_found(get(build_conn(), frame_path(ctx, tampered, "home.html")))

    other_salt =
      Phoenix.Token.sign(ApiaryWeb.Endpoint, "user auth", %{
        v: ctx.version.public_id,
        w: ctx.work_item.id,
        u: ctx.user.id
      })

    assert_not_found(get(build_conn(), frame_path(ctx, other_salt, "home.html")))
  end

  test "is the frame's 404 for a token of another version, work item or organisation", ctx do
    other_item = work_item_fixture(ctx.scope)
    %{dispatch_run: other_run} = explore_run_fixture(other_item, state: :handed_over)
    other_version = pages(other_run, other_item)
    second = pages(ctx.run, ctx.work_item, "second")

    # A token of the version, at another version's path, the same work item's or not.
    token = token(ctx)

    assert_not_found(
      get(build_conn(), frame_path(ctx, token, "home.html", version_id: second.public_id))
    )

    assert_not_found(
      get(
        build_conn(),
        frame_path(ctx, token, "home.html",
          number: other_item.number,
          version_id: other_version.public_id
        )
      )
    )

    # A token whose work item is another, at the version's path.
    assert_not_found(
      get(build_conn(), frame_path(ctx, token(ctx, work_item: other_item.id), "home.html"))
    )

    # A token of another organisation's person and version, at this one's path.
    %{user: stranger, scope: elsewhere} = sign_up_fixture()
    foreign = work_item_fixture(elsewhere)
    %{dispatch_run: foreign_run} = explore_run_fixture(foreign, state: :handed_over)
    foreign_version = pages(foreign_run, foreign)

    foreign_token =
      token(ctx, version: foreign_version.public_id, work_item: foreign.id, user: stranger)

    assert get(
             build_conn(),
             frame_path(ctx, foreign_token, "home.html",
               scope: elsewhere,
               number: foreign.number,
               version_id: foreign_version.public_id
             )
           ).status == 200

    assert_not_found(
      get(
        build_conn(),
        frame_path(ctx, foreign_token, "home.html", version_id: foreign_version.public_id)
      )
    )

    # This organisation's token for a person who is no member of it.
    assert_not_found(get(build_conn(), frame_path(ctx, token(ctx, user: stranger), "home.html")))
  end

  test "is the frame's 404 once the person signed in the token leaves the workspace", ctx do
    %{user: member, membership: membership} = member_fixture(ctx.scope, :member)
    token = token(ctx, user: member)
    assert get(build_conn(), frame_path(ctx, token, "home.html")).status == 200

    assert {:ok, _removed} = Apiary.Organisations.remove_member(ctx.scope, membership.id)

    assert_not_found(get(build_conn(), frame_path(ctx, token, "home.html")))
  end

  test "is the frame's 404 for a page that is no screen, or a version of pictures", ctx do
    token = token(ctx)

    for page <- ["gone.html", "home", "screens.json", "home.html.html", ".html"] do
      assert_not_found(get(build_conn(), frame_path(ctx, token, page)))
    end

    pictures = token(ctx, version: ctx.pictures.public_id)

    assert_not_found(
      get(
        build_conn(),
        frame_path(ctx, pictures, "form.html", version_id: ctx.pictures.public_id)
      )
    )
  end

  test "is the frame's 404 once the person signs out, or changes the password", ctx do
    {session_token, session_id} = session(ctx.user)
    token = token(ctx, session: session_id)
    assert get(build_conn(), frame_path(ctx, token, "home.html")).status == 200

    :ok = Accounts.delete_user_session_token(session_token)
    assert_not_found(get(build_conn(), frame_path(ctx, token, "home.html")))

    {_session_token, session_id} = session(ctx.user)
    token = token(ctx, session: session_id)
    assert get(build_conn(), frame_path(ctx, token, "home.html")).status == 200

    {:ok, _changed} =
      Accounts.update_user_password(ctx.user, %{password: "another valid password 42"})

    assert_not_found(get(build_conn(), frame_path(ctx, token, "home.html")))
  end

  test "is the frame's 404 for a token of no session, or another person's session", ctx do
    assert_not_found(get(build_conn(), frame_path(ctx, token(ctx, session: nil), "home.html")))

    %{user: member} = member_fixture(ctx.scope, :member)
    {_token, other} = session(member)
    assert_not_found(get(build_conn(), frame_path(ctx, token(ctx, session: other), "home.html")))
  end

  # The edition narrows the rights of a member: the role does not read work items.
  defmodule NoWorkItemRead do
    def check(_scope, :"work_item.read", _subject), do: {:error, :forbidden}
    def check(scope, action, subject), do: Apiary.Edition.module().check(scope, action, subject)
  end

  test "is the frame's 404 for a person who may not read the work item", ctx do
    token = token(ctx)
    assert get(build_conn(), frame_path(ctx, token, "home.html")).status == 200

    :ok = Apiary.Edition.put_test_stub(NoWorkItemRead)
    assert_not_found(get(build_conn(), frame_path(ctx, token, "home.html")))
  end

  describe "with workflow_model off" do
    @describetag with_features: Apiary.Features.all() -- [:workflow_model]

    test "the route is the router's not found, under the console's policy", ctx do
      conn = get(build_conn(), frame_path(ctx, token(ctx), "home.html"))
      assert conn.status == 404
      refute conn.resp_body =~ "Home"
      assert [policy] = get_resp_header(conn, "content-security-policy")
      assert policy =~ "frame-ancestors 'none'"
      refute policy =~ "sandbox"
    end
  end
end
