defmodule Apiary.Connections.WorkspaceKeysTest do
  # A model provider added for one workspace (`Apiary.Connections.create_provider/3` with
  # `:workspace`): its keys are a secret of that workspace, it reaches that workspace
  # alone and never another, its keys are written only as the provider's, read for sealing
  # under the workspace's data key, and listed with their provider at each level
  # (`Apiary.Secrets.list_provider_keys/2`).
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures

  alias Apiary.{Connections, Secrets}
  alias Apiary.Connections.Connection
  alias Apiary.Secrets.{DataKey, Secret, Value}

  @moduletag needs: :factory

  @key "sk-workspace-key-0123456789"

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope}
  end

  defp provider!(scope, place, attrs \\ %{}) do
    {:ok, provider} =
      Connections.create_provider(
        scope,
        Map.merge(%{provider: "anthropic", keys: [%{value_id: "main", value: @key}]}, attrs),
        place
      )

    provider
  end

  defp other_workspace(scope) do
    workspace = workspace_fixture(scope.organisation, "Billing")
    {workspace, workspace_scope(scope.user, workspace)}
  end

  describe "adding a provider for the workspace" do
    test "keeps its keys as the workspace's secret, and reaches that workspace alone",
         %{scope: scope} do
      provider = provider!(scope, :workspace, %{applies_to: "all"})

      assert %Connection{applies_to: "selected", default_value_id: "main", intact: true} =
               provider

      assert Connections.workspace_ids_of(provider) == [scope.workspace.id]

      assert %Secret{workspace_id: workspace_id, organisation_id: organisation_id} =
               secret = Repo.get!(Secret, provider.secret_id)

      assert workspace_id == scope.workspace.id
      assert organisation_id == scope.organisation.id

      # Encrypted under the workspace's data key, never the organisation's.
      for value <- Repo.all(from v in Value, where: v.secret_id == ^secret.id) do
        assert value.workspace_id == scope.workspace.id
        assert is_nil(value.organisation_data_key_id)
        assert %DataKey{workspace_id: ^workspace_id} = Repo.get!(DataKey, value.data_key_id)
      end

      # Left out of the workspace's secrets, as the organisation's are.
      assert {:ok, []} = Secrets.list_secrets(scope)
      assert Secrets.get_secret(scope, secret.public_id) == {:error, :not_found}
    end

    test "at the organisation, keeps its keys as the organisation's secret, as before",
         %{scope: scope} do
      provider = provider!(scope, :organisation)
      assert provider.applies_to == "all"
      assert %Secret{workspace_id: nil} = Repo.get!(Secret, provider.secret_id)
      assert provider_keys!(scope, :organisation) |> Enum.map(& &1.provider.id) == [provider.id]
      assert provider_keys!(scope, :workspace) == []
    end

    test "is refused without a workspace, and for the operator's chain", %{scope: scope} do
      no_workspace = %{scope | workspace: nil}

      assert Connections.create_provider(
               no_workspace,
               %{provider: "anthropic", keys: [%{value_id: "main", value: @key}]},
               :workspace
             ) == {:error, :workspace_not_found}

      assert Connections.create_provider(
               scope,
               %{
                 provider: "anthropic",
                 chain: "operator",
                 keys: [%{value_id: "main", value: @key}]
               },
               :workspace
             ) == {:error, :forbidden}

      assert Repo.aggregate(Connection, :count) == 0
      assert Repo.aggregate(Secret, :count) == 0
    end
  end

  describe "the reach of a provider added for one workspace" do
    test "no change of applies_to, nor another workspace added", %{scope: scope} do
      provider = provider!(scope, :workspace)
      {billing, _billing_scope} = other_workspace(scope)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Connections.update_provider(scope, provider, %{applies_to: "all"})

      assert [applies_to: {message, bindings}] = changeset.errors

      assert message ==
               "To share this provider, add it again with “Available to every workspace in %{organisation}” on. Its key is a secret of %{workspace}."

      assert bindings[:organisation] == scope.organisation.name
      assert bindings[:workspace] == scope.workspace.name

      assert {:error, %Ecto.Changeset{errors: [applies_to: {^message, _}]}} =
               Connections.put_workspace(scope, provider, billing.id)

      reread = Repo.get!(Connection, provider.id)
      assert reread.applies_to == "selected"
      assert Connections.workspace_ids_of(reread) == [scope.workspace.id]

      # Another change of it goes on, and so does a workspace it lists already.
      assert {:ok, %Connection{name: "Payments key"}} =
               Connections.update_provider(scope, provider, %{name: "Payments key"})

      assert {:ok, _same} = Connections.put_workspace(scope, provider, scope.workspace.id)
    end

    test "a provider of the organisation keeps the reach of its add too", %{scope: scope} do
      provider = provider!(scope, :organisation, %{applies_to: "selected"})
      {billing, _billing_scope} = other_workspace(scope)

      assert Connections.put_workspace(scope, provider, billing.id) == {:error, :reach_fixed}

      assert Connections.update_provider(scope, provider, %{applies_to: "all"}) ==
               {:error, :reach_fixed}

      assert Repo.get!(Connection, provider.id).applies_to == "selected"
    end
  end

  describe "the keys of a provider added for one workspace" do
    test "are written through the provider, under provider.write", %{scope: scope} do
      provider = provider!(scope, :workspace)

      assert {:ok, _} =
               Connections.add_provider_key(scope, provider, %{value_id: "spare", value: "x"})

      assert {:ok, _} = Connections.set_provider_key(scope, provider, "spare", "y")
      assert {:ok, _} = Connections.rename_provider_key(scope, provider, "spare", "backup")
      assert values(provider) == ["backup", "main"]

      assert Secrets.reveal_for_sealing(Repo.get!(Connection, provider.id), "backup") ==
               {:ok, "y"}

      assert {:ok, _} = Connections.delete_provider_key(scope, provider, "backup")
      assert values(provider) == ["main"]

      changes =
        Repo.all(
          from e in Apiary.Audit.Entry,
            where: e.subject_id == ^provider.id,
            order_by: [asc: e.inserted_at, asc: e.id],
            select: {e.action, e.details["change"]}
        )

      assert changes == [
               {"provider.write", "provider_created"},
               {"provider.write", "provider_keys_changed"},
               {"provider.write", "provider_keys_changed"},
               {"provider.write", "provider_keys_changed"},
               {"provider.write", "provider_keys_changed"}
             ]

      refute Repo.exists?(from e in Apiary.Audit.Entry, where: e.action == "secret.write")

      # A member may not.
      %{scope: member} = member_fixture(scope, :member)

      assert Connections.set_provider_key(member, provider, "main", "z") ==
               {:error, :forbidden}
    end

    test "are not written as a secret of the workspace", %{scope: scope} do
      provider = provider!(scope, :workspace)
      secret = Repo.get!(Secret, provider.secret_id) |> Repo.preload(:values)

      assert Secrets.set_value(scope, secret, "main", "z") == {:error, :not_found}

      assert Secrets.add_value(scope, secret, %{value_id: "b", value: "z"}) ==
               {:error, :not_found}

      assert Secrets.rename_value(scope, secret, "main", "b") == {:error, :not_found}
      assert Secrets.update_secret(scope, secret, %{name: "TAKEN"}) == {:error, :not_found}
      assert Secrets.delete_secret(scope, secret) == {:error, :not_found}

      # Nor as the keys of another provider.
      other = provider!(scope, :organisation)

      assert Secrets.set_value(scope, secret, "main", "z", provider: other) ==
               {:error, :not_found}

      assert Secrets.reveal_for_sealing(Repo.get!(Connection, provider.id), "main") ==
               {:ok, @key}
    end

    test "go with the provider", %{scope: scope} do
      provider = provider!(scope, :workspace)
      assert {:ok, _deleted} = Connections.delete_provider(scope, provider)
      assert Repo.get(Secret, provider.secret_id) == nil
      assert Repo.aggregate(Value, :count) == 0
    end
  end

  describe "list_provider_keys/2" do
    test "lists each level's keys with their provider, never a value", %{scope: scope} do
      here = provider!(scope, :workspace, %{name: "Payments key"})
      shared = provider!(scope, :organisation, %{name: "Shared key"})
      {_billing, billing_scope} = other_workspace(scope)
      there = provider!(billing_scope, :workspace, %{name: "Billing key"})

      assert [%{secret: secret, provider: provider, value_ids: ["main"]}] =
               provider_keys!(scope, :workspace)

      assert provider.id == here.id
      assert secret.id == here.secret_id
      assert [%Value{value_id: "main", ciphertext: nil, nonce: nil}] = secret.values

      assert [%{provider: %Connection{id: billing_id}}] =
               provider_keys!(billing_scope, :workspace)

      assert billing_id == there.id

      assert [%{provider: %Connection{id: shared_id}, value_ids: ["main"]}] =
               provider_keys!(scope, :organisation)

      assert shared_id == shared.id
      refute inspect(provider_keys!(scope, :workspace)) =~ @key
    end

    test "every member reads them; nobody without a workspace at the workspace level",
         %{scope: scope} do
      provider!(scope, :workspace)
      %{scope: member} = member_fixture(scope, :member)
      assert [_one] = provider_keys!(member, :workspace)

      assert Secrets.list_provider_keys(%{scope | workspace: nil}, :workspace) ==
               {:error, :not_found}

      %{scope: other} = sign_up_fixture()
      assert provider_keys!(other, :workspace) == []
      assert provider_keys!(other, :organisation) == []
    end
  end

  defp provider_keys!(scope, level) do
    {:ok, keys} = Secrets.list_provider_keys(scope, level)
    keys
  end

  defp values(provider) do
    Repo.all(
      from v in Value,
        where: v.secret_id == ^provider.secret_id,
        order_by: v.value_id,
        select: v.value_id
    )
  end
end
