defmodule Apiary.ConnectionsTest do
  use Apiary.DataCase, async: true

  import Apiary.ConnectionsFixtures
  import Apiary.DescriptionFixtures
  import Apiary.OrganisationsFixtures
  import ExUnit.CaptureLog

  alias Apiary.Accounts.Scope
  alias Apiary.Audit.Entry
  alias Apiary.{Connections, Deletion}
  alias Apiary.Connections.{Connection, ConnectionWorkspace, ServiceDefinition}
  alias Apiary.Organisations.Workspace

  @moduletag needs: :secrets

  setup do
    owner = sign_up_fixture()
    %{scope: owner.scope}
  end

  defp status_definition(overrides \\ %{}) do
    Map.merge(
      %{
        "version" => 1,
        "key" => "status-api",
        "title" => "Status API",
        "hosts" => ["status.example.com"],
        "auth" => %{"scheme" => "bearer", "secret" => "key"},
        "declares" => [%{"id" => "key", "title" => "API key", "name" => "STATUS_API_KEY"}]
      },
      overrides
    )
  end

  defp trail(subject_id),
    do:
      Repo.all(
        from e in Entry,
          where: e.subject_id == ^subject_id,
          order_by: [asc: e.inserted_at, asc: e.id]
      )

  describe "a runtime" do
    test "is set up from the catalogue, for every workspace", %{scope: scope} do
      assert {:ok,
              %Connection{kind: "runtime", name: "claude", applies_to: "all", intact: true} =
                connection} =
               Connections.create_runtime(scope, %{runtime: "claude"})

      assert connection.public_id =~ ~r/\Acon_[0-9a-hjkmnp-tv-z]{16}\z/
      assert connection.settings == "{}"

      assert Connections.create_runtime(scope, %{runtime: "nothing"}) ==
               {:error, :runtime_unknown}
    end

    test "is one per runtime where two would apply to a workspace alike", %{scope: scope} do
      main = scope.workspace
      site = workspace!(scope, "Site")

      {:ok, first} =
        Connections.create_runtime(scope, %{
          runtime: "claude",
          applies_to: "selected",
          workspace_ids: [main.id]
        })

      assert {:ok, _} =
               Connections.create_runtime(scope, %{
                 runtime: "claude",
                 applies_to: "selected",
                 workspace_ids: [site.id]
               })

      assert {:error, {:overlap, [_ | _] = ids}} =
               Connections.create_runtime(scope, %{runtime: "claude"})

      assert first.public_id in ids

      assert {:error, {:overlap, [id]}} =
               Connections.create_runtime(scope, %{
                 runtime: "claude",
                 applies_to: "selected",
                 workspace_ids: [main.id]
               })

      assert id == first.public_id
    end

    test "applies to a workspace of its organisation", %{scope: scope} do
      site = workspace!(scope, "Site")
      {:ok, runtime} = Connections.create_runtime(scope, %{runtime: "claude"})

      assert {:ok, runtime} = Connections.put_workspace(scope, runtime, site.id)
      assert [%ConnectionWorkspace{workspace_id: workspace_id}] = runtime.workspaces
      assert workspace_id == site.id
    end
  end

  describe "an integration" do
    setup %{scope: scope} do
      %{release: ready_release!(scope, github_description())}
    end

    test "is added from a ready release, with its plain settings and argument",
         %{scope: scope, release: release} do
      assert {:ok, %Connection{} = connection} =
               Connections.create_integration(scope, release.id, %{
                 settings: %{"app_id" => "123456"},
                 argument: "acme/shop"
               })

      assert connection.kind == "integration"
      assert connection.name == "github"
      assert connection.source == "github.com/qoryai/qory-github"
      assert connection.forge_kind == "github"
      assert connection.version == "0.1.0"
      assert connection.description_sha256 == release.description_sha256
      assert Connection.settings_map(connection) == %{"app_id" => "123456"}
      assert connection.argument == "acme/shop"
      assert connection.intact

      assert {:ok, %{name: "github", roles: ["credential"]}} =
               Connections.description(connection)
    end

    test "never stores a secret, a secret's _file, or a setting its description does not have",
         %{scope: scope, release: release} do
      assert Connections.create_integration(scope, release.id, %{
               settings: %{"private_key_file" => "/etc/key.pem"}
             }) ==
               {:error, {:integration_settings_not_allowed, ["private_key_file"]}}

      assert Connections.create_integration(scope, release.id, %{
               settings: %{"private_key" => "-----BEGIN"}
             }) ==
               {:error, {:integration_settings_not_allowed, ["private_key"]}}

      assert Connections.create_integration(scope, release.id, %{
               settings: %{"region" => "eu"}
             }) ==
               {:error, {:integration_settings_not_allowed, ["region"]}}

      assert {:error, {:integration_settings_invalid, _}} =
               Connections.create_integration(scope, release.id, %{
                 settings: %{"app_id" => "no id"}
               })

      assert Repo.aggregate(Connection, :count) == 0
    end

    test "refuses an argument its credential role does not match", %{
      scope: scope,
      release: release
    } do
      assert Connections.create_integration(scope, release.id, %{argument: "acme"}) ==
               {:error, {:integration_argument_not_allowed, ["credential"]}}
    end

    test "is added from a ready release only", %{scope: scope} do
      {:ok, pending} =
        Apiary.Integrations.request_release(scope, %{
          source: "github.com/acme/other",
          version: "1.0.0"
        })

      assert Connections.create_integration(scope, pending.id, %{}) ==
               {:error, :release_not_ready}

      assert Connections.create_integration(scope, Ecto.UUID.generate(), %{}) ==
               {:error, :release_not_ready}
    end

    test "is added with every top-level plain setting, its description's other roles as they are",
         %{scope: scope} do
      tracker = ready_release!(scope, tracker_description(), "github.com/acme/tracker")

      {:ok, connection} =
        Connections.create_integration(scope, tracker.id, %{
          settings: %{"url" => "https://tracker.example.com"}
        })

      assert {:ok, %{roles: ["acme_role", "credential"]}} = Connections.description(connection)
      assert Connection.settings_map(connection) == %{"url" => "https://tracker.example.com"}

      assert {:ok, connection} = Connections.put_workspace(scope, connection, scope.workspace.id)
      assert [%ConnectionWorkspace{}] = connection.workspaces
    end

    test "is one per name where two would apply to a workspace alike", %{
      scope: scope,
      release: release
    } do
      {:ok, first} = Connections.create_integration(scope, release.id, %{})
      other = ready_release!(scope, github_description(), "github.com/acme/hub")

      assert Connections.create_integration(scope, other.id, %{}) ==
               {:error, {:overlap, [first.public_id]}}
    end

    test "moves to another release of its source, and of nothing else",
         %{scope: scope, release: release} do
      {:ok, connection} =
        Connections.create_integration(scope, release.id, %{settings: %{"app_id" => "1"}})

      newer = ready_release!(scope, github_description(%{"program_version" => "0.2.0"}))

      assert {:ok, %Connection{version: "0.2.0", intact: true}} =
               Connections.change_release(scope, connection, newer.id)

      renamed =
        ready_release!(
          scope,
          github_description(%{"name" => "hub", "program_version" => "0.3.0"})
        )

      assert Connections.change_release(scope, connection, renamed.id) ==
               {:error, {:integration_source_mismatch, :name}}

      elsewhere = ready_release!(scope, github_description(), "github.com/acme/qory-github")

      assert Connections.change_release(scope, connection, elsewhere.id) ==
               {:error, {:integration_source_mismatch, :source}}
    end

    test "changes its settings and argument, checked again, each change in the trail",
         %{scope: scope, release: release} do
      {:ok, connection} = Connections.create_integration(scope, release.id, %{})

      assert {:ok, updated} =
               Connections.update_connection(scope, connection, %{
                 settings: %{"app_id" => "42"},
                 argument: "acme/site"
               })

      assert Connection.settings_map(updated) == %{"app_id" => "42"}
      assert updated.intact

      assert {:error, {:integration_settings_not_allowed, _}} =
               Connections.update_connection(scope, updated, %{settings: %{"private_key" => "x"}})

      assert {:error, {:integration_argument_not_allowed, _}} =
               Connections.update_connection(scope, updated, %{argument: "nope"})

      assert {:ok, unchanged} =
               Connections.update_connection(scope, updated, %{argument: "acme/site"})

      assert unchanged.updated_at == updated.updated_at

      changes = for e <- trail(connection.id), do: e.details["change"]
      assert changes == ["created", "updated"]
    end
  end

  describe "a service" do
    test "its name is refused with a control character or a bidirectional control",
         %{scope: scope} do
      for cp <- [0x1B, 0x9F, 0x202D, 0x2066, 0x200F] do
        name = "Sentry#{<<cp::utf8>>}EU"

        assert {:error, %Ecto.Changeset{} = changeset} =
                 Connections.create_service(scope, %{service: "sentry", name: name})

        assert errors_on(changeset) == %{name: ["must not contain control characters"]}
      end

      name = "Sentry 👩#{<<0x200D::utf8>>}💻"

      assert {:ok, %Connection{name: ^name}} =
               Connections.create_service(scope, %{service: "sentry", name: name})
    end

    test "names a built-in definition and holds no host or auth of its own", %{scope: scope} do
      assert {:ok,
              %Connection{kind: "service", name: "Sentry", service_builtin: "sentry"} = connection} =
               Connections.create_service(scope, %{service: "sentry"})

      assert connection.settings == "{}"
      assert {:ok, %{"hosts" => ["sentry.io"]}} = Connections.definition(connection)

      assert Connections.create_service(scope, %{service: "nothing"}) ==
               {:error, :service_unknown}
    end

    test "names a definition of the organisation, which is written, replaced and kept while in use",
         %{scope: scope} do
      assert {:ok, %ServiceDefinition{key: "status-api", title: "Status API"} = definition} =
               Connections.create_service_definition(scope, status_definition())

      assert definition.public_id =~ ~r/\Asvc_/

      assert {:error, changeset} =
               Connections.create_service_definition(scope, status_definition())

      assert %{key: [_]} = errors_on(changeset)

      {:ok, connection} =
        Connections.create_service(scope, %{definition_id: definition.public_id, name: "Status"})

      assert connection.name == "Status"
      assert {:ok, %{"hosts" => ["status.example.com"]}} = Connections.definition(connection)

      assert {:ok, replaced} =
               Connections.update_service_definition(
                 scope,
                 definition,
                 status_definition(%{"hosts" => ["api.status.example.com"]})
               )

      assert replaced.digest != definition.digest
      {:ok, connection} = Connections.get_connection(scope, connection.public_id)
      assert {:ok, %{"hosts" => ["api.status.example.com"]}} = Connections.definition(connection)

      assert Connections.delete_service_definition(scope, replaced) ==
               {:error, {:in_use, [connection.public_id]}}

      {:ok, _} = Connections.delete_connection(scope, connection)
      assert {:ok, _} = Connections.delete_service_definition(scope, replaced)
    end

    test "a definition is refused as the rules say", %{scope: scope} do
      assert {:error, {:definition_invalid, [{:placeholder_conflict, "QORY_KEY"}]}} =
               Connections.create_service_definition(
                 scope,
                 status_definition(%{
                   "declares" => [%{"id" => "key", "title" => "Key", "name" => "QORY_KEY"}]
                 })
               )

      assert {:error, {:definition_invalid, _}} =
               Connections.create_service_definition(scope, "{")

      assert {:error, {:definition_invalid, _}} =
               Connections.create_service_definition(scope, %{"key" => "x"})
    end

    test "collides with what serves one of its hosts where both apply", %{scope: scope} do
      {:ok, _runtime} = Connections.create_runtime(scope, %{runtime: "claude"})

      {:ok, definition} =
        Connections.create_service_definition(
          scope,
          status_definition(%{"key" => "model-api", "hosts" => ["api.anthropic.com"]})
        )

      # The claude runtime declares no secret, so its connection serves no host: the run's
      # model key comes from a model provider.
      assert {:ok, _} =
               Connections.create_service(scope, %{definition_id: definition.public_id})

      ready = ready_release!(scope, github_description())

      {:ok, _github} =
        Connections.create_integration(scope, ready.id, %{
          applies_to: "selected",
          workspace_ids: [scope.workspace.id]
        })

      {:ok, hub} =
        Connections.create_service_definition(
          scope,
          status_definition(%{"key" => "hub", "hosts" => ["api.github.com"]})
        )

      assert {:error, {:overlap, [_]}} =
               Connections.create_service(scope, %{definition_id: hub.public_id})

      site = workspace!(scope, "Site")

      assert {:ok, _} =
               Connections.create_service(scope, %{
                 definition_id: hub.public_id,
                 applies_to: "selected",
                 workspace_ids: [site.id]
               })
    end
  end

  describe "where a connection applies" do
    test "selected keeps the workspaces it lists; another organisation's, or one marked for deletion, is not found",
         %{scope: scope} do
      {:ok, connection} =
        Connections.create_service(scope, %{
          service: "sentry",
          applies_to: "selected",
          workspace_ids: [scope.workspace.id]
        })

      assert [%ConnectionWorkspace{workspace_id: id}] = connection.workspaces
      assert id == scope.workspace.id

      elsewhere = sign_up_fixture().scope.workspace

      assert Connections.create_service(scope, %{
               service: "npm",
               applies_to: "selected",
               workspace_ids: [elsewhere.id]
             }) == {:error, :workspace_not_found}

      assert Connections.put_workspace(scope, connection, elsewhere.id) ==
               {:error, :workspace_not_found}

      assert Connections.put_workspace(scope, connection, "not-an-id") ==
               {:error, :workspace_not_found}

      marked = workspace!(scope, "Marked")
      {:ok, _} = Deletion.delete_workspace(scope, marked.id, marked.slug)

      assert Connections.put_workspace(scope, connection, marked.id) ==
               {:error, :workspace_not_found}

      # A workspace it lists already is kept as it is.
      assert {:ok, %{workspaces: [_]}} =
               Connections.put_workspace(scope, connection, scope.workspace.id)

      {:ok, connection} = Connections.remove_workspace(scope, connection, scope.workspace.id)
      assert connection.workspaces == []

      assert Connections.remove_workspace(scope, connection, scope.workspace.id) ==
               {:error, :workspace_not_found}
    end

    test "all covers every workspace, one made later included; selected only those it lists",
         %{scope: scope} do
      site = workspace!(scope, "Site")
      {:ok, every} = Connections.create_service(scope, %{service: "npm"})

      {:ok, chosen} =
        Connections.create_service(scope, %{
          service: "sentry",
          applies_to: "selected",
          workspace_ids: [site.id]
        })

      later = workspace!(scope, "Later")

      rendered = fn workspace ->
        {:ok, connections} = Connections.list_for_rendering(workspace)
        Enum.map(connections, & &1.public_id)
      end

      assert rendered.(scope.workspace) == [every.public_id]
      assert Enum.sort(rendered.(site)) == Enum.sort([every.public_id, chosen.public_id])
      assert rendered.(later) == [every.public_id]

      # Every workspace reads the organisation's connections, those that do not apply to it
      # too.
      assert {:ok, listed} = Connections.list_connections(workspace_scope(scope.user, later))

      assert Enum.sort(Enum.map(listed, & &1.public_id)) ==
               Enum.sort([every.public_id, chosen.public_id])
    end

    test "the overlap check is per workspace where both apply", %{scope: scope} do
      main = scope.workspace
      site = workspace!(scope, "Site")
      docs = workspace!(scope, "Docs")

      {:ok, here} =
        Connections.create_runtime(scope, %{
          runtime: "claude",
          applies_to: "selected",
          workspace_ids: [main.id, docs.id]
        })

      {:ok, there} =
        Connections.create_runtime(scope, %{
          runtime: "claude",
          applies_to: "selected",
          workspace_ids: [site.id]
        })

      # Where both would apply, docs: refused, and nothing is written.
      assert Connections.put_workspace(scope, there, docs.id) ==
               {:error, {:overlap, [here.public_id]}}

      assert Connections.workspace_ids_of(there) == [site.id]

      # Each workspace has one claude; every workspace would meet both.
      assert Connections.update_connection(scope, there, %{applies_to: "all"}) ==
               {:error, {:overlap, [here.public_id]}}

      {:ok, here} = Connections.remove_workspace(scope, here, docs.id)
      assert {:ok, _} = Connections.put_workspace(scope, there, docs.id)

      # A selected one that lists none meets nothing, not even every workspace.
      {:ok, _} = Connections.remove_workspace(scope, here, main.id)
      {:ok, there} = Connections.remove_workspace(scope, there, site.id)
      {:ok, _} = Connections.remove_workspace(scope, there, docs.id)
      assert {:ok, _} = Connections.create_runtime(scope, %{runtime: "claude"})
    end

    test "a workspace's purge takes it from every list, and a selected one may list none",
         %{scope: scope} do
      site = workspace!(scope, "Site")

      {:ok, only_site} =
        Connections.create_runtime(scope, %{
          runtime: "claude",
          applies_to: "selected",
          workspace_ids: [site.id]
        })

      {:ok, both} =
        Connections.create_service(scope, %{
          service: "sentry",
          applies_to: "selected",
          workspace_ids: [scope.workspace.id, site.id]
        })

      {:ok, _} = Deletion.delete_workspace(scope, site.id, site.slug)

      Repo.update_all(from(w in Workspace, where: w.id == ^site.id),
        set: [purge_after: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

      assert {:ok, :purged} =
               Deletion.purge_workspace(
                 Scope.for_instance(scope.organisation, Repo.get!(Workspace, site.id))
               )

      assert {:ok, %Connection{applies_to: "selected", workspaces: []}} =
               Connections.get_connection(scope, only_site.public_id)

      assert {:ok, %Connection{workspaces: [%ConnectionWorkspace{workspace_id: id}]}} =
               Connections.get_connection(scope, both.public_id)

      assert id == scope.workspace.id
    end

    test "a change of applies_to is checked for overlap", %{scope: scope} do
      {:ok, _all} =
        Connections.create_runtime(scope, %{
          runtime: "claude",
          applies_to: "selected",
          workspace_ids: [scope.workspace.id]
        })

      {:ok, other} =
        Connections.create_runtime(scope, %{runtime: "claude", applies_to: "selected"})

      assert {:error, {:overlap, _}} =
               Connections.update_connection(scope, other, %{applies_to: "all"})
    end

    test "applies_to is all or selected", %{scope: scope} do
      assert {:error, changeset} =
               Connections.create_runtime(scope, %{runtime: "claude", applies_to: "some"})

      assert %{applies_to: [_]} = errors_on(changeset)
    end
  end

  describe "integrity" do
    test "a connection changed in the database is not intact, and is not rendered", %{
      scope: scope
    } do
      {:ok, connection} = Connections.create_service(scope, %{service: "sentry"})
      assert {:ok, [_]} = Connections.list_for_rendering(scope.workspace)

      Repo.update_all(from(c in Connection, where: c.id == ^connection.id),
        set: [service_builtin: "npm"]
      )

      assert {:ok, %Connection{intact: false}} =
               Connections.get_connection(scope, connection.public_id)

      assert {:ok, [%Connection{intact: false}]} = Connections.list_connections(scope)

      log =
        capture_log(fn ->
          assert Connections.list_for_rendering(scope.workspace) ==
                   {:error, {:integrity, [connection.public_id]}}
        end)

      assert log =~ connection.public_id
    end

    test "an integration whose release or settings changed is not intact", %{scope: scope} do
      release = ready_release!(scope, github_description())

      {:ok, connection} =
        Connections.create_integration(scope, release.id, %{settings: %{"app_id" => "1"}})

      Repo.update_all(from(c in Connection, where: c.id == ^connection.id),
        set: [settings: ~s({"app_id":"2"})]
      )

      assert {:ok, %Connection{intact: false}} =
               Connections.get_connection(scope, connection.public_id)
    end

    test "an integration whose release's description changed is not intact", %{scope: scope} do
      release = ready_release!(scope, github_description())
      {:ok, connection} = Connections.create_integration(scope, release.id, %{})

      Repo.update_all(from(r in Apiary.Integrations.Release, where: r.id == ^release.id),
        set: [description: encode(github_description(%{"title" => "Other"}))]
      )

      assert {:ok, %Connection{intact: false}} =
               Connections.get_connection(scope, connection.public_id)
    end

    test "a service whose own definition changed is not intact", %{scope: scope} do
      {:ok, definition} = Connections.create_service_definition(scope, status_definition())

      {:ok, connection} =
        Connections.create_service(scope, %{definition_id: definition.public_id})

      Repo.update_all(from(d in ServiceDefinition, where: d.id == ^definition.id),
        set: [
          definition:
            ServiceDefinition.decoded(definition)
            |> Map.put("hosts", ["evil.example.com"])
            |> Jason.encode!()
        ]
      )

      assert {:ok, %Connection{intact: false}} =
               Connections.get_connection(scope, connection.public_id)
    end
  end

  describe "who" do
    test "a member reads the organisation's and changes nothing", %{scope: scope} do
      {:ok, connection} = Connections.create_service(scope, %{service: "sentry"})
      {:ok, definition} = Connections.create_service_definition(scope, status_definition())
      %{scope: member} = member_fixture(scope)

      for member <- [member, %{member | workspace: nil}] do
        assert {:ok, [_]} = Connections.list_connections(member)
        assert {:ok, _} = Connections.get_connection(member, connection.public_id)
        assert {:ok, [_]} = Connections.list_service_definitions(member)
        assert {:ok, _} = Connections.get_service_definition(member, definition.public_id)
      end

      assert Connections.create_runtime(member, %{runtime: "claude"}) == {:error, :forbidden}

      assert Connections.put_workspace(member, connection, scope.workspace.id) ==
               {:error, :forbidden}

      assert Connections.update_connection(member, connection, %{name: "Other"}) ==
               {:error, :forbidden}

      assert Connections.delete_connection(member, connection) == {:error, :forbidden}

      assert Connections.create_service_definition(member, status_definition()) ==
               {:error, :forbidden}
    end

    test "an admin changes them, from the organisation or any of its workspaces", %{
      scope: scope
    } do
      site = workspace!(scope, "Site")
      %{scope: admin, user: user} = member_fixture(scope, :admin)
      at_organisation = %{admin | workspace: nil}

      assert {:ok, runtime} =
               Connections.create_runtime(at_organisation, %{
                 runtime: "claude",
                 applies_to: "selected"
               })

      assert {:ok, _} = Connections.put_workspace(at_organisation, runtime, site.id)

      at_site = workspace_scope(user, site)
      assert {:ok, _} = Connections.remove_workspace(at_site, runtime, site.id)
      assert {:ok, _} = Connections.create_service_definition(at_site, status_definition())

      assert [%Entry{workspace_id: nil} | _] = trail(runtime.id)
      assert Enum.all?(trail(runtime.id), &is_nil(&1.workspace_id))
    end

    test "another organisation's connection is out of reach", %{scope: scope} do
      {:ok, connection} = Connections.create_service(scope, %{service: "sentry"})
      {:ok, definition} = Connections.create_service_definition(scope, status_definition())
      other = sign_up_fixture().scope

      assert Connections.get_connection(other, connection.public_id) == {:error, :not_found}
      assert {:ok, []} = Connections.list_connections(other)

      assert Connections.update_connection(other, connection, %{name: "Mine"}) ==
               {:error, :not_found}

      assert Connections.delete_connection(other, connection) == {:error, :not_found}

      assert Connections.get_service_definition(other, definition.public_id) ==
               {:error, :not_found}

      assert Connections.delete_service_definition(other, definition) == {:error, :not_found}
    end
  end

  describe "the trail" do
    test "every change leaves one entry, and none carries a secret value", %{scope: scope} do
      release = ready_release!(scope, github_description())
      site = workspace!(scope, "Site")

      {:ok, connection} =
        Connections.create_integration(scope, release.id, %{settings: %{"app_id" => "7"}})

      {:ok, connection} = Connections.put_workspace(scope, connection, site.id)
      {:ok, connection} = Connections.remove_workspace(scope, connection, site.id)
      {:ok, _} = Connections.delete_connection(scope, connection)

      entries = trail(connection.id)

      assert Enum.map(entries, & &1.details["change"]) == [
               "created",
               "workspace_added",
               "workspace_removed",
               "deleted"
             ]

      assert Enum.at(entries, 1).details["workspace_id"] == site.id

      assert Enum.all?(entries, &(&1.action == "connection.write"))

      {:error, _} =
        Connections.create_integration(scope, release.id, %{
          settings: %{"private_key" => "s3cr3t-value"}
        })

      refute Enum.any?(Repo.all(Entry), &(inspect(&1) =~ "s3cr3t-value"))
    end

    test "a change that changes nothing leaves no entry", %{scope: scope} do
      {:ok, connection} = Connections.create_service(scope, %{service: "sentry"})
      {:ok, _} = Connections.update_connection(scope, connection, %{name: "Sentry"})
      assert length(trail(connection.id)) == 1
    end
  end
end
