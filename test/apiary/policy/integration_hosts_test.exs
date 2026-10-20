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
  alias Apiary.Policy.{Change, Entry, Error, Render, RunConfiguration}

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

  # The document served to the holder, which the contract's schema takes.
  defp document(scope, holder) do
    {:ok, %RunConfiguration{document: document}} = Policy.current_configuration(scope, holder)
    assert Policy.valid_document(document) == :ok
    document
  end

  # The egress of the document served to the holder.
  defp served(scope, holder),
    do: Jason.decode!(document(scope, holder))["security_policy"]["egress"]

  # The hosts the render keeps beside the holder's document.
  defp allow_first(scope, holder) do
    {:ok, _document, allow_first} =
      Render.render(Policy.effective(scope, holder, integrations: true))

    allow_first
  end

  defp integration_entries(scope, holder) do
    for %Entry{source: :integration} = entry <-
          Policy.effective(scope, holder, integrations: true).entries,
        do: entry
  end

  describe "a connection that applies to every workspace" do
    test "adds its hosts to the baseline's egress.allow_first, once the workspace is managed",
         %{scope: scope} do
      connection = integration!(scope, "acme-tracker", ["api.example.com"])

      # A workspace nobody has changed is not served a policy: its machines use theirs.
      refute Policy.managed?(scope)

      {:ok, _rule} = Policy.allow(scope, nil, %{host: "docs.example.com"})

      assert document(scope, nil) ==
               ~s({"version":1,"security_policy":{"version":1,"egress":{"mode":"observe",) <>
                 ~s("allow":["docs.example.com"],"allow_first":["api.example.com"]}}})

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

      assert %{"allow" => ["docs.example.com"], "allow_first" => ["api.example.com"]} =
               served(scope, nil)

      assert %{
               "allow" => ["cdn.example.com", "docs.example.com"],
               "allow_first" => ["api.example.com"]
             } = served(scope, target)

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

      assert served(at_site, nil)["allow_first"] == ["api.example.com"]
      refute Map.has_key?(served(scope, nil), "allow_first")

      {:ok, connection} = Connections.put_workspace(scope, connection, scope.workspace.id)
      assert served(scope, nil)["allow_first"] == ["api.example.com"]

      {:ok, connection} = Connections.remove_workspace(scope, connection, site.id)
      refute Map.has_key?(served(at_site, nil), "allow_first")
      assert served(scope, nil)["allow_first"] == ["api.example.com"]

      # Switching to every workspace reaches the site again; deleting it reaches none.
      {:ok, connection} = Connections.update_connection(scope, connection, %{applies_to: "all"})
      assert served(at_site, nil)["allow_first"] == ["api.example.com"]

      {:ok, _deleted} = Connections.delete_connection(scope, connection)

      # With no integration's host, a document is the bytes it was before the integration.
      for at <- [at_site, scope] do
        assert document(at, nil) ==
                 ~s({"version":1,"security_policy":{"version":1,"egress":{"mode":"observe",) <>
                   ~s("allow":["docs.example.com"]}}})
      end
    end
  end

  describe "a deny rule" do
    test "of the workspace, locked or not, and of a target loses to the integration's host",
         %{scope: scope} do
      # The denies are saved before the integration is added: once it is, a deny of its
      # host is refused at save.
      target = target!(scope, "acme/site")
      {:ok, "enforce"} = Policy.set_mode(scope, "enforce")
      {:ok, rule} = Policy.deny(scope, nil, %{host: "api.example.com"})
      {:ok, _rule} = Policy.deny(scope, target, %{host: "api.example.com"})

      integration!(scope, "acme-tracker", ["api.example.com"])
      expected = %{"mode" => "enforce", "allow" => [], "allow_first" => ["api.example.com"]}
      assert served(scope, nil) == expected
      assert served(scope, target) == expected

      {:ok, _rule} = Policy.lock(scope, rule)
      assert served(scope, nil) == expected
      assert allow_first(scope, nil) == ["api.example.com"]
      assert allow_first(scope, target) == ["api.example.com"]

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

      # The sibling is denied by the deny; the gateway allows the integration's host
      # before it reads the deny.
      assert served(scope, nil) == %{
               "mode" => "enforce",
               "allow" => [],
               "allow_first" => ["api.example.com"],
               "deny" => ["*.example.com"]
             }

      assert allow_first(scope, nil) == ["api.example.com"]

      entries = Policy.effective(scope, nil, integrations: true).entries
      assert %Entry{in_force: true} = Enum.find(entries, &(&1.host == "*.example.com"))
      assert %Entry{in_force: false} = Enum.find(entries, &(&1.host == "cdn.example.com"))

      assert [%Entry{in_force: true, overrides: [%Entry{host: "*.example.com"}]}] =
               integration_entries(scope, nil)
    end
  end

  test "two integrations that list one host both stay in force", %{scope: scope} do
    {:ok, _rule} = Policy.deny(scope, nil, %{host: "api.example.com"})
    integration!(scope, "acme-tracker", ["api.example.com"])
    integration!(scope, "acme-chat", ["api.example.com", "chat.example.com"])

    assert served(scope, nil)["allow"] == []
    assert served(scope, nil)["allow_first"] == ["api.example.com", "chat.example.com"]
    assert allow_first(scope, nil) == ["api.example.com", "chat.example.com"]

    assert scope
           |> integration_entries(nil)
           |> Enum.filter(&(&1.host == "api.example.com"))
           |> Enum.map(&{&1.connection.name, &1.in_force})
           |> Enum.sort() == [{"acme-chat", true}, {"acme-tracker", true}]
  end

  describe "saving a deny rule of an integration's host" do
    test "is refused at the workspace, at a target and at the level above", %{scope: scope} do
      connection = integration!(scope, "acme-tracker", ["api.example.com"])
      target = target!(scope, "acme/site")
      {:ok, allowed} = Policy.allow(scope, nil, %{host: "api.example.com"})

      expected = %{
        connection: %{
          id: connection.id,
          public_id: connection.public_id,
          name: connection.name
        },
        host: "api.example.com"
      }

      sentence =
        "Remove api.example.com from the rule. acme-tracker needs this host, so no rule can deny it."

      for holder <- [nil, target] do
        assert {:error,
                %Error{
                  reason: :integration_host,
                  field: :host,
                  details: ^expected,
                  message: ^sentence
                }} = Policy.deny(scope, holder, %{host: "api.example.com"})
      end

      # A rule there already is not turned into a deny either.
      assert {:error, %Error{reason: :integration_host}} =
               Policy.deny(scope, nil, %{host: allowed.host, locked: true})

      assert {:error, %Error{reason: :integration_host, details: ^expected, message: ^sentence}} =
               Policy.check_deny(scope, :above, "api.example.com")

      assert {:error, %Error{reason: :integration_host, details: ^expected, message: ^sentence}} =
               Policy.check_deny(scope, :workspace, "api.example.com")

      assert [%{host: "api.example.com", action: "allow"}] = Policy.list_rules(scope, nil)
      assert Policy.list_rules(scope, target) == []
    end

    test "saves a *. deny, a deny of another host, and an allow", %{scope: scope} do
      integration!(scope, "acme-tracker", ["api.example.com"])

      assert {:ok, _rule} = Policy.deny(scope, nil, %{host: "*.example.com"})
      assert {:ok, _rule} = Policy.deny(scope, nil, %{host: "a.api.example.com"})
      assert {:ok, _rule} = Policy.allow(scope, nil, %{host: "api.example.com"})
      assert Policy.check_deny(scope, :above, "*.example.com") == :ok
      assert Policy.check_deny(scope, :above, "a.api.example.com") == :ok
      assert allow_first(scope, nil) == ["api.example.com"]
    end

    test "is refused only where the connection reaches", %{scope: scope, user: user} do
      site = workspace!(scope, "Site")
      at_site = workspace_scope(user, site)

      integration!(scope, "acme-tracker", ["api.example.com"], %{
        applies_to: "selected",
        workspace_ids: [site.id]
      })

      assert {:ok, _rule} = Policy.deny(scope, nil, %{host: "api.example.com"})

      assert {:error, %Error{reason: :integration_host}} =
               Policy.deny(at_site, nil, %{host: "api.example.com"})

      # The level above holds in every workspace, the site included.
      assert {:error, %Error{reason: :integration_host}} =
               Policy.check_deny(scope, :above, "api.example.com")

      assert allow_first(scope, nil) == []
      assert allow_first(at_site, nil) == ["api.example.com"]
    end
  end

  test "more than 64 hosts is refused with the write that would render them", %{scope: scope} do
    {:ok, _rule} = Policy.allow(scope, nil, %{host: "docs.example.com"})
    many = for n <- 1..65, do: "host#{n}.example.com"

    log =
      capture_log(fn ->
        assert {:error, %Error{reason: :invalid_document}} =
                 Connections.create_integration(
                   scope,
                   release!(scope, "acme-tracker", many).id,
                   %{}
                 )
      end)

    assert log =~ "65 hosts"
    assert served(scope, nil)["allow"] == ["docs.example.com"]
    assert Connections.egress_hosts(scope.workspace) == []
  end

  describe "a host from a setting" do
    @describetag :capture_log

    test "is left out when the address fails the endpoint rule, and a setting change renders it",
         %{scope: scope} do
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "docs.example.com"})

      connection =
        integration!(scope, "acme-models", [%{"setting" => "address"}], %{
          settings: %{"address" => "http://models.example.com"}
        })

      refute Map.has_key?(served(scope, nil), "allow_first")

      {:ok, connection} =
        Connections.update_connection(scope, connection, %{
          settings: %{"address" => "https://models.example.com:8443/v1"}
        })

      assert served(scope, nil)["allow_first"] == ["models.example.com"]

      {:ok, _connection} =
        Connections.update_connection(scope, connection, %{
          settings: %{"address" => "https://localhost/v1"}
        })

      refute Map.has_key?(served(scope, nil), "allow_first")
    end

    test "is left out unless it is exact, with a log line without the address",
         %{scope: scope} do
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "docs.example.com"})

      connection =
        integration!(scope, "acme-models", ["api.example.com", %{"setting" => "address"}], %{
          settings: %{"address" => "https://models.example.com"}
        })

      # Other tests log at the same time; a token in each value keeps
      # the refute to this test's values.
      token = "t#{System.unique_integer([:positive])}"

      for address <- [
            "https://*.#{token}.example.com",
            "https://010.0.0.12/#{token}",
            "https://models.#{token}.example.com\n"
          ] do
        log =
          capture_log(fn ->
            {:ok, _connection} =
              Connections.update_connection(scope, connection, %{
                settings: %{"address" => address}
              })
          end)

        assert served(scope, nil)["allow_first"] == ["api.example.com"]
        assert allow_first(scope, nil) == ["api.example.com"]
        assert log =~ "the setting address of the integration connection #{connection.public_id}"
        refute log =~ token
      end

      {:ok, _connection} =
        Connections.update_connection(scope, connection, %{
          settings: %{"address" => "https://10.0.0.12/v1"}
        })

      assert served(scope, nil)["allow"] == ["docs.example.com"]
      assert served(scope, nil)["allow_first"] == ["10.0.0.12", "api.example.com"]
      assert allow_first(scope, nil) == ["10.0.0.12", "api.example.com"]
    end

    test "with a value the address rules refuse, does not fall back to the default",
         %{scope: scope} do
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "docs.example.com"})

      release =
        settings_release!(scope, "acme-models", %{
          "title" => "Address",
          "type" => "string",
          "default" => "https://fallback.example.com"
        })

      {:ok, connection} = Connections.create_integration(scope, release.id, %{})
      assert served(scope, nil)["allow_first"] == ["api.example.com", "fallback.example.com"]

      for address <- [
            "https://*.example.com",
            "https://localhost/v1",
            "http://models.example.com"
          ] do
        {:ok, _connection} =
          Connections.update_connection(scope, connection, %{
            settings: %{"endpoint" => address}
          })

        assert served(scope, nil)["allow_first"] == ["api.example.com"], address
      end
    end

    test "with a property schema of true or false adds no host, and every write renders" do
      for schema <- [true, false] do
        %{scope: scope} = sign_up_fixture()
        {:ok, _rule} = Policy.allow(scope, nil, %{host: "docs.example.com"})
        release = settings_release!(scope, "acme-flag", schema)

        assert {:ok, _connection} = Connections.create_integration(scope, release.id, %{})
        assert {:ok, _rule} = Policy.allow(scope, nil, %{host: "cdn.example.com"})
        assert {:ok, _rule} = Policy.deny(scope, nil, %{host: "tracker.example.org"})

        assert %{
                 "allow" => ["cdn.example.com", "docs.example.com"],
                 "allow_first" => ["api.example.com"],
                 "deny" => ["tracker.example.org"]
               } = served(scope, nil)

        assert allow_first(scope, nil) == ["api.example.com"]
      end
    end
  end

  # A release of an integration named `name` whose `egress_hosts` are `api.example.com`
  # and the setting `endpoint`, whose property schema is `endpoint`.
  defp settings_release!(scope, name, endpoint) do
    description =
      tracker_description(%{
        "name" => name,
        "settings" => %{
          "type" => "object",
          "properties" => %{
            "endpoint" => endpoint,
            "api_key" => %{"title" => "API key", "type" => "string", "writeOnly" => true},
            "api_key_file" => %{"title" => "API key file", "type" => "string"}
          }
        },
        "roles" => %{
          "credential" => %{"argument" => "[A-Z]+", "hosts" => ["#{name}.example.net"]}
        },
        "egress_hosts" => ["api.example.com", %{"setting" => "endpoint"}]
      })

    ready_release!(scope, description, "codeberg.org/acme/#{name}")
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

  describe "saving a deny rule of a model provider's host" do
    @describetag needs: :factory

    defp provider!(scope, attrs) do
      {:ok, provider} =
        Connections.create_provider(
          scope,
          Map.merge(%{keys: [%{value_id: "main", value: "sk-hosts-test-0123456789"}]}, attrs)
        )

      provider
    end

    defp refused(provider, host) do
      %{
        reason: :integration_host,
        details: %{
          connection: %{id: provider.id, public_id: provider.public_id, name: provider.name},
          host: host
        },
        message:
          "Remove #{host} from the rule. #{provider.name} needs this host, so no rule can deny it."
      }
    end

    test "is refused at the workspace, at a target and at the level above", %{scope: scope} do
      provider = provider!(scope, %{provider: "anthropic"})
      target = target!(scope, "acme/site")
      expected = refused(provider, "api.anthropic.com")

      for holder <- [nil, target] do
        assert {:error, %Error{} = error} =
                 Policy.deny(scope, holder, %{host: "api.anthropic.com"})

        assert Map.take(error, [:reason, :details, :message]) == expected
      end

      for place <- [:workspace, :above] do
        assert {:error, %Error{} = error} = Policy.check_deny(scope, place, "api.anthropic.com")
        assert Map.take(error, [:reason, :details, :message]) == expected
      end

      # A *. deny that covers it saves, and the provider's host is in no workspace document.
      assert {:ok, _rule} = Policy.deny(scope, nil, %{host: "*.anthropic.com"})
      assert {:ok, _rule} = Policy.deny(scope, target, %{host: "*.anthropic.com"})
      assert Policy.check_deny(scope, :above, "*.anthropic.com") == :ok
      refute Map.has_key?(served(scope, nil), "allow_first")
      assert Policy.list_rules(scope, nil) |> Enum.map(& &1.host) == ["*.anthropic.com"]
    end

    test "is refused for an endpoint a setting has", %{scope: scope} do
      provider =
        provider!(scope, %{
          provider: "litellm",
          settings: %{"address" => "https://litellm.example.com"}
        })

      assert {:error, %Error{} = error} =
               Policy.deny(scope, nil, %{host: "litellm.example.com"})

      assert Map.take(error, [:reason, :details, :message]) ==
               refused(provider, "litellm.example.com")
    end

    test "is refused only where the provider reaches", %{scope: scope, user: user} do
      site = workspace!(scope, "Site")
      at_site = workspace_scope(user, site)

      provider =
        provider!(scope, %{
          provider: "anthropic",
          applies_to: "selected",
          workspace_ids: [site.id]
        })

      assert {:ok, _rule} = Policy.deny(scope, nil, %{host: "api.anthropic.com"})

      assert {:error, %Error{details: %{connection: %{id: id}}}} =
               Policy.deny(at_site, nil, %{host: "api.anthropic.com"})

      assert id == provider.id
    end
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
