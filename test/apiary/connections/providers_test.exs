defmodule Apiary.Connections.ProvidersTest do
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import ExUnit.CaptureLog

  alias Apiary.{Connections, ModelKeys, Secrets}
  alias Apiary.Audit.Entry
  alias Apiary.Connections.Connection
  alias Apiary.Kinds.Providers
  alias Apiary.ModelKeys.Setting
  alias Apiary.Secrets.{Secret, Value}

  # A model provider needs `factory` and `secrets`; a leg with `factory` has `secrets`
  # too, which `factory` needs.
  @moduletag needs: :factory

  @key "sk-provider-test-0123456789"

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope}
  end

  defp openrouter!(scope, attrs \\ %{}) do
    {:ok, provider} =
      Connections.create_provider(
        scope,
        Map.merge(
          %{
            provider: "openrouter",
            keys: [%{value_id: "main", value: @key}, %{value_id: "spare", value: "sk-spare"}]
          },
          attrs
        )
      )

    provider
  end

  defp litellm(scope, address) do
    Connections.create_provider(scope, %{
      provider: "litellm",
      settings: %{"address" => address},
      keys: [%{value_id: "main", value: @key}]
    })
  end

  defp trail(subject_id),
    do:
      Repo.all(
        from e in Entry,
          where: e.subject_id == ^subject_id,
          order_by: [asc: e.inserted_at, asc: e.id]
      )

  defp changes(provider), do: Enum.map(trail(provider.id), & &1.details["change"])

  describe "adding a provider" do
    test "links a secret of its keys and offers the description's models", %{scope: scope} do
      {:ok, catalogue} = Providers.fetch("openrouter")
      provider = openrouter!(scope)

      assert %Connection{
               kind: "integration",
               name: "OpenRouter",
               applies_to: "all",
               provider_kind: "openrouter",
               default_value_id: "main",
               chain: "organisation",
               release_id: nil,
               intact: true
             } = provider

      assert provider.description_ref == Providers.ref()
      assert provider.description_sha256 == catalogue.sha256
      assert Connections.provider_models(provider) == catalogue.models
      assert Connections.default_model(provider) == hd(catalogue.models)["id"]

      assert %Secret{workspace_id: nil, values: values} = provider.secret
      assert Enum.map(values, & &1.value_id) == ["main", "spare"]
      assert Enum.all?(values, &is_nil(&1.ciphertext))

      assert Secrets.reveal_for_sealing(scope.organisation, provider.secret.public_id, "main") !=
               {:ok, nil}

      assert changes(provider) == ["provider_created"]
      assert {:ok, [listed]} = Connections.list_providers(scope)
      assert listed.id == provider.id
      assert {:ok, %Connection{id: id}} = Connections.get_provider(scope, provider.public_id)
      assert id == provider.id
      assert Connections.provider(provider) == {:ok, catalogue}
      assert Connections.description(provider) == {:ok, catalogue.description}
    end

    test "is left out of the other connections", %{scope: scope} do
      provider = openrouter!(scope)
      {:ok, runtime} = Connections.create_runtime(scope, %{runtime: "claude"})

      assert {:ok, [%Connection{id: id}]} = Connections.list_connections(scope)
      assert id == runtime.id
      assert Connections.get_connection(scope, provider.public_id) == {:error, :not_found}
      assert Connections.get_provider(scope, runtime.public_id) == {:error, :not_found}
    end

    test "takes a name, a default key and the keys of a form", %{scope: scope} do
      provider =
        openrouter!(scope, %{
          name: " Team models ",
          keys: %{
            "1" => %{"value_id" => "spare", "value" => "y"},
            "0" => %{"value_id" => "main", "value" => "x"}
          },
          default_key: "spare"
        })

      assert provider.name == "Team models"
      assert provider.default_value_id == "spare"
      assert Enum.map(provider.secret.values, & &1.value_id) == ["main", "spare"]
    end

    test "refuses a provider the catalogue does not have", %{scope: scope} do
      assert Connections.create_provider(scope, %{provider: "nothing", keys: []}) ==
               {:error, :provider_unknown}
    end

    test "refuses a default key that is not among its keys, and writes nothing",
         %{scope: scope} do
      assert {:error, changeset} =
               Connections.create_provider(scope, %{
                 provider: "openrouter",
                 keys: [%{value_id: "main", value: "x"}],
                 default_key: "other"
               })

      assert errors_on(changeset).default_value_id == [
               "Choose one of OpenRouter's keys: other is not one of them."
             ]

      assert Repo.aggregate(Connection, :count) == 0
      assert Repo.aggregate(from(s in Secret, where: is_nil(s.workspace_id)), :count) == 0
    end

    test "refuses keys the secret refuses", %{scope: scope} do
      assert {:error, %Ecto.Changeset{data: %Secret{}}} =
               Connections.create_provider(scope, %{
                 provider: "openrouter",
                 keys: [%{value_id: "Main", value: "x"}]
               })

      assert Repo.aggregate(Connection, :count) == 0
    end

    test "checks each address setting by the endpoint rule", %{scope: scope} do
      for {address, message} <- [
            {"http://models.example.com",
             "Start the address with https://, such as https://models.example.com."},
            {"https://models.localhost",
             "Enter the host that runs reach over the network. models.localhost is a name for the local machine."},
            {"https://models.example.com?x=1",
             "Remove the ? and everything after it. The address takes a path, but no query or fragment."},
            {"https://127.0.0.1",
             "Enter another host. Runs may not reach 127.0.0.1: it is in 127.0.0.0/8."}
          ] do
        assert {:error, changeset} = litellm(scope, address)
        assert errors_on(changeset).settings == [message]
        assert {_message, opts} = changeset.errors[:settings]
        assert opts[:setting] == "address"
      end

      assert {:error, changeset} =
               Connections.create_provider(scope, %{
                 provider: "litellm",
                 keys: [%{value_id: "main", value: "x"}]
               })

      assert errors_on(changeset).settings == [
               "Start the address with https://, such as https://models.example.com."
             ]

      assert Repo.aggregate(Connection, :count) == 0
      assert {:ok, provider} = litellm(scope, "https://litellm.example.com")
      assert Connections.provider_models(provider) == []
      assert Connections.default_model(provider) == nil
      assert Connection.settings_map(provider) == %{"address" => "https://litellm.example.com"}
    end

    test "refuses a setting the description does not have", %{scope: scope} do
      assert Connections.create_provider(scope, %{
               provider: "openrouter",
               settings: %{"address" => "https://models.example.com"},
               keys: [%{value_id: "main", value: "x"}]
             }) == {:error, {:integration_settings_not_allowed, ["address"]}}
    end

    test "is for a reader with provider.write only", %{scope: scope} do
      %{scope: member} = member_fixture(scope)
      provider = openrouter!(scope)

      assert Connections.create_provider(member, %{
               provider: "openrouter",
               keys: [%{value_id: "main", value: "x"}]
             }) == {:error, :forbidden}

      assert {:ok, [_provider]} = Connections.list_providers(member)

      assert Connections.update_provider(member, provider, %{name: "Other"}) ==
               {:error, :forbidden}

      assert Connections.delete_provider(member, provider) == {:error, :forbidden}

      # The keys go by the same answer, not by the edition's.
      assert Connections.delete_provider_key(member, provider, "spare") == {:error, :forbidden}
    end

    test "is not found in another organisation", %{scope: scope} do
      provider = openrouter!(scope)
      %{scope: other} = sign_up_fixture()

      assert Connections.get_provider(other, provider.public_id) == {:error, :not_found}

      assert Connections.update_provider(other, provider, %{name: "Other"}) ==
               {:error, :not_found}

      assert Connections.delete_provider(other, provider) == {:error, :not_found}
    end
  end

  describe "changing a provider" do
    test "renames it, and keeps where it applies as its add set it", %{scope: scope} do
      provider = openrouter!(scope)

      assert {:ok, %Connection{name: "Team models", intact: true}} =
               Connections.update_provider(scope, provider, %{name: "Team models"})

      assert Connections.update_connection(scope, provider, %{applies_to: "selected"}) ==
               {:error, :reach_fixed}

      assert Connections.update_provider(scope, provider, %{applies_to: "selected"}) ==
               {:error, :reach_fixed}

      assert Repo.get!(Connection, provider.id).applies_to == "all"
      assert changes(provider) == ["provider_created", "updated"]
    end

    test "enters a change of address with its host before and after", %{scope: scope} do
      {:ok, provider} = litellm(scope, "https://litellm.example.com")

      assert {:ok, provider} =
               Connections.update_provider(scope, provider, %{
                 settings: %{"address" => "https://models.example.org/proxy"}
               })

      assert {:ok, ^provider} =
               Connections.update_provider(scope, provider, %{
                 settings: %{"address" => "https://models.example.org/proxy"}
               })

      assert {:error, changeset} =
               Connections.update_provider(scope, provider, %{
                 settings: %{"address" => "https://Models.example.org"}
               })

      assert errors_on(changeset).settings == [
               "Write the host in lower case: models.example.org."
             ]

      [_created, entry] = trail(provider.id)
      assert entry.details["change"] == "provider_address_changed"
      assert entry.before["host"] == "litellm.example.com"
      assert entry.after["host"] == "models.example.org"
    end

    test "refuses a provider whose description changed since it was added", %{scope: scope} do
      provider = openrouter!(scope)
      changed = %{provider | description_sha256: String.duplicate("0", 64)}

      assert Connections.provider(changed) == {:error, :provider_changed}

      assert Connections.provider(%{provider | provider_kind: "gone"}) ==
               {:error, :provider_unknown}
    end

    test "makes another key its default", %{scope: scope} do
      provider = openrouter!(scope)

      assert {:ok, %Connection{default_value_id: "spare"} = provider} =
               Connections.put_default_key(scope, provider, "spare")

      assert {:ok, ^provider} = Connections.put_default_key(scope, provider, "spare")

      assert {:error, changeset} = Connections.put_default_key(scope, provider, "other")

      assert errors_on(changeset).default_value_id == [
               "Choose one of OpenRouter's keys: other is not one of them."
             ]

      [_created, entry] = trail(provider.id)
      assert entry.details["change"] == "provider_default_key_changed"
      assert entry.before == %{"default_value_id" => "main"}
      assert entry.after == %{"default_value_id" => "spare"}
    end

    test "on an operator's chain is the edition's, and refused", %{scope: scope} do
      provider = openrouter!(scope)

      Repo.update_all(from(c in Connection, where: c.id == ^provider.id),
        set: [chain: "operator"]
      )

      assert Connections.update_provider(scope, provider, %{name: "Other"}) ==
               {:error, :forbidden}

      assert Connections.delete_provider(scope, provider) == {:error, :forbidden}
    end
  end

  describe "the models" do
    test "are the description's, in its order, the first the default", %{scope: scope} do
      provider = openrouter!(scope)
      {:ok, catalogue} = Providers.fetch("openrouter")

      assert [%{"id" => first, "title" => _title} | _rest] =
               Connections.provider_models(provider)

      assert Connections.provider_models(catalogue) == catalogue.models
      assert Connections.default_model(provider) == first
      assert Connections.default_model(catalogue) == first
      refute Map.has_key?(Map.from_struct(provider), :models)
    end

    test "are none once the catalogue no longer has the description", %{scope: scope} do
      provider = openrouter!(scope)

      for changed <- [
            %{provider | description_sha256: String.duplicate("0", 64)},
            %{provider | provider_kind: "gone"}
          ] do
        assert Connections.provider_models(changed) == []
        assert Connections.default_model(changed) == nil
      end
    end
  end

  describe "the keys" do
    test "are entered and changed only through the provider", %{scope: scope} do
      provider = openrouter!(scope)

      assert {:ok, provider} =
               Connections.add_provider_key(scope, provider, %{value_id: "third", value: "z"})

      assert {:ok, provider} = Connections.rename_provider_key(scope, provider, "third", "fourth")
      assert {:ok, provider} = Connections.set_provider_key(scope, provider, "fourth", "w")
      assert {:ok, provider} = Connections.delete_provider_key(scope, provider, "spare")
      assert Enum.map(provider.secret.values, & &1.value_id) == ["fourth", "main"]

      # The default key stays, by its value id.
      for refused <- [
            Connections.delete_provider_key(scope, provider, "main"),
            Connections.rename_provider_key(scope, provider, "main", "first")
          ] do
        assert {:error, changeset} = refused

        assert errors_on(changeset).value_id == [
                 "Choose another default key for OpenRouter first: main is its default key."
               ]
      end

      assert {:error, changeset} =
               Connections.add_provider_key(scope, provider, %{value_id: "Bad", value: "x"})

      assert errors_on(changeset)[:value_id]

      # Each change is the provider's entry, and the keys' secret has none.
      entries = Enum.drop(trail(provider.id), 1)

      assert Enum.map(entries, & &1.details["change"]) ==
               List.duplicate("provider_keys_changed", 4)

      assert Enum.map(entries, &{&1.before, &1.after, &1.details["value_id"]}) == [
               {nil, %{"value_id" => "third"}, "third"},
               {%{"value_id" => "third"}, %{"value_id" => "fourth"}, nil},
               {nil, nil, "fourth"},
               {%{"value_id" => "spare"}, nil, "spare"}
             ]

      refute Repo.exists?(from e in Entry, where: e.subject_id == ^provider.secret_id)
    end

    test "are left out of the organisation's secrets, and not found there", %{scope: scope} do
      Apiary.Edition.put_test_stub(Apiary.EditionStubs.GrantsOrganisationSecrets)
      provider = openrouter!(scope)
      secret = provider.secret

      {:ok, other} =
        Secrets.create_organisation_secret(scope, %{name: "SHARED_TOKEN", value: "x"})

      assert {:ok, [%Secret{id: id}]} = Secrets.list_organisation_secrets(scope)
      assert id == other.id
      assert Secrets.get_organisation_secret(scope, secret.public_id) == {:error, :not_found}
      assert {:ok, %Secret{}} = Secrets.get_organisation_secret(scope, other.public_id)
      assert Secrets.list_uses(scope, [secret]) == {:ok, %{secret.id => []}}

      for refused <- [
            Secrets.update_secret(scope, secret, %{name: "RENAMED"}),
            Secrets.add_value(scope, secret, %{value_id: "third", value: "z"}),
            Secrets.set_value(scope, secret, "main", "y"),
            Secrets.rename_value(scope, secret, "spare", "other"),
            Secrets.delete_value(scope, secret, "spare"),
            Secrets.delete_secret(scope, secret)
          ] do
        assert refused == {:error, :not_found}
      end

      # Nor is another secret written or deleted as a provider's keys: only the secret the
      # provider's row links, in the scope's organisation.
      %{scope: elsewhere} = sign_up_fixture()

      {:ok, foreign} =
        Connections.create_provider(elsewhere, %{
          provider: "openrouter",
          keys: [%{value_id: "main", value: "x"}, %{value_id: "spare", value: "y"}]
        })

      {:ok, runtime} = Connections.create_runtime(scope, %{runtime: "claude"})

      assert Secrets.delete_value(scope, other, nil, provider: provider) == {:error, :not_found}
      assert Secrets.set_value(scope, other, nil, "y", provider: provider) == {:error, :not_found}

      assert Secrets.delete_value(scope, foreign.secret, "spare", provider: provider) ==
               {:error, :not_found}

      assert Secrets.delete_value(scope, foreign.secret, "spare", provider: foreign) ==
               {:error, :not_found}

      for named <- [
            %Connection{id: Ecto.UUID.generate(), secret_id: other.id},
            %{runtime | secret_id: other.id},
            %{foreign | secret_id: other.id},
            foreign
          ] do
        assert Secrets.delete_provider_keys(scope, named, fn -> flunk("unlinked") end) ==
                 {:error, :not_found}
      end

      assert {:ok, %Secret{}} = Secrets.get_organisation_secret(scope, other.public_id)
      assert {:ok, %Connection{}} = Connections.get_provider(elsewhere, foreign.public_id)

      assert {:ok, %Connection{secret: %Secret{name: name, values: values}}} =
               Connections.get_provider(scope, provider.public_id)

      assert name == secret.name
      assert Enum.map(values, & &1.value_id) == ["main", "spare"]
    end

    test "go with the provider", %{scope: scope} do
      provider = openrouter!(scope)

      assert {:ok, %Connection{}} = Connections.delete_provider(scope, provider)
      assert Connections.get_provider(scope, provider.public_id) == {:error, :not_found}
      refute Repo.get(Secret, provider.secret_id)

      assert Repo.aggregate(from(v in Value, where: v.secret_id == ^provider.secret_id), :count) ==
               0

      [_created, entry] = trail(provider.id)
      assert entry.details["change"] == "provider_deleted"
      assert entry.before["provider_kind"] == "openrouter"

      refute Repo.exists?(from e in Entry, where: e.subject_id == ^provider.secret_id)
    end

    test "never reach a log line, an entry or a refusal", %{scope: scope} do
      log =
        capture_log([level: :debug], fn ->
          provider = openrouter!(scope)
          {:ok, provider} = Connections.update_provider(scope, provider, %{name: "Other"})
          {:error, refused} = Connections.put_default_key(scope, provider, "other")
          {:error, keys_refused} = Connections.delete_provider_key(scope, provider, "main")

          {:error, created_refused} =
            Connections.create_provider(scope, %{
              provider: "openrouter",
              keys: [%{value_id: "Bad Id", value: @key}]
            })

          refute inspect(refused) =~ "sk-provider"
          refute inspect(keys_refused) =~ "sk-provider"
          refute inspect(created_refused, limit: :infinity) =~ @key
          {:ok, _provider} = Connections.delete_provider(scope, provider)
        end)

      refute log =~ @key

      for entry <- Repo.all(Entry) do
        refute inspect({entry.details, entry.before, entry.after}, limit: :infinity) =~ @key
      end
    end
  end

  defp value!(provider, value_id),
    do: Repo.get_by!(Value, secret_id: provider.secret_id, value_id: value_id)

  describe "a key's settings" do
    @settings %{
      "reset_weekday" => "1",
      "reset_time" => "09:00",
      "reset_time_zone" => "Europe/Berlin",
      "pause_seconds" => 7200
    }

    test "are added with the key, in one transaction", %{scope: scope} do
      provider = openrouter!(scope)

      assert {:ok, _provider} =
               Connections.add_provider_key(
                 scope,
                 provider,
                 %{value_id: "third", value: "z"},
                 @settings
               )

      setting = ModelKeys.setting(value!(provider, "third").id)
      assert {setting.reset_weekday, setting.reset_time} == {1, ~T[09:00:00]}
      assert {setting.reset_time_zone, setting.pause_seconds} == {"Europe/Berlin", 7200}

      # Settings that cannot be saved leave no key.
      assert {:error, %Ecto.Changeset{data: %Setting{}}} =
               Connections.add_provider_key(
                 scope,
                 provider,
                 %{value_id: "fourth", value: "y"},
                 %{"reset_weekday" => "2"}
               )

      refute Repo.get_by(Value, secret_id: provider.secret_id, value_id: "fourth")

      # A key added without settings has none.
      assert {:ok, _provider} =
               Connections.add_provider_key(
                 scope,
                 provider,
                 %{value_id: "fifth", value: "x"},
                 %{}
               )

      refute ModelKeys.setting(value!(provider, "fifth").id)
    end

    test "change with the value, in one transaction", %{scope: scope} do
      provider = openrouter!(scope)
      id = value!(provider, "spare").id
      main = value!(provider, "main").id
      until = Apiary.ModelKeysFixtures.in_seconds(3_600)
      Apiary.ModelKeysFixtures.key_state!(provider, "spare", until: until)
      Apiary.ModelKeysFixtures.key_state!(provider, "main", until: until)

      # Settings that cannot be saved leave the value and its cooldown.
      assert {:error, %Ecto.Changeset{data: %Setting{}}} =
               Connections.set_provider_key(scope, provider, "spare", "sk-new", %{
                 "pause_seconds" => 604_801
               })

      assert [%{status: "rejected"}] = ModelKeys.provider_states(provider, DateTime.utc_now())[id]

      assert {:ok, _provider} =
               Connections.set_provider_key(scope, provider, "spare", "sk-new", @settings)

      assert ModelKeys.setting(id).pause_seconds == 7200
      assert List.last(trail(provider.id)).details["value_set"] == true

      # The new value is out of cooldown; the other key keeps its state.
      states = ModelKeys.provider_states(provider, DateTime.utc_now())
      refute states[id]
      assert [%{status: "rejected"}] = states[main]

      assert Secrets.reveal_key_for_sealing(Repo.get!(Connection, provider.id), id) ==
               {:ok, "sk-new"}

      assert {:error, %Ecto.Changeset{data: %Setting{}}} =
               Connections.set_provider_key(scope, provider, "spare", "sk-newer", %{
                 "pause_seconds" => 604_801
               })

      assert ModelKeys.setting(id).pause_seconds == 7200

      assert Secrets.reveal_key_for_sealing(Repo.get!(Connection, provider.id), id) ==
               {:ok, "sk-new"}
    end

    test "a key's change renames it, and its settings and states stay", %{scope: scope} do
      provider = openrouter!(scope)
      value = value!(provider, "spare")

      key = %{
        name: "model-1",
        secret_value_id: value.id,
        organisation_id: value.organisation_id,
        copy_set_at: value.value_set_at,
        copy_kept: true
      }

      now = ~U[2026-11-10 12:00:00.000000Z]

      :ok =
        ModelKeys.record(
          [key],
          [
            %{
              credential: "model-1",
              window: "five_hour",
              status: "allowed",
              utilization: 30,
              source: "provider",
              observed_at: now
            }
          ],
          now
        )

      assert {:ok, _provider} =
               Connections.update_provider_key(scope, provider, "spare", %{
                 "value_id" => "backup",
                 "settings" => @settings
               })

      assert value!(provider, "backup").id == value.id
      assert ModelKeys.setting(value.id).pause_seconds == 7200
      assert [%{utilization: 30}] = ModelKeys.provider_states(provider, now)[value.id]

      # Settings alone; then a save that changes nothing leaves no entry.
      assert {:ok, _provider} =
               Connections.update_provider_key(scope, provider, "backup", %{
                 "value_id" => "backup",
                 "settings" => Map.put(@settings, "pause_seconds", 60)
               })

      entries = length(trail(provider.id))

      assert {:ok, _provider} =
               Connections.update_provider_key(scope, provider, "backup", %{
                 "value_id" => "backup",
                 "settings" => Map.put(@settings, "pause_seconds", 60)
               })

      assert length(trail(provider.id)) == entries
      assert ModelKeys.setting(value.id).pause_seconds == 60

      assert Enum.map(
               Enum.take(trail(provider.id), -2),
               &{&1.before, &1.after, &1.details["value_id"]}
             ) ==
               [
                 {%{"value_id" => "spare"}, %{"value_id" => "backup"}, "backup"},
                 {nil, nil, "backup"}
               ]

      # Settings that cannot be saved leave the name as it was.
      assert {:error, %Ecto.Changeset{data: %Setting{}}} =
               Connections.update_provider_key(scope, provider, "backup", %{
                 "value_id" => "other",
                 "settings" => Map.put(@settings, "reset_weekday", nil)
               })

      assert value!(provider, "backup").id == value.id

      # A name another key has is refused.
      assert {:error, changeset} =
               Connections.update_provider_key(scope, provider, "backup", %{"value_id" => "main"})

      assert errors_on(changeset).value_id == ["is already a value ID of this secret"]
      assert Connections.update_provider_key(scope, provider, "gone", %{}) == {:error, :not_found}
    end

    test "a key's change with a new value replaces it and ends its cooldown", %{scope: scope} do
      provider = openrouter!(scope)
      spare = value!(provider, "spare")
      main = value!(provider, "main").id
      until = Apiary.ModelKeysFixtures.in_seconds(3_600)
      Apiary.ModelKeysFixtures.key_state!(provider, "spare", until: until)
      Apiary.ModelKeysFixtures.key_state!(provider, "main", until: until)

      reveal = fn ->
        Secrets.reveal_key_for_sealing(Repo.get!(Connection, provider.id), spare.id)
      end

      # A value that is empty or only whitespace keeps the value and its cooldown.
      for blank <- [nil, "", "   "] do
        assert {:ok, _provider} =
                 Connections.update_provider_key(scope, provider, "spare", %{
                   "value_id" => "spare",
                   "value" => blank,
                   "settings" => @settings
                 })
      end

      assert reveal.() == {:ok, "sk-spare"}
      assert value!(provider, "spare").value_set_at == spare.value_set_at
      states = ModelKeys.provider_states(provider, DateTime.utc_now())
      assert [%{status: "rejected"}] = states[spare.id]

      # The settings alone leave an entry without `value_set`.
      settings_only = List.last(trail(provider.id))
      assert settings_only.details["value_id"] == "spare"
      refute Map.has_key?(settings_only.details, "value_set")

      # A value that fails its checks leaves the name, the settings, the value and the cooldown.
      entries = length(trail(provider.id))

      assert {:error, changeset} =
               Connections.update_provider_key(scope, provider, "spare", %{
                 "value_id" => "backup",
                 "value" => @key <> <<0>>,
                 "settings" => Map.put(@settings, "pause_seconds", 60)
               })

      assert errors_on(changeset).value == ["must not contain a NUL byte"]
      refute inspect(changeset, limit: :infinity, printable_limit: :infinity) =~ @key

      # A rename that fails leaves the new value unset, though it is set first.
      assert {:error, changeset} =
               Connections.update_provider_key(scope, provider, "spare", %{
                 "value_id" => "main",
                 "value" => @key <> "-taken",
                 "settings" => Map.put(@settings, "pause_seconds", 60)
               })

      assert errors_on(changeset).value_id == ["is already a value ID of this secret"]
      refute inspect(changeset, limit: :infinity, printable_limit: :infinity) =~ @key
      assert value!(provider, "spare").id == spare.id
      assert value!(provider, "spare").value_set_at == spare.value_set_at
      assert ModelKeys.setting(spare.id).pause_seconds == 7200
      assert reveal.() == {:ok, "sk-spare"}

      assert [%{status: "rejected"}] =
               ModelKeys.provider_states(provider, DateTime.utc_now())[spare.id]

      assert length(trail(provider.id)) == entries

      # A new value with a rename: the value is set, then encrypted again under the new
      # name, and its cooldown ends; the other key keeps its cooldown.
      assert {:ok, _provider} =
               Connections.update_provider_key(scope, provider, "spare", %{
                 "value_id" => "backup",
                 "value" => "sk-rotated",
                 "settings" => @settings
               })

      backup = value!(provider, "backup")
      assert backup.id == spare.id
      assert DateTime.compare(backup.value_set_at, spare.value_set_at) == :gt
      assert reveal.() == {:ok, "sk-rotated"}

      states = ModelKeys.provider_states(provider, DateTime.utc_now())
      refute states[spare.id]
      assert [%{status: "rejected"}] = states[main]

      # A new value alone leaves an entry, with no value in it.
      assert {:ok, _provider} =
               Connections.update_provider_key(scope, provider, "backup", %{
                 "value_id" => "backup",
                 "value" => "sk-rotated-again",
                 "settings" => @settings
               })

      assert reveal.() == {:ok, "sk-rotated-again"}

      assert Enum.map(
               Enum.take(trail(provider.id), -2),
               &{&1.before, &1.after, &1.details["value_id"], &1.details["value_set"]}
             ) ==
               [
                 {%{"value_id" => "spare"}, %{"value_id" => "backup"}, "backup", true},
                 {nil, nil, "backup", true}
               ]

      refute inspect(trail(provider.id), limit: :infinity, printable_limit: :infinity) =~
               "sk-rotated"
    end

    test "are for a reader with provider.write, in the provider's organisation", %{scope: scope} do
      provider = openrouter!(scope)
      %{scope: member} = member_fixture(scope)
      %{scope: other} = sign_up_fixture()
      other_provider = openrouter!(other)

      for {reader, target} <- [{member, provider}, {other, provider}, {member, other_provider}] do
        refused = [
          Connections.add_provider_key(reader, target, %{value_id: "x", value: "y"}, @settings),
          Connections.set_provider_key(reader, target, "spare", "y", @settings),
          Connections.update_provider_key(reader, target, "spare", %{
            "value_id" => "spare",
            "settings" => @settings
          })
        ]

        for result <- refused, do: assert(result in [{:error, :forbidden}, {:error, :not_found}])
      end

      # Another organisation's key is not one of this organisation's provider's keys.
      assert Connections.update_provider_key(scope, other_provider, "spare", %{
               "value_id" => "spare",
               "settings" => @settings
             }) == {:error, :not_found}

      refute Repo.exists?(from(s in Setting))
    end
  end

  describe "a key's value" do
    # Spaces, a tab, a newline, a no-break space and an ideographic space around a key, as a
    # copy can bring them.
    @around {" \t\n\u00A0", " \r\n\u3000"}

    defp wrapped(value), do: elem(@around, 0) <> value <> elem(@around, 1)

    defp reveal!(provider, value_id) do
      provider = Repo.get!(Connection, provider.id)
      Secrets.reveal_key_for_sealing(provider, value!(provider, value_id).id)
    end

    test "is trimmed at both ends when a provider is added, its inner spaces kept", ctx do
      provider =
        openrouter!(ctx.scope, %{
          keys: [
            %{value_id: "main", value: wrapped(@key)},
            %{"value_id" => "spare", "value" => wrapped("sk spare\tkey")}
          ]
        })

      assert reveal!(provider, "main") == {:ok, @key}
      assert reveal!(provider, "spare") == {:ok, "sk spare\tkey"}

      # Only whitespace is an empty key, refused as one.
      for blank <- ["", " \n\t\u00A0"] do
        assert {:error, changeset} =
                 Connections.create_provider(ctx.scope, %{
                   provider: "openrouter",
                   keys: [%{value_id: "main", value: blank}]
                 })

        assert [%{value: ["can't be blank" | _]}] = errors_on(changeset).values
      end
    end

    test "is trimmed by Add key, and only whitespace is refused as an empty key", ctx do
      provider = openrouter!(ctx.scope)

      assert {:ok, _provider} =
               Connections.add_provider_key(ctx.scope, provider, %{
                 value_id: "third",
                 value: wrapped("sk third key")
               })

      assert reveal!(provider, "third") == {:ok, "sk third key"}

      assert {:error, empty} =
               Connections.add_provider_key(ctx.scope, provider, %{value_id: "fourth", value: ""})

      assert {:error, blank} =
               Connections.add_provider_key(ctx.scope, provider, %{
                 "value_id" => "fourth",
                 "value" => " \n\t\u00A0"
               })

      assert errors_on(blank) == errors_on(empty)
      assert "can't be blank" in errors_on(blank).value
      refute Repo.get_by(Value, secret_id: provider.secret_id, value_id: "fourth")
    end

    test "is trimmed by a change of the value, which is new though only its spaces differ",
         ctx do
      provider = openrouter!(ctx.scope)
      spare = value!(provider, "spare")

      Apiary.ModelKeysFixtures.key_state!(provider, "spare",
        until: Apiary.ModelKeysFixtures.in_seconds(3_600)
      )

      # The stored value with spaces around it: set, its time moved, its cooldown ended.
      assert {:ok, _provider} =
               Connections.set_provider_key(ctx.scope, provider, "spare", wrapped("sk-spare"))

      assert reveal!(provider, "spare") == {:ok, "sk-spare"}
      assert DateTime.compare(value!(provider, "spare").value_set_at, spare.value_set_at) == :gt
      refute ModelKeys.provider_states(provider, DateTime.utc_now())[spare.id]
      assert List.last(trail(provider.id)).details["value_set"] == true

      # Only whitespace is an empty value, refused as one, and the value stays.
      set_at = value!(provider, "spare").value_set_at
      assert {:error, empty} = Connections.set_provider_key(ctx.scope, provider, "spare", "")

      assert {:error, blank} =
               Connections.set_provider_key(ctx.scope, provider, "spare", " \n\t\u00A0")

      assert errors_on(blank) == errors_on(empty)
      assert "can't be blank" in errors_on(blank).value
      assert reveal!(provider, "spare") == {:ok, "sk-spare"}
      assert value!(provider, "spare").value_set_at == set_at
    end

    test "is trimmed by Edit key's New value; only whitespace keeps the value", ctx do
      provider = openrouter!(ctx.scope)
      spare = value!(provider, "spare")
      until = Apiary.ModelKeysFixtures.in_seconds(3_600)
      Apiary.ModelKeysFixtures.key_state!(provider, "spare", until: until)

      assert {:ok, _provider} =
               Connections.update_provider_key(ctx.scope, provider, "spare", %{
                 "value_id" => "spare",
                 "value" => " \n\t\u00A0\r\n"
               })

      assert reveal!(provider, "spare") == {:ok, "sk-spare"}
      assert value!(provider, "spare").value_set_at == spare.value_set_at

      assert [%{status: "rejected"}] =
               ModelKeys.provider_states(provider, DateTime.utc_now())[spare.id]

      # The stored value with spaces around it is a new value: set, and its cooldown ends.
      assert {:ok, _provider} =
               Connections.update_provider_key(ctx.scope, provider, "spare", %{
                 "value_id" => "spare",
                 "value" => wrapped("sk-spare")
               })

      assert reveal!(provider, "spare") == {:ok, "sk-spare"}
      assert DateTime.compare(value!(provider, "spare").value_set_at, spare.value_set_at) == :gt
      refute ModelKeys.provider_states(provider, DateTime.utc_now())[spare.id]

      assert {:ok, _provider} =
               Connections.update_provider_key(ctx.scope, provider, "spare", %{
                 "value_id" => "backup",
                 "value" => wrapped("sk rotated key")
               })

      assert reveal!(provider, "backup") == {:ok, "sk rotated key"}
    end

    test "is trimmed of Unicode whitespace only: a zero-width space stays", ctx do
      provider = openrouter!(ctx.scope)
      zwsp = "\u200B"

      assert {:ok, _provider} =
               Connections.set_provider_key(
                 ctx.scope,
                 provider,
                 "spare",
                 " #{zwsp}sk-spare#{zwsp}\n"
               )

      assert reveal!(provider, "spare") == {:ok, "#{zwsp}sk-spare#{zwsp}"}
    end

    test "is trimmed only for a provider: another secret keeps its last newline", ctx do
      pem = "-----BEGIN PRIVATE KEY-----\nMIIB\n-----END PRIVATE KEY-----\n"
      {:ok, secret} = Secrets.create_secret(ctx.scope, %{name: "DEPLOY_KEY", value: "x"})
      assert {:ok, secret} = Secrets.set_value(ctx.scope, secret, nil, pem)
      assert Secrets.reveal_for_sealing(ctx.scope.workspace, secret.public_id, nil) == {:ok, pem}
    end
  end

  describe "a refused write" do
    # Whether `needle` is anywhere in `term`: a string, a map or struct, a list or a tuple.
    defp holds?(term, needle) when is_binary(term), do: String.contains?(term, needle)
    defp holds?(%_{} = term, needle), do: term |> Map.from_struct() |> holds?(needle)

    defp holds?(term, needle) when is_map(term),
      do: Enum.any?(term, fn {key, value} -> holds?(key, needle) or holds?(value, needle) end)

    defp holds?(term, needle) when is_list(term), do: Enum.any?(term, &holds?(&1, needle))

    defp holds?(term, needle) when is_tuple(term),
      do: term |> Tuple.to_list() |> holds?(needle)

    defp holds?(_term, _needle), do: false

    defp refused!({:error, %Ecto.Changeset{} = changeset}) do
      for part <- [changeset.params, changeset.changes, changeset.errors] do
        refute holds?(part, @key)
      end

      refute Map.has_key?(changeset.params || %{}, "keys")
      changeset
    end

    test "of a new provider returns a changeset with no key in its params", %{scope: scope} do
      keys = [%{"value_id" => "main", "value" => @key}]

      for attrs <- [
            %{"provider" => "openrouter", "name" => "", "keys" => keys},
            %{"provider" => "openrouter", "applies_to" => "nowhere", "keys" => keys},
            %{"provider" => "litellm", "settings" => %{"address" => "http://x"}, "keys" => keys},
            %{"provider" => "openrouter", "keys" => keys, "default_key" => "other"},
            %{provider: "openrouter", name: "", keys: [%{value_id: "main", value: @key}]}
          ] do
        changeset = scope |> Connections.create_provider(attrs) |> refused!()
        assert changeset.params["name"] in ["", nil] or changeset.params["provider"]
      end
    end

    test "of a change to a provider returns a changeset with no key in its params",
         %{scope: scope} do
      provider = openrouter!(scope)

      changeset =
        scope
        |> Connections.update_provider(provider, %{
          "name" => "",
          "keys" => [%{"value_id" => "main", "value" => @key}]
        })
        |> refused!()

      assert changeset.params == %{"name" => ""}

      refused!(Connections.put_default_key(scope, provider, "other"))
      refused!(Connections.delete_provider_key(scope, provider, "main"))

      refused!(
        Connections.add_provider_key(scope, provider, %{"value_id" => "Bad Id", "value" => @key})
      )

      refused!(Connections.set_provider_key(scope, provider, "main", ""))

      refused!(
        Connections.update_provider_key(scope, provider, "main", %{
          "value_id" => "main",
          "value" => @key <> <<0>>
        })
      )

      refused!(
        Connections.update_provider_key(scope, provider, "main", %{
          "value_id" => "Bad Id",
          "value" => @key
        })
      )
    end
  end

  test "an organisation's deletion takes its providers and their keys",
       %{scope: scope} do
    provider = openrouter!(scope)
    assert {:ok, :purged} = Apiary.Deletion.purge_now(scope.organisation, scope.user)

    refute Repo.get(Connection, provider.id)
    refute Repo.get(Secret, provider.secret_id)
  end
end
