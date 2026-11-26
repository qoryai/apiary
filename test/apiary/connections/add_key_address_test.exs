defmodule Apiary.Connections.AddKeyAddressTest do
  # The address of a LiteLLM key is part of its key group (`Apiary.Connections.add_key/2`):
  # a key with another address goes to another provider. LiteLLM needs the feature Model
  # proxies, which changes the features of the whole node, so the tests are not async.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures

  import Ecto.Query, only: [from: 2]
  alias Apiary.Connections

  @moduletag needs: :factory

  setup {Apiary.DataCase, :with_model_proxies}

  defp add!(scope, address) do
    {:ok, provider, value_id} = add(scope, address)
    {provider, value_id}
  end

  defp add(scope, address),
    do:
      Connections.add_key(scope, %{
        "provider" => "litellm",
        "value" => "sk-litellm-0123456789abcdef",
        "applies_to" => "all",
        "settings" => %{"address" => address}
      })

  test "another address makes another provider" do
    %{scope: scope} = sign_up_fixture()

    {first, "key-1"} = add!(scope, "https://litellm.example.com")
    {same, "key-2"} = add!(scope, "https://litellm.example.com")
    {other, "key-3"} = add!(scope, "https://proxy.example.com")

    assert same.id == first.id
    refute other.id == first.id
  end

  test "with Model proxies off, a key for a LiteLLM provider that exists is refused" do
    %{scope: scope} = sign_up_fixture()
    {provider, "key-1"} = add!(scope, "https://litellm.example.com")

    Application.put_env(:apiary, :features, Apiary.Features.enabled() -- [:model_proxies])

    assert {:error, %Ecto.Changeset{errors: [provider_kind: _error]}} =
             add(scope, "https://litellm.example.com")

    assert Apiary.Repo.aggregate(
             from(v in Apiary.Secrets.Value, where: v.secret_id == ^provider.secret_id),
             :count
           ) == 1
  end

  test "a key that moves to a new provider keeps its address, and its group" do
    %{scope: scope} = sign_up_fixture()
    {every, "key-1"} = add!(scope, "https://litellm.example.com")
    {_every, "key-2"} = add!(scope, "https://litellm.example.com")

    assert {:ok, moved_to} =
             Connections.update_provider_key(scope, every, "key-2", %{
               "value_id" => "key-2",
               "applies_to" => "selected",
               "workspace_ids" => [scope.workspace.id]
             })

    refute moved_to.id == every.id
    assert moved_to.settings == every.settings
    assert Apiary.ModelKeys.Group.same?(moved_to, every)
  end
end
