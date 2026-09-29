defmodule ApiaryWeb.JumpControllerTest do
  use ApiaryWeb.ConnCase, async: true

  import Apiary.OrganisationsFixtures
  import Apiary.RunListFixtures

  alias Apiary.Organisations

  setup :register_and_log_in_user

  defp jump(conn, path, q \\ "") do
    conn
    |> put_req_header("accept", "application/json")
    |> get(path, %{"q" => q})
    |> json_response(200)
  end

  defp group(answer, label), do: Enum.find(answer["groups"], &(&1["label"] == label))
  defp labels(nil), do: []
  defp labels(group), do: Enum.map(group["items"], & &1["label"])

  test "with nothing typed: every page the reader may open, the workspace's, the organisation's and their own",
       %{conn: conn, scope: scope} do
    answer = jump(conn, workspace_path(scope, "/jump"))
    go_to = group(answer, "Go to")

    assert "Runs" in labels(go_to)
    assert "Settings › Access keys" in labels(go_to)
    assert "Settings › People" in labels(go_to)
    assert "Profile" in labels(go_to)

    runs = Enum.find(go_to["items"], &(&1["label"] == "Runs"))
    assert runs["href"] == workspace_path(scope, "/runs")
    assert runs["detail"] == scope.workspace.name

    # nothing else is listed for nothing typed but what New offers
    assert Enum.map(answer["groups"], & &1["label"]) == ["Go to", "Actions"]
    assert labels(group(answer, "Actions")) == ["New access key", "Invite people"]
  end

  test "what is typed narrows the pages, in the domain's words", %{conn: conn, scope: scope} do
    answer = jump(conn, workspace_path(scope, "/jump"), "keys")
    assert labels(group(answer, "Go to")) == ["Settings › Access keys"]
    assert answer["status"] == "1 result"

    answer = jump(conn, workspace_path(scope, "/jump"), "no such page")
    assert answer["groups"] == []
    assert answer["empty"] == "Nothing matches “no such page”."
  end

  test "a target by its path, and runs by their id or task", %{conn: conn, scope: scope} do
    run =
      started_run(scope, %{
        "forge" => "github.example",
        "repository" => "acme/shop",
        "task" => "fix-checkout"
      })

    answer = jump(conn, workspace_path(scope, "/jump"), "shop")
    [target] = group(answer, "Repositories")["items"]
    assert target["label"] == "acme/shop"
    assert target["detail"] == "github.example"
    assert target["href"] == workspace_path(scope, "/targets/github.example/acme/shop")

    short = String.slice(run.run_id, 0, 8)
    href = workspace_path(scope, "/runs/#{run.run_id}")

    for q <- [short, String.slice(run.run_id, 0, 4), run.run_id, "https://x.example#{href}"] do
      answer = jump(conn, workspace_path(scope, "/jump"), q)
      assert [%{"href" => ^href}] = group(answer, "Runs")["items"], q
    end

    answer = jump(conn, workspace_path(scope, "/jump"), "checkout")
    assert [%{"label" => label, "href" => ^href}] = group(answer, "Runs")["items"]
    assert label == "#{short} · fix-checkout"

    # three characters are not an id
    refute group(jump(conn, workspace_path(scope, "/jump"), "abc"), "Runs")
  end

  test "places by name and slug", %{conn: conn, user: user, scope: scope} do
    other = sign_up_fixture(%{organisation_name: "Northwind"})
    %{token: token} = invitation_fixture(other.scope, %{"email" => user.email})
    {:ok, _membership} = Organisations.accept_invitation(user, token)

    answer = jump(conn, workspace_path(scope, "/jump"), "northwind")

    assert [%{"label" => "Northwind / " <> _, "href" => href}] =
             group(answer, "Places")["items"]

    assert href == workspace_path(other)
  end

  test "an organisation's path answers for the organisation and the person, never a workspace",
       %{conn: conn, scope: scope} do
    started_run(scope, shop())
    answer = jump(conn, ~p"/#{scope.organisation}/jump")

    refute "Runs" in labels(group(answer, "Go to"))
    assert "Activity" in labels(group(answer, "Go to"))
    assert labels(group(answer, "Actions")) == ["Invite people"]
    refute group(jump(conn, ~p"/#{scope.organisation}/jump", "shop"), "Repositories")
  end

  test "a runner's words are text in the answer", %{conn: conn, scope: scope} do
    started_run(scope, %{
      "forge" => "github.example",
      "repository" => "acme/<b>shop</b>",
      "task" => "<script>x</script>"
    })

    answer = jump(conn, workspace_path(scope, "/jump"), "<")
    assert "acme/<b>shop</b>" in labels(group(answer, "Repositories"))
    assert Enum.any?(labels(group(answer, "Runs")), &(&1 =~ "<script>x</script>"))
  end

  test "nobody signed in is told so, and a stranger finds nothing", %{scope: scope} do
    conn =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> get(workspace_path(scope, "/jump"), %{"q" => "x"})

    assert json_response(conn, 401) == %{"error" => "unauthenticated"}

    stranger = log_in_user(build_conn(), Apiary.AccountsFixtures.user_fixture())

    conn =
      stranger
      |> put_req_header("accept", "application/json")
      |> get(workspace_path(scope, "/jump"), %{"q" => "x"})

    assert conn.status == 404
  end
end
