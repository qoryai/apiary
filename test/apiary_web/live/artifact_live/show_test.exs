defmodule ApiaryWeb.ArtifactLive.ShowTest do
  # A version's page (`ApiaryWeb.ArtifactLive.Show`), the page that adds a version by
  # hand (`ApiaryWeb.ArtifactLive.New`) and the plain list (`ApiaryWeb.ArtifactComponents.list/1`):
  # each base view as Qory Apiary shows it, nothing of an artifact as markup, the
  # history read again on a push, a refused push as a line that says what to change, and
  # the pages not found for another workspace and with `workflow_model` off.
  # Not async: the store's root is the application's setting.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.Artifacts
  alias ApiaryWeb.ArtifactComponents

  @moduletag :tmp_dir
  @moduletag needs: :workflow_model

  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR">>
  @svg ~s(<svg xmlns="http://www.w3.org/2000/svg"><rect/></svg>)
  @mp4 <<0, 0, 0, 24, "ftypisom", 0, 0, 2, 0, "isomiso2">>
  @document """
  # Checkout

  <script>window.pwned = true</script>

  The gift card field, see [the plan](https://example.com/plan).

  ```mermaid
  flowchart LR
    Cart --> Pay
  ```
  """

  setup %{tmp_dir: tmp_dir} = context do
    previous = Application.get_env(:apiary, :artifacts_dir)
    Application.put_env(:apiary, :artifacts_dir, Path.join(tmp_dir, "store"))
    on_exit(fn -> Application.put_env(:apiary, :artifacts_dir, previous) end)

    %{user: user, scope: scope} = sign_up_fixture()
    work_item = work_item_fixture(scope)
    %{dispatch_run: run} = explore_run_fixture(work_item)

    Map.merge(context, %{
      conn: log_in_user(build_conn(), user),
      scope: scope,
      work_item: work_item,
      run: run
    })
  end

  # The status a path answers: the instance's gate answers before the router, and a
  # page's gate raises a 404 exception.
  defp status(conn, path) do
    get(conn, path).status
  rescue
    error -> Plug.Exception.status(error)
  end

  defp pushed!(ctx, type, files, opts \\ []) do
    files = Enum.map(files, fn {filename, bytes} -> %{filename: filename, binary: bytes} end)
    {:ok, version} = Artifacts.push({:run, ctx.run}, ctx.work_item, type, files, opts)
    version
  end

  defp page(ctx, version),
    do: ArtifactComponents.version_path(ctx.scope, ctx.work_item.number, version.public_id)

  defp file_path(ctx, version, filename) do
    "/#{ctx.scope.organisation.slug}/#{ctx.scope.workspace.slug}/work/#{ctx.work_item.number}" <>
      "/artifacts/#{version.public_id}/files/#{filename}"
  end

  describe "a version's page" do
    test "shows a document's Markdown with no raw HTML, and its diagram for the hook", ctx do
      pushed!(ctx, "explainer", [{"plan.md", "# First"}])
      version = pushed!(ctx, "explainer", [{"plan.md", @document}], note: "Second pass")

      {:ok, view, dead} = live(ctx.conn, page(ctx, version))
      html = render(view)

      # The files are read and rendered once, on the connected mount.
      refute dead =~ "q-ticket-formatted"
      assert html =~ "q-ticket-formatted"

      assert has_element?(view, "#artifact-header-title", "explainer v2")
      assert has_element?(view, "#artifact-type", "explainer")
      assert has_element?(view, "#artifact-number", "2")
      assert has_element?(view, "#artifact-writer", "A run")
      assert has_element?(view, "#artifact-note", "Second pass")
      refute html =~ "<script>window"
      refute html =~ "pwned"
      assert has_element?(view, ~s(a[href="https://example.com/plan"]))
      assert has_element?(view, ~s([phx-hook="Mermaid"][data-script="/assets/js/mermaid.js"]))
      assert has_element?(view, "pre.q-mermaid-source code", "Cart --> Pay")

      assert has_element?(
               view,
               ~s(#artifact-files a[href="#{file_path(ctx, version, "plan.md")}"])
             )

      # The history, newest first, each a link; this version is the current one.
      assert [_v2, _v1] =
               view
               |> element("#artifact-history ol")
               |> render()
               |> then(&Regex.scan(~r/Version \d/, &1))

      assert has_element?(view, ~s(#artifact-history a[aria-current="page"]), "Version 2")
    end

    test "shows raster images inline and an SVG as a download only", ctx do
      version = pushed!(ctx, "mockup", [{"form.png", @png}, {"form.svg", @svg}])
      {:ok, view, _html} = live(ctx.conn, page(ctx, version))

      assert has_element?(view, ~s(img[src="#{file_path(ctx, version, "form.png")}"]))
      refute has_element?(view, ~s(img[src="#{file_path(ctx, version, "form.svg")}"]))
      refute has_element?(view, "svg rect")

      assert has_element?(
               view,
               ~s(figure a[href="#{file_path(ctx, version, "form.svg")}"][download])
             )
    end

    test "shows a video with its captions", ctx do
      version = pushed!(ctx, "demo-video", [{"demo.mp4", @mp4}, {"en.vtt", "WEBVTT\n"}])
      {:ok, view, _html} = live(ctx.conn, page(ctx, version))

      assert has_element?(
               view,
               ~s(video source[src="#{file_path(ctx, version, "demo.mp4")}"][type="video/mp4"])
             )

      assert has_element?(
               view,
               ~s(video track[kind="captions"][src="#{file_path(ctx, version, "en.vtt")}"])
             )
    end

    test "shows structured JSON as a table of text, a change's http URL as a link", ctx do
      change =
        pushed!(ctx, "change", [
          {"change.json", ~s({"url":"https://example.com/pr/7","title":"<b>Gift cards</b>"})}
        ])

      {:ok, view, _dead} = live(ctx.conn, page(ctx, change))
      html = render(view)

      assert has_element?(view, ~s(table a[href="https://example.com/pr/7"]))
      assert html =~ "&lt;b&gt;Gift cards&lt;/b&gt;"
      refute html =~ "<b>Gift cards"

      {:ok, _type} =
        Artifacts.create_type(ctx.scope, ctx.scope.workspace, %{
          name: "bid-set",
          base_view: :structured,
          json_schema: %{"type" => "object"}
        })

      bids =
        pushed!(ctx, "bid-set", [
          {"bids.json", ~s({"campaign":{"name":"Web shop","bids":[1.5,"javascript:x"]}})}
        ])

      {:ok, view, _html} = live(ctx.conn, page(ctx, bids))

      assert has_element?(view, "table table th", "name")
      assert has_element?(view, "table table td", "Web shop")
      assert has_element?(view, "table table table td", "javascript:x")
      refute has_element?(view, ~s(a[href="javascript:x"]))
    end

    test "says the table is cut only when values are left out" do
      shown = fn values ->
        render_component(&ArtifactComponents.view/1,
          id: "view",
          type: %Apiary.Artifacts.Type{name: "bid-set", base_view: :structured},
          version: %Apiary.Artifacts.Version{
            files: [%Apiary.Artifacts.ArtifactFile{filename: "a.json"}]
          },
          content: %{"a.json" => {:json, values}},
          path: fn _file -> "/a.json" end
        )
      end

      refute shown.(List.duplicate(1, 5000)) =~ "Shown: the first"
      refute shown.(%{"a" => List.duplicate(1, 4999)}) =~ "Shown: the first"
      assert shown.(List.duplicate(1, 5001)) =~ "Shown: the first 5,000 values."
      assert shown.(%{"a" => List.duplicate(1, 5000)}) =~ "Shown: the first 5,000 values."
    end

    test "is read again when a version is pushed to its work item", ctx do
      version = pushed!(ctx, "explainer", [{"plan.md", "# First"}])
      {:ok, view, _html} = live(ctx.conn, page(ctx, version))

      newer = pushed!(ctx, "explainer", [{"plan.md", "# Second"}])
      assert render(view) =~ "Version 2"
      assert has_element?(view, "#artifact-history-#{newer.public_id}")
    end

    test "is open to a member, with Add a version", ctx do
      version = pushed!(ctx, "explainer", [{"plan.md", "# First"}])
      %{user: member} = member_fixture(ctx.scope, :member)

      {:ok, view, _html} = live(log_in_user(build_conn(), member), page(ctx, version))
      assert has_element?(view, "#artifact-add")
    end

    test "is not found for another work item's version or another workspace", ctx do
      version = pushed!(ctx, "explainer", [{"plan.md", "# First"}])
      other = work_item_fixture(ctx.scope)

      assert status(
               ctx.conn,
               ArtifactComponents.version_path(ctx.scope, other.number, version.public_id)
             ) ==
               404

      %{user: stranger} = sign_up_fixture()
      assert status(log_in_user(build_conn(), stranger), page(ctx, version)) == 404
    end
  end

  defp new_page(ctx, type),
    do: ArtifactComponents.new_path(ctx.scope, ctx.work_item.number) <> "?type=" <> type

  # Adds notes.md as an explainer on an open Add a version page; the page's HTML after.
  defp add_notes(view) do
    view
    |> file_input("#artifact-form", :files, [
      %{name: "notes.md", content: "# Notes", type: "text/markdown"}
    ])
    |> render_upload("notes.md")

    view
    |> form("#artifact-form", artifact: %{type: "explainer", name: "main", note: ""})
    |> render_submit()
  end

  describe "adding a version by hand" do
    test "stores the files and goes to the new version's page", ctx do
      {:ok, view, _html} =
        live(
          ctx.conn,
          ArtifactComponents.new_path(ctx.scope, ctx.work_item.number) <> "?type=explainer"
        )

      input =
        file_input(view, "#artifact-form", :files, [
          %{name: "notes.md", content: "# Notes", type: "text/markdown"}
        ])

      assert render_upload(input, "notes.md") =~ "notes.md"

      view
      |> form("#artifact-form", artifact: %{type: "explainer", name: "main", note: "By hand"})
      |> render_submit()

      [artifact] = Artifacts.list(ctx.work_item)
      [version] = artifact.versions

      assert {version.writer, version.note, version.user_id} ==
               {:person, "By hand", ctx.scope.user.id}

      assert_redirect(view, page(ctx, version))
    end

    test "says what to change when the push refuses the files or the name", ctx do
      {:ok, view, _html} =
        live(ctx.conn, ArtifactComponents.new_path(ctx.scope, ctx.work_item.number))

      input =
        file_input(view, "#artifact-form", :files, [
          %{name: "notes.png", content: @png, type: "image/png"}
        ])

      render_upload(input, "notes.png")

      html =
        view
        |> form("#artifact-form", artifact: %{type: "explainer", name: "main", note: ""})
        |> render_submit()

      assert html =~ "Rename notes.png to end in .md: a document is a Markdown file."

      html =
        view
        |> form("#artifact-form", artifact: %{type: "mockup", name: "Main Screen", note: ""})
        |> render_submit()

      assert html =~
               "Use lowercase letters and digits, in groups joined by single hyphens, at most 64 characters."

      assert Artifacts.list(ctx.work_item) == []
    end

    test "counts the chosen type's most files as the reader adds them", ctx do
      {:ok, view, _html} =
        live(ctx.conn, ArtifactComponents.new_path(ctx.scope, ctx.work_item.number))

      input =
        file_input(view, "#artifact-form", :files, [
          %{name: "a.md", content: "# A", type: "text/markdown"},
          %{name: "b.md", content: "# B", type: "text/markdown"}
        ])

      render_upload(input, "a.md")
      render_upload(input, "b.md")

      html = view |> form("#artifact-form", artifact: %{type: "explainer"}) |> render_change()
      assert html =~ "Remove files: a version of explainer has at most 1 file."
    end

    test "says why the work item takes no new versions", ctx do
      import Ecto.Query
      work_items = from(w in Apiary.WorkItems.WorkItem, where: w.id == ^ctx.work_item.id)
      Apiary.Repo.update_all(work_items, set: [stage_id: "a stage!"])

      {:ok, view, _html} = live(ctx.conn, new_page(ctx, "explainer"))
      html = add_notes(view)

      assert html =~
               "Work item ##{ctx.work_item.number} takes no new versions in its stage: the stage&#39;s id is not 1 to 64 letters, digits, hyphens or underscores."

      Apiary.Repo.update_all(work_items, set: [stage_id: nil])
      {:ok, view, _html} = live(ctx.conn, new_page(ctx, "explainer"))
      other = workspace_fixture(ctx.scope.organisation)
      Apiary.Repo.update_all(work_items, set: [workspace_id: other.id])

      assert add_notes(view) =~
               "Work item ##{ctx.work_item.number} is no longer in this workspace, so it takes no new versions."

      assert Artifacts.list(ctx.work_item) == []
    end

    test "sets the upload from the chosen type", ctx do
      {:ok, view, _html} = live(ctx.conn, new_page(ctx, "explainer"))

      # explainer takes 1 file of at most 1 MiB, so LiveView refuses a larger file before
      # it uploads a byte.
      big = String.duplicate("a", 1_048_577)
      input = file_input(view, "#artifact-form", :files, [%{name: "a.md", content: big}])
      assert {:error, [[_ref, :too_large]]} = render_upload(input, "a.md")
    end

    test "sets the upload again when the type changes with no file", ctx do
      {:ok, view, _html} = live(ctx.conn, new_page(ctx, "explainer"))
      view |> form("#artifact-form", artifact: %{type: "mockup"}) |> render_change()

      input =
        file_input(view, "#artifact-form", :files, [
          %{name: "a.png", content: @png, type: "image/png"},
          %{name: "b.png", content: @png, type: "image/png"}
        ])

      assert render_upload(input, "a.png") =~ "a.png"
      assert render_upload(input, "b.png") =~ "b.png"
      refute has_element?(view, "#artifact-files-error-0")
    end

    test "asks for the files again when the type changes after they are added", ctx do
      {:ok, view, _html} = live(ctx.conn, new_page(ctx, "explainer"))

      file_input(view, "#artifact-form", :files, [
        %{name: "a.png", content: @png, type: "image/png"},
        %{name: "b.png", content: @png, type: "image/png"}
      ])
      |> render_upload("a.png")

      html = view |> form("#artifact-form", artifact: %{type: "mockup"}) |> render_change()

      assert html =~
               "Remove the files and add them again, so they are checked against mockup."
    end

    test "uploads no byte of files that come to more than the type's size limit", ctx do
      {:ok, view, _html} = live(ctx.conn, new_page(ctx, "mockup"))

      # mockup takes at most 10 MiB in all: each file fits, the two together do not.
      half = @png <> String.duplicate("a", 6 * 1_048_576)

      input =
        file_input(view, "#artifact-form", :files, [
          %{name: "a.png", content: half, type: "image/png"},
          %{name: "b.png", content: half, type: "image/png"}
        ])

      assert {:error, _reason} = render_upload(input, "a.png")

      assert render(view) =~
               "Remove or shrink files: the files of a version of mockup come to at most"
    end
  end

  describe "the plain list" do
    test "shows each artifact's newest version, files, writer and check, with links", ctx do
      pushed!(ctx, "explainer", [{"plan.md", "# First"}])
      newest = pushed!(ctx, "explainer", [{"plan.md", "# Second"}])
      pushed!(ctx, "mockup", [{"a.png", @png}, {"b.png", @png}], name: "checkout")

      html =
        render_component(&ArtifactComponents.list/1,
          id: "list",
          artifacts: Artifacts.list(ctx.work_item),
          scope: ctx.scope,
          number: ctx.work_item.number,
          checks: %{"explainer" => :passed},
          add: true
        )

      assert html =~ "explainer v2"
      assert html =~ "mockup checkout v1"
      assert html =~ "2 files"
      assert html =~ "Check passed"
      assert html =~ ~s(href="#{page(ctx, newest)}")
      assert html =~ "Add a version"

      bare =
        render_component(&ArtifactComponents.list/1,
          id: "list",
          artifacts: Artifacts.list(ctx.work_item)
        )

      refute bare =~ "href="
      refute bare =~ "Check"
    end
  end

  describe "with workflow_model off" do
    @describetag with_features: Apiary.Features.all() -- [:workflow_model]

    test "the pages are not found", ctx do
      version = pushed!(ctx, "explainer", [{"plan.md", "# First"}])

      for path <- [
            page(ctx, version),
            ArtifactComponents.new_path(ctx.scope, ctx.work_item.number)
          ] do
        assert status(ctx.conn, path) == 404, path
      end
    end
  end
end
