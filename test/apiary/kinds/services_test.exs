defmodule Apiary.Kinds.ServicesTest do
  use ExUnit.Case, async: true

  alias Apiary.Kinds.{Bounds, Headers, Placeholders, Runtimes, ServiceDefinition, Services}

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

    test "refuses a title or a declaration's title with a control, a format character or a separator" do
      for cp <- [0x0, 0x7, 0x85, 0x202E, 0x2066, 0x200F, 0x061C, 0x200B, 0xFEFF, 0x2028] do
        title = "Status#{<<cp::utf8>>} API"

        assert {:error, [{:definition_invalid, _}]} =
                 ServiceDefinition.validate(definition(%{"title" => title})),
               Integer.to_string(cp, 16)

        declares = [%{"id" => "key", "title" => title, "name" => "STATUS_API_KEY"}]

        assert {:error, [{:definition_invalid, _}]} =
                 ServiceDefinition.validate(definition(%{"declares" => declares})),
               Integer.to_string(cp, 16)
      end

      # The join controls stay, as in a name a person types (`Apiary.Names`).
      assert {:ok, _} =
               ServiceDefinition.validate(
                 definition(%{"title" => "می#{<<0x200C::utf8>>}خواهم 👩#{<<0x200D::utf8>>}💻"})
               )
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

    test "builds its auth on the schemes and members of the contract's auth, but oauth" do
      contract =
        Application.app_dir(:apiary, ["priv", "contract", "auth.schema.json"])
        |> File.read!()
        |> Jason.decode!()

      own =
        Application.app_dir(:apiary, ["priv", "schemas", "service-definition.schema.json"])
        |> File.read!()
        |> Jason.decode!()
        |> get_in(["properties", "auth"])

      # `oauth` marks a model key, which comes from a model provider; a service's value
      # is never one.
      assert Map.has_key?(contract["properties"], "oauth")
      refute Map.has_key?(own["properties"], "oauth")

      for member <- Map.keys(contract["properties"]) -- ["oauth"] do
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
    test "the catalogue lists Claude Code with its model formats, keys, effort and endpoint" do
      assert {:ok, runtime} = Runtimes.fetch("claude")
      assert runtime.title == "Claude Code"
      assert runtime.declares == []
      assert runtime.reserves == []
      assert runtime.one_of == []
      assert runtime.model["formats"] == ["anthropic-messages"]
      assert Runtimes.formats(runtime) == ["anthropic-messages"]
      assert Runtimes.hosts(runtime) == []

      assert runtime.model_keys == [
               %{
                 "format" => "anthropic-messages",
                 "auth" => %{"scheme" => "header", "header" => "x-api-key"},
                 "variable" => "ANTHROPIC_API_KEY"
               },
               %{
                 "format" => "anthropic-messages",
                 "auth" => %{"scheme" => "bearer"},
                 "variable" => "ANTHROPIC_AUTH_TOKEN"
               },
               %{
                 "format" => "anthropic-messages",
                 "auth" => %{"scheme" => "bearer", "oauth" => true},
                 "variable" => "CLAUDE_CODE_OAUTH_TOKEN"
               }
             ]

      assert runtime.effort_values == ~w(low medium high xhigh max)
      assert runtime.endpoint_variable == "ANTHROPIC_BASE_URL"
      assert Runtimes.fetch("nothing") == :error
    end

    @tag :contract
    test "every vendored file .forager-contract-ref lists is the contract's" do
      dir = Apiary.ContractFixtures.contract_dir()
      # A local Forager checkout from before a file has none of it; CI, at the pinned
      # commit, requires every one.
      required? = System.get_env("CONTRACT_FIXTURES_REQUIRED") == "1"
      root = Path.dirname(Mix.Project.project_file())
      vendored = Apiary.ContractFixtures.vendored()

      assert Enum.sort(vendored) ==
               Enum.sort(
                 ~w(api-format.schema.json auth.schema.json policy.schema.json
                    run-configuration.schema.json runtimes.json secrets-request.schema.json
                    secrets-answer.schema.json sealed-plaintext.schema.json)
                 |> Enum.map(&("priv/contract/" <> &1))
                 |> Enum.concat(
                   for file <- ~w(sealed/invalid/bad-signature.json sealed/invalid/expired.json
                                  sealed/invalid/other-digest.json sealed/invalid/other-run.json
                                  sealed/invalid/too-far-ahead.json sealed/invalid/unknown-suite.json
                                  sealed/invalid/value-not-requested.json
                                  sealed/invalid/wrong-aad.json sealed/invalid/wrong-info.json
                                  sealed/plaintext-not-requested.json
                                  sealed/plaintext-other-digest.json sealed/run-configuration.json
                                  sealed/sealed-plaintext.json sealed/secrets-answer.json
                                  sealed/secrets-request.json sealed/vectors.json
                                  known-answers/keys.json known-answers/small-order.json
                                  policy/observe-allow-first.yaml
                                  invalid/policy-allow-first-pattern.yaml
                                  invalid/policy-allow-first-too-many.yaml),
                       do: "test/fixtures/forager-contract/" <> file
                 )
               )

      for path <- vendored,
          file = Apiary.ContractFixtures.contract_path(path),
          required? or File.exists?(Path.join(dir, file)) do
        assert {:ok, File.read!(Path.join(root, path))} == File.read(Path.join(dir, file)),
               "#{path} differs from the contract's #{file}: copy it from #{dir}"
      end

      # Every fixture of fixtures/sealed is vendored.
      if required? or File.dir?(Path.join(dir, "fixtures/sealed")) do
        sealed =
          for file <- Path.wildcard(Path.join(dir, "fixtures/sealed/**/*.json")),
              do: Path.relative_to(file, dir)

        assert sealed -- Enum.map(vendored, &Apiary.ContractFixtures.contract_path/1) == []
      end
    end

    test "a runtime's declared and reserved variables are placeholder conflicts" do
      for name <- ["ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_AUTH_TOKEN"],
          do: assert(Placeholders.conflict?(name))

      refute Placeholders.conflict?("STATUS_API_KEY")
    end
  end

  describe "the size of a definition" do
    # The bounds the schema gives, lists of 32 entries and objects of 8 members, refuse an
    # oversized definition within 100000 reductions, where JSV and the normalising of its
    # errors took up to 0.4 s; deep nesting passes them and the schema refuses it within
    # 2000000, and the largest valid definition passes within 100000. The work is
    # asserted in reductions, the same on any machine running the same OTP release, not
    # in time; which inputs the bounds refuse is asserted apart from it.

    setup do
      # The schema and its bounds are built once; the first check pays for it.
      assert {:ok, _} = ServiceDefinition.validate(definition())
      :ok
    end

    # The value of `fun` and the reductions it did, in another process. Garbage is
    # collected first, so that a collection's work is not counted.
    defp reductions(fun) do
      task =
        Task.async(fn ->
          :erlang.garbage_collect()
          {:reductions, before} = Process.info(self(), :reductions)
          result = fun.()
          {:reductions, done} = Process.info(self(), :reductions)
          {done - before, result}
        end)

      Task.await(task, 60_000)
    end

    defp deep(depth), do: Enum.reduce(1..depth, [], fn _, inner -> [inner] end)

    # Each about 120 KB as JSON: the page takes 64 KiB, and a definition given to
    # `Apiary.Connections` as a string is not bounded before it is decoded.
    defp oversized do
      [
        definition(%{"hosts" => List.duplicate(1, 60_000)}),
        definition(%{"hosts" => List.duplicate(%{}, 40_000)}),
        definition(%{"paths" => List.duplicate("/a", 24_000)}),
        definition(%{"declares" => List.duplicate(%{}, 40_000)}),
        Map.merge(definition(), Map.new(1..11_000, &{"k#{&1}", 1})),
        definition(%{"auth" => Map.new(1..11_000, &{"k#{&1}", 1})})
      ]
    end

    test "a definition over the schema's bounds is refused within 100000 reductions" do
      for definition <- oversized() do
        assert byte_size(Jason.encode!(definition)) in 100_000..140_000
        refute Bounds.within?(definition, ServiceDefinition.bounds())

        {reductions, result} = reductions(fn -> ServiceDefinition.validate(definition) end)
        # JSV reads the entries in millions.
        assert reductions < 100_000, "#{reductions} reductions"
        assert result == {:error, [{:definition_invalid, ""}]}
      end
    end

    test "deep nesting passes the bounds in constant stack, and the schema refuses it" do
      definition = definition(%{"hosts" => deep(60_000)})
      assert byte_size(Jason.encode!(definition)) in 100_000..140_000
      assert Bounds.within?(definition, ServiceDefinition.bounds())

      {reductions, result} = reductions(fn -> ServiceDefinition.validate(definition) end)
      assert reductions < 2_000_000, "#{reductions} reductions"
      assert result == {:error, [{:definition_invalid, ""}]}
    end

    test "a valid definition with every list at its largest passes" do
      ids = for i <- 1..16, do: "key_#{i}"

      largest =
        definition(%{
          "description" => String.duplicate("d", 500),
          "hosts" => for(i <- 1..16, do: "api#{i}.example.com"),
          "paths" => for(i <- 1..32, do: "/v#{i}/" <> String.duplicate("p", 100) <> "/*"),
          "auth" => %{"scheme" => "header", "header" => "x-api-key", "secret" => "key_1"},
          "declares" =>
            for(
              id <- ids,
              do: %{
                "id" => id,
                "title" => String.duplicate("t", 128),
                "name" => String.upcase(id)
              }
            )
        })

      assert Bounds.within?(largest, ServiceDefinition.bounds())
      {reductions, result} = reductions(fn -> ServiceDefinition.validate(largest) end)
      assert reductions < 100_000, "#{reductions} reductions"
      assert {:ok, ^largest} = result

      refute Bounds.within?(
               %{largest | "paths" => ["/" | largest["paths"]]},
               ServiceDefinition.bounds()
             )
    end
  end
end
