defmodule Apiary.ConnectionsTest do
  use Apiary.DataCase, async: true

  import Apiary.ConnectionsFixtures
  import Apiary.DescriptionFixtures
  import Apiary.OrganisationsFixtures
  import ExUnit.CaptureLog

  alias Apiary.Audit.Entry
  alias Apiary.Connections
  alias Apiary.Connections.{Connection, ServiceDefinition, Target}

  @moduletag needs: :security

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
    test "is set up from the catalogue, for every repository", %{scope: scope} do
      assert {:ok,
              %Connection{kind: "runtime", name: "claude", applies_to: "all", intact: true} =
                connection} =
               Connections.create_runtime(scope, %{runtime: "claude"})

      assert connection.public_id =~ ~r/\Acon_[0-9a-hjkmnp-tv-z]{16}\z/
      assert connection.settings == "{}"

      assert Connections.create_runtime(scope, %{runtime: "nothing"}) ==
               {:error, :runtime_unknown}
    end

    test "is one per runtime where two would apply to a repository alike", %{scope: scope} do
      shop = target!(scope, "acme/shop")
      site = target!(scope, "acme/site")

      {:ok, first} =
        Connections.create_runtime(scope, %{
          runtime: "claude",
          applies_to: "selected",
          target_ids: [shop.id]
        })

      assert {:ok, _} =
               Connections.create_runtime(scope, %{
                 runtime: "claude",
                 applies_to: "selected",
                 target_ids: [site.id]
               })

      assert {:error, {:overlap, [_ | _] = ids}} =
               Connections.create_runtime(scope, %{runtime: "claude"})

      assert first.public_id in ids

      assert {:error, {:overlap, [id]}} =
               Connections.create_runtime(scope, %{
                 runtime: "claude",
                 applies_to: "selected",
                 target_ids: [shop.id]
               })

      assert id == first.public_id
    end

    test "takes no ways on a repository", %{scope: scope} do
      shop = target!(scope, "acme/shop")
      {:ok, runtime} = Connections.create_runtime(scope, %{runtime: "claude"})

      assert Connections.put_target(scope, runtime, shop.id, ["credential"]) ==
               {:error, :ways_not_allowed}

      assert {:ok, _} = Connections.put_target(scope, runtime, shop.id)
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

      assert {:ok, %{name: "github", publisher: %{"name" => "Qory"}}} =
               Connections.description(connection)
    end

    test "never stores a secret, a secret's _file, or what its roles do not list as a setting",
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
               settings: %{"api_url" => "https://api.github.com"}
             }) ==
               {:error, {:integration_settings_not_allowed, ["api_url"]}}

      assert {:error, {:integration_settings_invalid, _}} =
               Connections.create_integration(scope, release.id, %{
                 settings: %{"app_id" => "no id"}
               })

      assert Repo.aggregate(Connection, :count) == 0
    end

    test "refuses an argument its roles do not match", %{scope: scope, release: release} do
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

    test "is used in the ways its description offers, per repository", %{scope: scope} do
      tracker = ready_release!(scope, tracker_description(), "github.com/acme/tracker")
      shop = target!(scope, "acme/shop")
      {:ok, connection} = Connections.create_integration(scope, tracker.id, %{})

      assert {:ok, connection} = Connections.put_target(scope, connection, shop.id, ["tool"])
      assert [%Target{ways: ["tool"]}] = connection.targets

      assert {:ok, connection} =
               Connections.put_target(scope, connection, shop.id, ["tool", "credential"])

      assert [%Target{ways: ["credential", "tool"]}] = connection.targets

      assert {:ok, connection} = Connections.put_target(scope, connection, shop.id, nil)
      assert [%Target{ways: nil}] = connection.targets

      assert Connections.put_target(scope, connection, shop.id, []) == {:error, :ways_not_allowed}

      assert Connections.put_target(scope, connection, shop.id, ["output"]) ==
               {:error, :ways_not_allowed}
    end

    test "is one per name where two would apply to a repository alike", %{
      scope: scope,
      release: release
    } do
      {:ok, first} = Connections.create_integration(scope, release.id, %{})
      other = ready_release!(scope, github_description(), "github.com/acme/hub")

      assert Connections.create_integration(scope, other.id, %{}) ==
               {:error, {:overlap, [first.public_id]}}
    end

    test "offers only the ways its description defines", %{scope: scope, release: release} do
      shop = target!(scope, "acme/shop")
      {:ok, connection} = Connections.create_integration(scope, release.id, %{})

      assert Connections.put_target(scope, connection, shop.id, ["tool"]) ==
               {:error, :ways_not_allowed}
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
    test "names a built-in definition and holds no host or auth of its own", %{scope: scope} do
      assert {:ok,
              %Connection{kind: "service", name: "Sentry", service_builtin: "sentry"} = connection} =
               Connections.create_service(scope, %{service: "sentry"})

      assert connection.settings == "{}"
      assert {:ok, %{"hosts" => ["sentry.io"]}} = Connections.definition(connection)

      assert Connections.create_service(scope, %{service: "nothing"}) ==
               {:error, :service_unknown}
    end

    test "names a definition of the workspace's own, which is written, replaced and kept while in use",
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

      assert {:error, {:overlap, [_]}} =
               Connections.create_service(scope, %{definition_id: definition.public_id})

      shop = target!(scope, "acme/shop")
      ready = ready_release!(scope, github_description())

      {:ok, _github} =
        Connections.create_integration(scope, ready.id, %{
          applies_to: "selected",
          target_ids: [shop.id]
        })

      {:ok, hub} =
        Connections.create_service_definition(
          scope,
          status_definition(%{"key" => "hub", "hosts" => ["api.github.com"]})
        )

      assert {:error, {:overlap, [_]}} =
               Connections.create_service(scope, %{definition_id: hub.public_id})

      site = target!(scope, "acme/site")

      assert {:ok, _} =
               Connections.create_service(scope, %{
                 definition_id: hub.public_id,
                 applies_to: "selected",
                 target_ids: [site.id]
               })
    end
  end

  describe "where a connection applies" do
    test "selected keeps the repositories it names; a repository of another workspace is not found",
         %{scope: scope} do
      shop = target!(scope, "acme/shop")

      {:ok, connection} =
        Connections.create_service(scope, %{
          service: "sentry",
          applies_to: "selected",
          target_ids: [shop.id]
        })

      assert [%Target{target_id: id}] = connection.targets
      assert id == shop.id

      other = sign_up_fixture().scope
      elsewhere = target!(other, "acme/elsewhere")

      assert Connections.create_service(scope, %{
               service: "npm",
               applies_to: "selected",
               target_ids: [elsewhere.id]
             }) ==
               {:error, :target_not_found}

      assert Connections.put_target(scope, connection, elsewhere.id) ==
               {:error, :target_not_found}

      {:ok, connection} = Connections.remove_target(scope, connection, shop.id)
      assert connection.targets == []
      assert Connections.remove_target(scope, connection, shop.id) == {:error, :target_not_found}
    end

    test "a change of applies_to is checked for overlap, and a repository's removal takes its rows",
         %{scope: scope} do
      shop = target!(scope, "acme/shop")

      {:ok, _all} =
        Connections.create_runtime(scope, %{
          runtime: "claude",
          applies_to: "selected",
          target_ids: [shop.id]
        })

      {:ok, other} =
        Connections.create_runtime(scope, %{runtime: "claude", applies_to: "selected"})

      assert {:error, {:overlap, _}} =
               Connections.update_connection(scope, other, %{applies_to: "all"})

      Repo.delete!(shop)
      assert Repo.aggregate(Target, :count) == 0

      assert {:ok, %Connection{applies_to: "all"}} =
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
    test "a member reads and changes nothing", %{scope: scope} do
      {:ok, connection} = Connections.create_service(scope, %{service: "sentry"})
      %{scope: member} = member_fixture(scope)

      assert {:ok, [_]} = Connections.list_connections(member)
      assert {:ok, _} = Connections.get_connection(member, connection.public_id)
      assert Connections.create_runtime(member, %{runtime: "claude"}) == {:error, :forbidden}

      assert Connections.update_connection(member, connection, %{name: "Other"}) ==
               {:error, :forbidden}

      assert Connections.delete_connection(member, connection) == {:error, :forbidden}

      assert Connections.create_service_definition(member, status_definition()) ==
               {:error, :forbidden}
    end

    test "an admin changes them", %{scope: scope} do
      %{scope: admin} = member_fixture(scope, :admin)
      assert {:ok, _} = Connections.create_runtime(admin, %{runtime: "claude"})
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
      shop = target!(scope, "acme/shop")

      {:ok, connection} =
        Connections.create_integration(scope, release.id, %{settings: %{"app_id" => "7"}})

      {:ok, connection} = Connections.put_target(scope, connection, shop.id, ["credential"])
      {:ok, connection} = Connections.remove_target(scope, connection, shop.id)
      {:ok, _} = Connections.delete_connection(scope, connection)

      entries = trail(connection.id)

      assert Enum.map(entries, & &1.details["change"]) == [
               "created",
               "target_set",
               "target_removed",
               "deleted"
             ]

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
