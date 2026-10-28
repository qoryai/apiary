defmodule Apiary.Adapters.ConfiguredTest do
  # Whether an adapter is configured (`Apiary.Adapters.configured?/1`): it declared a
  # connect address, holds an access key in use, declares no `setup_url`, and, where it is
  # installed with Qory Apiary, `QORY_INSTALLED_ADAPTERS` lists it; and the
  # configured adapters that serve a domain (`Apiary.Adapters.list_configured/1`).
  # `Apiary.AdaptersWithoutFactoryTest` lists none where the feature is off.
  #
  # Not async: a test changes the adapters `QORY_INSTALLED_ADAPTERS` lists.
  use Apiary.DataCase, async: false

  import Ecto.Query
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Adapters, Repo}
  alias Apiary.Lingo.Domain.{Example, Software}
  alias Apiary.Nodes.Node

  @moduletag needs: :factory

  # `adapter` with `fields` written straight into its row, as its start would write them.
  defp put(adapter, fields) do
    {1, _} = Repo.update_all(from(n in Node, where: n.id == ^adapter.id), set: fields)
    Repo.get!(Node, adapter.id)
  end

  # A configured adapter whose name starts with `name`, serving `domains`, nil for every
  # domain. The suffix keeps the name free of another test's, which runs at the same time.
  defp configured(name, domains \\ nil) do
    name = "#{name}-#{System.unique_integer([:positive])}"
    %{adapter: adapter} = connectable_adapter_fixture(%{name: name})
    put(adapter, domains: domains)
  end

  # The adapters `list_configured/1` gives for `domain`, among the adapters `made`, in
  # order, by id.
  defp listed(domain, made) do
    ids = MapSet.new(made, & &1.id)
    for adapter <- Adapters.list_configured(domain), adapter.id in ids, do: adapter.id
  end

  defp ids(adapters), do: Enum.map(adapters, & &1.id)

  setup do
    saved_list = Application.fetch_env(:apiary, :installed_adapters)

    on_exit(fn ->
      case saved_list do
        {:ok, names} -> Application.put_env(:apiary, :installed_adapters, names)
        :error -> Application.delete_env(:apiary, :installed_adapters)
      end
    end)
  end

  # A configured adapter installed with Qory Apiary as a name `QORY_INSTALLED_ADAPTERS`
  # does not list yet: it is set up and may be connected.
  defp unlisted do
    name = "tracker-#{System.unique_integer([:positive])}"
    Application.put_env(:apiary, :installed_adapters, [])
    adapter = configured("tracker-installed")
    put(adapter, installed_as: name)
  end

  describe "configured?/1" do
    test "an adapter with a connect address, a key in use and no setup_url is configured" do
      %{adapter: adapter} = connectable_adapter_fixture()
      assert Adapters.configured?(adapter)
    end

    test "an adapter that declares a setup_url is not configured" do
      %{adapter: adapter} = settable_adapter_fixture()
      refute Adapters.configured?(adapter)
      assert Adapters.configured?(put(adapter, setup_url: nil))
    end

    test "an adapter that declared no connect address is not configured" do
      %{adapter: adapter} = connectable_adapter_fixture()
      refute Adapters.configured?(put(adapter, connect_url: nil))
    end

    test "an adapter with no key is not configured" do
      adapter = put(adapter_fixture(), connect_url: "https://tracker.example.com/connect")
      refute Adapters.configured?(adapter)
    end

    test "an adapter whose key is revoked is not configured" do
      %{adapter: adapter, access_key: key} = connectable_adapter_fixture()
      {:ok, _revoked} = Adapters.revoke_key(instance_admin_scope(), key)
      refute Adapters.configured?(adapter)
    end

    test "an installed adapter is configured only while QORY_INSTALLED_ADAPTERS lists it" do
      adapter = unlisted()
      refute Adapters.configured?(adapter)

      Application.put_env(:apiary, :installed_adapters, [adapter.installed_as])
      assert Adapters.configured?(adapter)
    end
  end

  describe "list_configured/1" do
    test "lists the configured adapters that serve the domain, by name" do
      all = configured("tracker-c")
      both = configured("tracker-b", ["software", "example"])
      example = configured("tracker-d", ["example"])
      made = [all, both, example]

      assert listed(Software, made) == ids([both, all])
      assert listed(Example, made) == ids([both, all, example])
    end

    test "an adapter that lists no domains serves every domain" do
      all = configured("tracker-all")

      for domain <- [Software, Example],
          do: assert(listed(domain, [all]) == [all.id])
    end

    test "leaves out the adapters that are not configured" do
      ready = configured("tracker-ready")
      %{adapter: unset} = settable_adapter_fixture()
      no_key = put(adapter_fixture(), connect_url: "https://tracker.example.com/connect")
      %{adapter: no_address} = connectable_adapter_fixture()
      no_address = put(no_address, connect_url: nil)
      %{adapter: revoked, access_key: key} = connectable_adapter_fixture()
      {:ok, _revoked} = Adapters.revoke_key(instance_admin_scope(), key)

      assert listed(Software, [ready, unset, no_key, no_address, revoked]) == [ready.id]
    end

    test "leaves out a deleted adapter" do
      adapter = configured("tracker-gone")
      {:ok, _deleted} = Adapters.delete_adapter(instance_admin_scope(), adapter)
      assert listed(Software, [adapter]) == []
    end

    test "leaves out an installed adapter until QORY_INSTALLED_ADAPTERS lists it" do
      adapter = unlisted()
      assert listed(Software, [adapter]) == []

      Application.put_env(:apiary, :installed_adapters, [adapter.installed_as])
      assert listed(Software, [adapter]) == [adapter.id]
    end
  end
end
