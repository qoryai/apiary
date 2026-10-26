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
    test "what the page sets and its steps, and in a software workspace the harness file comes first",
         %{conn: conn, path: path, scope: scope} do
      view = open(conn, path)

      assert has_element?(
               view,
               "#workflow-help > p#workflow-what:first-child",
               "#{scope.workspace.name}'s runs follow the workflow you choose here, from a harness repository."
             )

      assert has_element?(view, "#workflow-help li", "Press Save.")

      assert has_element?(
               view,
               "#workflow-help p",
               "The list shows the repositories linked to #{scope.organisation.name} that have a stack"
             )

      assert has_element?(
               view,
               "#workflow-file-first",
               "A repository's harness.yaml or qory.yaml comes first."
             )
    end

    test "a general workspace has no line on the harness file", %{
      conn: conn,
      scope: scope,
      path: path
    } do
      with_domain(scope, "general")
      view = open(conn, path)

      assert has_element?(view, "#workflow-help")
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

      assert has_element?(
               view,
               ~s(#workflow_source optgroup[label="Linked repositories"] option[value="#{linked_id}"]),
               "acme/harness"
             )

      refute render(view) =~ "acme/app"

      assert has_element?(
               view,
               ~s(#workflow_source optgroup[label="Assigned by an instance admin"] option),
               "example-org/team-harness"
             )

      assert has_element?(
               view,
               ~s(#workflow_source optgroup[label="Public address"] option[value="address"])
             )
    end
  end

  describe "Source's groups" do
    test "each shows when it is empty", %{conn: conn, path: path} do
      view = open(conn, path)

      assert has_element?(view, ~s(#workflow_source optgroup[label="Linked repositories"]))

      assert has_element?(
               view,
               ~s(#workflow_source optgroup[label="Assigned by an instance admin"])
             )

      refute has_element?(view, ~s(optgroup[label="Assigned by an instance admin"] option))
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

      assert has_element?(
               view,
               "#workflow-current",
               "Runs of #{scope.workspace.name} follow the workflow triage of #{@harness}."
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

      assert has_element?(view, ~s(#workflow_source option[value="#{linked_id}"][selected]))
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
end
