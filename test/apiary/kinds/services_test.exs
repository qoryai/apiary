defmodule Apiary.Kinds.ServicesTest do
  use ExUnit.Case, async: true

  alias Apiary.Kinds.{Headers, Placeholders, Runtimes, ServiceDefinition, Services}

  @dir Path.expand("../../../priv/services", __DIR__)

  defp definition(overrides \\ %{}) do
    Map.merge(
      %{
        "version" => 1,
        "key" => "status-api",
        "title" => "Status API",
        "hosts" => ["status.example.com"],
        "paths" => ["/api/*"],
        "auth" => %{"scheme" => "header", "header" => "x-api-key", "secret" => "key"},
        "declares" => [%{"id" => "key", "title" => "API key", "name" => "STATUS_API_KEY"}]
      },
      overrides
    )
  end

  describe "the built-in definitions" do
    test "every file of priv/services passes the schema and the rules, and is named for its key" do
      files = Path.wildcard(Path.join(@dir, "*.json"))
      assert files != []

      for file <- files do
        decoded = file |> File.read!() |> Jason.decode!()

        assert {:ok, ^decoded} = ServiceDefinition.validate(decoded),
               "#{Path.basename(file)} is not a valid service definition"

        assert decoded["key"] == Path.basename(file, ".json")
      end

      assert Enum.sort(Services.keys()) ==
               files |> Enum.map(&Path.basename(&1, ".json")) |> Enum.sort()
    end

    test "each is found by its key, with a digest of its canonical JSON" do
      assert {:ok, %{"key" => "sentry", "hosts" => ["sentry.io"]}} = Services.fetch("sentry")
      assert Services.fetch("nothing") == :error
      assert Services.digest("sentry") =~ ~r/\A[0-9a-f]{64}\z/
      assert Services.digest("nothing") == nil
    end
  end

  describe "a definition" do
    test "is valid as written" do
      assert {:ok, _} = ServiceDefinition.validate(definition())
    end

    test "is refused by the schema for a wildcard, an IP literal, a port or a trailing newline" do
      for host <- [
            "*.example.com",
            "203.0.113.10",
            "status.example.com:8443",
            "status.example.com\n",
            "status"
          ] do
        assert {:error, [{:definition_invalid, _}]} =
                 ServiceDefinition.validate(definition(%{"hosts" => [host]})),
               host
      end
    end

    test "refuses a host name that names no host of the internet" do
      assert {:error, [{:connection_host_invalid, "status.internal"}]} =
               ServiceDefinition.validate(definition(%{"hosts" => ["status.internal"]}))
    end

    test "refuses an auth whose secret is not declared" do
      auth = %{"scheme" => "bearer", "secret" => "other"}

      assert {:error, [{:declaration_unknown, "auth.secret"}]} =
               ServiceDefinition.validate(definition(%{"auth" => auth}))
    end

    test "refuses a header the list of refused headers holds" do
      for header <- ["Authorization", "x-forwarded-for", "Cookie", "qory-run", "accept-language"] do
        auth = %{"scheme" => "header", "header" => header, "secret" => "key"}

        assert {:error, [{:connection_header_reserved, ^header}]} =
                 ServiceDefinition.validate(definition(%{"auth" => auth}))
      end

      refute Headers.refused?("x-api-key")
    end

    test "refuses a declaration's variable that a placeholder may not take: placeholder_conflict" do
      for name <- ["QORY_TOKEN", "qory_token", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"] do
        declares = [%{"id" => "key", "title" => "API key", "name" => name}]

        assert {:error, [{:placeholder_conflict, ^name}]} =
                 ServiceDefinition.validate(definition(%{"declares" => declares})),
               name
      end
    end

    test "basic takes a username or a username secret, never both, and header needs its header" do
      basic = %{"scheme" => "basic", "secret" => "key"}
      assert {:error, _} = ServiceDefinition.validate(definition(%{"auth" => basic}))

      assert {:ok, _} =
               ServiceDefinition.validate(
                 definition(%{"auth" => Map.put(basic, "username", "dana")})
               )

      assert {:error, _} =
               ServiceDefinition.validate(
                 definition(%{
                   "auth" => Map.merge(basic, %{"username" => "dana", "username_secret" => "key"})
                 })
               )

      assert {:error, _} =
               ServiceDefinition.validate(
                 definition(%{"auth" => %{"scheme" => "header", "secret" => "key"}})
               )
    end

    test "takes Apiary's own auth: a scheme, the secret it sets, and the scheme's members" do
      declares = [%{"id" => "key", "title" => "API key"}, %{"id" => "user", "title" => "User"}]

      for auth <- [
            %{"scheme" => "bearer", "secret" => "key"},
            %{"scheme" => "header", "header" => "x-api-key", "secret" => "key"},
            %{"scheme" => "basic", "username" => "dana", "secret" => "key"},
            %{"scheme" => "basic", "username" => String.duplicate("a", 128), "secret" => "key"},
            %{"scheme" => "basic", "username_secret" => "user", "secret" => "key"}
          ] do
        assert {:ok, _} =
                 ServiceDefinition.validate(definition(%{"auth" => auth, "declares" => declares})),
               inspect(auth)
      end

      for auth <- [
            %{"scheme" => "bearer", "secret" => "key", "prefix" => "Token"},
            %{"scheme" => "bearer"},
            %{"secret" => "key"},
            %{"scheme" => "digest", "secret" => "key"},
            %{"scheme" => "bearer", "secret" => "Key"},
            %{"scheme" => "bearer", "username" => "dana", "secret" => "key"},
            %{"scheme" => "bearer", "username_secret" => "user", "secret" => "key"},
            %{"scheme" => "bearer", "header" => "x-api-key", "secret" => "key"},
            %{"scheme" => "basic", "username" => "da:na", "secret" => "key"},
            %{"scheme" => "basic", "username" => "", "secret" => "key"},
            %{"scheme" => "basic", "secret" => "key", "username" => String.duplicate("a", 129)},
            %{"scheme" => "header", "header" => "x api key", "secret" => "key"}
          ] do
        assert {:error, [{:definition_invalid, _}]} =
                 ServiceDefinition.validate(definition(%{"auth" => auth, "declares" => declares})),
               inspect(auth)
      end
    end

    test "builds its auth on the schemes and members of the contract's auth" do
      contract =
        Application.app_dir(:apiary, ["priv", "contract", "auth.schema.json"])
        |> File.read!()
        |> Jason.decode!()

      own =
        Application.app_dir(:apiary, ["priv", "schemas", "service-definition.schema.json"])
        |> File.read!()
        |> Jason.decode!()
        |> get_in(["properties", "auth"])

      for member <- Map.keys(contract["properties"]) do
        assert own["properties"][member]["$ref"] ==
                 contract["$id"] <> "#/properties/" <> member,
               member
      end

      assert Enum.at(contract["allOf"], 0)["then"] == %{"required" => ["header"]}
      assert %{"$ref" => ref} = Enum.at(own["allOf"], 0)
      assert ref == contract["$id"] <> "#/allOf/0"
    end

    test "has one canonical encoding, whatever the order of its members" do
      a = definition()
      b = a |> Enum.reverse() |> Map.new()
      assert ServiceDefinition.encode(a) == ServiceDefinition.encode(b)
      assert ServiceDefinition.digest(a) == ServiceDefinition.digest(b)
    end
  end

  describe "the runtimes" do
    test "the catalogue lists Claude Code with its declarations and its required group" do
      assert {:ok, runtime} = Runtimes.fetch("claude")
      assert runtime.title == "Claude Code"
      assert Enum.map(runtime.declares, & &1["id"]) == ["api_key", "oauth_token"]
      assert [%{"id" => "model_key", "required" => true}] = runtime.one_of
      assert Runtimes.hosts(runtime) == ["api.anthropic.com"]
      assert Runtimes.fetch("nothing") == :error
    end

    @tag :contract
    test "the vendored catalogue and auth schema are the contract's" do
      dir = Apiary.ContractFixtures.contract_dir()
      # A local runner checkout from before the catalogue has neither file; CI, at the
      # pinned commit, requires both.
      required? = System.get_env("CONTRACT_FIXTURES_REQUIRED") == "1"

      for file <- ~w(runtimes.json auth.schema.json),
          required? or File.exists?(Path.join(dir, file)) do
        assert {:ok, File.read!(Application.app_dir(:apiary, ["priv", "contract", file]))} ==
                 File.read(Path.join(dir, file)),
               "priv/contract/#{file} differs from the contract's: copy it from #{dir}"
      end
    end

    test "a runtime's declared and reserved variables are placeholder conflicts" do
      for name <- ["ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_AUTH_TOKEN"],
          do: assert(Placeholders.conflict?(name))

      refute Placeholders.conflict?("STATUS_API_KEY")
    end
  end
end
