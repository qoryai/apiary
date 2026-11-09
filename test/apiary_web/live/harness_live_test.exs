defmodule ApiaryWeb.HarnessLiveTest do
  @moduledoc """
  Workspace settings › Harness (`ApiaryWeb.HarnessLive`) against stub adapters
  (`Req.Test`): who opens it and where it is in the list; About this step, with the
  paragraphs on the harness; the harness choice and its version; the destinations' Stack
  selects under the choice, their saves and refusals; each kind of source, read when
  chosen; a refused address; the save, its document, and the setting shown again. With
  the feature `workflow_model`, the page keeps the harness choice, drops the workflow
  choice and links to Stages.

  Not async: each test sets the instance's features, which are the whole node's. The
  workflow choice is tested with `workflow_model` off, as an instance without it shows it.
  """
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.HarnessReadsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Processes, Repo}
  alias Apiary.Harnesses.Assignment
  alias Apiary.Stacks
  alias Apiary.Stacks.Sources
  alias Apiary.PublicGitServer
  alias Apiary.QoryHarnessFixture

  @moduletag needs: :factory
  @moduletag with_features: Apiary.Features.all() -- [:workflow_model]
  @moduletag :capture_log

  @harness "https://code.example.com/acme/harness"
  @app "https://code.example.com/acme/app"
  @team "https://code.example.com/example-org/team-harness"

  @stack "modules:\n  - name: core\n    source: {path: modules/core}\n"

  @files %{
    {"R_harness", "harness.yaml"} => "exports:\n  stacks: [triage]\n",
    {"R_harness", "stacks/triage/qory-stack.yaml"} =>
      @stack <> "workflows:\n  triage: {}\n  fix:\n    access: write\n",
    {"R_team", "qory-stack.yaml"} => @stack <> "workflows:\n  review: {}\n"
  }

  setup :register_and_log_in_user

  setup %{scope: scope} do
    adapter = call_adapter_fixture()
    {connection, _nonce} = connection_fixture(scope, adapter.adapter, :listed)
    live_grant_fixture(scope.organisation.id, adapter.adapter, connection, "G_acme")
    harness = harness_collection_fixture(connection, @harness, "acme/harness")
    harness_collection_fixture(connection, @app, "acme/app")

    covered = %{
      adapter.adapter.id => %{@harness => {"G_acme", "R_harness"}, @app => {"G_acme", "R_app"}}
    }

    serve_calls([adapter], covered: covered, files: @files)

    %{
      adapter: adapter,
      covered: covered,
      linked_id: "linked:" <> harness.public_id,
      path: workspace_path(scope, "/settings/harness")
    }
  end

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view, 2_000)
    view
  end

  defp change(view, params) do
    view |> form("#workflow-form", workflow: params) |> render_change()
    render_async(view, 2_000)
  end

  # Ends every collection, so the organisation has no connected repository.
  defp end_collections! do
    Repo.update_all(Apiary.Adapters.Collection,
      set: [ended_at: DateTime.utc_now(), ended_reason: :not_listed]
    )
  end

  defp words(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  defp calls do
    receive do
      {:harness_call, path, call} -> [{path, call} | calls()]
    after
      0 -> []
    end
  end

  describe "access" do
    test "an owner opens it, after the sections before it and before Runs", %{
      conn: conn,
      path: path
    } do
      view = open(conn, path)

      assert has_element?(view, "#settings-section-title", "Harness")
      assert has_element?(view, ~s(#settings-tab-harness[href="#{path}"][aria-current="page"]))
      refute has_element?(view, "#settings-tab-workflows")

      html = render(view)
      [before, _after] = String.split(html, ~s(id="settings-tab-harness"), parts: 2)
      assert before =~ ~s(id="settings-tab-general")
      refute before =~ ~s(id="settings-tab-runs")
      assert html =~ ~s(id="settings-tab-runs")
    end

    test "an admin opens it", %{scope: scope, path: path} do
      %{user: user} = member_fixture(scope, :admin)
      view = open(log_in_user(build_conn(), user), path)
      assert has_element?(view, "#workflow-form")
    end

    test "a member finds no such page, and no such section", %{scope: scope, path: path} do
      %{user: user} = member_fixture(scope)
      conn = log_in_user(build_conn(), user)

      assert_raise ApiaryWeb.NotFound, fn -> live(conn, path) end

      {:ok, view, _html} = live(conn, workspace_path(scope, "/settings/runs"))
      refute has_element?(view, "#settings-tab-harness")
    end

    test "another organisation's owner finds no such page", %{path: path} do
      %{user: user} = sign_up_fixture()
      assert build_conn() |> log_in_user(user) |> get(path) |> Map.get(:status) == 404
    end
  end

  describe "the page" do
    test "About this step has what the page sets, what a harness is and the order of a run's harness, and no notice on the harness file shows",
         %{conn: conn, path: path, scope: scope} do
      view = open(conn, path)

      assert has_element?(view, "aside#page-context h2", "About this step")

      assert has_element?(
               view,
               "#page-context p#workflow-what",
               "Runs in #{scope.workspace.name} use the workflow you choose here, from a harness repository."
             )

      assert words(view, "#page-context p#workflow-list") ==
               "The list shows the repositories connected to #{scope.organisation.name}, and " <>
                 "the harness sources Qory Apiary provides to #{scope.organisation.name}. " <>
                 "If your harness repository is missing, connect it to " <>
                 "#{scope.organisation.name}, or contact support."

      # The steps that repeated the form are gone.
      refute has_element?(view, "#workflow-help")
      refute render(view) =~ "Press Save."

      # The paragraphs of the Harness step's About this step.
      assert words(view, "#page-context #harness-about-what") ==
               "A harness is the skills and workflows the agent runs with."

      assert words(view, "#page-context #harness-about-order") ==
               "A repository whose harness.yaml or qory.yaml at its root sets a harness runs " <>
                 "with that file. Every other repository runs with the stack set for it under " <>
                 "Repositories, else with the harness you choose here, else with the Qory harness."

      for id <- ~w(harness-about-qory harness-about-exports harness-about-versions),
          do: assert(has_element?(view, "#page-context ##{id}"))

      refute has_element?(view, "#workflow-file-first")
      refute render(view) =~ "comes first."
    end

    test "no notice on a repository's harness file shows, whatever the harness choice",
         %{conn: conn, path: path, scope: scope} do
      {:ok, _choice} = Sources.choose(scope, :qory)
      refute has_element?(open(conn, path), "#workflow-file-first")

      document =
        "extends:\n  git: \"#{@harness}\"\n  ref: \"#{String.duplicate("c3", 20)}\"\n"

      {:ok, _choice} =
        Stacks.put_stack(scope, {:workspace, scope.workspace}, document, choice: :repository)

      refute has_element?(open(conn, path), "#workflow-file-first")
    end

    test "an example workspace has no line on the harness file", %{
      conn: conn,
      scope: scope,
      path: path
    } do
      with_domain(scope, "example")
      view = open(conn, path)

      assert has_element?(view, "#page-context")
      refute has_element?(view, "#workflow-file-first")
    end

    test "Source groups the connected repositories, the assigned sources and the public address",
         %{conn: conn, scope: scope, path: path, linked_id: linked_id} do
      Repo.insert!(%Assignment{
        organisation_id: scope.organisation.id,
        every_organisation: false,
        source: %{"git" => @team, "ref" => "v1"},
        created_by_id: instance_admin_scope().user.id
      })

      view = open(conn, path)

      refute has_element?(view, "select#workflow_source")
      assert has_element?(view, "button#workflow_source", "Choose a source")
      assert has_element?(view, "#workflow_source-g0", "Linked repositories")
      assert has_element?(view, ~s(#workflow_source-g0 ~ label input[value="#{linked_id}"]))
      assert has_element?(view, "#workflow_source-g0 ~ label .q-pick-t.mono", "acme/harness")

      # The list is built with no read, so a repository with no stack is listed too.
      assert has_element?(view, "#workflow_source-g0 ~ label .q-pick-t.mono", "acme/app")

      assert has_element?(view, "#workflow_source-g1", "Assigned to this organisation")

      assert has_element?(
               view,
               "#workflow_source-g1 ~ label .q-pick-t.mono",
               "example-org/team-harness"
             )

      assert has_element?(view, "#workflow_source-g2", "Public address")
      assert has_element?(view, ~s(#workflow_source-g2 ~ label input[value="address"]))
      assert has_element?(view, "#workflow_source-g2 ~ label .q-pick-t", "Enter an address")
      refute has_element?(view, "#workflow_source-g2 ~ label .q-pick-t.mono")

      # Source's options have titles only.
      refute has_element?(view, "#workflow_source-options .q-pick-s")
    end

    test "until the linked repositories are read, Reading… shows and cannot be chosen", %{
      conn: conn,
      path: path
    } do
      doc = conn |> get(path) |> html_response(200) |> LazyHTML.from_document()

      reading = LazyHTML.query(doc, ~s(#workflow_source-g0 ~ label input[value=""]))
      assert LazyHTML.attribute(reading, "disabled") == [""]
      assert LazyHTML.attribute(reading, "checked") == []

      assert doc |> LazyHTML.query("#workflow_source-g0 ~ label .q-pick-t") |> LazyHTML.text() =~
               "Reading…"

      # A blank field chooses nothing: the button shows the prompt.
      assert doc |> LazyHTML.query("button#workflow_source") |> LazyHTML.text() =~
               "Choose a source"
    end
  end

  describe "Source's groups" do
    test "each shows when it is empty", %{conn: conn, path: path} do
      view = open(conn, path)

      assert has_element?(view, "#workflow_source-g0", "Linked repositories")
      assert has_element?(view, "#workflow_source-g1", "Assigned to this organisation")
      refute has_element?(view, "#workflow_source-g1 ~ label")
    end

    test "the connected repositories are listed on each load with no call", %{
      conn: conn,
      path: path
    } do
      for _n <- 1..3 do
        view = open(conn, path)
        assert render(view) =~ "acme/harness"
      end

      # The workspace's harness is the Qory harness, which no load reads.
      assert calls() == []
    end

    test "with no connected repository, the group is empty and the address stays",
         %{conn: conn, path: path} do
      end_collections!()
      view = open(conn, path)

      assert has_element?(view, "#workflow_source-g0", "Linked repositories")
      refute has_element?(view, ~s(#workflow_source-options input[value=""]))
      refute render(view) =~ "No connected repository"
      refute has_element?(view, "#workflow_source-search")

      change(view, %{source: "address"})
      assert has_element?(view, "#workflow_address")
    end

    test "with a linked repository listed, Source has a search box, which keeps the address in view",
         %{conn: conn, path: path, linked_id: linked_id} do
      view = open(conn, path)

      assert has_element?(view, "#workflow_source-search")
      assert has_element?(view, ~s(#workflow_source-g0 ~ label input[value="#{linked_id}"]))

      assert has_element?(
               view,
               ~s(#workflow_source-g2 ~ label[data-keep="true"] input[value="address"])
             )

      refute has_element?(view, ~s(#workflow_source-g0 ~ label[data-keep="true"]))
    end
  end

  describe "a linked repository" do
    test "chosen, its workflows are listed, and Save stores the document a run then takes",
         %{conn: conn, scope: scope, path: path, linked_id: linked_id} do
      view = open(conn, path)
      assert has_element?(view, "#workflow_workflow[disabled]")

      change(view, %{source: linked_id})

      assert has_element?(view, ~s(#workflow_workflow option[value="0/fix"]), "fix")
      assert has_element?(view, ~s(#workflow_workflow option[value="0/triage"]), "triage")

      # A source only tried in Source is no snapshot: the snapshot is of the workspace's
      # harness, the Qory harness, whose names the page recorded when it opened.
      assert %{names: ["explore-a-ticket"]} = Processes.declared_snapshot(scope.workspace)

      change(view, %{source: linked_id, workflow: "0/triage"})
      view |> form("#workflow-form", workflow: %{workflow: "0/triage"}) |> render_submit()

      # Saved, it changes no snapshot.
      assert %{names: ["explore-a-ticket"]} = Processes.declared_snapshot(scope.workspace)

      assert render(view) =~ "Runs of #{scope.workspace.name} now follow the workflow triage."

      assert Sources.current(scope.workspace) == %{
               workflow: "triage",
               base: %{"git" => @harness, "ref" => "HEAD", "stack" => "triage"}
             }

      assert Stacks.workflow_for(scope.workspace, nil) == "triage"

      # The line shows the workflow alone, whatever the harness choice.
      assert has_element?(
               view,
               "#workflow-current",
               "Runs of #{scope.workspace.name} follow the workflow triage."
             )

      refute render(view) =~ "follow the workflow triage of"
    end

    test "chosen, it is checked and shown on the button", %{
      conn: conn,
      path: path,
      linked_id: linked_id
    } do
      view = open(conn, path)
      radio = "#workflow_source-options input[type=radio]"

      change(view, %{source: linked_id})

      assert has_element?(view, ~s{#{radio}[value="#{linked_id}"][checked]})
      refute has_element?(view, ~s{#{radio}[checked]:not([value="#{linked_id}"])})

      assert has_element?(
               view,
               "button#workflow_source:not(.is-prompt) .q-pick-t",
               "acme/harness"
             )
    end

    test "the saved setting is chosen again when the page opens", %{
      conn: conn,
      scope: scope,
      path: path,
      linked_id: linked_id
    } do
      base = %{"git" => @harness, "ref" => "HEAD", "stack" => "triage"}
      {:ok, _stack} = Sources.save(scope, base, "fix")

      view = open(conn, path)
      render_async(view, 2_000)

      assert has_element?(
               view,
               ~s(#workflow_source-options input[value="#{linked_id}"][checked])
             )

      assert has_element?(view, ~s(#workflow_workflow option[value="0/fix"][selected]))

      # The saved source, read, is no snapshot: the workspace's harness is the Qory harness.
      assert %{names: ["explore-a-ticket"]} = Processes.declared_snapshot(scope.workspace)
    end

    test "the page reads the workspace's harness choice when it opens, as Check again does, and keeps its workflows",
         %{conn: conn, scope: scope, adapter: adapter, covered: covered} do
      # A branch is chosen at the commit it points to.
      pin = String.duplicate("c3", 20)
      serve_calls([adapter], covered: covered, files: @files, versions: %{"R_harness" => pin})

      {:ok, _choice} =
        Sources.choose(scope, {:repository, %{git: @harness}, "triage", {:branch, "main"}})

      assert Processes.declared_snapshot(scope.workspace) == nil
      open(conn, workspace_path(scope, "/settings/harness"))

      assert %{names: ["fix", "triage"]} = Processes.declared_snapshot(scope.workspace)
    end

    test "a source tried in Source, read, changes no snapshot of the saved source", %{
      conn: conn,
      scope: scope,
      path: path,
      linked_id: linked_id
    } do
      base = %{"git" => @harness, "ref" => "v2", "stack" => "triage"}
      {:ok, _stack} = Sources.save(scope, base, "fix")

      view = open(conn, path)
      snapshot = Processes.declared_snapshot(scope.workspace)
      assert %{names: ["explore-a-ticket"]} = snapshot
      change(view, %{source: linked_id})
      assert has_element?(view, ~s(#workflow_workflow option[value="0/triage"]), "triage")

      assert Processes.declared_snapshot(scope.workspace) == snapshot
    end
  end

  describe "a source whose stacks are not read" do
    test "with no stack, its adapter not reached, or a stack file that is not valid: the cause",
         %{conn: conn, path: path, adapter: adapter, covered: covered, linked_id: linked_id} do
      serve_calls([adapter], covered: covered, files: %{})
      view = open(conn, path)
      change(view, %{source: linked_id})

      assert words(view, "#workflow-read-error") ==
               "acme/harness exports no stack. Add a qory.yaml or harness.yaml at its root " <>
                 "that lists the stack under exports."

      serve_calls([adapter], covered: covered, files: @files, down: true)
      view = open(conn, path)
      change(view, %{source: linked_id})

      assert words(view, "#workflow-read-error") ==
               "Qory Apiary could not connect to the #{Apiary.Adapters.title(adapter.adapter)} " <>
                 "adapter. Try again. If it repeats, contact support."

      files = Map.put(@files, {"R_harness", "stacks/triage/qory-stack.yaml"}, "modules: [core\n")
      serve_calls([adapter], covered: covered, files: files)
      view = open(conn, path)
      change(view, %{source: linked_id})

      assert words(view, "#workflow-read-error") ==
               "Correct stacks/triage/qory-stack.yaml in acme/harness: is not valid YAML."
    end

    test "a refused call, a listed stack with no stack file, or a stack section that is not valid: the cause",
         %{conn: conn, path: path, adapter: adapter, covered: covered, linked_id: linked_id} do
      serve_calls([adapter], covered: covered, files: @files, refuse_at: %{"HEAD" => "internal"})
      view = open(conn, path)
      change(view, %{source: linked_id})

      assert words(view, "#workflow-read-error") ==
               "Contact support: Qory Apiary could not call the " <>
                 "#{Apiary.Adapters.title(adapter.adapter)} adapter."

      files = Map.delete(@files, {"R_harness", "stacks/triage/qory-stack.yaml"})
      serve_calls([adapter], covered: covered, files: files)
      view = open(conn, path)
      change(view, %{source: linked_id})

      assert words(view, "#workflow-read-error") ==
               "acme/harness lists the stack triage under exports, but stacks/triage has no " <>
                 "qory-stack.yaml. Add that file."

      files = Map.put(@files, {"R_harness", "stacks/triage/qory-stack.yaml"}, "modules: 7\n")
      serve_calls([adapter], covered: covered, files: files)
      view = open(conn, path)
      change(view, %{source: linked_id})

      assert words(view, "#workflow-read-error") ==
               "Correct stacks/triage/qory-stack.yaml in acme/harness: it lists no modules: a " <>
                 "qory-stack.yaml lists at least one module, each a mapping."
    end

    test "an assigned folder with no qory-stack.yaml, or a stack name the root does not export: the cause",
         %{conn: conn, scope: scope, path: path} do
      admin = instance_admin_scope()

      # The second assignment's label has its stack name, which tells the two apart.
      for {narrowing, words} <- [
            {%{"path" => "stacks/web"},
             "acme/harness has no qory-stack.yaml in the folder stacks/web. Add that file."},
            {%{"stack" => "web"},
             "acme/harness · web exports no stack named web. List it under exports in the " <>
               "qory.yaml or harness.yaml at its root."}
          ] do
        assignment =
          Repo.insert!(%Assignment{
            organisation_id: scope.organisation.id,
            every_organisation: false,
            source: Map.merge(%{"git" => @harness, "ref" => "v1"}, narrowing),
            created_by_id: admin.user.id
          })

        view = open(conn, path)
        change(view, %{source: "assigned:" <> assignment.id})

        assert words(view, "#workflow-read-error") == words
      end
    end

    test "a stack that lists no workflow: where to add one",
         %{conn: conn, path: path, adapter: adapter, covered: covered, linked_id: linked_id} do
      files = Map.put(@files, {"R_harness", "stacks/triage/qory-stack.yaml"}, @stack)
      serve_calls([adapter], covered: covered, files: files)
      view = open(conn, path)
      change(view, %{source: linked_id})

      assert words(view, "#workflow-no-workflow") ==
               "The stack of acme/harness lists no workflow: add one under workflows in its " <>
                 "qory-stack.yaml."
    end
  end

  describe "an assigned source" do
    test "is read through the instance's grant when chosen", %{
      conn: conn,
      scope: scope,
      path: path,
      adapter: adapter,
      covered: covered
    } do
      instance = call_adapter_fixture()
      admin = instance_admin_scope()
      {connection, _nonce} = connection_fixture(admin, instance.adapter, :listed)
      live_grant_fixture(admin.organisation.id, instance.adapter, connection, "G_i")
      covered = Map.put(covered, instance.adapter.id, %{@team => {"G_i", "R_team"}})
      serve_calls([adapter, instance], covered: covered, files: @files)

      assignment =
        Repo.insert!(%Assignment{
          organisation_id: scope.organisation.id,
          every_organisation: false,
          source: %{"git" => @team, "ref" => "v1"},
          created_by_id: admin.user.id
        })

      view = open(conn, path)
      change(view, %{source: "assigned:" <> assignment.id})

      assert has_element?(view, ~s(#workflow_workflow option[value="0/review"]), "review")
    end
  end

  describe "a public address" do
    # A public repository on its host at `git` with `files`, and one more file whose name
    # no other test's has, so no commit of another test is in the cache.
    defp public!(git, files) do
      unique = %{".test-#{System.unique_integer([:positive])}" => ""}
      repo = PublicGitServer.repository!(Map.merge(files, unique))
      PublicGitServer.serve(%{git => repo.dir})
    end

    test "with a password is refused under the field, and nothing is read", %{
      conn: conn,
      path: path
    } do
      view = open(conn, path)
      change(view, %{source: "address"})
      calls()

      assert has_element?(
               view,
               "#workflow_address-hint",
               "The repository's address, without a password or token in it."
             )

      change(view, %{source: "address", address: "https://deploy:s3cret@code.example.com/x"})

      assert has_element?(
               view,
               "#workflow_address-error",
               "remove the user name and password from https://code.example.com/x"
             )

      refute view |> element("#workflow_address-error") |> render() =~ "s3cret"
      assert calls() == []
      assert has_element?(view, "#workflow_workflow[disabled]")
    end

    test "that no integration reaches, and that is not public, says so", %{
      conn: conn,
      scope: scope,
      path: path
    } do
      view = open(conn, path)
      change(view, %{source: "address"})
      change(view, %{source: "address", address: "https://public.example.org/qory/stack"})

      assert has_element?(
               view,
               "#workflow-read-error",
               "Owners and admins of #{scope.organisation.name} connect an integration that covers https://public.example.org/qory/stack in Organisation settings › Integrations. https://public.example.org/qory/stack is not public, or does not exist, and no connection of #{scope.organisation.name} reaches it."
             )
    end

    test "whose host is out of reach says who checks what", %{conn: conn, path: path} do
      view = open(conn, path)
      change(view, %{source: "address"})
      change(view, %{source: "address", address: "https://nowhere.example.org/qory/stack"})

      assert has_element?(
               view,
               "#workflow-read-error",
               "Contact support: Qory Apiary did not receive https://nowhere.example.org/qory/stack from nowhere.example.org on port 443 within 10 s."
             )
    end

    test "that is public lists the workflows of its stack at HEAD, read from its host, and saves",
         %{conn: conn, scope: scope, path: path} do
      public = "https://code.example.com/example-org/public-harness"
      public!(public, %{"qory-stack.yaml" => @stack <> "workflows:\n  review: {}\n"})

      view = open(conn, path)
      change(view, %{source: "address"})
      calls()
      change(view, %{source: "address", address: public})

      assert has_element?(view, ~s(#workflow_workflow option[value="0/review"]), "review")
      refute has_element?(view, "#workflow-read-error")
      assert [] = for({"read", _call} <- calls(), do: :read)

      change(view, %{source: "address", address: public, workflow: "0/review"})
      view |> form("#workflow-form", workflow: %{workflow: "0/review"}) |> render_submit()

      assert Sources.current(scope.workspace) == %{
               workflow: "review",
               base: %{"git" => public, "ref" => "HEAD"}
             }
    end

    test "that a grant covers with no assignment, and that is public, is read from its host",
         %{conn: conn, path: path, adapter: adapter, covered: covered} do
      instance = call_adapter_fixture()
      admin = instance_admin_scope()
      {connection, _nonce} = connection_fixture(admin, instance.adapter, :listed)
      live_grant_fixture(admin.organisation.id, instance.adapter, connection, "G_i")
      covered = Map.put(covered, instance.adapter.id, %{@team => {"G_i", "R_team"}})
      serve_calls([adapter, instance], covered: covered, files: @files)
      public!(@team, %{"qory-stack.yaml" => @stack <> "workflows:\n  audit: {}\n"})

      view = open(conn, path)
      change(view, %{source: "address"})
      calls()
      change(view, %{source: "address", address: @team})

      assert has_element?(view, ~s(#workflow_workflow option[value="0/audit"]), "audit")
      assert [] = for({"read", _call} <- calls(), do: :read)
    end

    test "that a link covers is read like a linked repository", %{conn: conn, path: path} do
      view = open(conn, path)
      change(view, %{source: "address"})
      change(view, %{source: "address", address: @harness})

      assert has_element?(view, ~s(#workflow_workflow option[value="0/triage"]))
    end
  end

  describe "the harness" do
    @pin String.duplicate("c3", 20)

    defp change_harness(view) do
      view |> element("#workflow-harness-change") |> render_click()
      view
    end

    @one_export %{
      {"R_harness", "harness.yaml"} => "exports:\n  stacks: [triage]\n",
      {"R_harness", "stacks/triage/qory-stack.yaml"} =>
        "modules:\n  - name: core\n    source: {path: modules/core}\n"
    }

    # The harness form with a harness repository and acme/harness chosen, its exports read.
    defp pick_repository(view, linked_id) do
      view
      |> form("#workflow-harness-form", harness: %{choice: "repository"})
      |> render_change()

      view
      |> form("#workflow-harness-form", harness: %{source: linked_id})
      |> render_change()

      render_async(view, 2_000)
      view
    end

    test "an adapter with no call address: a line at Repository before any pick, with no address",
         %{conn: conn, path: path, adapter: adapter} do
      {1, _} =
        Repo.update_all(from(n in Apiary.Nodes.Node, where: n.id == ^adapter.adapter.id),
          set: [call_url: nil, call_instance_id: nil]
        )

      view = conn |> open(path) |> change_harness()

      view
      |> form("#workflow-harness-form", harness: %{choice: "repository"})
      |> render_change()

      assert words(view, "#harness-source-unplaced-#{adapter.adapter.public_id}-no_address") ==
               "Contact support: Qory Apiary could not read the repositories of the " <>
                 "#{Apiary.Adapters.title(adapter.adapter)} adapter."

      refute has_element?(view, "#harness-source-none")
      refute render(view) =~ adapter.host
    end

    test "without a choice: the Qory harness on main, with Change and no Update",
         %{conn: conn, path: path} do
      view = open(conn, path)

      assert has_element?(view, "#workflow-harness", "Harness")

      assert words(view, "#harness-line") ==
               "Qory harness, stack software main"

      refute render(view) =~ "fe3b3ab"
      assert has_element?(view, "#workflow-harness-change", "Change")
      refute has_element?(view, "#workflow-harness-form")
      refute render(view) =~ "Update"
    end

    test "Change opens the two choices; the Qory harness saves on main, the branch it starts on",
         %{
           conn: conn,
           path: path,
           scope: scope
         } do
      view = conn |> open(path) |> change_harness()

      refute has_element?(view, "#harness-intro")
      assert has_element?(view, "#harness-choice-qory-radio[checked]")
      assert words(view, "#harness-choice-qory") == "Qory harness"
      assert has_element?(view, "#harness-qory-version-branch[checked]")
      assert has_element?(view, ~s(#harness-qory-branch[value="main"]))
      refute has_element?(view, "#harness-qory-version-fixed[checked]")
      refute has_element?(view, "#harness-qory-version-fixed[disabled]")

      refute render(view) =~ "fe3b3ab"
      refute has_element?(view, "#harness-choice-target_file")
      refute has_element?(view, "#harness-choice-qory-file")
      assert has_element?(view, "#harness-choice-repository", "A harness repository")

      view
      |> form("#workflow-harness-form", harness: %{choice: "qory"})
      |> render_submit()

      render_async(view, 2_000)
      assert words(view, "#harness-line") == "Qory harness, stack software main"

      refute has_element?(view, "#workflow-harness-form")

      assert %{choice: :qory, version_kind: :branch, version_name: "main"} =
               Stacks.choice(scope.workspace)

      refute has_element?(view, "#workflow-file-first")

      # Cancel closes the choices with nothing saved.
      change_harness(view)
      view |> element("#workflow-harness-cancel") |> render_click()
      refute has_element?(view, "#workflow-harness-form")
    end

    test "the Qory harness at a tag or a commit: A fixed version, read before the save", %{
      conn: conn,
      path: path,
      scope: scope
    } do
      repository = QoryHarnessFixture.serve!(QoryHarnessFixture.files(), tags: ["v1.0.0"])
      view = conn |> open(path) |> change_harness()

      view
      |> form("#workflow-harness-form",
        harness: %{choice: "qory", qory_version: "fixed", qory_fixed: "v1.0.0"}
      )
      |> render_submit()

      render_async(view, 2_000)
      assert words(view, "#harness-line") == "Qory harness, stack software v1.0.0"
      assert %{version_kind: :tag, version_name: "v1.0.0"} = Stacks.choice(scope.workspace)

      view = conn |> open(path) |> change_harness()
      assert has_element?(view, "#harness-qory-version-fixed[checked]")
      assert has_element?(view, ~s(#harness-qory-fixed[value="v1.0.0"]))

      view
      |> form("#workflow-harness-form",
        harness: %{choice: "qory", qory_version: "fixed", qory_fixed: repository.commit}
      )
      |> render_submit()

      render_async(view, 2_000)

      assert words(view, "#harness-line") ==
               "Qory harness, stack software #{String.slice(repository.commit, 0, 7)}"

      assert %{version_kind: :commit, version_name: commit} = Stacks.choice(scope.workspace)
      assert commit == repository.commit
    end

    test "the Qory harness on a branch it does not have: the words of the missing ref, and nothing saved",
         %{conn: conn, path: path, scope: scope} do
      view = conn |> open(path) |> change_harness()

      view
      |> form("#workflow-harness-form", harness: %{choice: "qory", qory_branch: "no-such-branch"})
      |> render_submit()

      render_async(view, 2_000)

      assert words(view, "#workflow-harness-refusal") ==
               "Set a branch, tag or commit that exists. " <>
                 "https://github.com/qoryai/harness has no branch no-such-branch."

      assert Stacks.choice(scope.workspace) == nil
    end

    test "the Qory harness at a fixed version it does not have: the words of a missing tag or commit, and nothing saved",
         %{conn: conn, path: path, scope: scope} do
      view = conn |> open(path) |> change_harness()

      view
      |> form("#workflow-harness-form",
        harness: %{choice: "qory", qory_version: "fixed", qory_fixed: "v9.9.9"}
      )
      |> render_submit()

      render_async(view, 2_000)

      assert words(view, "#workflow-harness-refusal") ==
               "Set a branch, tag or commit that exists. " <>
                 "https://github.com/qoryai/harness has no tag or commit v9.9.9."

      assert Stacks.choice(scope.workspace) == nil
    end

    test "the Qory harness whose host fails: save again later, why, and nothing saved",
         %{conn: conn, path: path, scope: scope} do
      PublicGitServer.serve(%{}, answer: fn conn -> Plug.Conn.send_resp(conn, 429, "") end)
      view = conn |> open(path) |> change_harness()

      view
      |> form("#workflow-harness-form", harness: %{choice: "qory"})
      |> render_submit()

      render_async(view, 2_000)

      assert words(view, "#workflow-harness-refusal") ==
               "Save again later. Reading the harness from https://github.com/qoryai/harness " <>
                 "failed: the host returned 429 Too Many Requests. If it fails again, " <>
                 "contact support."

      assert Stacks.choice(scope.workspace) == nil
    end

    test "a workspace with no template shows the stack core", %{
      conn: conn,
      path: path,
      scope: scope
    } do
      {1, _rows} =
        Repo.update_all(
          from(w in Apiary.Organisations.Workspace, where: w.id == ^scope.workspace.id),
          set: [qory_stack: nil]
        )

      view = open(conn, path)

      assert words(view, "#harness-line") == "Qory harness, stack core main"
    end

    test "without a choice of the workspace: the shared harness and its version as a line, with no version field",
         %{conn: conn, path: path, scope: scope} do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ScopeSetting)
      {:ok, _shared} = Sources.choose(scope, :qory, shared: true)
      view = open(conn, path)

      assert words(view, "#harness-line") == "Qory harness, stack software main"

      refute has_element?(view, "#harness-qory-version")
      refute has_element?(view, "#harness-version")

      for {version, line} <- [
            {{:branch, "main"}, "triage · acme/harness · main"},
            {{:tag, "v1"}, "triage · acme/harness · v1"}
          ] do
        {:ok, _shared} =
          Stacks.put_stack(
            scope,
            {:organisation, scope.organisation},
            "extends:\n  git: \"#{@harness}\"\n  ref: \"#{elem(version, 1)}\"\n  stack: \"triage\"\n",
            choice: :repository,
            version: version
          )

        view = open(conn, path)

        assert words(view, "#harness-line") == "A harness repository " <> line
        refute has_element?(view, "#harness-qory-version")
        refute has_element?(view, "#harness-version")
      end

      assert Stacks.choice(scope.workspace) == nil
    end

    test "with a shared Qory harness and a destination: the Qory harness once, and the destination's row",
         %{conn: conn, path: path, scope: scope} do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ScopeSetting)
      {:ok, _shared} = Sources.choose(scope, :qory, shared: true)
      collection = collection_fixture(scope)

      {1, _} =
        Repo.update_all(
          from(n in Apiary.Nodes.Node, where: n.id == ^collection.adapter_id),
          set: [targets: true]
        )

      view = conn |> open(path) |> change_harness()

      assert ["harness-choice-qory", "harness-choice-repository"] ==
               view
               |> render()
               |> LazyHTML.from_fragment()
               |> LazyHTML.query("#harness-choice label")
               |> LazyHTML.attribute("id")

      refute has_element?(view, "#harness-choice-shared")
      assert has_element?(view, "#harness-targets #harness-target-#{collection.public_id}")
    end

    # The Qory harness row and its Version, as Change draws them, chosen.
    defp qory_row(view) do
      for selector <- ["#harness-choice-qory", "#harness-qory-version"],
          do: view |> element(selector) |> render()
    end

    test "the Qory harness row is the same with no shared harness, a shared Qory harness, a shared harness repository, and the workspace's Qory harness under a shared Qory harness",
         %{conn: conn, path: path, scope: scope} do
      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ScopeSetting)
      plain = conn |> open(path) |> change_harness() |> qory_row()

      # The organisation shares the Qory harness, and the workspace reuses it.
      {:ok, _shared} = Sources.choose(scope, :qory, shared: true)
      view = conn |> open(path) |> change_harness()
      assert qory_row(view) == plain
      refute render(view) =~ "every workspace"
      refute has_element?(view, "#harness-choice-shared")

      # The organisation shares a harness repository: the Qory harness row, once chosen.
      {:ok, _shared} =
        Stacks.put_stack(
          scope,
          {:organisation, scope.organisation},
          "extends:\n  git: \"#{@harness}\"\n  ref: \"#{@pin}\"\n",
          choice: :repository
        )

      view = conn |> open(path) |> change_harness()
      assert has_element?(view, "#harness-choice-repository-radio[checked]")
      view |> form("#workflow-harness-form", harness: %{choice: "qory"}) |> render_change()
      assert qory_row(view) == plain

      # The workspace's Qory harness while the organisation shares the Qory harness.
      {:ok, _deleted} = Stacks.delete_stack({:organisation, scope.organisation})
      {:ok, _shared} = Sources.choose(scope, :qory, shared: true)
      {:ok, _row} = Sources.choose(scope, :qory)
      assert %{choice: :qory, shared: false} = Sources.chosen(scope.workspace)
      view = conn |> open(path) |> change_harness()
      assert qory_row(view) == plain
      refute render(view) =~ "every workspace"
    end

    test "a harness repository: one repository by name, its exported stack, and a fixed version",
         %{
           conn: conn,
           path: path,
           scope: scope,
           adapter: adapter,
           covered: covered,
           linked_id: linked_id
         } do
      files = Map.merge(@files, @one_export)
      serve_calls([adapter], covered: covered, files: files, versions: %{"R_harness" => @pin})
      view = conn |> open(path) |> change_harness()

      view
      |> form("#workflow-harness-form", harness: %{choice: "repository"})
      |> render_change()

      # No repository is chosen until the person picks one.
      assert words(view, "#harness-source-label") == "Repository"
      assert has_element?(view, "button#harness-source.is-prompt", "Find a repository")
      assert has_element?(view, "#harness-source-search")
      assert has_element?(view, "#workflow-harness-save[disabled]")

      pick_repository(view, linked_id)

      assert has_element?(view, ~s(#harness-source-options input[value="#{linked_id}"][checked]))
      assert has_element?(view, ~s(#harness-stack input[value="triage"][checked]))
      refute has_element?(view, "#harness-ref-hint")

      # The Qory harness's names, recorded when the page opened.
      assert %{names: ["explore-a-ticket"]} = Processes.declared_snapshot(scope.workspace)

      view
      |> form("#workflow-harness-form", harness: %{version: "fixed", fixed: "v2"})
      |> render_submit()

      render_async(view, 2_000)
      render_async(view, 2_000)

      # The choice saved, its stack is read again: it lists no workflows.
      assert %{names: []} = Processes.declared_snapshot(scope.workspace)

      assert words(view, "#harness-line") == "A harness repository triage · acme/harness · v2"

      assert {"R_harness", "harness.yaml", "v2"} in for(
               {"read", call} <- calls(),
               do: {call["resource_ref"], call["path"], call["at"]}
             )

      assert %{choice: :repository, version_kind: :tag, version_name: "v2"} =
               Stacks.choice(scope.workspace)
    end

    test "a harness repository with no connected repository: Repository has none to choose, and a line under it shows how to get one",
         %{conn: conn, path: path, scope: scope} do
      end_collections!()
      view = conn |> open(path) |> change_harness()

      view
      |> form("#workflow-harness-form", harness: %{choice: "repository"})
      |> render_change()

      assert has_element?(view, "button#harness-source[disabled]")
      refute render(view) =~ "No connected repository"

      assert words(view, "#harness-source-none") ==
               "#{scope.organisation.name} has no connected repository. Connect a work source " <>
                 "to pick one."

      assert has_element?(view, "#workflow-harness-save[disabled]")
    end

    test "a harness repository that exports no stack: the line in place of Stack", %{
      conn: conn,
      path: path,
      scope: scope,
      adapter: adapter,
      covered: covered,
      linked_id: linked_id
    } do
      serve_calls([adapter], covered: covered, files: %{})
      view = conn |> open(path) |> change_harness() |> pick_repository(linked_id)

      assert words(view, "#harness-stack-none") ==
               "acme/harness exports no stack. Add a qory.yaml or harness.yaml at its root " <>
                 "that lists the stack under exports."

      assert has_element?(view, "#workflow-harness-save[disabled]")
      assert Stacks.choice(scope.workspace) == nil
    end

    test "a harness repository its adapter cannot be reached for, or whose qory.yaml is not valid: the cause in place of Stack",
         %{conn: conn, path: path, adapter: adapter, covered: covered, linked_id: linked_id} do
      serve_calls([adapter], covered: covered, files: @files, down: true)
      view = conn |> open(path) |> change_harness() |> pick_repository(linked_id)

      assert words(view, "#harness-stack-error") ==
               "Qory Apiary could not connect to the #{Apiary.Adapters.title(adapter.adapter)} " <>
                 "adapter. Try again. If it repeats, contact support."

      files = %{{"R_harness", "qory.yaml"} => "exports: [triage\n"}
      serve_calls([adapter], covered: covered, files: files)
      view = conn |> open(path) |> change_harness() |> pick_repository(linked_id)

      assert words(view, "#harness-stack-error") ==
               "Correct qory.yaml in acme/harness: is not valid YAML."

      assert has_element?(view, "#workflow-harness-save[disabled]")

      serve_calls([adapter],
        covered: covered,
        files: %{{"R_harness", "qory.yaml"} => "exports: 7\n"}
      )

      view = conn |> open(path) |> change_harness() |> pick_repository(linked_id)

      assert words(view, "#harness-stack-error") ==
               "Correct the exports section of qory.yaml in acme/harness: write stacks as a " <>
                 "list of stack names, and dir, if there is one, as a folder name or as the " <>
                 "names of a stacks folder and a modules folder."
    end

    test "a harness repository whose stack cannot be read shows the reason, and the choice stays",
         %{
           conn: conn,
           path: path,
           scope: scope,
           adapter: adapter,
           covered: covered,
           linked_id: linked_id
         } do
      # acme/harness exports triage, and has no qory-stack.yaml for it.
      files = Map.delete(@files, {"R_harness", "stacks/triage/qory-stack.yaml"})
      serve_calls([adapter], covered: covered, files: files)
      view = conn |> open(path) |> change_harness() |> pick_repository(linked_id)

      view |> form("#workflow-harness-form") |> render_submit()
      render_async(view, 2_000)

      assert words(view, "#workflow-harness-refusal") ==
               "acme/harness lists the stack triage under exports, but stacks/triage has no " <>
                 "qory-stack.yaml. Add that file."

      assert words(view, "#harness-line") ==
               "Qory harness, stack software main"

      assert Stacks.choice(scope.workspace) == nil
    end

    test "a tag the read finds no version for: correct it, and the choice stays", %{
      conn: conn,
      path: path,
      scope: scope,
      adapter: adapter,
      covered: covered,
      linked_id: linked_id
    } do
      # The read returns c-R_harness, which is no commit.
      serve_calls([adapter], covered: covered, files: Map.merge(@files, @one_export))
      view = conn |> open(path) |> change_harness() |> pick_repository(linked_id)

      view
      |> form("#workflow-harness-form", harness: %{version: "fixed", fixed: "v9"})
      |> render_submit()

      render_async(view, 2_000)

      assert words(view, "#workflow-harness-refusal") ==
               "acme/harness has no branch, tag or commit named v9. Correct the version."

      assert words(view, "#harness-line") ==
               "Qory harness, stack software main"

      assert Stacks.choice(scope.workspace) == nil
    end
  end

  describe "the destinations" do
    # A destination of the workspace: a collection with a target, assigned to it, of an
    # adapter with targets.
    defp destination!(scope) do
      collection = collection_fixture(scope)

      {1, _} =
        Repo.update_all(
          from(n in Apiary.Nodes.Node, where: n.id == ^collection.adapter_id),
          set: [targets: true]
        )

      collection
    end

    defp target_of(collection),
      do: %{system: collection.target_system, path: collection.target_path}

    # The options of a destination's Stack select, `{text, value}`.
    defp row_options(view, collection) do
      options =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#harness-target-#{collection.public_id}-stack option")

      values = LazyHTML.attribute(options, "value")
      texts = Enum.map(options, &(&1 |> LazyHTML.text() |> String.trim()))
      Enum.zip(texts, values)
    end

    defp row_chosen(view, collection),
      do: words(view, "#harness-target-#{collection.public_id}-stack option[selected]")

    defp pick_row(view, collection, value) do
      view
      |> form("#harness-target-#{collection.public_id}-form", row: %{stack: value})
      |> render_change()

      render_async(view, 2_000)
      view
    end

    # Whether the element with the id `first` comes before the one with the id `second`.
    defp before?(html, first, second) do
      {at_first, _length} = :binary.match(html, ~s(id="#{first}"))
      {at_second, _length} = :binary.match(html, ~s(id="#{second}"))
      at_first < at_second
    end

    test "the rows show under the harness choice, with the Harness step's Stack select; the workspace's harness and a stack of the Qory harness save at once",
         %{conn: conn, path: path, scope: scope} do
      destination = destination!(scope)
      view = open(conn, path)

      assert words(view, "#workflow-harness #harness-targets-h") == "Repositories"
      assert has_element?(view, "#harness-target-#{destination.public_id}", destination.title)

      assert words(view, ~s(label[for="harness-target-#{destination.public_id}-stack"])) ==
               "Stack"

      # Under the choice's line, and under its form once Change opens it.
      assert before?(render(view), "harness-line", "harness-targets")
      assert before?(render(view), "harness-targets", "workflow-form")
      change_harness(view)
      assert before?(render(view), "workflow-harness-form", "harness-targets")

      assert row_options(view, destination) == [
               {"Workspace's harness", "default"},
               {"core · Qory harness · main", "workspace:core"},
               {"software · Qory harness · main", "workspace:software"},
               {"authoring · Qory harness · main", "workspace:authoring"},
               {"A stack of another repository…", "other"}
             ]

      assert row_chosen(view, destination) == "Workspace's harness"

      pick_row(view, destination, "workspace:core")
      assert row_chosen(view, destination) == "core · Qory harness · main"

      assert %{choice: :qory, version_kind: :workspace} =
               Stacks.target_choice(scope.workspace, target_of(destination))

      pick_row(view, destination, "default")
      assert row_chosen(view, destination) == "Workspace's harness"
      assert Stacks.target_choice(scope.workspace, target_of(destination)) == nil
    end

    test "a harness repository saved on the page: the rows offer the stacks it exports, and one saves",
         %{
           conn: conn,
           path: path,
           scope: scope,
           adapter: adapter,
           covered: covered,
           linked_id: linked_id
         } do
      serve_calls([adapter], covered: covered, files: @files, versions: %{"R_harness" => @pin})
      destination = destination!(scope)
      view = conn |> open(path) |> change_harness() |> pick_repository(linked_id)

      view
      |> form("#workflow-harness-form", harness: %{version: "fixed", fixed: "v2"})
      |> render_submit()

      # The save, then the read of the stacks the saved choice exports.
      render_async(view, 2_000)
      render_async(view, 2_000)

      assert words(view, "#harness-line") == "A harness repository triage · acme/harness · v2"

      assert row_options(view, destination) == [
               {"Workspace's harness", "default"},
               {"triage · acme/harness · v2", "workspace:triage"},
               {"A stack of another repository…", "other"}
             ]

      pick_row(view, destination, "workspace:triage")
      assert row_chosen(view, destination) == "triage · acme/harness · v2"

      assert %{choice: :repository, version_kind: :workspace, harness: harness} =
               Stacks.target_choice(scope.workspace, target_of(destination))

      assert harness =~ ~s(stack: "triage")
    end

    test "A stack of another repository…: a connected repository's exported stack at a fixed version saves",
         %{
           conn: conn,
           path: path,
           scope: scope,
           adapter: adapter,
           covered: covered,
           linked_id: linked_id
         } do
      serve_calls([adapter], covered: covered, files: @files, versions: %{"R_harness" => @pin})
      destination = destination!(scope)
      view = open(conn, path)

      pick_row(view, destination, "other")
      assert row_chosen(view, destination) == "A stack of another repository…"
      assert words(view, "#target_stack_source-label") == "Repository"
      assert has_element?(view, "#harness-target-save[disabled]")

      view
      |> form("#harness-target-form", target_stack: %{source: linked_id})
      |> render_change()

      render_async(view, 2_000)
      assert has_element?(view, ~s(#target_stack_stack input[value="triage"][checked]))

      view
      |> form("#harness-target-form", target_stack: %{version: "fixed", fixed: "v2"})
      |> render_submit()

      render_async(view, 2_000)

      refute has_element?(view, "#harness-target-form")
      assert row_chosen(view, destination) == "triage · acme/harness · v2"

      assert %{choice: :repository, version_kind: :tag, version_name: "v2"} =
               Stacks.target_choice(scope.workspace, target_of(destination))
    end

    test "a refused save shows its reason under its row, and nothing is saved", %{
      conn: conn,
      path: path,
      scope: scope,
      linked_id: linked_id
    } do
      # The read returns c-R_harness, which is no commit.
      destination = destination!(scope)
      view = open(conn, path)
      pick_row(view, destination, "other")

      view
      |> form("#harness-target-form", target_stack: %{source: linked_id})
      |> render_change()

      render_async(view, 2_000)

      view
      |> form("#harness-target-form", target_stack: %{version: "fixed", fixed: "v9"})
      |> render_submit()

      render_async(view, 2_000)

      assert words(view, "#harness-target-#{destination.public_id} #harness-target-refusal") ==
               "acme/harness has no branch, tag or commit named v9. Correct the version."

      assert has_element?(view, "#harness-target-form")
      assert Stacks.target_choice(scope.workspace, target_of(destination)) == nil
    end

    test "a person whom harness.save no longer allows: the save is refused with who may, and the rows show disabled",
         %{scope: scope, path: path} do
      %{user: user, membership: membership} = member_fixture(scope, :admin)
      destination = destination!(scope)
      view = open(log_in_user(build_conn(), user), path)
      refute has_element?(view, "#harness-target-#{destination.public_id}-stack[disabled]")

      {1, _} =
        Repo.update_all(
          from(m in Apiary.Organisations.Membership, where: m.id == ^membership.id),
          set: [level: :member]
        )

      pick_row(view, destination, "workspace:core")

      assert render(view) =~ "Only owners and admins can change the workflow."
      assert has_element?(view, "#harness-target-#{destination.public_id}-stack[disabled]")
      assert Stacks.target_choice(scope.workspace, target_of(destination)) == nil

      # A save sent with the select disabled changes nothing.
      render_change(view, "choose_target_stack", %{
        "row" => %{"id" => destination.public_id, "stack" => "workspace:core"}
      })

      assert Stacks.target_choice(scope.workspace, target_of(destination)) == nil
    end
  end

  describe "with workflow_model" do
    @describetag with_features: Apiary.Features.all()

    test "the workflow choice is gone, with its line and its About paragraphs", %{
      conn: conn,
      path: path
    } do
      view = open(conn, path)

      refute has_element?(view, "#workflow-form")
      refute has_element?(view, "#workflow-current")
      refute has_element?(view, "#workflow-what")
      refute has_element?(view, "#workflow-list")
    end

    test "the harness choice stays, with Change and the destinations", %{conn: conn, path: path} do
      view = open(conn, path)

      assert has_element?(view, "#workflow-harness")
      view |> element("#workflow-harness-change") |> render_click()
      assert has_element?(view, "#workflow-harness-form")
    end

    test "the sidebar lists Workflows, then Harness, the current section", %{
      conn: conn,
      path: path,
      scope: scope
    } do
      view = open(conn, path)

      assert has_element?(view, "#settings-section-title", "Harness")
      assert has_element?(view, ~s(#settings-tab-harness[href="#{path}"][aria-current="page"]))

      workflows = workspace_path(scope, "/settings/workflows")
      assert has_element?(view, ~s(#settings-tab-workflows[href="#{workflows}"]), "Workflows")
      refute has_element?(view, ~s(#settings-tab-workflows[aria-current="page"]))

      [before, _after] = String.split(render(view), ~s(id="settings-tab-harness"), parts: 2)
      assert before =~ ~s(id="settings-tab-workflows")
    end

    test "the page links to Workflows", %{conn: conn, path: path, scope: scope} do
      view = open(conn, path)

      assert has_element?(
               view,
               "#workflow-stages",
               "Set the stages of #{scope.workspace.name}, and the workflows each stage runs, on the Workflows page."
             )

      assert has_element?(
               view,
               ~s(#workflow-stages-link[href="#{workspace_path(scope, "/settings/workflows")}"]),
               "Open Workflows"
             )
    end
  end
end
