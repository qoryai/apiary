defmodule ApiaryWeb.ArtifactLive.ShowTest do
  # A version's page (`ApiaryWeb.ArtifactLive.Show`), the page that adds a version by
  # hand (`ApiaryWeb.ArtifactLive.New`) and the plain list (`ApiaryWeb.ArtifactComponents.list/1`):
  # each base view as Qory Apiary shows it, nothing of an artifact as markup, the
  # history read again on a push, a refused push as a line that says what to change, and
  # the pages not found for another workspace and with `workflow_model` off.
  # Not async: the store's root is the application's setting.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import Apiary.StagesFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{ArtifactStoreHook, Artifacts, Processes, Repo}
  alias Apiary.WorkItems.WorkItem
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
    %{dispatch_run: run, run: registered} = explore_run_fixture(work_item)

    Map.merge(context, %{
      conn: log_in_user(build_conn(), user),
      scope: scope,
      work_item: work_item,
      run: run,
      claimed: registered
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

      # The files are read and rendered once, on the connected mount: the first render,
      # the one a GET answers, has an empty block.
      dead = ctx.conn |> get(page(ctx, version)) |> html_response(200)
      refute dead =~ "q-ticket-formatted"
      assert dead =~ ~s(id="artifact-view-#{version.public_id}-pending")

      {:ok, view, html} = live(ctx.conn, page(ctx, version))
      assert html =~ "q-ticket-formatted"

      assert has_element?(view, "#artifact-header-title", "explainer v2")
      assert has_element?(view, "#artifact-type", "explainer")
      assert has_element?(view, "#artifact-number", "2")
      short = String.slice(ctx.claimed.public_id, 0, 11)
      run_page = "/#{ctx.scope.organisation.slug}/#{ctx.scope.workspace.slug}/runs/"

      assert has_element?(
               view,
               ~s(#artifact-writer a[href="#{run_page}#{ctx.claimed.public_id}"]),
               short
             )

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

    test "names the run that made a version, with its round, or a run it cannot name", ctx do
      import Ecto.Query

      Apiary.Repo.update_all(from(d in Apiary.Dispatches.DispatchRun, where: d.id == ^ctx.run.id),
        set: [round: 2]
      )

      version = pushed!(ctx, "explainer", [{"plan.md", "# First"}])
      {:ok, view, _html} = live(ctx.conn, page(ctx, version))
      short = String.slice(ctx.claimed.public_id, 0, 11)
      assert has_element?(view, "#artifact-writer a", "#{short} · round 2")
      assert has_element?(view, "#artifact-history a.font-mono", "#{short} · round 2")

      %{dispatch_run: unclaimed} =
        explore_run_fixture(ctx.work_item, state: :waiting, registered: false)

      {:ok, by_unclaimed} =
        Artifacts.push({:run, unclaimed}, ctx.work_item, "explainer", [
          %{filename: "plan.md", binary: "# Second"}
        ])

      {:ok, view, _html} = live(ctx.conn, page(ctx, by_unclaimed))
      assert has_element?(view, "#artifact-writer", "A run")
      refute has_element?(view, "#artifact-writer a")
    end

    test "names the run without a link for a reader who may not read runs", ctx do
      pushed!(ctx, "explainer", [{"plan.md", "# First"}])
      [%{versions: [version]}] = Artifacts.list(ctx.work_item)
      short = String.slice(ctx.claimed.public_id, 0, 11)

      # A person of another organisation may not read this workspace's runs (`run.read`).
      %{scope: stranger} = sign_up_fixture()
      stranger = %{stranger | workspace: ctx.scope.workspace}

      html = render_component(&ArtifactComponents.made_by/1, version: version, scope: stranger)
      assert html =~ short
      refute html =~ "href="

      html = render_component(&ArtifactComponents.made_by/1, version: version, scope: ctx.scope)
      assert html =~ ~s(href="/#{ctx.scope.organisation.slug}/#{ctx.scope.workspace.slug}/runs/)
    end

    test "offers a document over 256 KiB as a download, not shown", ctx do
      assert ApiaryWeb.ArtifactLive.Markdown.max_bytes() == 262_144
      large = "# Large\n" <> String.duplicate("a", 262_144)
      version = pushed!(ctx, "explainer", [{"plan.md", large}])
      {:ok, view, _html} = live(ctx.conn, page(ctx, version))

      assert render(view) =~ "This document is too large to show here. Download it to read it."
      assert has_element?(view, ~s(a[download="plan.md"]))
      refute has_element?(view, "h3", "Large")

      # At 256 KiB the same document is shown.
      fits = pushed!(ctx, "explainer", [{"plan.md", binary_part(large, 0, 262_144)}])
      {:ok, view, _html} = live(ctx.conn, page(ctx, fits))
      assert has_element?(view, "h3", "Large")
    end

    test "renders one document file at a time, the others as the reader opens them", ctx do
      {:ok, _type} =
        Artifacts.create_type(ctx.scope, ctx.scope.workspace, %{
          name: "demo-findings",
          base_view: :document,
          max_files: 3
        })

      version =
        pushed!(ctx, "demo-findings", [{"a.md", "# Alpha findings"}, {"b.md", "# Beta findings"}])

      {:ok, view, _html} = live(ctx.conn, page(ctx, version))
      view_id = "#artifact-view-#{version.public_id}"

      assert has_element?(view, "#{view_id}-0 h3", "Alpha findings")
      refute render(view) =~ "Beta findings"
      assert has_element?(view, ~s(#{view_id}-documents [aria-current="true"]), "a.md")

      view |> element(~s(#{view_id}-documents button[phx-value-file="b.md"])) |> render_click()

      assert has_element?(view, "#{view_id}-1 h3", "Beta findings")
      refute render(view) =~ "Alpha findings"

      # A filename of no file of the version, or no filename, changes nothing.
      render_hook(view, "show-document", %{"file" => "c.md"})
      assert has_element?(view, "#{view_id}-1 h3", "Beta findings")
      render_hook(view, "show-document", %{})
      assert has_element?(view, "#{view_id}-1 h3", "Beta findings")

      # The file shown is not read again: with its stored copy gone, it stays as it was.
      {:ok, path} = Artifacts.open_file(Enum.find(version.files, &(&1.filename == "b.md")))
      File.rm!(path)
      render_hook(view, "show-document", %{"file" => "b.md"})
      assert has_element?(view, "#{view_id}-1 h3", "Beta findings")
    end

    test "stops reading the history once the reader loses the work item", ctx do
      version = pushed!(ctx, "explainer", [{"plan.md", "# First"}])
      %{user: member, membership: membership} = member_fixture(ctx.scope, :member)
      {:ok, view, _html} = live(log_in_user(build_conn(), member), page(ctx, version))
      listeners = Registry.lookup(Apiary.PubSub, Artifacts.topic(ctx.work_item))
      assert Enum.any?(listeners, fn {pid, _value} -> pid == view.pid end)

      Apiary.Repo.delete!(membership)
      newer = pushed!(ctx, "explainer", [{"plan.md", "# Second"}])

      refute has_element?(view, "#artifact-history-#{newer.public_id}")

      # The page no longer listens on the work item's artifacts topic.
      listeners = Registry.lookup(Apiary.PubSub, Artifacts.topic(ctx.work_item))
      refute Enum.any?(listeners, fn {pid, _value} -> pid == view.pid end)
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

  defp in_stage(work_item, stage_id) do
    {1, _rows} =
      Repo.update_all(from(w in WorkItem, where: w.id == ^work_item.id),
        set: [stage_id: stage_id]
      )
  end

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
      {:ok, view, html} =
        live(
          ctx.conn,
          ArtifactComponents.new_path(ctx.scope, ctx.work_item.number) <> "?type=explainer"
        )

      assert html =~
               "Keep main. Give another name only when this work item keeps two artifacts of this type, such as two mockups called payment and receipt."

      assert html =~ "Document. At most 1 file, 1 MiB in all."

      # The file picker: a button and a place to drop files, the input itself hidden.
      assert has_element?(view, "#artifact-drop[phx-drop-target] input.sr-only[type=file]")
      assert has_element?(view, "#artifact-drop label.btn", "Choose a file")

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

    test "says why the work item takes no new versions: it moved", ctx do
      import Ecto.Query
      work_items = from(w in Apiary.WorkItems.WorkItem, where: w.id == ^ctx.work_item.id)

      {:ok, view, _html} = live(ctx.conn, new_page(ctx, "explainer"))
      other = workspace_fixture(ctx.scope.organisation)
      Apiary.Repo.update_all(work_items, set: [workspace_id: other.id])

      assert add_notes(view) =~
               "Work item ##{ctx.work_item.number} is no longer in this workspace, so it takes no new versions."

      assert Artifacts.list(ctx.work_item) == []
    end

    test "says so when artifacts are turned off after the page opened", ctx do
      {:ok, view, _html} = live(ctx.conn, new_page(ctx, "explainer"))

      previous = Application.get_env(:apiary, :features)
      Application.put_env(:apiary, :features, Apiary.Features.enabled() -- [:workflow_model])
      on_exit(fn -> Application.put_env(:apiary, :features, previous) end)

      html = add_notes(view)
      assert html =~ "Artifacts are not available here. Contact support if you need them."
      refute html =~ "QORY_FEATURES"
    end

    test "says so when the reader can no longer read the work items", ctx do
      %{user: member, membership: membership} = member_fixture(ctx.scope, :member)
      conn = log_in_user(build_conn(), member)
      {:ok, view, _html} = live(conn, new_page(ctx, "explainer"))

      Apiary.Repo.delete!(membership)

      assert add_notes(view) =~
               "You can no longer read the work items of this workspace, so you cannot add a version."

      assert Artifacts.list(ctx.work_item) == []
    end

    test "says where a structured file fails its schema, as text", ctx do
      {:ok, view, _html} = live(ctx.conn, new_page(ctx, "verdict"))
      json = ~s({"verdict":"passed","<i>x</i>":1})

      view
      |> file_input("#artifact-form", :files, [
        %{name: "v.json", content: json, type: "application/json"}
      ])
      |> render_upload("v.json")

      view
      |> form("#artifact-form", artifact: %{type: "verdict", name: "main", note: ""})
      |> render_submit()

      line = view |> element("#artifact-files-error-0") |> render()

      assert line =~ "Fix v.json to match the JSON Schema of verdict: at #,"
      assert line =~ "&lt;i&gt;x&lt;/i&gt;"
      refute line =~ "<i>"
      assert Artifacts.list(ctx.work_item) == []
    end

    test "tells a reader whose level no longer lets them add versions who changes it", ctx do
      assert ApiaryWeb.ArtifactLive.New.role_lines(ctx.scope) == [
               "Your level no longer lets you add versions.",
               "Owners of #{ctx.scope.organisation.name} change your level in Organisation settings › People if you need to."
             ]
    end

    test "gives the general line and logs the cause, with nothing of the files", ctx do
      changeset =
        %Apiary.Artifacts.ArtifactFile{}
        |> Ecto.Changeset.change(filename: "notes.md")
        |> Ecto.Changeset.add_error(:filename, "is taken")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert ApiaryWeb.ArtifactLive.New.general_line(
                   ctx.work_item,
                   "explainer",
                   {:error, changeset}
                 ) == "Add the version again. If it fails again, contact support."
        end)

      assert log =~
               "A push from Add a version failed: " <>
                 "{:error, changeset of Apiary.Artifacts.ArtifactFile, errors on filename}; " <>
                 "work item #{ctx.work_item.public_id}, type explainer"

      refute log =~ "notes.md"
    end

    test "says so when the store cannot keep the files", ctx do
      blocked = Path.join(ctx.tmp_dir, "a-file")
      File.write!(blocked, "")
      Application.put_env(:apiary, :artifacts_dir, Path.join(blocked, "store"))

      {:ok, view, _html} = live(ctx.conn, new_page(ctx, "explainer"))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert add_notes(view) =~ "Store the files again. If it fails again, contact support."
        end)

      # The store's cause, then the page's line: the work item and the type, and nothing
      # of the file.
      assert log =~ "The artifact store could not stage a file of type explainer: :"

      assert log =~
               "A push from Add a version failed: :store_unavailable; " <>
                 "work item #{ctx.work_item.public_id}, type explainer"

      refute log =~ "notes.md"
      refute log =~ "# Notes"
    end

    test "gives the support address in each line that sends the reader to support", ctx do
      Application.put_env(:apiary, :support_address, "support@example.com")
      on_exit(fn -> Application.put_env(:apiary, :support_address, nil) end)

      ExUnit.CaptureLog.capture_log(fn ->
        assert ApiaryWeb.ArtifactLive.New.general_line(ctx.work_item, "explainer", :busy) ==
                 "Add the version again. If it fails again, contact support at support@example.com."
      end)

      blocked = Path.join(ctx.tmp_dir, "a-file")
      File.write!(blocked, "")
      Application.put_env(:apiary, :artifacts_dir, Path.join(blocked, "store"))
      {:ok, view, _html} = live(ctx.conn, new_page(ctx, "explainer"))

      ExUnit.CaptureLog.capture_log(fn ->
        assert add_notes(view) =~
                 "Store the files again. If it fails again, contact support at support@example.com."
      end)

      Application.put_env(:apiary, :artifacts_dir, Path.join(ctx.tmp_dir, "store"))
      {:ok, view, _html} = live(ctx.conn, new_page(ctx, "explainer"))
      previous = Application.get_env(:apiary, :features)
      Application.put_env(:apiary, :features, Apiary.Features.enabled() -- [:workflow_model])
      on_exit(fn -> Application.put_env(:apiary, :features, previous) end)

      assert add_notes(view) =~
               "Artifacts are not available here. Contact support at support@example.com if you need them."
    end

    test "stores the version in the stage the work item moved to before Add version", ctx do
      in_stage(ctx.work_item, "st_aaaaaaaaaa")
      {:ok, view, _html} = live(ctx.conn, new_page(ctx, "explainer"))
      in_stage(ctx.work_item, "st_bbbbbbbbbb")

      assert {:error, {:live_redirect, _to}} = add_notes(view)
      assert %{stage_id: "st_bbbbbbbbbb"} = Artifacts.newest(ctx.work_item, "explainer")
    end

    test "says so when the work item moves while the push stores the files; the next try stores it",
         ctx do
      in_stage(ctx.work_item, "st_aaaaaaaaaa")
      {:ok, view, _html} = live(ctx.conn, new_page(ctx, "explainer"))

      ArtifactStoreHook.on_commit(fn -> in_stage(ctx.work_item, "st_bbbbbbbbbb") end)

      html = add_notes(view)

      assert html =~
               "Add the version again: work item ##{ctx.work_item.number} moved to another stage."

      assert Artifacts.list(ctx.work_item) == []

      # The file stays uploaded, so a second Add version needs nothing more.
      assert html =~ "notes.md"

      assert {:error, {:live_redirect, _to}} =
               view
               |> form("#artifact-form", artifact: %{type: "explainer", name: "main", note: ""})
               |> render_submit()

      assert %{stage_id: "st_bbbbbbbbbb", number: 1} =
               Artifacts.newest(ctx.work_item, "explainer")
    end

    @tag needs: [:factory, :workflow_model]
    test "starts a stage that waits for the version as an input", ctx do
      criteria = %{"type" => "acceptance-criteria", "required" => true}

      {:ok, _process} =
        Processes.save(ctx.scope, ctx.scope.workspace, %{
          "schema" => "qory.process/v1",
          "machine" => "default",
          "stages" => [
            %{
              "id" => "st_r79kph11eg",
              "name" => "Explore",
              "inputs" => [criteria],
              "sequence" => [
                %{"loop" => %{"rounds" => 3, "body" => [%{"workflow" => "explore-a-ticket"}]}}
              ],
              "outputs" => [%{"type" => "proposal", "required" => true}],
              "gate" => %{"kind" => "person", "approvers" => "members"}
            }
          ]
        })

      work_item = taken_in_fixture(ctx.scope)
      assert work_item.stage_state == :waiting_inputs

      {:ok, view, _html} =
        live(ctx.conn, ArtifactComponents.new_path(ctx.scope, work_item.number))

      view
      |> file_input("#artifact-form", :files, [
        %{name: "criteria.md", content: "- The sale price", type: "text/markdown"}
      ])
      |> render_upload("criteria.md")

      assert {:error, {:live_redirect, _to}} =
               view
               |> form("#artifact-form",
                 artifact: %{type: "acceptance-criteria", name: "main", note: ""}
               )
               |> render_submit()

      assert %{stage_state: :running} = Repo.get!(WorkItem, work_item.id)
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

    test "uploads no byte while a file has a size below 0", ctx do
      half = @png <> String.duplicate("a", 6 * 1_048_576)

      for {files, sizes} <- [
            {[{"a.png", @png}, {"c.png", @png}], %{"c.png" => -1}},
            # A size below 0 would lower the sum of 12 MiB under mockup's 10 MiB.
            {[{"a.png", half}, {"b.png", half}, {"c.png", @png}], %{"c.png" => -100_000_000}}
          ] do
        {:ok, view, _html} = live(ctx.conn, new_page(ctx, "mockup"))

        entries =
          for {name, content} <- files, do: %{name: name, content: content, type: "image/png"}

        input = file_input(view, "#artifact-form", :files, entries)

        # The browser sends the sizes; LiveView takes any integer.
        input = %{
          input
          | entries:
              Enum.map(
                input.entries,
                &Map.put(&1, "size", Map.get(sizes, &1["name"], &1["size"]))
              )
        }

        assert {:error, _reason} = render_upload(input, "a.png")

        assert view |> form("#artifact-form", artifact: %{type: "mockup"}) |> render_change() =~
                 "Remove c.png and add it again: the browser sent no size of 0 or more for it."
      end
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

      assert view |> form("#artifact-form", artifact: %{type: "mockup"}) |> render_change() =~
               "Remove or shrink files: the files of a version of mockup come to at most 10 MiB."
    end
  end

  test "size/1 shows a size in binary units" do
    assert Enum.map(
             [812, 1024, 65_536, 1_572_864, 1_048_576, 10_485_760, 1_073_741_824, 1_048_575],
             &ArtifactComponents.size/1
           ) == ["812 B", "1 KiB", "64 KiB", "1.5 MiB", "1 MiB", "10 MiB", "1 GiB", "1 MiB"]
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
