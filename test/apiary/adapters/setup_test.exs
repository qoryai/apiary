defmodule Apiary.Adapters.SetupTest do
  # Starting an adapter's set-up (`Apiary.Adapters.setup/2`, `adapter.setup`): to an
  # instance admin, a new setup pass each time, signed under the instance's key, on the
  # adapter's setup_url as its `state`; one entry in the trail of the instance's
  # organisation, without the pass; nothing kept of the pass; and the refusals, which
  # change nothing.
  use Apiary.DataCase, async: true

  import Ecto.Query
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{AccessKeys, Adapters, Edition, SigningKey}
  alias Apiary.Adapters.SetupPass
  alias Apiary.Audit.Entry
  alias Apiary.Nodes.Node

  @moduletag needs: :factory

  setup do
    %{adapter: adapter, access_key: key} =
      settable_adapter_fixture(%{name: unique_adapter_name("Acme tracker")})

    %{admin: instance_admin_scope(), adapter: adapter, key: key}
  end

  defp entries,
    do:
      Repo.all(
        from e in Entry, where: e.action == "adapter.setup", order_by: [asc: e.inserted_at]
      )

  defp pass_of(url) do
    assert "https://tracker.example.com/setup?site=main&state=" <> pass = url
    pass
  end

  test "an instance admin is given the setup_url with a new pass as its state, signed under the instance's key",
       %{admin: admin, adapter: adapter} do
    now = DateTime.utc_now()
    assert {:ok, url} = Adapters.setup(admin, adapter)
    pass = pass_of(url)

    assert {:ok, %{adapter_id: adapter_id, expires_at: expires_at}} =
             SetupPass.verify(pass, SigningKey.public_key(), now: now)

    assert adapter_id == adapter.public_id
    assert DateTime.diff(expires_at, now, :second) in 899..900

    # Each use gives a new pass.
    assert {:ok, again} = Adapters.setup(admin, adapter)
    assert pass_of(again) != pass
  end

  test "one entry each time, in the instance's trail, about the adapter, never with the pass",
       %{admin: admin, adapter: adapter} do
    before = Repo.get!(Node, adapter.id)
    {:ok, url} = Adapters.setup(admin, adapter)
    pass = pass_of(url)
    [payload, _signature] = String.split(pass, ".")
    nonce = payload |> Base.url_decode64!(padding: false) |> Jason.decode!() |> Map.get("nonce")

    assert [entry] = entries()
    assert entry.organisation_id == Edition.instance_organisation_id()
    assert {entry.subject_kind, entry.subject_id} == {"node", adapter.id}
    assert {entry.actor_kind, entry.actor_id} == {:person, admin.user.id}
    assert entry.details == %{"name" => adapter.name, "public_id" => adapter.public_id}

    stored = inspect(Map.from_struct(entry))
    refute stored =~ pass
    refute stored =~ nonce

    # Nothing of the pass is kept on the adapter either.
    assert Repo.get!(Node, adapter.id) == before
  end

  test "while the adapter declares no setup_url, it is refused :no_setup_url, and nothing changes",
       %{admin: admin, adapter: adapter} do
    {1, _} = Repo.update_all(from(n in Node, where: n.id == ^adapter.id), set: [setup_url: nil])
    assert Adapters.setup(admin, adapter) == {:error, :no_setup_url}
    assert entries() == []
  end

  test "while it holds no key in use, it is refused :no_key, and nothing changes",
       %{admin: admin, adapter: adapter, key: key} do
    {:ok, _} = AccessKeys.revoke_access_key(admin, key)
    assert Adapters.setup(admin, adapter) == {:error, :no_key}
    assert entries() == []
  end

  # Where the feature is off, it is not found to everyone: `Apiary.AdaptersWithoutFactoryTest`.
  test "anyone but an instance admin is refused, and a deleted adapter is not found",
       %{admin: admin, adapter: adapter} do
    %{scope: owner} = sign_up_fixture()
    assert Adapters.setup(owner, adapter) == {:error, :forbidden}

    {:ok, _} = Adapters.delete_adapter(admin, adapter)
    assert Adapters.setup(admin, adapter) == {:error, :not_found}
    assert entries() == []
  end
end
