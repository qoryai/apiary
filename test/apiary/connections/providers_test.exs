defmodule Apiary.Connections.ProvidersTest do
  use Apiary.DataCase, async: true

  import Apiary.OrganisationsFixtures
  import ExUnit.CaptureLog

  alias Apiary.{Connections, Secrets}
  alias Apiary.Audit.Entry
  alias Apiary.Connections.{Connection, ProviderModel}
  alias Apiary.Kinds.Providers
  alias Apiary.Secrets.{Secret, Value}

  # A model provider needs `factory` and `secrets`; `factory` is the one opt-in of the two
  # that the suite's legs leave off, and a leg with `factory` has `secrets` too.
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

  defp model_ids(provider), do: Enum.map(provider.models, & &1.model_id)

  defp default_model(provider),
    do: Enum.find_value(provider.models, &(&1.is_default && &1.model_id))

  describe "adding a provider" do
    test "links a secret of its keys and lists the description's models", %{scope: scope} do
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
      assert model_ids(provider) == Enum.map(catalogue.models, & &1["id"])
      assert default_model(provider) == hd(catalogue.models)["id"]

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
      assert provider.models == []
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

      assert Connections.add_provider_model(member, provider, %{model_id: "a"}) ==
               {:error, :forbidden}

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
    test "renames it, and changes where it applies", %{scope: scope} do
      provider = openrouter!(scope)

      assert {:ok, %Connection{name: "Team models", intact: true}} =
               Connections.update_provider(scope, provider, %{name: "Team models"})

      assert {:ok, %Connection{applies_to: "selected", workspaces: []}} =
               Connections.update_connection(scope, provider, %{applies_to: "selected"})

      assert changes(provider) == ["provider_created", "updated", "updated"]
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
      assert Connections.put_default_model(scope, provider, "x") == {:error, :forbidden}
    end
  end

  describe "the list of models" do
    test "adds a model at the end, by its exact id", %{scope: scope} do
      provider = openrouter!(scope)

      assert {:ok, provider} =
               Connections.add_provider_model(scope, provider, %{
                 model_id: "acme/Model-1:free",
                 effort: ["low", "high"]
               })

      assert %ProviderModel{
               title: "acme/Model-1:free",
               effort: ["low", "high"],
               is_default: false
             } =
               List.last(provider.models)

      assert {:error, changeset} =
               Connections.add_provider_model(scope, provider, %{model_id: "acme/Model-1:free"})

      assert errors_on(changeset).model_id == [
               "Edit the model already listed, or enter another ID. This provider already has acme/Model-1:free."
             ]

      [_created, entry] = trail(provider.id)
      assert entry.details["change"] == "provider_model_added"
      assert entry.details["model_id"] == "acme/Model-1:free"
    end

    test "refuses an id, a title or effort values that break their rules", %{scope: scope} do
      provider = openrouter!(scope)

      for {attrs, field, message} <- [
            {%{model_id: " model"}, :model_id,
             "Use 1 to 200 ASCII letters, digits and punctuation with no space, starting with a letter or a digit."},
            {%{model_id: String.duplicate("m", 201)}, :model_id,
             "Use 1 to 200 ASCII letters, digits and punctuation with no space, starting with a letter or a digit."},
            {%{model_id: "m", title: String.duplicate("t", 129)}, :title,
             "should be at most 128 character(s)"},
            {%{model_id: "m", effort: ["High"]}, :effort,
             "Use 1 to 32 lower-case letters, digits and hyphens, starting with a letter, such as high."},
            {%{model_id: "m", effort: ["low", "low"]}, :effort,
             "List at most 16 effort values, each once."},
            {%{model_id: "m", effort: Enum.map(1..17, &"e#{&1}")}, :effort,
             "List at most 16 effort values, each once."}
          ] do
        assert {:error, changeset} = Connections.add_provider_model(scope, provider, attrs)
        assert message in Map.fetch!(errors_on(changeset), field), inspect(attrs)
      end

      assert {:ok, provider} =
               Connections.add_provider_model(scope, provider, %{
                 model_id: String.duplicate("m", 200),
                 title: String.duplicate("t", 128),
                 effort: Enum.map(1..16, &"e#{&1}")
               })

      assert length(provider.models) == 5
    end

    test "holds at most 200 models", %{scope: scope} do
      {:ok, provider} = litellm(scope, "https://litellm.example.com")

      provider =
        Enum.reduce(1..200, provider, fn n, provider ->
          {:ok, provider} = Connections.add_provider_model(scope, provider, %{model_id: "m#{n}"})
          provider
        end)

      assert length(provider.models) == 200
      assert default_model(provider) == "m1"

      assert {:error, changeset} =
               Connections.add_provider_model(scope, provider, %{model_id: "m201"})

      assert errors_on(changeset).model_id == [
               "Remove a model first: a provider has at most 200 models."
             ]
    end

    test "changes a model's title and effort, by its exact id", %{scope: scope} do
      provider = openrouter!(scope)
      [first | _rest] = provider.models

      assert {:ok, provider} =
               Connections.update_provider_model(scope, provider, first.model_id, %{
                 title: "Opus",
                 effort: [],
                 model_id: "ignored"
               })

      assert %ProviderModel{title: "Opus", effort: nil} = hd(provider.models)
      assert hd(provider.models).model_id == first.model_id

      assert {:ok, ^provider} =
               Connections.update_provider_model(scope, provider, first.model_id, %{title: "Opus"})

      assert Connections.update_provider_model(scope, provider, String.upcase(first.model_id), %{
               title: "x"
             }) == {:error, :not_found}

      assert changes(provider) == ["provider_created", "provider_model_changed"]
    end

    test "removes a model; the next becomes the default", %{scope: scope} do
      provider = openrouter!(scope)
      [first, second | _rest] = model_ids(provider)

      assert {:ok, provider} = Connections.put_default_model(scope, provider, second)
      assert default_model(provider) == second
      assert {:ok, ^provider} = Connections.put_default_model(scope, provider, second)

      assert {:ok, provider} = Connections.delete_provider_model(scope, provider, first)
      assert default_model(provider) == second
      assert {:ok, provider} = Connections.delete_provider_model(scope, provider, second)
      assert hd(provider.models).is_default
      assert Connections.delete_provider_model(scope, provider, first) == {:error, :not_found}

      assert changes(provider) == [
               "provider_created",
               "provider_default_model_changed",
               "provider_model_removed",
               "provider_model_removed"
             ]
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

    test "go with the provider, as do its models", %{scope: scope} do
      provider = openrouter!(scope)

      assert {:ok, %Connection{}} = Connections.delete_provider(scope, provider)
      assert Connections.get_provider(scope, provider.public_id) == {:error, :not_found}
      refute Repo.get(Secret, provider.secret_id)

      assert Repo.aggregate(from(v in Value, where: v.secret_id == ^provider.secret_id), :count) ==
               0

      assert Repo.aggregate(
               from(m in ProviderModel, where: m.connection_id == ^provider.id),
               :count
             ) == 0

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
    end
  end

  test "an organisation's deletion takes its providers, their models and their keys",
       %{scope: scope} do
    provider = openrouter!(scope)
    assert {:ok, :purged} = Apiary.Deletion.purge_now(scope.organisation, scope.user)

    refute Repo.get(Connection, provider.id)
    refute Repo.get(Secret, provider.secret_id)
    assert Repo.aggregate(ProviderModel, :count) == 0
  end
end
