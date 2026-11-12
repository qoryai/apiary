defmodule ApiaryWeb.WorkspaceSetupLiveTemplatesTest do
  @moduledoc """
  New workspace (`ApiaryWeb.WorkspaceSetupLive`) lists a card for each template of the Qory
  harness, the organisation's shared harness, the sources assigned to it and its connected
  repositories (`Apiary.Stacks.Sources.listed/1`), against stub adapters (`Req.Test`): the
  groups and their headings, a card's source label, a shared harness that runs hide, a
  shared row only a narrowed assignment covers, a repository read once, the person's limit
  of reads and the reads that follow it, a read that fails, the modules that are not
  templates, the organisation at the edition's limit, and the empty organisation overview,
  which keeps the Qory card alone.
  """
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.HarnessReadsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Organisations, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.Collection
  alias Apiary.Harnesses.Assignment
  alias Apiary.Stacks
  alias Apiary.Stacks.Stack

  @moduletag needs: :factory
  @moduletag :capture_log

  @harness "https://code.example.com/acme/harness"
  @app "https://code.example.com/acme/app"
  @team "https://code.example.com/example-org/team-harness"

  @module_files %{"support-desk" => support_desk_file()}

  # An organisation with no workspace, so it may have another, its owner logged in, and one
  # connected repository, acme/harness, that exports the template module support-desk.
  setup %{conn: conn} do
    %{user: user, organisation: organisation} = sign_up_without_workspace()
    scope = Organisations.load_scope(Scope.for_user(user), organisation.id)
    adapter = call_adapter_fixture()
    {connection, _nonce} = connection_fixture(scope, adapter.adapter, :listed)
    live_grant_fixture(organisation.id, adapter.adapter, connection, "G_acme")
    harness = harness_collection_fixture(connection, @harness, "acme/harness")

    %{
      conn: log_in_user(conn, user),
      user: user,
      scope: scope,
      organisation: organisation,
      adapter: adapter,
      connection: connection,
      harness: harness,
      covered: %{adapter.adapter.id => %{@harness => {"G_acme", "R_harness"}}},
      path: ~p"/#{organisation}/workspaces/new"
    }
  end

  defp sign_up_without_workspace do
    {:ok, %{user: user, organisation: organisation}} =
      Organisations.sign_up_user(
        %{email: Apiary.AccountsFixtures.unique_user_email(), organisation_name: "Acme Studio"},
        nil,
        open: true,
        workspace: false
      )

    %{user: user, organisation: organisation}
  end

  defp serve(ctx, files, opts \\ []),
    do: serve_calls([ctx.adapter], [covered: ctx.covered, files: files] ++ opts)

  defp harness_files(modules \\ @module_files, opts \\ []),
    do: repository_files("R_harness", modules, opts)

  defp harness_calls do
    receive do
      {:harness_call, path, call} -> [{path, call} | harness_calls()]
    after
      0 -> []
    end
  end

  defp open(ctx, path \\ nil) do
    {:ok, lv, _html} = live(ctx.conn, path || ctx.path)
    settle(lv)
  end

  # Waits for the reads: each result starts the next read, so one wait is not enough. It
  # ends once no group is reading, or once the limit line shows and the reads under way
  # have ended. The limit starts no read, but the reads started before it still finish,
  # and each of them adds its card.
  defp settle(lv, rounds \\ 20) do
    render_async(lv, 2_000)

    cond do
      has_element?(lv, "#set-up-templates-limited") ->
        render_async(lv, 2_000)
        lv

      rounds > 0 and has_element?(lv, ~s([id^="set-up-group-"][id$="-reading"])) ->
        settle(lv, rounds - 1)

      true ->
        lv
    end
  end

  defp words(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  defp texts(lv, selector) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))
  end

  defp template_card_id(key), do: ApiaryWeb.SetUpComponents.template_card_id(key)

  # The id of the shared harness's card of the module support-desk.
  defp shared_card, do: "#" <> template_card_id("shared.support-desk")

  # The id of the card of `module` in the repository `collection`.
  defp card(collection, module \\ "support-desk"),
    do: "#" <> template_card_id(collection.public_id <> "." <> module)

  # The organisation's shared harness: a repository at `git`, on the stack support.
  defp share!(ctx, git, ref \\ "HEAD") do
    document =
      "extends:\n  git: #{Jason.encode!(git)}\n  stack: \"support\"\n  ref: #{Jason.encode!(ref)}\n"

    {:ok, row} =
      Stacks.put_stack(ctx.scope, {:organisation, ctx.organisation}, document,
        choice: :repository,
        version: {:branch, ref}
      )

    row
  end

  # The instance's adapter with a grant over `@team`, served with the organisation's.
  defp instance_grant(ctx, files) do
    instance = call_adapter_fixture()
    admin = instance_admin_scope()
    {connection, _nonce} = connection_fixture(admin, instance.adapter, :listed)
    live_grant_fixture(admin.organisation.id, instance.adapter, connection, "G_i")
    covered = Map.put(ctx.covered, instance.adapter.id, %{@team => {"G_i", "R_team"}})
    serve_calls([ctx.adapter, instance], covered: covered, files: files)
    admin
  end

  defp assign!(ctx, source, admin) do
    Repo.insert!(%Assignment{
      organisation_id: ctx.organisation.id,
      every_organisation: false,
      source: source,
      created_by_id: admin.user.id
    })
  end

  describe "the groups" do
    test "the Qory card is on the page at once, and Reading harnesses… is there until the reads end",
         ctx do
      serve(ctx, harness_files())

      html = ctx.conn |> get(ctx.path) |> html_response(200)
      assert html =~ "Software factory"
      assert html =~ "Qory harness"
      assert html =~ "Connected repositories"
      assert html =~ "Reading harnesses…"
      refute html =~ "Support desk"

      lv = open(ctx)

      refute has_element?(lv, "#set-up-group-connected-reading")
      assert has_element?(lv, "#set-up-group-qory #set-up-card-software h3", "Software factory")

      assert has_element?(lv, "#{card(ctx.harness)} h3", "Support desk")

      assert has_element?(
               lv,
               ~s(#{card(ctx.harness)}-link[href="/#{ctx.organisation.slug}/workspaces/new/#{ctx.harness.public_id}.support-desk"])
             )

      # The label of the repository is under the summary.
      assert words(lv, "#{card(ctx.harness)}-label") == "acme/harness"
      assert has_element?(lv, "#{card(ctx.harness)}-summary", "Agents draft answers")
    end

    test "lists the Qory template, the shared harness, the assigned sources and the connected repositories, in that order",
         ctx do
      app = harness_collection_fixture(ctx.connection, @app, "acme/app")

      covered = %{
        ctx.adapter.adapter.id => %{
          @harness => {"G_acme", "R_harness"},
          @app => {"G_acme", "R_app"}
        }
      }

      files =
        Map.merge(
          repository_files("R_app", @module_files),
          Map.merge(repository_files("R_team", @module_files), harness_files())
        )

      share!(ctx, @harness, "v1")
      admin = instance_grant(%{ctx | covered: covered}, files)
      assignment = assign!(ctx, %{"git" => @team, "ref" => "v1"}, admin)

      lv = open(ctx)

      assert texts(lv, "#set-up-cards h2") == [
               "Qory harness",
               "Shared harness",
               "Assigned harnesses",
               "Connected repositories"
             ]

      # The shared harness is read at v1, which the stub serves like any other version.
      assert has_element?(
               lv,
               "#set-up-group-shared #{shared_card()} h3",
               "Support desk"
             )

      refute has_element?(lv, "#{shared_card()}-label")

      id = "#" <> template_card_id("assigned-#{assignment.id}.support-desk")
      assert has_element?(lv, "#set-up-group-assigned #{id} h3", "Support desk")
      assert words(lv, "#{id}-label") == "example-org/team-harness"

      assert has_element?(lv, "#set-up-group-connected #{card(app)} h3", "Support desk")
      assert words(lv, "#{card(app)}-label") == "acme/app"
      assert has_element?(lv, "#set-up-group-connected #{card(ctx.harness)} h3", "Support desk")
    end

    test "a shared harness that runs hide shows no address anywhere", ctx do
      serve(ctx, harness_files())
      row = share!(ctx, @harness)

      {1, _} =
        Repo.update_all(from(s in Stack, where: s.id == ^row.id),
          set: [owner_organisation_id: Apiary.Edition.instance_organisation_id()]
        )

      lv = open(ctx)
      html = render(lv)

      assert has_element?(lv, "#set-up-group-shared #{shared_card()} h3")
      refute html =~ "acme/harness"
      refute html =~ "code.example.com"

      # The page of its template says "shared harness", and not where it is read from.
      {:ok, page, _html} =
        live(ctx.conn, ~p"/#{ctx.organisation}/workspaces/new/shared.support-desk")

      render_async(page, 2_000)

      assert words(page, "#workspace-type-harness") == "Harness: shared harness, stack support"
      refute render(page) =~ "acme/harness"
    end

    test "a hidden shared harness that cannot be fetched shows no host or port", ctx do
      serve(ctx, harness_files())
      row = share!(ctx, "https://private.example.org/acme/harness")

      {1, _} =
        Repo.update_all(from(s in Stack, where: s.id == ^row.id),
          set: [owner_organisation_id: Apiary.Edition.instance_organisation_id()]
        )

      lv = open(ctx)
      html = render(lv)

      assert has_element?(
               lv,
               "#set-up-group-shared p",
               "Qory Apiary could not read the shared harness. Try again. If it repeats,"
             )

      refute html =~ "private.example.org"
      refute html =~ "acme/harness\""
    end

    test "a shared row whose repository only a narrowed assignment covers has no template",
         ctx do
      admin = instance_grant(ctx, repository_files("R_team", @module_files))
      assign!(ctx, %{"git" => @team, "ref" => "v1", "stack" => "web"}, admin)
      share!(ctx, @team, "v1")

      lv = open(ctx)

      refute has_element?(lv, shared_card())
      assert has_element?(lv, "#set-up-group-shared p", "example-org/team-harness")
    end

    test "a repository the shared harness has at the same ref is read once, and listed once",
         ctx do
      serve(ctx, harness_files())
      share!(ctx, @harness)
      harness_calls()

      lv = open(ctx)

      assert has_element?(lv, shared_card())
      refute has_element?(lv, card(ctx.harness))
      refute has_element?(lv, "#set-up-group-connected")

      reads =
        for {"read", %{"path" => "qory.yaml"}} <- harness_calls(), do: :read

      assert reads == [:read]
    end

    test "modules whose names differ by one character get one card each, with unique ids",
         ctx do
      names = ["a.b", "a-b", "a_b", "x", "x-link", "x-summary", "x-label"]
      serve(ctx, harness_files(Map.new(names, &{&1, support_desk_file()})))
      lv = open(ctx)

      ids = Enum.map(names, &card(ctx.harness, &1))
      assert length(Enum.uniq(ids)) == length(names)
      for id <- ids, do: assert(has_element?(lv, id))
      assert length(texts(lv, "#set-up-group-connected h3")) == length(names)

      # Every id of the page is the id of one element, the links, summaries and labels of
      # the cards included.
      page_ids =
        lv
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[id]")
        |> LazyHTML.attribute("id")

      assert page_ids -- Enum.uniq(page_ids) == []

      assert template_card_id("a_2eb") != template_card_id("a.b")
      refute String.contains?(template_card_id("x-link"), "-link")
    end

    test "a connected repository with nothing to show shows nothing", ctx do
      serve(ctx, %{{"R_harness", "qory.yaml"} => "exports:\n  stacks: [support]\n"})
      lv = open(ctx)

      refute has_element?(lv, "#set-up-group-connected")
      refute has_element?(lv, "#set-up-group-shared")
      refute has_element?(lv, "#set-up-group-assigned")
      assert has_element?(lv, "#set-up-group-qory")
    end
  end

  describe "the lines" do
    test "a module that is not a template says why, for each reason", ctx do
      stack = String.replace(support_desk_file(), "stack: support", "stack: other")
      invalid = String.replace(support_desk_file(), "name: Check", "name: Answer")

      serve(
        ctx,
        harness_files(%{
          "a" => stack,
          "b" => invalid,
          "c" => "name: x\n",
          "support-desk" => support_desk_file()
        })
      )

      lv = open(ctx)

      assert has_element?(lv, card(ctx.harness))

      assert texts(lv, "#set-up-group-connected p") == [
               "a in acme/harness is not a template: its stack is not exported.",
               "b in acme/harness is not a template: its process is not valid.",
               "c in acme/harness is not a template: Qory Apiary cannot read its process.yaml."
             ]
    end

    test "a template whose types are refused has a line for each refusal", ctx do
      types = "artifact_types:\n  - name: reply-draft\n  - name: tone-note\n"
      serve(ctx, harness_files(%{"a" => support_desk_file() <> types}))
      lv = open(ctx)

      refute has_element?(lv, "#set-up-group-connected ul")

      assert texts(lv, "#set-up-group-connected p") == [
               "a in acme/harness is not a template: reply-draft is not a standard type, so it needs a definition.",
               "a in acme/harness is not a template: tone-note is not a standard type, so it needs a definition."
             ]
    end

    test "a type listed twice and an entry the schema refuses each have a line with the name",
         ctx do
      twice = "artifact_types:\n  - name: mockup\n  - name: mockup\n"
      refused = "artifact_types:\n  - {name: reply-draft, base_view: document}\n"

      serve(
        ctx,
        harness_files(%{
          "a" => support_desk_file() <> twice,
          "b" => support_desk_file() <> refused
        })
      )

      assert texts(open(ctx), "#set-up-group-connected p") == [
               "a in acme/harness is not a template: list mockup once in artifact_types.",
               "b in acme/harness is not a template: the entry reply-draft in artifact_types does not match process.schema.json."
             ]
    end

    test "modules that are not a list of names", ctx do
      serve(ctx, harness_files(%{}, root: "a"))
      lv = open(ctx)

      assert texts(lv, "#set-up-group-connected p") == [
               "Change modules under exports in the qory.yaml or harness.yaml of acme/harness to a list of names. Qory Apiary cannot read the templates of that repository until then."
             ]
    end

    test "modules past the first 20, singular and plural", ctx do
      names = for n <- 1..21, do: "m#{String.pad_leading(Integer.to_string(n), 2, "0")}"

      serve(
        ctx,
        harness_files(Map.new(names, &{&1, support_desk_file()}),
          root: "[#{Enum.join(names, ", ")}]"
        )
      )

      lv = open(ctx)

      assert has_element?(
               lv,
               "#set-up-group-connected p",
               "acme/harness lists 1 more module. New workspace reads the first 20."
             )

      names = for n <- 1..22, do: "m#{String.pad_leading(Integer.to_string(n), 2, "0")}"

      serve(
        ctx,
        harness_files(Map.new(names, &{&1, support_desk_file()}),
          root: "[#{Enum.join(names, ", ")}]"
        )
      )

      assert has_element?(
               open(ctx),
               "#set-up-group-connected p",
               "acme/harness lists 2 more modules. New workspace reads the first 20."
             )
    end

    test "a source that cannot be read shows its reason in its group", ctx do
      serve(ctx, harness_files(), down: true)
      lv = open(ctx)

      assert has_element?(lv, "#set-up-group-qory #set-up-card-software")
      refute has_element?(lv, "#{card(ctx.harness)}")
      refute has_element?(lv, "#set-up-group-connected-reading")
      assert has_element?(lv, "#set-up-group-connected p", "Qory Apiary could not connect")
    end
  end

  describe "the person's limit of reads" do
    test "12 connected repositories: the limit line shows, the first results stay, the rest come after the window",
         ctx do
      {1, _} =
        Repo.update_all(from(c in Collection, where: c.id == ^ctx.harness.id),
          set: [ended_at: DateTime.utc_now(), ended_reason: :not_listed]
        )

      collections = many_repositories(ctx.adapter, ctx.connection, "G_acme", 12)
      lv = open(ctx)

      # 10 reads of a minute: the 11th is stopped, and the first 10 stay.
      assert has_element?(lv, "#set-up-templates-limited")

      assert words(lv, "#set-up-templates-limited") =~
               ~r/^The list continues in \d+ seconds?\. Qory Apiary reads at most 10 harnesses a minute for one person\.$/

      shown = for c <- collections, has_element?(lv, card(c)), do: c
      assert length(shown) == 10
      assert has_element?(lv, "#set-up-group-connected-reading")

      # The window ends: the page reads the rest with no click.
      :ets.delete(Apiary.Runs.RateLimit, {Apiary.Stacks.Sources, :read, ctx.user.id})
      send(lv.pid, :templates_resume)
      settle(lv)

      refute has_element?(lv, "#set-up-templates-limited")
      refute has_element?(lv, "#set-up-group-connected-reading")
      assert Enum.all?(collections, &has_element?(lv, card(&1)))
    end
  end

  describe "the edition's limit and the empty overview" do
    # The core's limit of one workspace showed its line on New workspace, and nothing was
    # read. The edition sets no limit: "Create workspace makes a second workspace, which
    # Workspaces lists" in test/apiary_pro_web/live/new_workspace_test.exs.

    test "the empty overview keeps the Qory card alone, and reads nothing", ctx do
      serve(ctx, harness_files())
      {:ok, lv, _html} = live(ctx.conn, ~p"/#{ctx.organisation}")
      render_async(lv, 2_000)

      assert has_element?(lv, "h2#set-up-cards-title", "What will your first workspace do?")
      assert has_element?(lv, "#set-up-cards #set-up-card-software h3", "Software factory")
      refute has_element?(lv, "#set-up-group-qory")
      refute has_element?(lv, "#set-up-group-connected")
      refute html_has?(lv, "Reading harnesses…")
      assert harness_calls() == []
    end
  end

  defp html_has?(lv, text), do: render(lv) =~ text
end
