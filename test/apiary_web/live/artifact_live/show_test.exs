defmodule ApiaryWeb.ArtifactLive.ShowTest do
  # A version's page (`ApiaryWeb.ArtifactLive.Show`) and the plain list
  # (`ApiaryWeb.ArtifactComponents.list/1`): each base view as Qory Apiary shows it,
  # nothing of an artifact as markup, the history read again on a push, and the page not
  # found for another workspace and with `workflow_model` off.
  # Not async: the store's root is the application's setting.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Artifacts, Repo, WorkItems}
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

      assert has_element?(view, "#artifact-view-title", "Mockup")

      assert view |> element("#artifact-type") |> render() =~
               ~r/mockup\s*<span class="text-muted">· Mockup<\/span>/

      [iframe] =
        html |> LazyHTML.from_document() |> LazyHTML.query("#{view_id} iframe") |> Enum.to_list()

      [attributes] = LazyHTML.attributes(iframe)
      attributes = Map.new(attributes)

      # The frame's address has the reader's token for the version, which verifies.
      prefix =
        "/#{ctx.scope.organisation.slug}/#{ctx.scope.workspace.slug}/work/" <>
          "#{ctx.work_item.number}/artifacts/#{version.public_id}/mockup/"

      assert [_all, token] =
               Regex.run(~r/\A#{Regex.escape(prefix)}([^\/]+)\/home\.html\z/, attributes["src"])

      # Its session is the reader's: the record of the session the page was opened in.
      session = Apiary.Accounts.session_token_id(get_session(ctx.conn, :user_token))
      assert is_binary(session)

      assert {:ok, %{v: version.public_id, w: ctx.work_item.id, u: ctx.scope.user.id, s: session}} ==
               ApiaryWeb.ArtifactMockupController.verify(ApiaryWeb.Endpoint, token)

      screen =
        &ArtifactComponents.mockup_path(
          ctx.scope,
          ctx.work_item.number,
          version.public_id,
          token,
          &1
        )

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

    test "shows a Speed row under each video, with 1x pressed", ctx do
      version =
        pushed!(ctx, "demo-video", [
          {"demo.mp4", @mp4},
          {"other.mp4", @mp4},
          {"en.vtt", "WEBVTT\n"}
        ])

      {:ok, view, _html} = live(ctx.conn, page(ctx, version))
      id = "artifact-view-#{version.public_id}-speed-0"
      row = "##{id}"

      # The first film is the player: its Speed row is in the line with Cinema and Full screen.
      bar = "#artifact-player > video + .q-player-bar"
      assert has_element?(view, "#{bar} > #{row}[phx-hook=VideoSpeed][phx-update=ignore]")
      assert has_element?(view, "#{bar} + figcaption", "demo.mp4")
      assert has_element?(view, "#{row}-label", "Speed")
      assert has_element?(view, ~s(#{row} [role=group][aria-labelledby="#{id}-label"]))

      buttons =
        view
        |> element(row)
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[role=group] button[type=button]")

      assert Enum.map(buttons, &String.trim(LazyHTML.text(&1))) == ["0.5x", "1x", "1.5x", "2x"]
      assert LazyHTML.attribute(buttons, "data-rate") == ["0.5", "1", "1.5", "2"]
      assert LazyHTML.attribute(buttons, "aria-pressed") == ["false", "true", "false", "false"]

      second = "#artifact-view-#{version.public_id}-speed-1"

      assert has_element?(
               view,
               "video + #{second}[phx-hook=VideoSpeed] + figcaption",
               "other.mp4"
             )
    end

    test "gives the first film Cinema and Full screen, and starts no film", ctx do
      version = pushed!(ctx, "demo-video", [{"demo.mp4", @mp4}, {"other.mp4", @mp4}])
      {:ok, view, html} = live(ctx.conn, page(ctx, version))
      sizes = "#artifact-view-#{version.public_id}-sizes-0"

      assert has_element?(view, "#artifact-player.q-player video")
      assert has_element?(view, "#{sizes}[phx-hook=ArtifactPlayer][phx-update=ignore]")
      assert has_element?(view, ~s(#{sizes} #artifact-cinema[aria-pressed="false"]), "Cinema")
      assert has_element?(view, ~s(#{sizes} #artifact-cinema.hidden.lg\\:flex))

      assert has_element?(
               view,
               ~s(#{sizes} #artifact-full-screen[aria-pressed="false"]),
               "Full screen"
             )

      assert has_element?(view, ~s|#{sizes} [data-leave-title="Leave full screen (Esc)"]|)
      assert has_element?(view, "#{sizes}[data-version=\"#{version.public_id}\"]")
      assert has_element?(view, "#{sizes}[data-film=\"0\"]")

      # One Cinema and one Full screen for the page, on the first film.
      assert html
             |> LazyHTML.from_document()
             |> LazyHTML.query("#artifact-cinema")
             |> Enum.count() == 1

      refute has_element?(view, "#artifact-view-#{version.public_id}-sizes-1")

      refute html =~ "autoplay"
    end

    test "gives a film's view no controls where the page passes no player" do
      version = %Apiary.Artifacts.Version{
        public_id: "av_x",
        files: [
          %Apiary.Artifacts.ArtifactFile{filename: "demo.mp4", content_type: "video/mp4"}
        ]
      }

      html =
        render_component(&ArtifactComponents.view/1,
          id: "run-view",
          type: %Apiary.Artifacts.Type{name: "demo-video", base_view: :video},
          version: version,
          path: &"/files/#{&1.filename}"
        )

      assert html =~ "run-view-speed-0"
      refute html =~ "artifact-cinema"
      refute html =~ "artifact-full-screen"
      refute html =~ "ArtifactPlayer"
      refute html =~ "q-player"
    end

    test "shows structured JSON as a table of text, a URL as text", ctx do
      point = %{"text" => "<b>Gift cards</b> https://example.com/pr/7", "action" => "run_again"}

      verdict =
        pushed!(ctx, "verdict", [
          {"verdict.json", Jason.encode!(%{"verdict" => "escalate", "points" => [point]})}
        ])

      {:ok, view, _dead} = live(ctx.conn, page(ctx, verdict))
      html = render(view)

      assert has_element?(view, "table td", "https://example.com/pr/7")
      refute has_element?(view, "table a")
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
                 "about" => %{"work_item" => true},
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

    test "lists a withdrawal as Withdrew, with its artifact and version", ctx do
      version = pushed!(ctx, "explainer", [{"plan.md", "# First"}], name: "scenario-2")

      {:ok, withdrawal} =
        Artifacts.withdraw({:run, ctx.run}, ctx.work_item, "explainer", name: "scenario-2")

      {:ok, view, _html} = live(ctx.conn, page(ctx, version))

      assert has_element?(
               view,
               "#artifact-history-#{withdrawal.public_id} a",
               "Withdrew explainer scenario-2 (version 2)"
             )

      assert has_element?(view, "#artifact-history-#{version.public_id} a", "Version 1")
    end

    test "writes the type of a withdrawal in its plain form, as the gate card does", ctx do
      {:ok, _type} =
        Artifacts.create_type(ctx.scope, ctx.scope.workspace, %{
          "name" => "demo-note",
          "base_view" => "file"
        })

      version =
        pushed!(ctx, "demo-note", [{"note.bin", "x"}], name: "voucher-expired")

      {:ok, withdrawal} =
        Artifacts.withdraw({:run, ctx.run}, ctx.work_item, "demo-note", name: "voucher-expired")

      {:ok, view, _html} = live(ctx.conn, page(ctx, version))

      assert has_element?(
               view,
               "#artifact-history-#{withdrawal.public_id} a",
               "Withdrew demo note voucher-expired (version 2)"
             )

      # The title of the other versions keeps the type's id.
      assert has_element?(view, "#artifact-header", "demo-note voucher-expired v1")
    end

    test "a withdrawal's own page reads as a withdrawal, with no view and no file list", ctx do
      version = pushed!(ctx, "explainer", [{"plan.md", "# First"}], name: "scenario-2")

      {:ok, withdrawal} =
        Artifacts.withdraw({:run, ctx.run}, ctx.work_item, "explainer", name: "scenario-2")

      {:ok, view, _html} = live(ctx.conn, page(ctx, withdrawal))

      assert has_element?(
               view,
               "#artifact-withdrawn",
               "Withdrew explainer scenario-2 (version 2)"
             )

      refute has_element?(view, "#artifact-view-part")
      refute has_element?(view, "#artifact-files-part")

      # The version before it keeps its view and its files.
      {:ok, view, _html} = live(ctx.conn, page(ctx, version))
      assert has_element?(view, "#artifact-view-part")
      assert has_element?(view, "#artifact-files-part")
      refute has_element?(view, "#artifact-withdrawn")
    end

    test "plain_name/2 is the type with spaces, then the name unless it is main" do
      alias ApiaryWeb.ArtifactComponents, as: Components

      assert Components.plain_name("demo-video", "scenario-1") == "demo video scenario-1"
      assert Components.plain_name("demo-video", "main") == "demo video"
      assert Components.plain_name("explainer", nil) == "explainer"
    end

    test "is read again when a version is pushed to its work item", ctx do
      version = pushed!(ctx, "explainer", [{"plan.md", "# First"}])
      {:ok, view, _html} = live(ctx.conn, page(ctx, version))

      newer = pushed!(ctx, "explainer", [{"plan.md", "# Second"}])
      assert render(view) =~ "Version 2"
      assert has_element?(view, "#artifact-history-#{newer.public_id}")
    end

    test "is open to a member", ctx do
      version = pushed!(ctx, "explainer", [{"plan.md", "# First"}])
      %{user: member} = member_fixture(ctx.scope, :member)

      {:ok, view, _html} = live(log_in_user(build_conn(), member), page(ctx, version))
      assert has_element?(view, "#artifact-header")
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

  test "size/1 shows a size in binary units" do
    assert Enum.map(
             [812, 1024, 65_536, 1_572_864, 1_048_576, 10_485_760, 1_073_741_824, 1_048_575],
             &ArtifactComponents.size/1
           ) == ["812 B", "1 KiB", "64 KiB", "1.5 MiB", "1 MiB", "10 MiB", "1 GiB", "1 MiB"]
  end

  test "file_size/1 shows a size with one decimal from 1 KiB up, and size/1 is unchanged" do
    sizes = [0, 812, 1024, 9_216, 65_536, 1_572_864, 1_048_576, 1_073_741_824, 1_048_575]

    assert Enum.map(sizes, &ArtifactComponents.file_size/1) ==
             [
               "0 B",
               "812 B",
               "1.0 KiB",
               "9.0 KiB",
               "64.0 KiB",
               "1.5 MiB",
               "1.0 MiB",
               "1.0 GiB",
               "1.0 MiB"
             ]

    assert Enum.map(sizes, &ArtifactComponents.size/1) ==
             ["0 B", "812 B", "1 KiB", "9 KiB", "64 KiB", "1.5 MiB", "1 MiB", "1 GiB", "1 MiB"]
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
          checks: %{"explainer" => :passed}
        )

      assert html =~ "explainer v2"
      assert html =~ "mockup checkout v1"
      assert html =~ "2 files"
      assert html =~ "Check passed"
      assert html =~ ~s(href="#{page(ctx, newest)}")

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

    test "the page is not found", ctx do
      version = pushed!(ctx, "explainer", [{"plan.md", "# First"}])
      assert status(ctx.conn, page(ctx, version)) == 404
    end
  end
end
