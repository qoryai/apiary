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

  alias Apiary.{ArtifactStoreHook, Artifacts, Processes, Repo, WorkItems}
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
    %{dispatch_run: run, run: registered} = explore_run_fixture(work_item, state: :handed_over)

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

  # A mockup of pages of two screens, home and cart; home's title has markup, as text.
  defp mockup_pages do
    page = fn title, body ->
      ~s(<!doctype html><html><head><meta charset="utf-8"><title>#{title}</title></head>) <>
        "<body>#{body}</body></html>"
    end

    index = %{
      "start" => "home",
      "screens" => [
        %{
          "id" => "home",
          "title" => "Home <b>",
          "file" => "home.html",
          "criteria" => [],
          "links" => [%{"to" => "cart", "label" => "Cart"}]
        },
        %{
          "id" => "cart",
          "title" => "Cart",
          "file" => "cart.html",
          "criteria" => [],
          "links" => []
        }
      ]
    }

    [
      {"screens.json", Jason.encode!(index)},
      {"home.html", page.("Home &lt;b&gt;", ~s(<a href="cart.html">Cart</a>))},
      {"cart.html", page.("Cart", "<p>Cart</p>")}
    ]
  end

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
      short = "Run #{ctx.claimed.number}"
      run_page = "/#{ctx.scope.organisation.slug}/#{ctx.scope.workspace.slug}/runs/"

      assert has_element?(
               view,
               ~s(#artifact-writer a[href="#{run_page}#{ctx.claimed.number}"]),
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
               ~s([phx-hook="Mermaid"][data-not-drawn="Qory Apiary does not draw this diagram, so it is shown as written."])
             )

      assert has_element?(
               view,
               ~s([phx-hook="Mermaid"][data-failed="This diagram has an error, so it is shown as written."])
             )

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

    test "shows only a proposal's Markdown file as its document, its images as words", ctx do
      text = "# Invoice total\n\n![Invoice header](checkout.svg)\n\n![x](sources.json)\n"
      version = pushed!(ctx, "proposal", [{"proposal.md", text}])

      # A proposal version with an image and sources.json beside its Markdown: the push of
      # this branch takes one Markdown file, so the other files are added as rows, before
      # the Markdown file in the version's order.
      [markdown] = version.files

      for {filename, type} <- [
            {"checkout.svg", "image/svg+xml"},
            {"sources.json", "application/json"}
          ] do
        Repo.insert!(%{
          markdown
          | id: nil,
            __meta__: %{markdown.__meta__ | state: :built},
            filename: filename,
            content_type: type
        })
      end

      files = Repo.preload(version, :files, force: true).files
      version = %{version | files: Enum.sort_by(files, &(&1.filename == "proposal.md"))}
      assert List.last(version.files).filename == "proposal.md"
      type = ApiaryWeb.ArtifactLive.Load.type(ctx.work_item, "proposal")

      assert Enum.map(ArtifactComponents.documents(type, version), & &1.filename) == [
               "proposal.md"
             ]

      {:ok, view, _html} = live(ctx.conn, page(ctx, version))
      view_id = "#artifact-view-#{version.public_id}"

      assert has_element?(view, "#{view_id}-0 h3", "Invoice total")
      assert has_element?(view, "#{view_id}-0", "Image: Invoice header")
      assert has_element?(view, "#{view_id}-0", "Image: x")
      refute has_element?(view, "#{view_id}-0 img")
      refute has_element?(view, "#{view_id}-documents")

      for filename <- ["proposal.md", "checkout.svg", "sources.json"] do
        assert has_element?(
                 view,
                 ~s(#artifact-files a[href="#{file_path(ctx, version, filename)}"]),
                 filename
               )
      end

      # An image or sources.json is never rendered as a document.
      for filename <- ["sources.json", "checkout.svg"] do
        render_hook(view, "show-document", %{"file" => filename})
        assert has_element?(view, "#{view_id}-0 h3", "Invoice total")
        refute has_element?(view, "#{view_id}-1")
      end
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

    test "shows a run's mockup of pages in a sandboxed frame beside its list of screens", ctx do
      version = pushed!(ctx, "mockup", mockup_pages())
      {:ok, view, html} = live(ctx.conn, page(ctx, version))
      view_id = "#artifact-view-#{version.public_id}"
      frame = "artifact-view-#{version.public_id}-frame"

      screen =
        &ArtifactComponents.mockup_path(ctx.scope, ctx.work_item.number, version.public_id, &1)

      assert has_element?(view, "#artifact-view-title", "Mockup")

      assert view |> element("#artifact-type") |> render() =~
               ~r/mockup\s*<span class="text-muted">· Mockup<\/span>/

      [iframe] =
        html |> LazyHTML.from_document() |> LazyHTML.query("#{view_id} iframe") |> Enum.to_list()

      [attributes] = LazyHTML.attributes(iframe)
      attributes = Map.new(attributes)

      assert attributes["sandbox"] == ""
      assert attributes["src"] == screen.("home")
      assert attributes["title"] == "Mockup screen"
      assert attributes["name"] == frame
      refute Map.has_key?(attributes, "allow")
      refute Map.has_key?(attributes, "srcdoc")

      assert has_element?(view, "#{view_id} nav[aria-labelledby] h3", "Screens")
      assert has_element?(view, "#{view_id} nav h3 .q-part-n", "2")

      links = html |> LazyHTML.from_document() |> LazyHTML.query("#{view_id} nav a")
      assert LazyHTML.text(links) |> String.replace(~r/\s+/, " ") =~ "Home <b>"

      for {node, id} <- Enum.zip(Enum.to_list(links), ["home", "cart"]) do
        [attributes] = LazyHTML.attributes(node)

        assert Map.new(attributes) == %{
                 "href" => screen.(id),
                 "target" => frame,
                 "class" => "text-accent break-words"
               }
      end

      assert has_element?(view, "#{view_id}-screen-home span.text-muted", "Start screen")
      refute has_element?(view, "#{view_id}-screen-cart span", "Start screen")
      # No link opens a screen alone: each to a screen opens it in the frame. The Files
      # part keeps each page's download, an attachment.
      for node <- html |> LazyHTML.from_document() |> LazyHTML.query(~s(a[href*="/mockup/"])) do
        assert [[{"target", ^frame}]] =
                 LazyHTML.attributes(node)
                 |> Enum.map(&Enum.filter(&1, fn {k, _} -> k == "target" end))
      end

      refute has_element?(view, "#{view_id} nav [phx-click]")
      refute has_element?(view, "#{view_id} nav script")
      refute html =~ "<b>"
    end

    test "shows a mockup of pictures as images, under Image, as before", ctx do
      version = pushed!(ctx, "mockup", [{"form.png", @png}])
      {:ok, view, html} = live(ctx.conn, page(ctx, version))

      assert has_element?(view, "#artifact-view-title", "Image")
      assert has_element?(view, ~s(img[src="#{file_path(ctx, version, "form.png")}"]))
      refute html =~ "<iframe"
      refute html =~ "Screens"
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

    test "a questions version shows a question's context as the Explore tab shows it", ctx do
      context =
        "See the [order export](https://example.com/export).\n\n<script>window.pwned = true</script>\n\n" <>
          "[bad](javascript:alert(1)) and [mail](mailto:a@example.com)"

      version =
        pushed!(ctx, "questions", [
          {"questions.json",
           Jason.encode!(%{
             "questions" => [
               %{
                 "id" => "q1",
                 "question" => "Which [order export](https://example.com/export)?",
                 "context" => context,
                 "options" => [],
                 "state" => "open",
                 "asked" => %{"run" => 1, "at" => "2026-11-05T10:00:00Z"}
               }
             ]
           })}
        ])

      {:ok, view, _html} = live(ctx.conn, page(ctx, version))

      assert has_element?(
               view,
               ~s(table .q-ticket-formatted.q-xp-md a[href="https://example.com/export"]),
               "order export"
             )

      assert has_element?(view, ~s(table .q-ticket-formatted a[href="mailto:a@example.com"]))
      refute has_element?(view, ~s(a[href^="javascript:"]))
      refute render(view) =~ "<script>window.pwned"

      # The question itself is plain text, on the tab too.
      assert has_element?(view, "table td", "Which [order export](https://example.com/export)?")
    end

    test "only a questions document's context is Markdown" do
      markdown = "See [the plan](https://example.com/plan)."

      shown = fn name, view, value ->
        render_component(&ArtifactComponents.view/1,
          id: "view",
          type: %Apiary.Artifacts.Type{name: name, base_view: :structured, view: view},
          version: %Apiary.Artifacts.Version{
            files: [%Apiary.Artifacts.ArtifactFile{filename: "a.json"}]
          },
          content: %{"a.json" => {:json, value}},
          path: fn _file -> "/a.json" end
        )
      end

      assert shown.("questions", :questions, %{"context" => markdown}) =~
               ~s(<a href="https://example.com/plan")

      for {name, view, value} <- [
            {"questions", :questions, %{"note" => markdown}},
            {"bid-set", nil, %{"context" => markdown}},
            {"verdict", :verdict, %{"context" => markdown}},
            {"change", :change, %{"context" => markdown}}
          ] do
        html = shown.(name, view, value)
        assert html =~ markdown, name
        refute html =~ "<a href", name
      end
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

    test "shows the run that made a version with its round, or A run for one with no number",
         ctx do
      import Ecto.Query

      Apiary.Repo.update_all(from(d in Apiary.Dispatches.DispatchRun, where: d.id == ^ctx.run.id),
        set: [round: 2]
      )

      version = pushed!(ctx, "explainer", [{"plan.md", "# First"}])
      {:ok, view, _html} = live(ctx.conn, page(ctx, version))
      writer = "Run #{ctx.claimed.number} · round 2"
      assert has_element?(view, "#artifact-writer a", writer)
      assert has_element?(view, "#artifact-history a", writer)

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
      short = "Run #{ctx.claimed.number}"

      # A person of another organisation may not read this workspace's runs (`run.read`).
      %{scope: stranger} = sign_up_fixture()
      stranger = %{stranger | workspace: ctx.scope.workspace}

      html = render_component(&ArtifactComponents.made_by/1, version: version, scope: stranger)
      assert html =~ short
      refute html =~ "href="

      html = render_component(&ArtifactComponents.made_by/1, version: version, scope: ctx.scope)
      assert html =~ ~s(href="/#{ctx.scope.organisation.slug}/#{ctx.scope.workspace.slug}/runs/)
    end

    # A work item moves with its artifacts, and its runs stay in the workspace they ran in:
    # this workspace may have another run with that number.
    test "shows a run of another workspace without a link, after a real move", ctx do
      connection = ticket_connection_fixture(ctx.scope)
      ticket = backlog_ticket_fixture(ctx.scope, connection: connection)
      {:ok, work_item} = WorkItems.take_in(ctx.scope, ticket.public_id)
      %{dispatch_run: run, run: claimed} = explore_run_fixture(work_item, state: :handed_over)
      pushed!(%{ctx | run: run, work_item: work_item}, "explainer", [{"plan.md", "# First"}])

      there = workspace_scope(ctx.scope.user, workspace_fixture(ctx.scope.organisation))

      %{work_item: moved} =
        moved_work_item_fixture(ctx.scope, work_item, ticket, connection, there)

      assert moved.workspace_id == there.workspace.id

      [%{versions: [version]}] = Artifacts.list(moved)

      html = render_component(&ArtifactComponents.made_by/1, version: version, scope: there)
      assert html =~ "Run #{claimed.number}"
      refute html =~ "href="
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

    test "the page's two columns use the class with the 1007 px breakpoint", ctx do
      version = pushed!(ctx, "explainer", [{"plan.md", "# First"}])
      {:ok, view, _html} = live(ctx.conn, page(ctx, version))

      assert has_element?(view, ".q-art-cols #artifact-details")
      refute render(view) =~ "lg:grid-cols-[minmax(0,1fr)_18rem]"
    end

    test "a proposal's Sources are a closed fold under its text; another type's are a heading",
         ctx do
      text = """
      ## Background

      The invoice shows the wrong currency.

      ## Sources

      - [Invoice guide](https://help.example.com/invoices)
      - web: src/invoice.ts
      """

      version = pushed!(ctx, "proposal", [{"proposal.md", text}], name: "main")
      {:ok, view, _html} = live(ctx.conn, page(ctx, version))
      html = render_async(view)
      doc = LazyHTML.from_fragment(html)

      assert has_element?(view, "details.q-xp-sources:not([open]) > summary", "Sources (2)")
      assert has_element?(view, "details.q-xp-sources a", "Invoice guide")
      assert has_element?(view, ".q-ticket-formatted h4", "Background")
      refute has_element?(view, "h4", "Sources")

      # The fold follows the text in the section, nothing after it.
      assert doc |> LazyHTML.query("section > details.q-xp-sources:last-child") |> Enum.count() ==
               1

      other = pushed!(ctx, "explainer", [{"plan.md", text}])
      {:ok, view, _html} = live(ctx.conn, page(ctx, other))
      render_async(view)

      assert has_element?(view, ".q-ticket-formatted h4", "Sources")
      refute has_element?(view, "details.q-xp-sources")
    end

    test "a wide table scrolls in a frame on a version's page, and only there", ctx do
      version =
        pushed!(ctx, "explainer", [{"plan.md", "| A | B |\n|---|---|\n| one | two |\n"}])

      {:ok, view, _html} = live(ctx.conn, page(ctx, version))
      assert has_element?(view, ".q-art-cols .q-ticket-formatted table")

      css = File.read!(Path.expand("../../../../assets/css/app.css", __DIR__))

      assert css =~
               ~r/\.q-art-cols \.q-ticket-formatted \{\s*contain: inline-size;\s*overflow-wrap: break-word;\s*\}/

      assert css =~
               ~r/\.q-art-cols \.q-ticket-formatted table \{\s*display: block;\s*overflow-x: auto;[^}]*scrollbar-color: auto;\s*\}/

      assert css =~
               ~r/\.q-art-cols \.q-ticket-formatted table::-webkit-scrollbar \{\s*height: 8px;\s*\}/

      assert css =~
               ~r/\.q-art-cols \.q-ticket-formatted table::-webkit-scrollbar-thumb \{\s*border-radius: 4px;\s*background-color: var\(--q-faint\);\s*\}/

      assert css =~
               ~r/\.q-art-cols \.q-ticket-formatted table::-webkit-scrollbar-track \{\s*background-color: var\(--color-base-200\);\s*\}/

      refute css =~ ~r/(?<!\.q-art-cols )\.q-ticket-formatted \{[^}]*contain:/
      refute css =~ ~r/(?<!\.q-art-cols )\.q-ticket-formatted table \{[^}]*display: block/
      refute css =~ ~r/(?<!\.q-art-cols )\.q-ticket-formatted table::-webkit-scrollbar/
    end

    test "a member who approves nothing adds a version: Add a version stores it", ctx do
      %{user: member} = member_fixture(ctx.scope, :member)

      push_proposal(%{ctx | conn: log_in_user(build_conn(), member)}, [
        {"proposal.md", "# Gift cards"}
      ])

      assert [%{versions: [version]}] = Artifacts.list(ctx.work_item)
      assert version.user_id == member.id
    end

    test "has no Add a version for the questions and the review comments", ctx do
      questions = pushed!(ctx, "questions", [{"questions.json", ~s({"questions": []})}])

      comments =
        pushed!(ctx, "review-comments", [{"review-comments.json", ~s({"review_comments": []})}])

      proposal = pushed!(ctx, "proposal", [{"proposal.md", "# Proposal"}])

      for version <- [questions, comments] do
        {:ok, view, _html} = live(ctx.conn, page(ctx, version))
        refute has_element?(view, "#artifact-add")
        refute render(view) =~ "Add a version"
      end

      {:ok, _type} =
        Artifacts.create_type(ctx.scope, ctx.scope.workspace, %{
          name: "bid-set",
          base_view: :structured,
          json_schema: %{"type" => "object"}
        })

      bids = pushed!(ctx, "bid-set", [{"bids.json", ~s({"campaign": "Web shop"})}])

      for version <- [proposal, bids] do
        {:ok, view, _html} = live(ctx.conn, page(ctx, version))
        assert has_element?(view, "#artifact-add")
      end
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

  defp show!(scope, names) do
    {1, _rows} =
      Repo.update_all(
        from(w in Apiary.Organisations.Workspace, where: w.id == ^scope.workspace.id),
        set: [shown_standard_types: names]
      )
  end

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

  # Adds `files`, `{filename, bytes}`, on an open Add a version page.
  defp upload_proposal(view, files) do
    input =
      file_input(
        view,
        "#artifact-form",
        :files,
        for({name, content} <- files, do: %{name: name, content: content})
      )

    for {name, _content} <- files, do: render_upload(input, name)
  end

  # Pushes `files` as a proposal on the Add a version page; the page's HTML after.
  defp push_proposal(ctx, files) do
    {:ok, view, _html} = live(ctx.conn, new_page(ctx, "proposal"))
    upload_proposal(view, files)

    view
    |> form("#artifact-form", artifact: %{type: "proposal", name: "main", note: ""})
    |> render_submit()
  end

  # Pushes `svg` as a proposal's diagram.svg and checks the line for `:svg_root`.
  defp assert_svg_root(ctx, svg) do
    html = push_proposal(ctx, [{"proposal.md", "# Gift cards"}, {"diagram.svg", svg}])

    assert html =~
             "Set xmlns=&quot;http://www.w3.org/2000/svg&quot; on the svg root element of diagram.svg."

    refute html =~ "Upload diagram.svg again."
    assert Artifacts.list(ctx.work_item) == []
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

    test "stores a mockup of pictures as before, and checks pages as pictures", ctx do
      {:ok, view, _html} =
        live(
          ctx.conn,
          ArtifactComponents.new_path(ctx.scope, ctx.work_item.number) <> "?type=mockup"
        )

      input =
        file_input(view, "#artifact-form", :files, [
          %{name: "form.png", content: @png, type: "image/png"}
        ])

      render_upload(input, "form.png")

      view
      |> form("#artifact-form", artifact: %{type: "mockup", name: "main", note: ""})
      |> render_submit()

      [artifact] = Artifacts.list(ctx.work_item)
      [version] = artifact.versions
      assert version.writer == :person
      assert_redirect(view, page(ctx, version))

      {:ok, view, html} = live(ctx.conn, page(ctx, version))
      assert has_element?(view, "#artifact-view-title", "Image")
      assert has_element?(view, ~s(img[src="#{file_path(ctx, version, "form.png")}"]))
      refute html =~ "<iframe"

      # A person's push of pages goes through the image check, as before: refused.
      {:ok, view, _html} =
        live(
          ctx.conn,
          ArtifactComponents.new_path(ctx.scope, ctx.work_item.number) <> "?type=mockup"
        )

      files =
        for {name, bytes} <- mockup_pages() do
          %{
            name: name,
            content: bytes,
            type: if(name =~ ".json", do: "application/json", else: "text/html")
          }
        end

      input = file_input(view, "#artifact-form", :files, files)
      for %{name: name} <- files, do: render_upload(input, name)

      html =
        view
        |> form("#artifact-form", artifact: %{type: "mockup", name: "pages", note: ""})
        |> render_submit()

      refute html =~ "<iframe"
      assert [%{versions: [_one]}] = Artifacts.list(ctx.work_item)
    end

    test "offers only the types the workspace shows", ctx do
      show!(ctx.scope, ["mockup"])

      {:ok, view, _html} = live(ctx.conn, new_page(ctx, "explainer"))

      for name <- ~w(mockup proposal verdict),
          do: assert(has_element?(view, ~s(#artifact-form option[value="#{name}"])), name)

      for name <- ~w(explainer screenshot change questions review-comments),
          do: refute(has_element?(view, ~s(#artifact-form option[value="#{name}"])), name)
    end

    test "leaves out the questions and the review comments, and refuses a push of them", ctx do
      {:ok, view, _html} = live(ctx.conn, new_page(ctx, "questions"))

      for name <- ~w(questions review-comments),
          do: refute(has_element?(view, ~s(#artifact-form option[value="#{name}"])), name)

      view
      |> file_input("#artifact-form", :files, [
        %{name: "questions.json", content: ~s({"questions": []}), type: "application/json"}
      ])
      |> render_upload("questions.json")

      html =
        view
        |> element("#artifact-form")
        |> render_submit(%{artifact: %{type: "questions", name: "main", note: ""}})

      assert html =~ "Choose a type from the list."
      assert Artifacts.list(ctx.work_item) == []
    end

    test "says to choose another type when the type is hidden after the page opened", ctx do
      {:ok, view, _html} = live(ctx.conn, new_page(ctx, "explainer"))

      show!(ctx.scope, ["mockup"])

      assert add_notes(view) =~ "Choose a type from the list."
      assert Artifacts.list(ctx.work_item) == []
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

    test "shows the line to remove a proposal's file that is neither Markdown nor an image",
         ctx do
      {:ok, view, _html} = live(ctx.conn, new_page(ctx, "proposal"))

      input =
        file_input(view, "#artifact-form", :files, [
          %{name: "proposal.md", content: "# Gift cards", type: "text/markdown"},
          %{name: "notes.txt", content: "Gift cards.", type: "text/plain"}
        ])

      render_upload(input, "proposal.md")
      render_upload(input, "notes.txt")

      html =
        view
        |> form("#artifact-form", artifact: %{type: "proposal", name: "main", note: ""})
        |> render_submit()

      assert html =~
               "Remove notes.txt: a proposal is one Markdown file (.md) with PNG, JPEG, GIF, WebP or SVG images and an optional sources.json."

      refute html =~ "a document is a Markdown file"
      assert Artifacts.list(ctx.work_item) == []
    end

    test "shows which part to remove from a proposal's SVG", ctx do
      svg =
        ~s(<svg xmlns="http://www.w3.org/2000/svg" onload="start"><rect/></svg>)

      html = push_proposal(ctx, [{"proposal.md", "# Gift cards"}, {"diagram.svg", svg}])

      assert html =~
               "Remove the onload attribute from diagram.svg. An SVG in a proposal may contain only shapes, text, gradients, patterns, masks, styles, simple filters and links inside the file."

      refute html =~ "Upload diagram.svg again."
      assert Artifacts.list(ctx.work_item) == []
    end

    test "shows the line to shrink a proposal's Markdown file past 256 KiB", ctx do
      big = "# Gift cards\n" <> String.duplicate("a", 262_144)

      html = push_proposal(ctx, [{"proposal.md", big}])

      assert html =~ "Shrink proposal.md to at most 256 KiB."
      refute html =~ "Upload proposal.md again."
      assert Artifacts.list(ctx.work_item) == []
    end

    test "shows the line to shrink a proposal's sources.json past 1 MiB", ctx do
      big = ~s({"sources":[]}) <> String.duplicate(" ", 1_048_576)

      html = push_proposal(ctx, [{"proposal.md", "# Gift cards"}, {"sources.json", big}])

      assert html =~ "Shrink sources.json to at most 1 MiB."
      refute html =~ "Upload sources.json again."
      assert Artifacts.list(ctx.work_item) == []
    end

    test "shows the line to add exactly one Markdown file to a proposal", ctx do
      html = push_proposal(ctx, [{"a.md", "# A"}, {"b.md", "# B"}])

      assert html =~ "Add exactly one Markdown file (.md) to the version."
      refute html =~ "Add the version again."
      assert Artifacts.list(ctx.work_item) == []
    end

    test "shows the line to replace a proposal's image that is not the type its name ends in",
         ctx do
      html = push_proposal(ctx, [{"proposal.md", "# Gift cards"}, {"chart.png", "Gift cards"}])

      assert html =~ "Replace chart.png with an image of the type its name ends in."
      refute html =~ "Upload chart.png again."
      assert Artifacts.list(ctx.work_item) == []
    end

    test "maps each reason for a proposal's file to its line" do
      for {reason, filename, line} <- [
            {:image_type, "chart.png",
             "Replace chart.png with an image of the type its name ends in."},
            {:svg_format, "diagram.svg",
             "Make diagram.svg a well-formed SVG file in UTF-8 with an svg root element."},
            {:svg_root, "diagram.svg",
             ~s(Set xmlns="http://www.w3.org/2000/svg" on the svg root element of diagram.svg.)},
            {:format, "proposal.md", "Replace proposal.md with a Markdown file of UTF-8 text."},
            {:format, "sources.json",
             "Make sources.json valid JSON. The file does not parse as JSON."}
          ] do
        assert ApiaryWeb.ArtifactLive.New.proposal_format_line(reason, filename) == line
      end
    end

    test "shows the line to make a proposal's SVG a well-formed SVG file", ctx do
      for svg <- [
            ~s(<svg xmlns="http://www.w3.org/2000/svg"><rect></svg>),
            <<"<svg xmlns=\"http://www.w3.org/2000/svg\"><text>", 0xFF, "</text></svg>">>
          ] do
        html = push_proposal(ctx, [{"proposal.md", "# Gift cards"}, {"diagram.svg", svg}])

        assert html =~
                 "Make diagram.svg a well-formed SVG file in UTF-8 with an svg root element."

        refute html =~ "Upload diagram.svg again."
        assert Artifacts.list(ctx.work_item) == []
      end
    end

    test "shows the line to set the SVG namespace on a proposal's svg root element with none",
         ctx do
      assert_svg_root(ctx, "<svg/>")
    end

    test "shows the line to set the SVG namespace on a proposal's svg root element of another",
         ctx do
      assert_svg_root(ctx, ~s(<svg xmlns="urn:x"/>))
    end

    test "shows the line to shrink a proposal's SVG past 512 KiB", ctx do
      svg =
        ~s(<svg xmlns="http://www.w3.org/2000/svg"><!--) <>
          String.duplicate("a", 524_288) <> "--></svg>"

      html = push_proposal(ctx, [{"proposal.md", "# Gift cards"}, {"diagram.svg", svg}])

      assert html =~ "Shrink diagram.svg to at most 512 KiB."
      refute html =~ "Upload diagram.svg again."
      assert Artifacts.list(ctx.work_item) == []
    end

    test "shows the line to remove a DOCTYPE or too many attributes from a proposal's SVG", ctx do
      attributes = Enum.map_join(1..257, " ", &~s(data-a#{&1}="1"))

      for {svg, part} <- [
            {~s(<!DOCTYPE svg><svg xmlns="http://www.w3.org/2000/svg"><rect/></svg>),
             "the DOCTYPE"},
            {~s(<svg xmlns="http://www.w3.org/2000/svg"><rect #{attributes}/></svg>),
             "the attributes past the 256th on the rect element"}
          ] do
        html = push_proposal(ctx, [{"proposal.md", "# Gift cards"}, {"diagram.svg", svg}])

        assert html =~
                 "Remove #{part} from diagram.svg. An SVG in a proposal may contain only shapes, text, gradients, patterns, masks, styles, simple filters and links inside the file."

        refute html =~ "Upload diagram.svg again."
        assert Artifacts.list(ctx.work_item) == []
      end
    end

    test "shows the line to replace a proposal's Markdown file that is not UTF-8 text", ctx do
      html = push_proposal(ctx, [{"proposal.md", <<"# Gift cards ", 0xFF, 0xFE>>}])

      assert html =~ "Replace proposal.md with a Markdown file of UTF-8 text."
      refute html =~ "an image of the type its name ends in"
      assert Artifacts.list(ctx.work_item) == []
    end

    test "shows the line to make a proposal's sources.json valid JSON", ctx do
      html = push_proposal(ctx, [{"proposal.md", "# Gift cards"}, {"sources.json", "{"}])

      assert html =~ "Make sources.json valid JSON. The file does not parse as JSON."
      refute html =~ "Markdown file of UTF-8 text"
      assert Artifacts.list(ctx.work_item) == []
    end

    test "shows where a proposal's sources.json fails its format", ctx do
      html =
        push_proposal(ctx, [
          {"proposal.md", "# Gift cards"},
          {"sources.json", ~s({"sources":"none"})}
        ])

      assert html =~
               "Fix sources.json to match the format of proposal sources: at #/sources, value is not of type array."

      refute html =~ "JSON Schema"
      assert Artifacts.list(ctx.work_item) == []
    end

    test "returns the line of the proposal sources format for a key twice in sources.json" do
      detail = %{path: "#", error: "the object has the key sources twice"}
      proposal = Enum.find(Apiary.Artifacts.Type.standard(), &(&1.name == "proposal"))

      assert ApiaryWeb.ArtifactLive.New.schema_line("sources.json", proposal, detail) ==
               "Fix sources.json to match the format of proposal sources: at #, the object has the key sources twice."
    end

    test "stores a proposal with an image and sources.json", ctx do
      sources =
        Jason.encode!(%{
          "sources" => [
            %{"kind" => "page", "ref" => "https://example.com/plan", "why" => "The plan."}
          ]
        })

      {:ok, view, _html} = live(ctx.conn, new_page(ctx, "proposal"))

      upload_proposal(view, [
        {"proposal.md", "# Gift cards"},
        {"chart.png", @png},
        {"diagram.svg", @svg},
        {"sources.json", sources}
      ])

      assert {:error, {:live_redirect, _to}} =
               view
               |> form("#artifact-form", artifact: %{type: "proposal", name: "main", note: ""})
               |> render_submit()

      [artifact] = Artifacts.list(ctx.work_item)
      [version] = artifact.versions
      assert_redirect(view, page(ctx, version))
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

      assert line =~ "Fix v.json to match the format of verdict: at #,"
      refute line =~ "JSON Schema"
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

      ArtifactStoreHook.on_stage(fn -> in_stage(ctx.work_item, "st_bbbbbbbbbb") end)

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

      view
      |> form("#artifact-form", artifact: %{type: "acceptance-criteria", name: "main", note: ""})
      |> render_submit()

      assert {:error, {:live_redirect, _to}} = confirm_spend(view)

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
