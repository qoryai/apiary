defmodule ApiaryWeb.WorkflowLiveTest do
  @moduledoc """
  Workspace settings › Workflow (`ApiaryWeb.WorkflowLive`) against stub adapters
  (`Req.Test`): who opens it and where it is in the list; its steps, and the line on a
  repository's harness file in a software workspace alone; each kind of source, read when
  chosen; a refused address; the save, its document, and the setting shown again.
  """
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.HarnessReadsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Repo
  alias Apiary.Harnesses.Assignment
  alias Apiary.Stacks
  alias Apiary.Stacks.Sources

  @moduletag needs: :factory
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
      path: workspace_path(scope, "/settings/workflow")
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

      assert has_element?(view, "#settings-section-title", "Workflow")
      assert has_element?(view, ~s(#settings-tab-workflow[href="#{path}"][aria-current="page"]))

      html = render(view)
      [before, _after] = String.split(html, ~s(id="settings-tab-workflow"), parts: 2)
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
      refute has_element?(view, "#settings-tab-workflow")
    end

    test "another organisation's owner finds no such page", %{path: path} do
      %{user: user} = sign_up_fixture()
      assert build_conn() |> log_in_user(user) |> get(path) |> Map.get(:status) == 404
    end
  end

  describe "the page" do
    test "About this step says what the page sets, and in a software workspace the harness file comes first",
         %{conn: conn, path: path, scope: scope} do
      view = open(conn, path)

      assert has_element?(view, "aside#page-context h2", "About this step")

      assert has_element?(
               view,
               "#page-context p#workflow-what",
               "Runs in #{scope.workspace.name} use the workflow you choose here, from a harness repository."
             )

      assert has_element?(
               view,
               "#page-context p#workflow-list",
               "The list shows the repositories linked to #{scope.organisation.name} that have a stack"
             )

      # The steps that repeated the form are gone.
      refute has_element?(view, "#workflow-help")
      refute render(view) =~ "Press Save."

      assert has_element?(
               view,
               "#workflow-file-first",
               "A repository's harness.yaml or qory.yaml comes first."
             )
    end

    test "with the Qory harness saved the harness file comes first; with a harness repository no line says so",
         %{conn: conn, path: path, scope: scope} do
      {:ok, _choice} = Sources.choose(scope, :qory)
      assert has_element?(open(conn, path), "#workflow-file-first")

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

    test "Source groups the linked repositories that have a stack, the assigned sources and the public address",
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

      refute render(view) =~ "acme/app"

      assert has_element?(view, "#workflow_source-g1", "Assigned by an instance admin")

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
      assert has_element?(view, "#workflow_source-g1", "Assigned by an instance admin")
      refute has_element?(view, "#workflow_source-g1 ~ label")
    end

    test "a third listing in a minute says when to reload", %{conn: conn, path: path} do
      open(conn, path)
      open(conn, path)
      view = open(conn, path)

      assert render(view) =~ "then reload the page to list the linked repositories."
      refute render(view) =~ "acme/harness"
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

      change(view, %{source: linked_id, workflow: "0/triage"})
      view |> form("#workflow-form", workflow: %{workflow: "0/triage"}) |> render_submit()

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

    test "that no linked repository or assignment covers, and that is not public, says so", %{
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
               "Link https://public.example.org/qory/stack to #{scope.organisation.name}, or ask an instance admin to assign it: Qory Apiary reads a harness repository that is not public only through a linked repository or an assignment."
             )
    end

    test "that is public lists the workflows of its stack at HEAD, read as public, and saves",
         %{conn: conn, scope: scope, path: path, adapter: adapter, covered: covered} do
      public = "https://code.example.com/example-org/public-harness"
      covered = Map.update!(covered, adapter.adapter.id, &Map.put(&1, public, {:public, "P_pub"}))

      files =
        Map.put(@files, {"P_pub", "qory-stack.yaml"}, @stack <> "workflows:\n  review: {}\n")

      serve_calls([adapter], covered: covered, files: files)

      view = open(conn, path)
      change(view, %{source: "address"})
      calls()
      change(view, %{source: "address", address: public})

      assert has_element?(view, ~s(#workflow_workflow option[value="0/review"]), "review")
      refute has_element?(view, "#workflow-read-error")

      reads = for {path, call} <- calls(), path in ["read", "read-public"], do: {path, call}
      assert [_ | _] = reads

      assert Enum.all?(reads, fn {path, call} ->
               path == "read-public" and call["resource_ref"] == "P_pub" and
                 not Map.has_key?(call, "grant_ref")
             end)

      assert {"read-public", %{"path" => "harness.yaml", "at" => "HEAD"}} = hd(reads)

      change(view, %{source: "address", address: public, workflow: "0/review"})
      view |> form("#workflow-form", workflow: %{workflow: "0/review"}) |> render_submit()

      assert Sources.current(scope.workspace) == %{
               workflow: "review",
               base: %{"git" => public, "ref" => "HEAD"}
             }
    end

    test "that a grant covers with no assignment, and that is public, is read at its public ref",
         %{conn: conn, path: path, adapter: adapter, covered: covered} do
      instance = call_adapter_fixture()
      admin = instance_admin_scope()
      {connection, _nonce} = connection_fixture(admin, instance.adapter, :listed)
      live_grant_fixture(admin.organisation.id, instance.adapter, connection, "G_i")

      covered =
        Map.put(covered, instance.adapter.id, %{@team => {"G_i", "R_team", {:public, "P_team"}}})

      files =
        Map.put(@files, {"P_team", "qory-stack.yaml"}, @stack <> "workflows:\n  audit: {}\n")

      serve_calls([adapter, instance], covered: covered, files: files)

      view = open(conn, path)
      change(view, %{source: "address"})
      calls()
      change(view, %{source: "address", address: @team})

      assert has_element?(view, ~s(#workflow_workflow option[value="0/audit"]), "audit")

      resources =
        for {path, call} <- calls(),
            path in ["read", "read-public"],
            do: {path, call["resource_ref"]}

      assert [_ | _] = resources
      assert Enum.uniq(resources) == [{"read-public", "P_team"}]
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
    @root_stack "modules:\n  - name: core\n    source: {path: modules/core}\n"

    defp words(view, selector) do
      view
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.split()
      |> Enum.join(" ")
    end

    defp change_harness(view) do
      view |> element("#workflow-harness-change") |> render_click()
      view
    end

    test "without a choice: the Qory harness and its pin, with Change and no Update", %{
      conn: conn,
      path: path
    } do
      view = open(conn, path)

      assert has_element?(view, "#workflow-harness", "Harness")
      assert words(view, "#harness-line") == "Qory harness · pinned at fe3b3ab"
      assert has_element?(view, "#workflow-harness-change", "Change")
      refute has_element?(view, "#workflow-harness-form")
      refute render(view) =~ "Update"
    end

    test "Change opens the two choices; the Qory harness saves pinned", %{
      conn: conn,
      path: path,
      scope: scope
    } do
      view = conn |> open(path) |> change_harness()

      assert has_element?(view, "#harness-choice-qory-radio[checked]")

      assert has_element?(view, "#harness-choice-qory .q-choice-h", "Qory harness")

      assert words(view, "#harness-choice-qory .q-choice-p") ==
               "github.com/qoryai/harness · fe3b3ab"

      refute has_element?(view, "#harness-choice-target_file")
      refute has_element?(view, "#harness-choice-qory-file")
      assert has_element?(view, "#harness-choice-repository", "A harness repository")

      view
      |> form("#workflow-harness-form", harness: %{choice: "qory"})
      |> render_submit()

      assert words(view, "#harness-line") == "Qory harness · pinned at fe3b3ab"
      refute has_element?(view, "#workflow-harness-form")
      assert %{choice: :qory} = Stacks.choice(scope.workspace)
      assert has_element?(view, "#workflow-file-first")

      # Cancel closes the choices with nothing saved.
      change_harness(view)
      view |> element("#workflow-harness-cancel") |> render_click()
      refute has_element?(view, "#workflow-harness-form")
    end

    test "a harness repository: a linked repository at a branch, pinned at the commit read", %{
      conn: conn,
      path: path,
      scope: scope,
      adapter: adapter,
      covered: covered,
      linked_id: linked_id
    } do
      files = Map.put(@files, {"R_harness", "qory-stack.yaml"}, @root_stack)
      serve_calls([adapter], covered: covered, files: files, versions: %{"R_harness" => @pin})
      view = conn |> open(path) |> change_harness()

      view
      |> form("#workflow-harness-form", harness: %{choice: "repository"})
      |> render_change()

      assert has_element?(
               view,
               ~s(#harness-source option[value="#{linked_id}"][selected]),
               "acme/harness"
             )

      assert words(view, "#harness-ref-hint") ==
               "Read through the #{Apiary.Adapters.title(adapter.adapter)} connection of " <>
                 "#{scope.organisation.name}."

      view
      |> form("#workflow-harness-form", harness: %{choice: "repository", ref: "v2"})
      |> render_submit()

      render_async(view, 2_000)

      assert words(view, "#harness-line") ==
               "A harness repository · pinned at c3c3c3c code.example.com/acme/harness"

      assert {"R_harness", "qory-stack.yaml", "v2"} in for(
               {"read", call} <- calls(),
               do: {call["resource_ref"], call["path"], call["at"]}
             )

      assert %{choice: :repository} = Stacks.choice(scope.workspace)
    end

    test "a harness repository that cannot be read says why, and the choice stays", %{
      conn: conn,
      path: path,
      scope: scope
    } do
      view = conn |> open(path) |> change_harness()

      view
      |> form("#workflow-harness-form", harness: %{choice: "repository"})
      |> render_change()

      # acme/harness has no root stack.
      view |> form("#workflow-harness-form") |> render_submit()
      render_async(view, 2_000)

      assert words(view, "#workflow-harness-refusal") =~
               "Reload the page to read acme/harness again, or choose another source."

      assert words(view, "#harness-line") == "Qory harness · pinned at fe3b3ab"
      assert Stacks.choice(scope.workspace) == nil
    end

    test "a branch or tag the read finds no version for: correct it, and the choice stays", %{
      conn: conn,
      path: path,
      scope: scope,
      adapter: adapter,
      covered: covered
    } do
      # The read returns c-R_harness, which is no commit.
      files = Map.put(@files, {"R_harness", "qory-stack.yaml"}, @root_stack)
      serve_calls([adapter], covered: covered, files: files)
      view = conn |> open(path) |> change_harness()

      view
      |> form("#workflow-harness-form", harness: %{choice: "repository"})
      |> render_change()

      view
      |> form("#workflow-harness-form", harness: %{choice: "repository", ref: "v9"})
      |> render_submit()

      render_async(view, 2_000)

      assert words(view, "#workflow-harness-refusal") ==
               "Correct the branch or tag, or choose another harness source. Qory Apiary " <>
                 "could not read v9 in acme/harness: its ref is no version of its source."

      assert words(view, "#harness-line") == "Qory harness · pinned at fe3b3ab"
      assert Stacks.choice(scope.workspace) == nil
    end
  end
end
