defmodule Apiary.Policy.IntegrationHostsTest do
  @moduledoc """
  The hosts an integration requires, in the documents served to the workspaces it
  reaches: added by every write to the integration and by every write of the policy,
  beating every deny, and left out of what the pages read.
  """
  use Apiary.DataCase, async: true

  import Apiary.ConnectionsFixtures
  import Apiary.DescriptionFixtures
  import Apiary.OrganisationsFixtures
  import ExUnit.CaptureLog

  alias Apiary.{Connections, Policy}
  alias Apiary.Connections.Connection
  alias Apiary.Policy.{Change, Entry, RunConfiguration}

  @moduletag needs: :secrets

  setup do
    %{scope: scope, user: user} = sign_up_fixture()
    %{scope: scope, user: user}
  end

  # A release of an integration named `name` whose `egress_hosts` are `hosts`, with an
  # address setting, `address`, and a credential host named after the integration.
  defp release!(scope, name, hosts) do
    description =
      tracker_description(%{
        "name" => name,
        "settings" => %{
          "type" => "object",
          "properties" => %{
            "address" => %{"title" => "Address", "type" => "string"},
            "api_key" => %{"title" => "API key", "type" => "string", "writeOnly" => true},
            "api_key_file" => %{"title" => "API key file", "type" => "string"}
          }
        },
        "roles" => %{
          "credential" => %{"argument" => "[A-Z]+", "hosts" => ["#{name}.example.net"]}
        },
        "egress_hosts" => hosts
      })

    ready_release!(scope, description, "codeberg.org/acme/#{name}")
  end

  defp integration!(scope, name, hosts, attrs \\ %{}) do
    {:ok, connection} =
      Connections.create_integration(scope, release!(scope, name, hosts).id, attrs)

    connection
  end

  # The egress of the document served to the holder.
  defp served(scope, holder) do
    {:ok, %RunConfiguration{document: document}} = Policy.current_configuration(scope, holder)
    Jason.decode!(document)["security_policy"]["egress"]
  end

  defp integration_entries(scope, holder) do
    for %Entry{source: :integration} = entry <-
          Policy.effective(scope, holder, integrations: true).entries,
        do: entry
  end

  describe "a connection that applies to every workspace" do
    test "adds its hosts to the baseline's egress.allow, once the workspace is managed", %{
      scope: scope
    } do
      connection = integration!(scope, "acme-tracker", ["api.example.com"])

      # A workspace nobody has changed is not served a policy: its machines use theirs.
      refute Policy.managed?(scope)

      {:ok, _rule} = Policy.allow(scope, nil, %{host: "docs.example.com"})
      assert served(scope, nil)["allow"] == ["api.example.com", "docs.example.com"]

      assert [%Entry{in_force: true, connection: %{public_id: public_id}}] =
               integration_entries(scope, nil)

      assert public_id == connection.public_id
    end

    test "is rendered into a managed workspace when it is added, with a change in the history",
         %{scope: scope} do
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "docs.example.com"})
      target = target!(scope, "acme/site")
      {:ok, _rule} = Policy.allow(scope, target, %{host: "cdn.example.com"})
      :ok = Policy.subscribe(scope)

      integration!(scope, "acme-tracker", ["api.example.com"])

      assert served(scope, nil)["allow"] == ["api.example.com", "docs.example.com"]

      assert served(scope, target)["allow"] ==
               ["api.example.com", "cdn.example.com", "docs.example.com"]

      assert %{items: [%Change{action: "rerendered", changed_by_id: by} | _]} =
               Policy.list_changes(scope, nil)

      assert by == scope.user.id
      workspace_id = scope.workspace.id

      assert_receive {:policy_changed,
                      %{workspace_id: ^workspace_id, target_id: nil, action: "rerendered"}}
    end
  end

  describe "a connection that applies to chosen workspaces" do
    test "adds its hosts to those workspaces only, as they are added and removed", %{
      scope: scope,
      user: user
    } do
      site = workspace!(scope, "Site")
      at_site = workspace_scope(user, site)
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "docs.example.com"})
      {:ok, _rule} = Policy.allow(at_site, nil, %{host: "docs.example.com"})

      connection =
        integration!(scope, "acme-tracker", ["api.example.com"], %{
          applies_to: "selected",
          workspace_ids: [site.id]
        })

      assert served(at_site, nil)["allow"] == ["api.example.com", "docs.example.com"]
      assert served(scope, nil)["allow"] == ["docs.example.com"]

      {:ok, connection} = Connections.put_workspace(scope, connection, scope.workspace.id)
      assert served(scope, nil)["allow"] == ["api.example.com", "docs.example.com"]

      {:ok, connection} = Connections.remove_workspace(scope, connection, site.id)
      assert served(at_site, nil)["allow"] == ["docs.example.com"]
      assert served(scope, nil)["allow"] == ["api.example.com", "docs.example.com"]

      # Switching to every workspace reaches the site again; deleting it reaches none.
      {:ok, connection} = Connections.update_connection(scope, connection, %{applies_to: "all"})
      assert served(at_site, nil)["allow"] == ["api.example.com", "docs.example.com"]

      {:ok, _deleted} = Connections.delete_connection(scope, connection)
      assert served(at_site, nil)["allow"] == ["docs.example.com"]
      assert served(scope, nil)["allow"] == ["docs.example.com"]
    end
  end

  describe "a deny rule" do
    test "of the workspace, locked or not, and of a target loses to the integration's host",
         %{scope: scope} do
      integration!(scope, "acme-tracker", ["api.example.com"])
      target = target!(scope, "acme/site")
      {:ok, "enforce"} = Policy.set_mode(scope, "enforce")

      {:ok, rule} = Policy.deny(scope, nil, %{host: "api.example.com"})
      assert served(scope, nil) == %{"mode" => "enforce", "allow" => ["api.example.com"]}

      {:ok, _rule} = Policy.lock(scope, rule)
      assert served(scope, nil)["allow"] == ["api.example.com"]
      refute Map.has_key?(served(scope, nil), "deny")

      {:ok, _rule} = Policy.deny(scope, target, %{host: "api.example.com"})
      assert served(scope, target)["allow"] == ["api.example.com"]
      refute Map.has_key?(served(scope, target), "deny")

      denies =
        for %Entry{action: :deny} = entry <-
              Policy.effective(scope, target, integrations: true).entries,
            do: entry

      assert [_workspace, _target] = denies

      for deny <- denies do
        refute deny.in_force
        assert %Entry{source: :integration, host: "api.example.com"} = deny.overridden_by
      end
    end

    test "a *. deny saves, blocks a sibling host, and is overridden for the integration's host",
         %{scope: scope} do
      integration!(scope, "acme-tracker", ["api.example.com"])
      {:ok, "enforce"} = Policy.set_mode(scope, "enforce")
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "cdn.example.com"})

      assert {:ok, _rule} = Policy.deny(scope, nil, %{host: "*.example.com"})

      # Under enforce the sibling is not reached: it has no allow.
      assert served(scope, nil)["allow"] == ["api.example.com"]

      entries = Policy.effective(scope, nil, integrations: true).entries
      assert %Entry{in_force: true} = Enum.find(entries, &(&1.host == "*.example.com"))
      assert %Entry{in_force: false} = Enum.find(entries, &(&1.host == "cdn.example.com"))

      assert [%Entry{in_force: true, overrides: [%Entry{host: "*.example.com"}]}] =
               integration_entries(scope, nil)
    end
  end

  test "two integrations that list one host both stay in force", %{scope: scope} do
    integration!(scope, "acme-tracker", ["api.example.com"])
    integration!(scope, "acme-chat", ["api.example.com", "chat.example.com"])
    {:ok, _rule} = Policy.deny(scope, nil, %{host: "api.example.com"})

    assert served(scope, nil)["allow"] == ["api.example.com", "chat.example.com"]

    assert scope
           |> integration_entries(nil)
           |> Enum.filter(&(&1.host == "api.example.com"))
           |> Enum.map(&{&1.connection.name, &1.in_force})
           |> Enum.sort() == [{"acme-chat", true}, {"acme-tracker", true}]
  end

  describe "a host from a setting" do
    test "is left out when the address fails the endpoint rule, and a setting change renders it",
         %{scope: scope} do
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "docs.example.com"})

      connection =
        integration!(scope, "acme-models", [%{"setting" => "address"}], %{
          settings: %{"address" => "http://models.example.com"}
        })

      assert served(scope, nil)["allow"] == ["docs.example.com"]

      {:ok, connection} =
        Connections.update_connection(scope, connection, %{
          settings: %{"address" => "https://models.example.com:8443/v1"}
        })

      assert served(scope, nil)["allow"] == ["docs.example.com", "models.example.com"]

      {:ok, _connection} =
        Connections.update_connection(scope, connection, %{
          settings: %{"address" => "https://localhost/v1"}
        })

      assert served(scope, nil)["allow"] == ["docs.example.com"]
    end
  end

  test "a connection whose integrity code fails adds nothing, with an error in the log", %{
    scope: scope
  } do
    connection = integration!(scope, "acme-tracker", ["api.example.com"])

    Repo.update_all(from(c in Connection, where: c.id == ^connection.id),
      set: [settings: ~s({"address":"https://tampered.example.com"})]
    )

    log =
      capture_log(fn ->
        {:ok, _rule} = Policy.allow(scope, nil, %{host: "docs.example.com"})
      end)

    assert served(scope, nil)["allow"] == ["docs.example.com"]
    assert log =~ "fails its integrity code"
    assert log =~ connection.public_id
  end

  @tag needs: :factory
  test "a model provider adds nothing here", %{scope: scope} do
    {:ok, _provider} =
      Connections.create_provider(scope, %{
        provider: "anthropic",
        keys: [%{value_id: "main", value: "sk-hosts-test-0123456789"}]
      })

    {:ok, _rule} = Policy.allow(scope, nil, %{host: "docs.example.com"})

    assert Connections.egress_hosts(scope.workspace) == []
    assert served(scope, nil)["allow"] == ["docs.example.com"]
  end

  test "effective/2, which the pages read, is as it was before the integration", %{
    scope: scope
  } do
    target = target!(scope, "acme/site")
    {:ok, rule} = Policy.deny(scope, nil, %{host: "api.example.com"})
    {:ok, _rule} = Policy.lock(scope, rule)
    {:ok, _rule} = Policy.deny(scope, nil, %{host: "*.example.org"})
    {:ok, _rule} = Policy.allow(scope, target, %{host: "cdn.example.org"})

    baseline = Policy.effective(scope, nil)
    targeted = Policy.effective(scope, target)

    integration!(scope, "acme-tracker", ["api.example.com", "files.example.org"])

    assert Policy.effective(scope, nil) == baseline
    assert Policy.effective(scope, target) == targeted
    assert Policy.effective(scope, nil, integrations: false) == baseline
    assert Policy.export(scope, nil) == {:ok, Apiary.Policy.Export.text(baseline)}

    assert [_api, _files] = integration_entries(scope, nil)
  end
end
