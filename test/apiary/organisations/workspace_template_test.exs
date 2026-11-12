defmodule Apiary.Organisations.WorkspaceTemplateTest do
  # A workspace made from a template: the Qory template (`create_workspace_of_kind/3`, the
  # first workspace) and a template a source offers (`create_workspace_from_template/3`).
  # Version 1 is the template's process, `process_versions.template` records where it came
  # from, and the harness is saved in the transaction that makes the workspace. A workspace
  # with no template keeps the stack `core`.
  use Apiary.DataCase, async: true

  import Ecto.Query
  import Apiary.HarnessReadsFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Edition, Organisations, Processes, Stacks}
  alias Apiary.Accounts.Scope
  alias Apiary.Artifacts.Type
  alias Apiary.Audit.Entry
  alias Apiary.Harnesses.{Assignment, Qory, Reader}
  alias Apiary.Lingo.Domain
  alias Apiary.QoryHarnessFixture
  alias Apiary.Organisations.Workspace
  alias Apiary.Processes.{TypeTemplates, Version}
  alias Apiary.Stacks.{Sources, Stack}

  @moduletag :capture_log

  @harness "https://code.example.com/acme/harness"
  @other "https://code.example.com/acme/other-harness"
  @commit "0123456789abcdef0123456789abcdef01234567"
  @file_path Path.expand("../../fixtures/harness/v1/sources/factory", __DIR__)
             |> Path.join("modules/support-desk/process.yaml")

  defmodule OneWorkspace do
    def limits, do: %{organisations: :unlimited, workspaces: 1}
  end

  setup do
    :ok = Edition.put_test_stub(Apiary.EditionStubs.ManyWorkspaces)
    :ok
  end

  # The fixture's template, as `Apiary.Stacks.Sources.templates/2` returns it.
  defp template(changes) do
    {:ok, template} = Reader.template(File.read!(@file_path))
    template |> Map.put(:module, "support-desk") |> Map.merge(changes)
  end

  defp source(kind, id, changes \\ %{}) do
    Map.merge(
      %{
        id: id,
        kind: kind,
        label: "acme/harness",
        git: @harness,
        ref: "HEAD",
        narrowing: %{},
        location: nil,
        version: nil,
        stacks: nil
      },
      changes
    )
  end

  # A connected repository of the organisation, as `Sources.repositories/1` lists it.
  defp linked!(scope) do
    adapter = call_adapter_fixture()
    {connection, _nonce} = connection_fixture(scope, adapter.adapter, :listed)
    harness_collection_fixture(connection, @harness, "acme/harness")
    [source] = Sources.repositories(scope)
    source
  end

  # An assignment of `source` to the organisation, as `Sources.assigned/1` lists it.
  defp assigned!(scope, source) do
    Repo.insert!(%Assignment{
      organisation_id: scope.organisation.id,
      every_organisation: false,
      source: source,
      created_by_id: instance_admin_scope().user.id
    })

    [listed] = Sources.assigned(scope)
    listed
  end

  defp start(source, changes \\ %{}, commit \\ @commit),
    do: %{source: source, commit: commit, template: template(changes)}

  # The organisation shares the harness at `git`, stack `triage`, on the branch `main`.
  defp share!(%Scope{organisation: organisation} = scope, git \\ @harness) do
    document = ~s(extends:\n  git: "#{git}"\n  ref: "main"\n  stack: "triage"\n)

    {:ok, row} =
      Stacks.put_stack(scope, {:organisation, organisation}, document,
        choice: :repository,
        version: {:branch, "main"}
      )

    row
  end

  # The organisation shares the Qory harness on the branch `main`, at `stack`.
  defp share_qory!(%Scope{organisation: organisation} = scope, stack) do
    document = ~s(extends:\n  git: "#{Qory.git()}"\n  ref: "main"\n  stack: "#{stack}"\n)

    {:ok, _row} =
      Stacks.put_stack(scope, {:organisation, organisation}, document,
        choice: :qory,
        version: {:branch, "main"}
      )
  end

  # The actions of the organisation's trail, oldest first, as `Audit.list_entries` orders it.
  defp trail(%Scope{organisation: %{id: id}}) do
    from e in Entry,
      where: e.organisation_id == ^id,
      order_by: [asc: e.inserted_at, asc: e.id],
      select: e.action
  end

  # What the organisation has, to compare before and after a create that fails.
  defp held(%Scope{organisation: %{id: id}}) do
    %{
      workspaces: Repo.aggregate(from(w in Workspace, where: w.organisation_id == ^id), :count),
      versions: Repo.aggregate(from(v in Version, where: v.organisation_id == ^id), :count),
      stacks: Repo.aggregate(from(s in Stack, where: s.organisation_id == ^id), :count),
      types: Repo.aggregate(from(t in Type, where: t.organisation_id == ^id), :count)
    }
  end

  defp first_version(workspace) do
    assert [%Version{number: 1, status: :current} = version] = Processes.list_versions(workspace)

    version
  end

  # A row's base.
  defp base(%Stack{harness: harness}) do
    {:ok, %{"extends" => base}} = Reader.document(harness)
    base
  end

  describe "the Qory template" do
    test "create_workspace_of_kind/3 records the stack and the template, in one version" do
      scope = scope_fixture()

      assert {:ok, workspace} =
               Organisations.create_workspace_of_kind(scope, Domain.Software, :any)

      assert workspace.qory_stack == "software"
      assert Repo.reload!(workspace).qory_stack == "software"
      assert Workspace.qory_stack(workspace) == "software"

      newest = TypeTemplates.newest("qory.software")
      version = first_version(workspace)
      assert version.document == newest.document
      assert version.author_id == nil

      assert version.template == %{
               "source" => "qory",
               "git" => Qory.git(),
               "commit" => QoryHarnessFixture.commit(),
               "module" => "software-factory",
               "stack" => "software",
               "type" => "qory.software",
               "version" => newest.number
             }

      assert version.template["type"] == Qory.template(Qory.current()).type
      assert version.template["type"] == workspace.type

      assert Stacks.choice(workspace) == nil
    end

    test "create_workspace_of_kind/3 reads main's commit then, and copies its template" do
      scope = scope_fixture()
      repository = QoryHarnessFixture.serve!(QoryHarnessFixture.explore_named("Discover"))

      assert {:ok, workspace} =
               Organisations.create_workspace_of_kind(scope, Domain.Software, :any)

      version = first_version(workspace)
      assert version.template["commit"] == repository.commit
      assert Processes.stage(version, "st_r79kph11eg")["name"] == "Discover"
      assert Qory.current() == repository.commit
    end

    test "a failed read of the Qory harness makes nothing" do
      scope = scope_fixture()
      before = held(scope)
      Apiary.PublicGitServer.serve(%{}, answer: &Plug.Conn.send_resp(&1, 503, ""))

      assert {:error, {:qory, {:unreadable, {:unreachable, _seconds}, {"github.com", 443}}}} =
               Organisations.create_workspace_of_kind(scope, Domain.Software, :any)

      assert held(scope) == before
    end

    test "the first workspace of a sign-up takes the Qory template" do
      %{workspace: workspace} = sign_up_fixture()

      assert workspace.qory_stack == "software"
      assert %{"source" => "qory", "stack" => "software"} = first_version(workspace).template
      assert Stacks.choice(workspace) == nil
      assert %{choice: :qory, stack: "software", saved: false} = Sources.chosen(workspace)
    end

    test "the first workspace of an organisation made with none takes the Qory template" do
      for create <- [
            &Organisations.create_first_workspace(&1, %{"domain" => "software"}),
            &Organisations.create_workspace_of_kind(&1, Domain.Software, :first)
          ] do
        {:ok, %{user: user}} =
          Apiary.AccountsFixtures.valid_user_attributes()
          |> Organisations.sign_up_user(nil, open: true, workspace: false)

        scope = Organisations.load_scope(Scope.for_user(user))

        assert {:ok, %Workspace{qory_stack: "software"} = workspace} = create.(scope)
        assert %{"source" => "qory", "stack" => "software"} = first_version(workspace).template
      end
    end

    test "the organisation's shared harness: a row of the Qory harness at the template's stack" do
      scope = scope_fixture()
      share!(scope)

      assert {:ok, workspace} =
               Organisations.create_workspace_of_kind(scope, Domain.Software, :any)

      row = Stacks.choice(workspace)
      assert %Stack{choice: :qory, version_kind: :branch, version_name: "main"} = row
      assert row.owner_organisation_id == scope.organisation.id
      assert base(row)["stack"] == "software"

      assert %{choice: :qory, stack: "software", version: {:branch, "main"}, shared: false} =
               Sources.chosen(workspace)
    end

    test "a shared Qory harness at another stack is another harness: a row" do
      scope = scope_fixture()
      share_qory!(scope, "core")

      assert {:ok, workspace} =
               Organisations.create_workspace_of_kind(scope, Domain.Software, :any)

      assert %{choice: :qory, stack: "software", shared: false} = Sources.chosen(workspace)
    end

    test "a shared Qory harness at the template's stack: no row" do
      scope = scope_fixture()
      share_qory!(scope, "software")

      assert {:ok, workspace} =
               Organisations.create_workspace_of_kind(scope, Domain.Software, :any)

      assert Stacks.choice(workspace) == nil
      assert %{choice: :qory, stack: "software", shared: true} = Sources.chosen(workspace)
    end
  end

  describe "a workspace with no template" do
    test "keeps core: no stack recorded, and the template record as before" do
      scope = scope_fixture()

      assert {:ok, workspace} =
               Organisations.create_workspace(scope, %{"name" => "Data", "domain" => "software"})

      assert workspace.qory_stack == nil
      assert Workspace.qory_stack(workspace) == "core"
      assert %{stack: "core", choice: :qory} = Sources.chosen(workspace)

      assert first_version(workspace).template == %{
               "type" => "qory.software",
               "version" => TypeTemplates.newest("qory.software").number
             }
    end

    test "one made before the column keeps core, and gets its version on first read" do
      %{organisation: organisation} = sign_up_fixture()
      workspace = workspace_fixture(organisation)

      assert Workspace.qory_stack(workspace) == "core"
      assert %{stack: "core"} = Sources.chosen(workspace)
      assert Map.keys(Processes.current(workspace).template) == ["type", "version"]
    end
  end

  describe "a template of a source" do
    @describetag needs: :factory

    test "a connected repository, read through its adapter: the template's process, its stack and the commit the list read" do
      scope = scope_fixture()
      adapter = call_adapter_fixture()
      {connection, _nonce} = connection_fixture(scope, adapter.adapter, :listed)
      live_grant_fixture(scope.organisation.id, adapter.adapter, connection, "G_acme")
      harness_collection_fixture(connection, @harness, "acme/harness")

      serve_calls([adapter],
        covered: %{adapter.adapter.id => %{@harness => {"G_acme", "R_harness"}}},
        versions: %{"R_harness" => @commit},
        files: %{
          {"R_harness", "qory.yaml"} =>
            "exports:\n  stacks: [support]\n  modules: [support-desk]\n",
          {"R_harness", "modules/support-desk/process.yaml"} => File.read!(@file_path)
        }
      )

      [source] = Sources.repositories(scope)
      assert {:ok, %{commit: @commit, templates: [read]}} = Sources.templates(scope, source)

      assert {:ok, workspace} =
               Organisations.create_workspace_from_template(scope, %{
                 source: source,
                 commit: @commit,
                 template: read
               })

      assert workspace.name == "Support desk"
      assert workspace.qory_stack == nil
      assert workspace.domain == "software"
      assert workspace.type == "qory.software"

      version = first_version(workspace)
      assert version.document == read.process
      assert version.author_id == scope.user.id

      assert version.template == %{
               "source" => "repository",
               "git" => @harness,
               "commit" => @commit,
               "module" => "support-desk",
               "stack" => "support",
               "type" => read.type,
               "version" => nil
             }

      assert read.type == workspace.type

      row = Stacks.choice(workspace)
      assert %Stack{choice: :repository, version_kind: nil} = row
      assert base(row) == %{"git" => @harness, "ref" => @commit, "stack" => "support"}
      assert row.owner_organisation_id == scope.organisation.id

      assert %{
               choice: :repository,
               git: @harness,
               stack: "support",
               pin: @commit,
               saved: true,
               shared: false
             } = Sources.chosen(workspace)
    end

    test "a commit an adapter gives that is no full id is recorded as given" do
      scope = scope_fixture()
      commit = "c-R_harness"
      source = linked!(scope)

      assert {:ok, workspace} =
               Organisations.create_workspace_from_template(scope, start(source, %{}, commit))

      assert first_version(workspace).template["commit"] == commit
      assert base(Stacks.choice(workspace))["ref"] == commit
    end

    test "an assigned source keeps the assignment's ref for reads and records the commit apart" do
      scope = scope_fixture()
      source = assigned!(scope, %{"git" => @harness, "ref" => "v1"})
      assert %{kind: :assigned, ref: "v1"} = source

      assert {:ok, workspace} =
               Organisations.create_workspace_from_template(scope, start(source))

      assert base(Stacks.choice(workspace))["ref"] == "v1"
      assert %{pin: "v1", stack: "support"} = Sources.chosen(workspace)

      template = first_version(workspace).template
      assert template["commit"] == @commit
      assert template["type"] == "qory.software"
    end

    test "the shared harness: a row at the template's stack and the commit the list read" do
      scope = scope_fixture()
      share!(scope)
      source = source(:shared, "shared", %{ref: "main"})

      assert {:ok, workspace} =
               Organisations.create_workspace_from_template(scope, start(source))

      row = Stacks.choice(workspace)
      assert base(row) == %{"git" => @harness, "ref" => @commit, "stack" => "support"}
      assert row.owner_organisation_id == scope.organisation.id

      template = first_version(workspace).template
      assert template["git"] == @harness
      assert template["type"] == "qory.software"

      assert {:chosen, %{harness_hidden: false}} =
               Stacks.chosen_for(scope.organisation, workspace, nil, "triage")
    end

    test "a shared harness that runs hide stays hidden, with no address in the record" do
      scope = scope_fixture()
      shared = share!(scope)
      owner = Edition.instance_organisation_id()
      refute owner == scope.organisation.id

      {1, _rows} =
        Repo.update_all(from(s in Stack, where: s.id == ^shared.id),
          set: [owner_organisation_id: owner]
        )

      source = source(:shared, "shared", %{ref: "main"})

      assert {:ok, workspace} =
               Organisations.create_workspace_from_template(scope, start(source))

      assert Stacks.choice(workspace).owner_organisation_id == owner

      assert {:chosen, %{harness_hidden: true}} =
               Stacks.chosen_for(scope.organisation, workspace, nil, "triage")

      assert %{"git" => nil, "commit" => @commit, "stack" => "support"} =
               first_version(workspace).template
    end

    test "a template's page key is the source and the module" do
      assert Sources.template_key(source(:linked, "linked:cl_1"), "a.b") == "cl_1.a.b"
      assert Sources.template_key(source(:assigned, "assigned:u1"), "a.b") == "assigned-u1.a.b"
      assert Sources.template_key(source(:shared, "shared"), "a.b") == "shared.a.b"
    end

    test "the domain is the one whose type is the template's: its type, rules and record" do
      scope = scope_fixture()
      source = linked!(scope)

      assert {:ok, workspace} =
               Organisations.create_workspace_from_template(
                 scope,
                 start(source, %{type: "qory.example"})
               )

      assert %Workspace{domain: "example", type: "qory.example"} = Repo.reload!(workspace)
      assert Domain.for_workspace(workspace) == Domain.Example
      assert first_version(workspace).template["type"] == "qory.example"

      assert Domain.target_labels(workspace) == ["platform", "account"]
      assert Domain.target_required?(workspace) == false
      assert Domain.check_target(workspace, nil) == :ok

      # A path with no owner: the example domain takes it, and the software domain does not.
      target = %{system: "desk.example.com", path: "account-1"}
      assert Domain.check_target(workspace, target) == :ok
      assert Domain.Software.check_target(target) == {:error, :target_invalid}
    end

    test "the name is the template's, numbered where it is taken" do
      scope = scope_fixture()
      source = linked!(scope)

      {:ok, first} = Organisations.create_workspace_from_template(scope, start(source))
      {:ok, second} = Organisations.create_workspace_from_template(scope, start(source))

      assert {first.name, second.name} == {"Support desk", "Support desk 2"}
    end

    test ":first refuses an organisation with a workspace" do
      scope = scope_fixture()

      assert Organisations.create_workspace_from_template(
               scope,
               start(linked!(scope)),
               :first
             ) == {:error, :exists}
    end

    test "a member, and an admin, may not create one" do
      scope = scope_fixture()
      before = held(scope)
      source = linked!(scope)

      for level <- [:member, :admin] do
        assert Organisations.create_workspace_from_template(
                 member_fixture(scope, level).scope,
                 start(source)
               ) == {:error, :forbidden}
      end

      assert held(scope) == before
    end

    test "a typed address and a narrowed source offer no template" do
      scope = scope_fixture()
      before = held(scope)

      narrowed = assigned!(scope, %{"git" => @harness, "ref" => "v1", "path" => "stacks/web"})

      for source <- [source(:address, "address"), narrowed] do
        assert Organisations.create_workspace_from_template(scope, start(source)) ==
                 {:error, :invalid}
      end

      assert held(scope) == before
    end

    test "a stage's description in the template reaches version 1; one over 500 characters is refused" do
      scope = scope_fixture()
      source = linked!(scope)

      file =
        @file_path
        |> File.read!()
        |> String.replace(
          "      name: Answer\n",
          "      name: Answer\n      description: \"Draft an answer.\\nCheck its tone.\"\n"
        )

      {:ok, %{process: process}} = Reader.template(file)
      assert [%{"description" => "Draft an answer.\nCheck its tone."}, check] = process["stages"]
      refute Map.has_key?(check, "description")

      assert {:ok, workspace} =
               Organisations.create_workspace_from_template(
                 scope,
                 start(source, %{process: process})
               )

      assert first_version(workspace).document == process

      before = held(scope)

      long =
        Map.update!(process, "stages", fn [answer, check] ->
          [Map.put(answer, "description", String.duplicate("a", 501)), check]
        end)

      assert {:error, errors} =
               Organisations.create_workspace_from_template(
                 scope,
                 start(source, %{process: long})
               )

      assert %{path: "#/stages/0/description", error: :schema, detail: :maxLength} in errors

      assert held(scope) == before
    end

    test "a template's stage description keeps its line breaks as LF, from CRLF and a lone CR" do
      scope = scope_fixture()
      source = linked!(scope)

      file =
        @file_path
        |> File.read!()
        |> String.replace(
          "      name: Answer\n",
          "      name: Answer\n      description: \"Draft an answer.\\r\\nCheck its tone.\\rSend it.\"\n"
        )

      {:ok, %{process: process}} = Reader.template(file)

      assert [%{"description" => "Draft an answer.\nCheck its tone.\nSend it."}, _check] =
               process["stages"]

      assert {:ok, workspace} =
               Organisations.create_workspace_from_template(
                 scope,
                 start(source, %{process: process})
               )

      assert [%{"description" => "Draft an answer.\nCheck its tone.\nSend it."}, _check] =
               first_version(workspace).document["stages"]
    end

    test "a process that does not pass the check is refused before the transaction" do
      scope = scope_fixture()
      before = held(scope)
      source = linked!(scope)

      assert {:error, [_error | _more]} =
               Organisations.create_workspace_from_template(
                 scope,
                 start(source, %{process: %{"schema" => "qory.process/v1", "stages" => [%{}]}})
               )

      assert held(scope) == before
    end

    test "a template's custom type and shown standard types reach the workspace" do
      scope = scope_fixture()
      adapter = call_adapter_fixture()
      {connection, _nonce} = connection_fixture(scope, adapter.adapter, :listed)
      live_grant_fixture(scope.organisation.id, adapter.adapter, connection, "G_acme")
      harness_collection_fixture(connection, @harness, "acme/harness")

      # A stage outputs the custom type, as a template read from a file has it.
      file =
        File.read!(@file_path)
        |> String.replace(
          "      name: Check\n",
          "      name: Check\n      outputs:\n        - {type: reply-draft, required: true}\n"
        )

      file =
        file <>
          """
          artifact_types:
            - name: mockup
            - name: proposal
            - {name: reply-draft, base_view: document, size_limit: 65536, max_files: 1}
          """

      serve_calls([adapter],
        covered: %{adapter.adapter.id => %{@harness => {"G_acme", "R_harness"}}},
        versions: %{"R_harness" => @commit},
        files: %{
          {"R_harness", "qory.yaml"} =>
            "exports:\n  stacks: [support]\n  modules: [support-desk]\n",
          {"R_harness", "modules/support-desk/process.yaml"} => file
        }
      )

      [source] = Sources.repositories(scope)
      assert {:ok, %{commit: @commit, templates: [read]}} = Sources.templates(scope, source)

      assert {:ok, workspace} =
               Organisations.create_workspace_from_template(scope, %{
                 source: source,
                 commit: @commit,
                 template: read
               })

      assert workspace.shown_standard_types == ["mockup"]
      assert Repo.reload!(workspace).shown_standard_types == ["mockup"]

      assert [%Type{name: "reply-draft", standard: false, base_view: :document}] =
               Repo.all(from t in Type, where: t.workspace_id == ^workspace.id)

      assert [%{"outputs" => [%{"type" => "reply-draft"}]}] =
               Enum.filter(first_version(workspace).document["stages"], & &1["outputs"])
    end

    test "a template with no list of types writes no type" do
      scope = scope_fixture()

      assert {:ok, %Workspace{shown_standard_types: nil} = workspace} =
               Organisations.create_workspace_from_template(
                 scope,
                 start(linked!(scope))
               )

      assert Repo.all(from t in Type, where: t.workspace_id == ^workspace.id) == []
    end

    test "the workspace's entry comes before the entries of the template's types" do
      scope = scope_fixture()
      type = %{"name" => "reply-draft", "base_view" => "document"}
      type = Map.merge(type, %{"size_limit" => 65_536, "max_files" => 1})
      source = linked!(scope)
      before = Repo.all(trail(scope))

      assert {:ok, _workspace} =
               Organisations.create_workspace_from_template(
                 scope,
                 start(source, %{artifact_types: [type]})
               )

      assert ["workspace.create", "artifact_type.edit", "security_policy.edit"] =
               Enum.drop(Repo.all(trail(scope)), length(before))
    end

    test "a failed insert of a template's type rolls the workspace back" do
      scope = scope_fixture()
      source = linked!(scope)
      before = held(scope)

      entries = fn ->
        Repo.aggregate(
          from(e in Entry, where: e.organisation_id == ^scope.organisation.id),
          :count
        )
      end

      entries_before = entries.()
      :ok = Organisations.subscribe_workspaces(scope)
      type = %{"name" => "reply-draft", "base_view" => "document"}
      type = Map.merge(type, %{"size_limit" => 65_536, "max_files" => 1})

      assert Organisations.create_workspace_from_template(
               scope,
               start(source, %{artifact_types: [type, type]})
             ) == {:error, {:invalid, "reply-draft", :repeated}}

      assert held(scope) == before
      assert entries.() == entries_before
      refute_received {:workspace_created, _ids}
    end

    test "a connected source that differs from its entry is refused, and nothing is made" do
      scope = scope_fixture()
      source = linked!(scope)
      before = held(scope)

      for forged <- [
            %{source | id: "linked:cl_0"},
            %{source | git: "https://code.example.com/acme/other"},
            %{source | ref: "v9"},
            %{source | narrowing: %{"stack" => "web"}}
          ] do
        assert Organisations.create_workspace_from_template(scope, start(forged)) ==
                 {:error, :invalid}
      end

      assert held(scope) == before
    end

    test "an assigned source that differs from its entry is refused, and nothing is made" do
      scope = scope_fixture()
      source = assigned!(scope, %{"git" => @harness, "ref" => "v1"})
      before = held(scope)

      for forged <- [
            %{source | id: "assigned:" <> Ecto.UUID.generate()},
            %{source | git: "https://code.example.com/acme/other"},
            %{source | ref: "v9"},
            %{source | narrowing: %{"stack" => "web"}}
          ] do
        assert Organisations.create_workspace_from_template(scope, start(forged)) ==
                 {:error, :invalid}
      end

      assert held(scope) == before
    end

    test "a source of no list is refused: an assignment or a repository that does not exist" do
      scope = scope_fixture()
      before = held(scope)

      for forged <- [
            source(:assigned, "assigned:" <> Ecto.UUID.generate(), %{ref: "v9"}),
            source(:linked, "linked:cl_0")
          ] do
        assert Organisations.create_workspace_from_template(scope, start(forged)) ==
                 {:error, :invalid}
      end

      assert held(scope) == before
    end

    test "a template of a type that is no domain's is refused, and nothing is made" do
      scope = scope_fixture()
      sources = [linked!(scope), assigned!(scope, %{"git" => @harness, "ref" => "v1"})]
      before = held(scope)
      :ok = Organisations.subscribe_workspaces(scope)

      for source <- sources do
        assert Organisations.create_workspace_from_template(
                 scope,
                 start(source, %{type: "customer-care"})
               ) == {:error, :invalid}
      end

      assert held(scope) == before
      refute_received {:workspace_created, _ids}
    end

    test "a create that fails after the workspace row leaves nothing" do
      scope = scope_fixture()
      refused = assigned!(scope, %{"git" => "http://code.example.com/acme", "ref" => "v1"})
      before = held(scope)
      entries = Repo.all(trail(scope))
      :ok = Organisations.subscribe_workspaces(scope)

      # A row the save rules refuse, and a shared harness gone since the page read it.
      assert Organisations.create_workspace_from_template(scope, start(refused)) ==
               {:error, :invalid}

      assert Organisations.create_workspace_from_template(
               scope,
               start(source(:shared, "shared"))
             ) == {:error, :not_found}

      assert held(scope) == before
      assert Repo.all(trail(scope)) == entries
      refute_received {:workspace_created, _ids}
    end

    test "a shared harness replaced since the page read it is refused" do
      scope = scope_fixture()
      share!(scope, @other)
      before = held(scope)

      assert Organisations.create_workspace_from_template(
               scope,
               start(source(:shared, "shared"))
             ) == {:error, :not_found}

      assert held(scope) == before
    end

    test "an organisation at the edition's limit: nothing is made" do
      scope = scope_fixture()
      :ok = Edition.put_test_stub(OneWorkspace)
      source = linked!(scope)
      before = held(scope)

      assert Organisations.create_workspace_from_template(scope, start(source)) ==
               {:error, :limit}

      assert held(scope) == before
    end
  end

  test "the Qory harness's template is what the first workspace records" do
    assert %{stack: "software", type: "qory.software"} = Qory.template(Qory.current())
    assert Qory.template_module() == "software-factory"
    assert Qory.default_stack() == "core"
  end
end

defmodule Apiary.Organisations.WorkspaceTemplateFeaturesTest do
  # `create_workspace_of_kind/3` and `create_workspace_from_template/3` with the feature
  # `factory` off: the Qory template is made, and a source's template is not found.
  use Apiary.DataCase

  import Ecto.Query
  import Apiary.AccountsFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Edition, Organisations}
  alias Apiary.Accounts.{Scope, User}
  alias Apiary.Artifacts.Type
  alias Apiary.Audit.Entry
  alias Apiary.Harnesses.{Qory, Reader}
  alias Apiary.Lingo.Domain
  alias Apiary.Organisations.Workspace
  alias Apiary.Processes
  alias Apiary.Processes.Version

  @moduletag with_features: [:observability]

  @file_path Path.expand("../../fixtures/harness/v1/sources/factory", __DIR__)
             |> Path.join("modules/support-desk/process.yaml")

  setup do
    :ok = Edition.put_test_stub(Apiary.EditionStubs.ManyWorkspaces)
    :ok
  end

  test "the Qory template makes the workspace" do
    scope = scope_fixture()

    assert {:ok, %Workspace{qory_stack: "software"} = workspace} =
             Organisations.create_workspace_of_kind(scope, Domain.Software, :any)

    assert [%Version{template: %{"source" => "qory"}}] = Processes.list_versions(workspace)
  end

  # The actions of the organisation's trail, oldest first, as `Audit.list_entries` orders it.
  defp actions(%{organisation: %{id: id}}) do
    Repo.all(
      from e in Entry,
        where: e.organisation_id == ^id,
        order_by: [asc: e.inserted_at, asc: e.id],
        select: e.action
    )
  end

  defp actions_since(scope, before), do: Enum.drop(actions(scope), length(before))

  describe "the Qory template's artifact types" do
    @standard ~w(acceptance-criteria explainer decision-record mockup screenshot demo-video change)

    test "the copy lists types, and create_workspace_of_kind/3 gives the workspace them" do
      scope = scope_fixture()
      assert [_type | _more] = Qory.template(Qory.current()).artifact_types
      before = actions(scope)

      assert {:ok, %Workspace{shown_standard_types: @standard} = workspace} =
               Organisations.create_workspace_of_kind(scope, Domain.Software, :any)

      assert [%Type{name: "branch", standard: false, base_view: :structured}] =
               Repo.all(from t in Type, where: t.workspace_id == ^workspace.id)

      assert ["workspace.create", "artifact_type.edit", "security_policy.edit"] =
               actions_since(scope, before)
    end

    test "a sign-up's first workspace gets them, after the entry that begins the trail" do
      user = User.email_changeset(%User{}, %{email: unique_user_email()})

      scope = fn %{user: user, organisation: organisation, workspace: workspace} ->
        %Scope{user: user, organisation: organisation, workspace: workspace}
      end

      assert {:ok, %{created: %{workspace: workspace}}} =
               Ecto.Multi.new()
               |> Ecto.Multi.insert(:user, user)
               |> Organisations.build_organisation(
                 name: "Acme Types",
                 how: {:kind, :organisation},
                 scope: scope
               )
               |> Repo.transaction()

      assert workspace.shown_standard_types == @standard

      assert [%Type{name: "branch"}] =
               Repo.all(from t in Type, where: t.workspace_id == ^workspace.id)

      assert Repo.all(
               from e in Entry,
                 where: e.organisation_id == ^workspace.organisation_id,
                 order_by: [asc: e.inserted_at, asc: e.id],
                 select: e.action
             ) == ["organisation.create", "artifact_type.edit", "security_policy.edit"]
    end
  end

  test "a source's template is not found, and nothing is made" do
    scope = scope_fixture()
    {:ok, template} = Reader.template(File.read!(@file_path))
    template = Map.put(template, :module, "support-desk")

    count = fn ->
      Repo.aggregate(
        from(w in Workspace, where: w.organisation_id == ^scope.organisation.id),
        :count
      )
    end

    before = count.()

    for {kind, id} <- [linked: "linked:cl_0", assigned: "assigned:u1", shared: "shared"] do
      source = %{
        id: id,
        kind: kind,
        label: "acme/harness",
        git: "https://code.example.com/acme/harness",
        ref: "HEAD",
        narrowing: %{},
        location: nil,
        version: nil,
        stacks: nil
      }

      assert Organisations.create_workspace_from_template(scope, %{
               source: source,
               commit: String.duplicate("a", 40),
               template: template
             }) == {:error, :not_found}
    end

    assert count.() == before
  end
end
