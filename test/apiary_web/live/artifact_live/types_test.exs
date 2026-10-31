defmodule ApiaryWeb.ArtifactLive.TypesTest do
  # Workspace settings › Artifact types (`ApiaryWeb.ArtifactLive.Types`): listed for
  # owners and admins, not for members; the standard types read only; a custom type
  # added, edited and deleted, a type in use kept with a line why; the add form filled
  # from `?name=` when the name is free and well formed; and the section absent with
  # `workflow_model` off.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.Artifacts

  @moduletag needs: :workflow_model

  setup :register_and_log_in_user

  defp types_path(scope, tail \\ ""),
    do: ~p"/#{scope.organisation}/#{scope.workspace}/settings/artifact-types" <> tail

  # The status a path answers: the instance's gate answers before the router, and a
  # page's gate raises a 404 exception.
  defp status(conn, path) do
    get(conn, path).status
  rescue
    error -> Plug.Exception.status(error)
  end

  defp custom!(scope, attrs) do
    {:ok, type} = Artifacts.create_type(scope, scope.workspace, attrs)
    type
  end

  test "lists the standard types read only and the custom types with their menu", ctx do
    type =
      custom!(ctx.scope, %{
        "name" => "bid-set",
        "base_view" => "structured",
        "json_schema" => %{"type" => "object"}
      })

    {:ok, view, _html} = live(ctx.conn, types_path(ctx.scope))

    assert has_element?(view, "#settings-tab-artifact_types")

    assert has_element?(
             view,
             "#artifact-types-standard-table #artifact-type-explainer",
             "Document"
           )

    assert has_element?(
             view,
             "#artifact-types-standard-table #artifact-type-demo-video",
             "200 MiB"
           )

    refute has_element?(view, "#artifact-types-standard-table [id$=-menu]")
    assert has_element?(view, "#artifact-type-#{type.public_id}", "Structured")
    assert has_element?(view, "#artifact-type-#{type.public_id}-menu")
    refute render(view) =~ "Workflows</th>"
  end

  test "adds a custom type and shows a refused name as the line to fix", ctx do
    {:ok, view, _html} = live(ctx.conn, types_path(ctx.scope, "/new"))

    html =
      view
      |> form("#artifact-type-form",
        artifact_type: %{name: "Bid Set", base_view: "document", size_mib: "2", max_files: "3"}
      )
      |> render_submit()

    assert html =~
             "Use lowercase letters and digits, in groups joined by single hyphens, at most 64 characters."

    html =
      view
      |> form("#artifact-type-form",
        artifact_type: %{name: "explainer", base_view: "document", size_mib: "2", max_files: "3"}
      )
      |> render_submit()

    assert html =~ "Choose another name: explainer is a standard type."

    view
    |> form("#artifact-type-form",
      artifact_type: %{
        name: "demo-findings",
        base_view: "document",
        size_mib: "2",
        max_files: "3"
      }
    )
    |> render_submit()

    assert_patch(view, types_path(ctx.scope))
    assert render(view) =~ "demo-findings added."
    type = Artifacts.type(ctx.scope.workspace, "demo-findings")
    assert {type.size_limit, type.max_files, type.base_view} == {2 * 1_048_576, 3, :document}
  end

  test "shows the size line for a size too large to read", ctx do
    {:ok, view, _html} = live(ctx.conn, types_path(ctx.scope, "/new"))

    for size <- ["1e308", "1048577", "1e400"] do
      html =
        view
        |> form("#artifact-type-form",
          artifact_type: %{name: "big-file", base_view: "file", size_mib: size, max_files: "1"}
        )
        |> render_submit()

      assert html =~ "Set a size limit above 0 and at most", size
    end

    assert Artifacts.type(ctx.scope.workspace, "big-file") == nil
  end

  test "edits a custom type's limits and schema", ctx do
    type =
      custom!(ctx.scope, %{
        "name" => "bid-set",
        "base_view" => "structured",
        "json_schema" => %{"type" => "object"}
      })

    {:ok, view, _html} = live(ctx.conn, types_path(ctx.scope, "/#{type.public_id}/edit"))

    html =
      view
      |> form("#artifact-type-form", artifact_type: %{size_mib: "0.5", json_schema: "not json"})
      |> render_submit()

    assert html =~
             "Paste a JSON Schema: one JSON object of at most 64 KiB that Qory Apiary can build."

    view
    |> form("#artifact-type-form",
      artifact_type: %{size_mib: "0.5", json_schema: ~s({"type":"array"})}
    )
    |> render_submit()

    assert_patch(view, types_path(ctx.scope))
    type = Artifacts.type(ctx.scope.workspace, "bid-set")
    assert {type.size_limit, type.json_schema} == {524_288, %{"type" => "array"}}
  end

  test "deletes a custom type, and keeps one in use with a line why", ctx do
    unused = custom!(ctx.scope, %{"name" => "demo-findings", "base_view" => "document"})
    used = custom!(ctx.scope, %{"name" => "bid-set", "base_view" => "document"})

    work_item = work_item_fixture(ctx.scope)
    %{dispatch_run: run} = explore_run_fixture(work_item)

    store =
      Path.join(System.tmp_dir!(), "apiary-types-test-#{System.unique_integer([:positive])}")

    previous = Application.get_env(:apiary, :artifacts_dir)
    Application.put_env(:apiary, :artifacts_dir, store)

    try do
      {:ok, _version} =
        Artifacts.push({:run, run}, work_item, "bid-set", [%{filename: "a.md", binary: "# A"}])
    after
      Application.put_env(:apiary, :artifacts_dir, previous)
      File.rm_rf!(store)
    end

    {:ok, view, _html} = live(ctx.conn, types_path(ctx.scope, "/#{unused.public_id}/delete"))
    view |> element("#artifact-type-delete") |> render_click()
    assert render(view) =~ "demo-findings deleted."
    assert Artifacts.type(ctx.scope.workspace, "demo-findings") == nil

    {:ok, view, _html} = live(ctx.conn, types_path(ctx.scope, "/#{used.public_id}/delete"))
    view |> element("#artifact-type-delete") |> render_click()

    assert has_element?(
             view,
             "#artifact-type-in-use",
             "bid-set cannot be deleted: work items of this workspace have artifacts of this type."
           )
  end

  describe "?name=" do
    test "opens the add form with a free, well-formed name filled in", ctx do
      {:ok, view, _html} = live(ctx.conn, types_path(ctx.scope, "?name=demo-findings"))

      assert has_element?(
               view,
               ~s(#artifact-type-form input[name="artifact_type[name]"][value="demo-findings"])
             )
    end

    test "opens the form empty for a malformed name or one a type has", ctx do
      custom!(ctx.scope, %{"name" => "bid-set", "base_view" => "document"})

      for name <- ["Bid Set", "bid-set", "explainer", "%3Cb%3E"] do
        {:ok, view, _html} = live(ctx.conn, types_path(ctx.scope, "?name=#{name}"))
        assert has_element?(view, "#artifact-type-form"), name

        assert has_element?(
                 view,
                 ~s(#artifact-type-form input[name="artifact_type[name]"][value=""])
               ),
               name
      end
    end
  end

  test "is not listed or opened for a member", ctx do
    %{user: member} = member_fixture(ctx.scope, :member)
    conn = log_in_user(build_conn(), member)

    {:ok, view, _html} =
      live(conn, ~p"/#{ctx.scope.organisation}/#{ctx.scope.workspace}/settings")

    refute has_element?(view, "#settings-tab-artifact_types")
    assert status(conn, types_path(ctx.scope)) in [302, 404]
  end

  test "is open to an admin", ctx do
    %{user: admin} = member_fixture(ctx.scope, :admin)
    {:ok, view, _html} = live(log_in_user(build_conn(), admin), types_path(ctx.scope))
    assert has_element?(view, "#artifact-type-add")
  end
end

defmodule ApiaryWeb.ArtifactLive.TypesWithoutWorkflowModelTest do
  # With `workflow_model` off, Artifact types is not listed and its paths are not found.
  # Not async: the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  defp status(conn, path) do
    get(conn, path).status
  rescue
    error -> Plug.Exception.status(error)
  end

  @tag with_features: Apiary.Features.all() -- [:workflow_model]
  test "the section is not listed and its paths are not found", %{conn: conn, scope: scope} do
    {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings")
    refute has_element?(view, "#settings-tab-artifact_types")

    base = "/#{scope.organisation.slug}/#{scope.workspace.slug}/settings/artifact-types"

    for path <- [base, base <> "/new", base <> "?name=bid-set"] do
      assert status(conn, path) == 404, path
    end
  end
end
