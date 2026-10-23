defmodule Apiary.Connections.WriteActionsTest do
  # A write to a connection is asked under the action for what it writes: `provider.write`
  # for a model provider, `runtime.write` for a runtime and `connection.write` for an
  # integration and a service. An edition refuses each of the three alone
  # (`Apiary.EditionStubs.NoConnectionWrite`, `NoRuntimeWrite` and `NoProviderWrite`), and
  # the other two are still taken.
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.{Audit, Connections, ModelChoices}
  alias Apiary.Audit.Entry
  alias Apiary.Connections.Connection
  alias Apiary.EditionStubs

  # A model provider needs `factory` and `secrets`, and a runtime and a service `secrets`.
  @moduletag needs: :factory

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope, site: workspace_fixture(scope.organisation, "Site")}
  end

  defp stub(stub), do: :ok = Apiary.Edition.put_test_stub(stub)

  defp provider!(scope) do
    {:ok, provider} =
      Connections.create_provider(scope, %{
        provider: "openrouter",
        keys: [%{value_id: "main", value: "sk-write-actions-1"}]
      })

    provider
  end

  defp runtime!(scope) do
    {:ok, runtime} = Connections.create_runtime(scope, %{runtime: "claude"})
    runtime
  end

  defp service!(scope) do
    {:ok, service} = Connections.create_service(scope, %{service: "sentry"})
    service
  end

  defp actions(connection) do
    Repo.all(
      from e in Entry,
        where: e.subject_id == ^connection.id,
        order_by: [asc: e.inserted_at, asc: e.id],
        select: e.action
    )
  end

  test "write_action/1 is the action for the kind of the connection" do
    assert Connections.write_action(%Connection{kind: "runtime"}) == :"runtime.write"
    assert Connections.write_action(%Connection{kind: "service"}) == :"connection.write"

    assert Connections.write_action(%Connection{kind: "integration"}) == :"connection.write"

    assert Connections.write_action(%Connection{kind: "integration", provider_kind: "openrouter"}) ==
             :"provider.write"
  end

  test "each write leaves an entry of its own action", %{scope: scope, site: site} do
    runtime = runtime!(scope)
    {:ok, runtime} = Connections.put_workspace(scope, runtime, site.id)
    {:ok, runtime} = Connections.remove_workspace(scope, runtime, site.id)
    {:ok, _deleted} = Connections.delete_connection(scope, runtime)
    assert actions(runtime) == List.duplicate("runtime.write", 4)

    service = service!(scope)
    {:ok, service} = Connections.put_workspace(scope, service, site.id)
    {:ok, _service} = Connections.update_connection(scope, service, %{name: "Errors"})
    assert actions(service) == List.duplicate("connection.write", 3)

    provider = provider!(scope)
    {:ok, provider} = Connections.update_provider(scope, provider, %{name: "Models"})
    {:ok, provider} = Connections.add_provider_model(scope, provider, %{model_id: "acme/m1"})
    {:ok, provider} = Connections.put_default_model(scope, provider, "acme/m1")
    {:ok, provider} = Connections.add_provider_key(scope, provider, %{value_id: "x", value: "k"})
    {:ok, provider} = Connections.put_default_key(scope, provider, "x")
    {:ok, _deleted} = Connections.delete_provider(scope, provider)
    assert actions(provider) == List.duplicate("provider.write", 7)
  end

  test "the organisation's default model choice is written under provider.write", %{scope: scope} do
    provider = provider!(scope)
    {:ok, choice} = ModelChoices.put_choice(scope, :organisation, %{provider: provider.public_id})

    assert [%Entry{action: "provider.write", details: %{"change" => "choice_set"}}] =
             Repo.all(from e in Entry, where: e.subject_id == ^choice.id)
  end

  describe "where an edition refuses connection.write alone" do
    test "runtimes and model providers are still written", %{scope: scope} do
      provider = provider!(scope)
      other = provider!(scope)
      stub(EditionStubs.NoConnectionWrite)

      assert {:ok, runtime} = Connections.create_runtime(scope, %{runtime: "claude"})
      assert {:ok, _runtime} = Connections.put_workspace(scope, runtime, scope.workspace.id)
      assert {:ok, _provider} = Connections.update_provider(scope, provider, %{name: "Models"})

      assert {:ok, _choice} =
               ModelChoices.put_choice(scope, :organisation, %{provider: provider.public_id})

      assert {:ok, _provider} = Connections.delete_provider(scope, other)
      assert {:ok, _runtime} = Connections.delete_connection(scope, runtime)
    end

    test "integrations and services are refused", %{scope: scope} = ctx do
      service = service!(scope)
      stub(EditionStubs.NoConnectionWrite)

      assert Connections.create_service(scope, %{service: "sentry"}) == {:error, :forbidden}

      assert Connections.update_connection(scope, service, %{name: "Errors"}) ==
               {:error, :forbidden}

      assert Connections.put_workspace(scope, service, ctx.site.id) == {:error, :forbidden}
      assert Connections.delete_connection(scope, service) == {:error, :forbidden}
      assert Connections.create_service_definition(scope, %{}) == {:error, :forbidden}
    end
  end

  describe "where an edition refuses runtime.write alone" do
    test "a runtime is refused, and a service and a model provider are written", ctx do
      %{scope: scope, site: site} = ctx
      runtime = runtime!(scope)
      service = service!(scope)
      provider = provider!(scope)
      stub(EditionStubs.NoRuntimeWrite)

      assert Connections.create_runtime(scope, %{runtime: "claude"}) == {:error, :forbidden}
      assert Connections.put_workspace(scope, runtime, site.id) == {:error, :forbidden}

      assert Connections.update_connection(scope, runtime, %{applies_to: "all"}) ==
               {:error, :forbidden}

      assert Connections.delete_connection(scope, runtime) == {:error, :forbidden}

      assert {:ok, _service} = Connections.put_workspace(scope, service, site.id)
      assert {:ok, _provider} = Connections.update_provider(scope, provider, %{name: "Models"})
    end
  end

  describe "where an edition refuses provider.write alone" do
    test "a model provider and the default model choice are refused, a runtime is written", ctx do
      %{scope: scope} = ctx
      provider = provider!(scope)
      runtime = runtime!(scope)
      stub(EditionStubs.NoProviderWrite)

      assert Connections.create_provider(scope, %{provider: "openrouter", keys: []}) ==
               {:error, :forbidden}

      assert Connections.update_provider(scope, provider, %{name: "Models"}) ==
               {:error, :forbidden}

      assert Connections.delete_provider(scope, provider) == {:error, :forbidden}

      assert Connections.update_connection(scope, provider, %{name: "Models"}) ==
               {:error, :forbidden}

      assert Connections.add_provider_model(scope, provider, %{model_id: "acme/m1"}) ==
               {:error, :forbidden}

      assert Connections.add_provider_key(scope, provider, %{value_id: "x", value: "k"}) ==
               {:error, :forbidden}

      assert Connections.put_default_model(scope, provider, "acme/m1") == {:error, :forbidden}

      assert ModelChoices.put_choice(scope, :organisation, %{provider: provider.public_id}) ==
               {:error, :forbidden}

      assert {:ok, _runtime} = Connections.put_workspace(scope, runtime, scope.workspace.id)
    end
  end

  test "the Action filter's connection.write finds the entries of the three actions", ctx do
    %{scope: scope} = ctx
    runtime!(scope)
    service!(scope)
    provider!(scope)

    assert {:ok, %{entries: all}} = Audit.list_entries(scope, %{action: "connection.write"}, 1)

    assert all |> Enum.map(& &1.action) |> Enum.sort() ==
             ["connection.write", "provider.write", "runtime.write"]

    assert {:ok, %{entries: [%Entry{action: "runtime.write"}]}} =
             Audit.list_entries(scope, %{action: "runtime.write"}, 1)
  end
end
