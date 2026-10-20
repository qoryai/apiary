defmodule Apiary.Integrations.DescriptionTest do
  use ExUnit.Case, async: true

  import Apiary.DescriptionFixtures
  import ExUnit.CaptureLog

  alias Apiary.Integrations
  alias Apiary.Integrations.{Description, Release}
  alias Apiary.Kinds.{Budget, Schema}

  @fixtures Path.expand("../../fixtures/integration-contract", __DIR__)

  defp parse(description), do: description |> encode() |> Description.parse()

  # The fixtures that match `pattern` under the contract's fixtures, each by its path there.
  defp fixture_names(pattern) do
    @fixtures
    |> Path.join(pattern)
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, @fixtures))
  end

  defp parse_fixture(name),
    do: @fixtures |> Path.join(name) |> File.read!() |> Description.parse()

  describe "the integrations contract's fixtures" do
    test "every accepted fixture is read" do
      names = fixture_names("*.json")

      assert names ==
               ~w(acme-chat.json acme-cloud.json acme-models.json acme-tracker.json
                  example-gateway.json example-projects.json example-tracker.json github.json
                  unknown-role.json)

      for name <- names, do: assert({:ok, %Description{}} = parse_fixture(name), name)
    end

    test "every refused fixture is refused, those a reader refuses included" do
      names = fixture_names("invalid/*.json") ++ fixture_names("refused-by-reader/*.json")
      assert length(names) == 98

      for name <- names do
        assert {:error, {:description_invalid, _}} = parse_fixture(name), name
      end
    end

    test "a fixture past a bound is refused before the schema is applied" do
      for name <- ~w(settings-enum-1025-entries settings-properties-1025-members
                     string-16385-characters) do
        name = "invalid/description-#{name}.json"

        assert {:error, {:description_invalid, [{:schema, %{limits: _}}]}} = parse_fixture(name),
               name
      end
    end

    test "a source role is refused where the schema refuses its shape" do
      names = fixture_names("invalid/description-source-*.json")
      assert length(names) == 33

      for {name, kind, location} <- [
            {"arabic-letter-mark", :pattern, "#/roles/source/access"},
            {"bidi-override", :pattern, "#/roles/source/connect"},
            {"byte-order-mark", :pattern, "#/roles/source/setup/help"},
            {"command-non-ascii", :pattern, "#/roles/source/start"},
            {"line-feed", :pattern, "#/roles/source/connect"},
            {"line-separator", :pattern, "#/roles/source/disconnect"},
            {"line-too-long", :maxLength, "#/roles/source/access"},
            {"program-upper-case", :pattern, "#/roles/source/program"},
            {"setup-no-help", :required, "#/roles/source/setup"},
            {"undefined-member", :additionalProperties, "#/roles/source"},
            {"zero-width-space", :pattern, "#/roles/source/description"},
            {"item-noun-33-characters", :maxLength, "#/roles/source/item_noun/one"},
            {"item-noun-double-space", :pattern, "#/roles/source/item_noun/one"},
            {"item-noun-empty", :minLength, "#/roles/source/item_noun/other"},
            {"item-noun-leading-hyphen", :pattern, "#/roles/source/item_noun/one"},
            {"item-noun-no-other", :required, "#/roles/source/item_noun"},
            {"item-noun-non-ascii", :pattern, "#/roles/source/item_noun/one"},
            {"item-noun-undefined-member", :additionalProperties, "#/roles/source/item_noun"},
            {"item-noun-upper-case", :pattern, "#/roles/source/item_noun/one"},
            {"item-noun-work-item", :not, "#/roles/source/item_noun/one"},
            {"item-noun-work-items-hyphen", :not, "#/roles/source/item_noun/other"},
            {"items-false-with-item-noun", :jsv@if, "#/roles/source"},
            {"items-true", :const, "#/roles/source/items"},
            {"collection-noun-33-characters", :maxLength, "#/roles/source/collection_noun/one"},
            {"collection-noun-double-space", :pattern, "#/roles/source/collection_noun/one"},
            {"collection-noun-empty", :minLength, "#/roles/source/collection_noun/other"},
            {"collection-noun-leading-hyphen", :pattern, "#/roles/source/collection_noun/one"},
            {"collection-noun-no-other", :required, "#/roles/source/collection_noun"},
            {"collection-noun-non-ascii", :pattern, "#/roles/source/collection_noun/one"},
            {"collection-noun-undefined-member", :additionalProperties,
             "#/roles/source/collection_noun"},
            {"collection-noun-upper-case", :pattern, "#/roles/source/collection_noun/one"},
            {"collection-noun-work-item", :not, "#/roles/source/collection_noun/one"},
            {"collection-noun-work-items-hyphen", :not, "#/roles/source/collection_noun/other"}
          ] do
        name = "invalid/description-source-#{name}.json"
        assert name in names
        assert {:error, {:description_invalid, [{:schema, summary}]}} = parse_fixture(name)
        assert %{kind: kind, instanceLocation: location} in summary.errors, name
      end
    end

    test "a fixture a reader refuses is refused for its cause" do
      assert fixture_names("refused-by-reader/*.json") == [
               "refused-by-reader/description-member-repeated.json",
               "refused-by-reader/description-string-invalid-utf-8.json",
               "refused-by-reader/description-string-lone-surrogate.json"
             ]

      assert parse_fixture("refused-by-reader/description-member-repeated.json") ==
               {:error, {:description_invalid, [:member_repeated]}}

      for name <- ~w(invalid-utf-8 lone-surrogate) do
        assert parse_fixture("refused-by-reader/description-string-#{name}.json") ==
                 {:error, {:description_invalid, [:not_json]}}
      end
    end

    test "example-tracker.json: a source role is read once the schema has checked its shape" do
      assert {:ok, tracker} = parse_fixture("example-tracker.json")
      assert tracker.roles == ["source"]
      assert tracker.document["roles"]["source"]["program"] == "qory-example-server"
    end

    test "a source role's words for its items, and whether it reports any" do
      assert {:ok, tracker} = parse_fixture("example-tracker.json")
      assert Description.item_noun(tracker) == %{one: "issue", other: "issues"}
      assert Description.items?(tracker)

      assert {:ok, projects} = parse_fixture("example-projects.json")
      assert Description.item_noun(projects) == nil
      refute Description.items?(projects)

      # No source role, or one that says neither: no words, and items.
      for name <- ~w(acme-tracker.json unknown-role.json) do
        assert {:ok, description} = parse_fixture(name)
        assert Description.item_noun(description) == nil, name
        assert Description.items?(description), name
        assert Description.collection_noun(description) == nil, name
      end
    end

    test "a source role's words for its collections, beside items: false too" do
      assert {:ok, tracker} = parse_fixture("example-tracker.json")
      assert Description.collection_noun(tracker) == %{one: "project", other: "projects"}

      assert {:ok, projects} = parse_fixture("example-projects.json")
      refute Description.items?(projects)
      assert Description.collection_noun(projects) == %{one: "project", other: "projects"}
    end

    test "a source role's access line, and none without a source role" do
      line =
        "In Example Tracker, open Settings, then Connected adapters, to change which " <>
          "projects the adapter reads."

      for name <- ~w(example-tracker.json example-projects.json) do
        assert {:ok, description} = parse_fixture(name)
        assert Description.access(description) == line, name
      end

      {:ok, tracker} = parse_fixture("example-tracker.json")

      assert {:ok, read} =
               tracker.document
               |> put_in(["roles", "source", "access"], "Ask an owner to change the boards.")
               |> Jason.encode!()
               |> Description.parse()

      assert Description.access(read) == "Ask an owner to change the boards."

      for name <- ~w(acme-tracker.json unknown-role.json) do
        assert {:ok, description} = parse_fixture(name)
        assert Description.access(description) == nil, name
      end
    end

    test "collection_noun's words: the same as item_noun's, never work item" do
      {:ok, tracker} = parse_fixture("example-tracker.json")

      with_noun = fn noun ->
        tracker.document
        |> put_in(["roles", "source", "collection_noun"], noun)
        |> Jason.encode!()
        |> Description.parse()
      end

      for word <- ["a", "code base", "work-board", String.duplicate("z", 32), "works"] do
        assert {:ok, read} = with_noun.(%{"one" => word, "other" => word}), word
        assert Description.collection_noun(read) == %{one: word, other: word}
      end

      for word <-
            ["", "Board", "board ", "code  base", "-board", "board2", "projèt"] ++
              ["work item", "work-item", "work items", "work-items"] ++
              [String.duplicate("z", 33)] do
        assert {:error, {:description_invalid, [{:schema, _}]}} =
                 with_noun.(%{"one" => "board", "other" => word}),
               word
      end
    end

    test "item_noun's words: lower-case words joined by one space or hyphen, never work item" do
      {:ok, tracker} = parse_fixture("example-tracker.json")

      with_noun = fn noun ->
        tracker.document
        |> put_in(["roles", "source", "item_noun"], noun)
        |> Jason.encode!()
        |> Description.parse()
      end

      for word <- ["a", "user story", "merge-request", String.duplicate("z", 32), "works"] do
        assert {:ok, read} = with_noun.(%{"one" => word, "other" => word}), word
        assert Description.item_noun(read) == %{one: word, other: word}
      end

      for word <- [
            "",
            "Issue",
            "issue ",
            "user  story",
            "-issue",
            "issue2",
            "tâche",
            "work item",
            "work-item",
            "work items",
            "work-items",
            String.duplicate("z", 33)
          ] do
        assert {:error, {:description_invalid, [{:schema, _}]}} =
                 with_noun.(%{"one" => "issue", "other" => word}),
               word
      end
    end

    test "github.json: a connection holds its plain settings, every top-level one" do
      assert {:ok, github} =
               @fixtures |> Path.join("github.json") |> File.read!() |> Description.parse()

      assert github.settings == ["api_url", "app_id", "installation_id", "permissions"]

      assert Description.check_settings(github, %{
               "app_id" => 123_456,
               "installation_id" => 7,
               "permissions" => %{"contents" => "read"},
               "api_url" => "https://api.github.com"
             }) == :ok

      assert Description.check_settings(github, %{"private_key_file" => "/etc/key.pem"}) ==
               {:error, {:integration_settings_not_allowed, ["private_key_file"]}}
    end

    test "unknown-role.json: a role Qory Apiary does not know is read as it is" do
      assert {:ok, description} =
               @fixtures |> Path.join("unknown-role.json") |> File.read!() |> Description.parse()

      assert description.roles == ["acme_role", "credential"]
    end
  end

  # The files vendored from qoryai/integrations at the commit in `.integration-contract-ref`
  # and in `test/fixtures/contract/integration/v1/.contract-ref`, by their SHA-256 there.
  @integrations_ref "a22946819868503a62d5855bd2c664d9e339527f"
  @vendored_sha256 %{
    "priv/contract/integration/description.schema.json" =>
      "016283cff012f7becd936d642e730149ac24787ec6a5fa9c2c82782ca2cd0b8e",
    "priv/contract/integration/definitions.schema.json" =>
      "dccf00468dc180a63a116b6fa823e04358b94d3b0b79678843f8f49ae9056e0b",
    "priv/contract/integration/descriptions/anthropic.json" =>
      "04f85c67a8f04e06c925ce61b5210c7141aec7453b3e645a298f075b06491c1b",
    "priv/contract/integration/descriptions/claude-subscription.json" =>
      "4bd492082526fe8184edb26fdb3bc9f4f812569c7d890c715e13f9208b4fc95d",
    "priv/contract/integration/descriptions/deepseek.json" =>
      "6cdf2ab9c102dfb01ba618b2b44fa7235e253cf29d3b349474eae5108cc6dd64",
    "priv/contract/integration/descriptions/litellm.json" =>
      "cbc50081646c9bb07b528a81c1c9cd38b82a506efad356641b0fef42615dceea",
    "priv/contract/integration/descriptions/openrouter.json" =>
      "f77a4df6d8115eb3030a2053e8c97f87aef2a8e0566b629673d618cefb28d7bb",
    "test/fixtures/contract/integration/v1/changes.schema.json" =>
      "20213633b1e66629e11b7406b386f0c85603196ae84677186d049329d16c8bf3",
    "test/fixtures/contract/integration/v1/definitions.schema.json" =>
      "dccf00468dc180a63a116b6fa823e04358b94d3b0b79678843f8f49ae9056e0b",
    "test/fixtures/contract/integration/v1/refusal.schema.json" =>
      "3290b901ceb26b3d52a08aa869e4bdb301d43ad73e383e991404ae060d9955b0"
  }

  @root Path.expand("../../..", __DIR__)
  @descriptions Path.join(@root, "priv/contract/integration/descriptions")

  defp vendored_description(name),
    do: @descriptions |> Path.join(name <> ".json") |> File.read!() |> Jason.decode!()

  describe "the files vendored from the integrations" do
    test "are the bytes of the pinned commit" do
      ref =
        @root
        |> Path.join(".integration-contract-ref")
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.reject(&String.starts_with?(&1, "#"))

      assert ref == [@integrations_ref]

      assert File.read!(Path.join(@root, "test/fixtures/contract/integration/v1/.contract-ref")) ==
               @integrations_ref <> "\n"

      vendored =
        for dir <- ["priv/contract/integration", "test/fixtures/contract/integration/v1"],
            path <- Path.wildcard(Path.join([@root, dir, "**", "*.json"])),
            do: Path.relative_to(path, @root)

      assert Enum.sort(vendored) == Enum.sort(Map.keys(@vendored_sha256))

      for {path, sha256} <- @vendored_sha256 do
        bytes = File.read!(Path.join(@root, path))
        assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == sha256, path
      end
    end
  end

  describe "a data description" do
    test "each vendored description of a model provider is read" do
      names =
        @descriptions |> Path.join("*.json") |> Path.wildcard() |> Enum.map(&Path.basename/1)

      assert names ==
               ~w(anthropic.json claude-subscription.json deepseek.json litellm.json
                  openrouter.json)

      for name <- names do
        assert {:ok, description} =
                 @descriptions |> Path.join(name) |> File.read!() |> Description.parse(),
               name

        assert description.name == Path.rootname(name)
        assert description.program_version == nil, name
        assert description.roles == ["model_provider"], name
        assert description.secrets == [], name
      end
    end

    test "is refused with a role member the apis replaced" do
      assert {:error, {:description_invalid, [{:schema, _}]}} =
               parse_fixture("invalid/description-model-provider-role-key-variables.json")

      anthropic = vendored_description("anthropic")

      for {member, value} <- [
            {"key_variables", ["ANTHROPIC_API_KEY"]},
            {"endpoint", "https://api.anthropic.com"},
            {"formats", ["anthropic-messages"]},
            {"hosts", ["api.anthropic.com"]},
            {"auth", %{"scheme" => "bearer"}}
          ] do
        assert {:error, {:description_invalid, [{:schema, _}]}} =
                 anthropic
                 |> put_in(["roles", "model_provider", member], value)
                 |> encode()
                 |> Description.parse(),
               member
      end
    end

    test "is refused with key prefixes or apis the schema refuses" do
      assert {:error, {:description_invalid, [{:schema, _}]}} =
               parse_fixture("invalid/description-model-provider-key-prefixes-space.json")

      anthropic = vendored_description("anthropic")
      [api] = anthropic["roles"]["model_provider"]["apis"]

      for prefixes <- [[], ["sk ant-"], List.duplicate("sk-ant-", 2), ~w(a b c d e)] do
        assert {:error, {:description_invalid, [{:schema, _}]}} =
                 anthropic
                 |> put_in(["roles", "model_provider", "apis"], [
                   Map.put(api, "key_prefixes", prefixes)
                 ])
                 |> encode()
                 |> Description.parse(),
               inspect(prefixes)
      end

      for apis <- [[], List.duplicate(api, 5), [Map.delete(api, "auth")]] do
        assert {:error, {:description_invalid, [{:schema, _}]}} =
                 anthropic
                 |> put_in(["roles", "model_provider", "apis"], apis)
                 |> encode()
                 |> Description.parse(),
               inspect(apis)
      end

      assert {:ok, _description} =
               anthropic
               |> put_in(["roles", "model_provider", "apis"], [
                 Map.put(api, "key_prefixes", ["sk-ant-"])
               ])
               |> encode()
               |> Description.parse()
    end

    test "is refused with an egress host that is a local name" do
      assert {:error, {:description_invalid, [{:schema, _}]}} =
               parse_fixture("invalid/description-egress-hosts-localhost.json")

      anthropic = vendored_description("anthropic")

      for host <- ["localhost", "api.localhost", "127.0.0.1", "169.254.169.254", "intranet"] do
        assert {:error, {:description_invalid, [{:schema, _}]}} =
                 anthropic |> Map.put("egress_hosts", [host]) |> encode() |> Description.parse(),
               host
      end
    end

    test "is refused with an egress host or a credential host that is a *. suffix" do
      for name <- ~w(egress-hosts-wildcard credential-hosts-wildcard) do
        assert {:error, {:description_invalid, [{:schema, _}]}} =
                 parse_fixture("invalid/description-#{name}.json"),
               name
      end

      anthropic = vendored_description("anthropic")

      for host <- ["*.example.com", "*.anthropic.com", "api.example.com\n"] do
        assert {:error, {:description_invalid, [{:schema, _}]}} =
                 anthropic
                 |> Map.update!("egress_hosts", &[host | &1])
                 |> encode()
                 |> Description.parse(),
               host
      end
    end

    test "is refused with a role that has a program, or with a program member" do
      assert {:error, {:description_invalid, [{:schema, _}]}} =
               parse_fixture("invalid/description-data-source.json")

      {:ok, tracker} = parse_fixture("example-tracker.json")
      anthropic = vendored_description("anthropic")

      assert {:error, {:description_invalid, [{:schema, _}]}} =
               anthropic
               |> put_in(["roles", "source"], tracker.document["roles"]["source"])
               |> encode()
               |> Description.parse()

      assert {:error, {:description_invalid, [{:schema, _}]}} =
               anthropic
               |> Map.put("program", "qory-anthropic")
               |> encode()
               |> Description.parse()
    end
  end

  describe "a description" do
    test "is read: its name, roles, secrets and plain settings" do
      assert {:ok, description} = parse(github_description())
      assert description.name == "github"
      assert description.program_version == "0.1.0"
      assert description.roles == ["credential"]
      assert description.secrets == [%{name: "private_key", title: "Private key"}]
      assert description.settings == ["api_url", "app_id"]
      refute Map.has_key?(description, :publisher)
    end

    test "is read when it holds only what the contract's shape holds" do
      minimal = %{
        "version" => 1,
        "name" => "acme-chat",
        "title" => "Acme chat",
        "program_version" => "0.1.0",
        "settings" => %{"type" => "object"},
        "roles" => %{"credential" => %{"argument" => "[a-z]+", "hosts" => ["chat.example.com"]}}
      }

      assert {:ok, %Description{roles: ["credential"], settings: [], secrets: []}} =
               parse(minimal)

      assert {:ok, %Description{domains: ["software"]}} =
               parse(Map.put(minimal, "domains", ["software"]))
    end

    test "is read with a role Qory Apiary does not know, which it leaves as it is" do
      assert {:ok, tracker} = parse(tracker_description())
      assert tracker.roles == ["acme_role", "credential"]

      assert tracker.document["roles"]["acme_role"] == %{"events" => ["issue.opened"]}
    end

    test "is refused with a role the schema does not name whose name breaks its pattern" do
      with_role = fn name ->
        update_in(tracker_description(), ["roles"], &Map.put(&1, name, %{"events" => []}))
      end

      assert {:ok, %Description{}} = parse(with_role.("acme_other"))

      for name <- ["Bad-Role", "acme-role", "1role", "Acme"] do
        assert {:error, {:description_invalid, [{:schema, summary}]}} = parse(with_role.(name)),
               name

        assert %{kind: :propertyNames, instanceLocation: "#/roles"} in summary.errors, name
      end
    end

    test "is refused with a role the schema does not name whose value is past a bound" do
      description =
        put_in(tracker_description(), ["roles", "acme_role", "events"], List.duplicate("e", 1025))

      assert {:error, {:description_invalid, [{:schema, %{limits: _}}]}} = parse(description)
    end

    test "takes its plain settings from the top level: neither a secret nor a secret's _file" do
      assert {:ok, tracker} = parse(tracker_description())
      assert tracker.settings == ["url"]
      assert tracker.secrets == [%{name: "api_key", title: "API key"}]
    end

    test "is refused with a publisher, or any other member the contract does not have" do
      assert {:error, {:description_invalid, [{:schema, _}]}} =
               parse(github_description(%{"publisher" => %{"name" => "Qory"}}))

      assert {:error, {:description_invalid, [{:schema, _}]}} =
               parse(github_description(%{"ways" => ["credential"]}))
    end

    test "is refused when its credential role lists settings or requires any" do
      for {key, value} <- [{"settings", ["app_id"]}, {"required", ["app_id"]}] do
        assert {:error, {:description_invalid, [{:schema, _}]}} =
                 parse(put_in(github_description(), ["roles", "credential", key], value))
      end
    end

    test "is refused when its credential role has no argument, or no hosts" do
      for key <- ["argument", "hosts"] do
        description =
          update_in(github_description(), ["roles", "credential"], &Map.delete(&1, key))

        assert {:error, {:description_invalid, [{:schema, _}]}} = parse(description)
      end

      assert {:error, {:description_invalid, [{:schema, _}]}} =
               parse(put_in(github_description(), ["roles", "credential", "hosts"], []))
    end

    test "is refused when it is no JSON object, or the schema refuses it" do
      assert {:error, {:description_invalid, [:not_json]}} = Description.parse("{")
      assert {:error, {:description_invalid, [:not_an_object]}} = Description.parse("[]")

      assert {:error, {:description_invalid, _}} =
               parse(github_description(%{"name" => "github\n"}))

      assert {:error, {:description_invalid, _}} = parse(github_description(%{"version" => 2}))
    end

    test "is refused for a secret without its _file, or nested in another setting" do
      description = github_description()

      without_file =
        update_in(description, ["settings", "properties"], &Map.delete(&1, "private_key_file"))

      assert {:error, {:description_invalid, [{:secret_without_file, "private_key"}]}} =
               parse(without_file)

      nested =
        put_in(description, ["settings", "properties", "app"], %{
          "type" => "object",
          "properties" => %{"key" => %{"type" => "string", "writeOnly" => true}}
        })

      assert {:error, {:description_invalid, [{:secret_nested, "app"}]}} = parse(nested)
    end

    test "names a secret by its title, or by its name when it has none" do
      untitled =
        update_in(
          github_description(),
          ["settings", "properties", "private_key"],
          &Map.delete(&1, "title")
        )

      assert {:ok, %Description{secrets: [%{name: "private_key", title: "private_key"}]}} =
               parse(untitled)
    end

    test "is refused when its credential argument does not compile" do
      bad = put_in(github_description(), ["roles", "credential", "argument"], "(")

      assert {:error, {:description_invalid, [{:argument_invalid, "credential"}]}} = parse(bad)
    end
  end

  describe "a member name held twice" do
    # The text of `description` with `raw`, JSON text, in place of the value at `path`.
    defp with_raw(description, path, raw) do
      marker = "raw-value-placeholder"
      description |> put_in(path, marker) |> encode() |> String.replace(~s("#{marker}"), raw)
    end

    defp repeated?(text),
      do: Description.parse(text) == {:error, {:description_invalid, [:member_repeated]}}

    test "is refused at the top level, the same value or another" do
      text = encode(tracker_description())
      assert {:ok, _} = Description.parse(text)

      assert repeated?(String.replace(text, ~s("version":1), ~s("version":1,"version":1)))
      assert repeated?(String.replace(text, ~s("version":1), ~s("version":1,"version":2)))
    end

    test "is refused nested in the settings, in a role, or in an object in a list" do
      in_settings =
        with_raw(github_description(), ["settings", "properties", "app_id"], ~s(
          {"type": "integer", "title": "App ID", "type": "string"}
        ))

      in_role =
        with_raw(github_description(), ["roles", "credential", "hosts"], ~s(
          ["api.github.com"], "hosts": ["github.com"]
        ))

      in_list =
        with_raw(github_description(), ["settings", "allOf"], ~s(
          [{"required": ["app_id"]}, {"required": ["app_id"], "required": []}]
        ))

      for text <- [in_settings, in_role, in_list], do: assert(repeated?(text))
    end

    test "is refused when the two names differ only in how they are escaped" do
      text =
        with_raw(github_description(), ["settings", "properties", "app_id"], ~s(
          {"type": "integer", "\\u0074ype": "string"}
        ))

      assert text =~ ~S("\u0074ype")
      assert repeated?(text)

      once = with_raw(github_description(), ["settings", "properties", "app_id"], ~s(
        {"\\u0074ype": "integer"}
      ))

      assert {:ok, _} = Description.parse(once)
    end

    test "is refused, as a string of invalid UTF-8 or a lone surrogate is" do
      text = encode(tracker_description(%{"settings" => %{"type" => "object"}}))
      assert {:ok, _} = Description.parse(text)

      assert repeated?(
               String.replace(text, ~s({"type":"object"}), ~s({"type":"object","type":"object"}))
             )

      for title <- [<<"Acme ", 0xFF, " tracker">>, ~S(Acme \ud800 tracker)] do
        broken = String.replace(text, ~s("Acme tracker"), ~s("#{title}"))
        assert broken != text
        assert {:error, {:description_invalid, [:not_json]}} = Description.parse(broken)
      end
    end

    test "is not found in any accepted fixture" do
      for file <- Path.wildcard(Path.join(@fixtures, "*.json")) do
        assert {:ok, %Description{}} = file |> File.read!() |> Description.parse(),
               Path.basename(file)
      end
    end

    test "makes a stored release's description unreadable, as any refusal does" do
      text = encode(github_description())
      assert {:ok, %Description{name: "github"}} = Integrations.description(ready(text))

      repeated = String.replace(text, ~s("version":1), ~s("version":1,"version":1))
      assert repeated?(repeated)
      assert Integrations.description(ready(repeated)) == {:error, :not_ready}
    end

    defp ready(bytes), do: %Release{state: "ready", description: bytes}

    # A description of 256 KiB, the most a release's description.json may be, whose
    # domains are 30001 objects; the last repeats its member when `repeat` is true.
    defp many_objects(repeat) do
      last = if repeat, do: ~s({"k":0,"k":1}), else: ~s({"k":0,"j":1})
      list = Enum.join(List.duplicate(~s({"k":0}), 30_000) ++ [last], ",")
      text = with_raw(tracker_description(), ["domains"], "[#{list}]")
      padding = 262_144 - byte_size(text) - byte_size(~s(,"x":""))
      text = String.replace_suffix(text, "}", ~s(,"x":"#{String.duplicate("p", padding)}"}))
      assert byte_size(text) == 262_144
      text
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

    test "is found within 5000000 reductions in a description of 256 KiB and 30001 objects" do
      for {repeat, expected} <- [{true, :member_repeated}, {false, :limits}] do
        text = many_objects(repeat)
        {reductions, result} = reductions(fn -> Description.parse(text) end)
        assert reductions < 5_000_000, "#{reductions} reductions"

        case expected do
          :member_repeated ->
            assert result == {:error, {:description_invalid, [:member_repeated]}}

          :limits ->
            assert {:error, {:description_invalid, [{:schema, %{limits: _}}]}} = result
        end
      end
    end
  end

  describe "a connection's settings" do
    setup do
      {:ok, description} = parse(github_description())
      %{description: description}
    end

    test "are its plain settings, valid against the description", %{description: description} do
      assert Description.check_settings(description, %{"app_id" => "123456"}) == :ok
      assert Description.check_settings(description, %{}) == :ok

      assert {:error, {:integration_settings_invalid, %{valid: false}}} ==
               Description.check_settings(description, %{"app_id" => "not an id"})

      assert {:error, {:integration_settings_invalid, %{valid: false}}} ==
               Description.check_settings(description, %{"app_id" => "1\n"})
    end

    test "never hold a secret, a secret's _file, or a name the description does not have",
         %{description: description} do
      assert Description.check_settings(description, %{"api_url" => "https://api.github.com"}) ==
               :ok

      assert {:error, {:integration_settings_not_allowed, ["private_key_file"]}} =
               Description.check_settings(description, %{"private_key_file" => "/etc/key.pem"})

      assert {:error, {:integration_settings_not_allowed, ["private_key"]}} =
               Description.check_settings(description, %{"private_key" => "-----BEGIN"})

      assert {:error, {:integration_settings_not_allowed, ["region"]}} =
               Description.check_settings(description, %{"region" => "eu"})
    end

    test "are each checked against its own property, never a rule across settings" do
      across =
        github_description()
        |> put_in(["settings", "required"], ["app_id"])
        |> put_in(["settings", "oneOf"], [
          %{"required" => ["private_key"]},
          %{"required" => ["private_key_file"]}
        ])

      assert {:ok, description} = parse(across)
      assert Description.check_settings(description, %{"app_id" => "123456"}) == :ok
      assert Description.check_settings(description, %{}) == :ok

      assert {:error, {:integration_settings_invalid, _}} =
               Description.check_settings(description, %{"app_id" => "not an id"})
    end

    test "are at most 64 KiB as canonical JSON", %{description: description} do
      assert {:error, {:integration_settings_too_large, 65_536}} =
               Description.check_settings(description, %{
                 "app_id" => String.duplicate("a", 65_536)
               })
    end

    test "an argument matches the credential role's pattern whole", %{description: description} do
      assert Description.check_argument(description, nil) == :ok
      assert Description.check_argument(description, "acme/shop") == :ok

      assert {:error, {:integration_argument_not_allowed, ["credential"]}} =
               Description.check_argument(description, "acme/shop\n")

      assert {:error, {:integration_argument_not_allowed, ["credential"]}} =
               Description.check_argument(description, "acme")
    end
  end

  describe "the size of a description, and of its settings" do
    # The limits refuse each input below before JSV reads it. Without them, JSV and the
    # normalising of its errors took about 3 to 5 s on the slowest descriptions below and
    # about 3 s on the slowest settings, and JSV alone over 0.25 s on some of them. Which
    # inputs the limits refuse is asserted, not the time: a refusal by the limits carries
    # them, `%{limits: _}`, and one by the schema does not; that JSV never reads an input
    # the limits refuse is asserted by tracing (`Apiary.Kinds.BoundsCallersTest`).

    setup do
      # The schemas are built once; the first check pays for it.
      assert {:ok, _} = parse(tracker_description())
      assert {:ok, description} = parse(unbounded_settings())
      %{description: description}
    end

    defp entries(entry, count), do: Enum.join(List.duplicate(entry, count), ",")

    # A role name for each integer: a, b, ..., z, aa, ab, ...
    defp letters(i) when i < 26, do: <<?a + i>>
    defp letters(i), do: letters(div(i, 26) - 1) <> <<?a + rem(i, 26)>>

    defp with_domains(list),
      do:
        String.replace(
          encode(tracker_description(%{"domains" => ["software"]})),
          ~s("domains":["software"]),
          ~s("domains":[#{list}])
        )

    defp nested(key, depth, inner),
      do: Enum.reduce(1..depth, inner, fn _, acc -> %{key => acc} end)

    defp limited?({:error, {:description_invalid, [{:schema, %{limits: _}}]}}), do: true
    defp limited?({:error, {:integration_settings_invalid, %{limits: _}}}), do: true
    defp limited?(_result), do: false

    defp attacks do
      [
        with_domains(entries("{}", 40_000)),
        with_domains(entries("1", 60_000)),
        encode(tracker_description(%{"roles" => Map.new(0..10_999, &{letters(&1), %{}})})),
        encode(put_in(tracker_description(), ["settings", "allOf"], List.duplicate(1, 60_000))),
        encode(put_in(tracker_description(), ["settings", "not"], nested("not", 15_000, %{}))),
        encode(
          put_in(
            tracker_description(),
            ["settings", "$id"],
            "https://example.com/" <> String.duplicate("a", 200_000)
          )
        )
      ]
    end

    # A description whose settings schema bounds nothing: a list of any length, a list of
    # any length whose every entry is a string of one of 32 patterns, an object of any
    # members, any value, and a tree of lists of any depth.
    defp unbounded_settings do
      tracker_description(%{
        "settings" => %{
          "type" => "object",
          "properties" => %{
            "list" => %{"type" => "array", "items" => %{"type" => "string"}},
            "choice" => %{
              "type" => "array",
              "items" => %{
                "anyOf" =>
                  for(
                    i <- 1..32,
                    do: %{"type" => "string", "pattern" => "^p#{i}-[0-9]+$"}
                  )
              }
            },
            "map" => %{"type" => "object", "additionalProperties" => %{"type" => "string"}},
            "any" => %{},
            "tree" => %{"$ref" => "#/$defs/tree"}
          },
          "$defs" => %{"tree" => %{"type" => "array", "items" => %{"$ref" => "#/$defs/tree"}}}
        }
      })
    end

    defp settings_attacks do
      [
        %{"list" => List.duplicate(1, 30_000)},
        %{"list" => List.duplicate(%{}, 20_000)},
        %{"choice" => List.duplicate(1, 30_000)},
        %{"map" => Map.new(1..6000, &{"k#{&1}", 1})},
        %{"any" => List.duplicate(1, 30_000)},
        %{"tree" => Enum.reduce(1..30_000, [], fn _, inner -> [inner] end)}
      ]
    end

    # A valid description at the limits: 1024 domains, a settings schema of 1000
    # properties and 64 lists and objects deep, a description of 16 KiB, 4096 values in all.
    # The document, `settings` and the outermost `not` are 3 deep; 61 more objects nest in it.
    defp largest do
      domains = for i <- 1..1024, do: "d#{i}"
      properties = Map.new(1..1000, &{"p#{&1}", %{"type" => "string"}})
      deep = nested("not", 61, %{})

      document =
        tracker_description(%{
          "domains" => domains,
          "description" => String.duplicate("d", 16_384)
        })
        |> update_in(["settings", "properties"], &Map.merge(&1, properties))
        |> put_in(["settings", "not"], deep)

      # `examples` holds a list that holds the filler: two values more.
      filler = for i <- 1..(4096 - values(document) - 2), do: "e#{i}"
      put_in(document, ["settings", "examples"], [filler])
    end

    defp values(value) when is_map(value),
      do: 1 + (value |> Map.values() |> Enum.map(&values/1) |> Enum.sum())

    defp values(value) when is_list(value), do: 1 + (value |> Enum.map(&values/1) |> Enum.sum())
    defp values(_value), do: 1

    test "a description of 262144 bytes is read, and one of a byte more refused unread" do
      text = encode(tracker_description())
      # JSON allows whitespace after the document: it counts as the document's bytes.
      padded = text <> String.duplicate(" ", 262_144 - byte_size(text))
      assert byte_size(padded) == Description.max_bytes()
      assert {:ok, %Description{}} = Description.parse(padded)

      assert Description.parse(padded <> " ") ==
               {:error, {:description_invalid, [:too_large]}}
    end

    test "a description over the limits is refused by them" do
      for text <- attacks() do
        assert byte_size(text) in 90_000..262_144
        assert limited?(Description.parse(text))
      end
    end

    test "a valid description at the limits is read, and one value, entry or byte more is refused" do
      document = largest()
      assert values(document) == 4096
      text = encode(document)
      assert byte_size(text) > 30_000
      assert {:ok, %Description{}} = Description.parse(text)

      # One string more in the filler: 4097 values, while the filler stays within 1024
      # entries, so the total alone passes a limit.
      one_more =
        update_in(document, ["settings", "examples"], fn [filler] -> [["e0" | filler]] end)

      assert values(one_more) == 4097
      assert length(hd(one_more["settings"]["examples"])) <= 1024

      for over <- [
            one_more,
            Map.put(document, "domains", for(i <- 1..1025, do: "d#{i}")),
            Map.put(document, "description", String.duplicate("d", 16_385)),
            put_in(document, ["settings", "not"], nested("not", 62, %{}))
          ] do
        assert limited?(parse(over))
      end
    end

    test "a settings schema nested deep inside a description is refused by the limits" do
      # The settings schema `check_settings/2` builds from is a part of the description's
      # `settings`, so the description's limits bound it. Without them, the description
      # schema's check of a property nested 15000 deep did about 471 million reductions;
      # the limits refuse it at the 65th level, after the document is decoded.
      for {at, deep} <- [
            {["settings", "properties", "url", "not"], nested("not", 15_000, %{})},
            {["settings", "properties", "url", "items"], nested("items", 15_000, %{})},
            {["settings", "not"], nested("not", 15_000, %{})},
            {["settings", "$defs"], %{"deep" => nested("properties", 15_000, %{})}}
          ] do
        text = encode(put_in(tracker_description(), at, deep))
        {count, result} = reductions(fn -> Description.parse(text) end)

        assert limited?(result), inspect(at)
        assert count < 5_000_000, "#{inspect(at)}: #{count} reductions"
      end
    end

    test "every fixture is within the limits, but those that pass a bound" do
      over =
        ~w(invalid/description-settings-enum-1025-entries.json
           invalid/description-settings-properties-1025-members.json
           invalid/description-string-16385-characters.json)

      names =
        fixture_names("*.json") ++
          fixture_names("invalid/*.json") ++ fixture_names("refused-by-reader/*.json")

      assert Enum.all?(over, &(&1 in names))

      for name <- names do
        assert limited?(parse_fixture(name)) == name in over, name
      end
    end

    test "settings over the limits are refused by them, whatever their schema",
         %{description: description} do
      for settings <- settings_attacks() do
        assert byte_size(Apiary.Kinds.CanonicalJSON.encode!(settings)) in 50_000..65_536
        assert limited?(Description.check_settings(description, settings))
      end
    end

    test "valid settings at the limits pass", %{description: description} do
      # The settings and 63 lists nested in them are 64 deep; `any` fills them to 4096 values.
      settings = %{
        "list" => for(i <- 1..1024, do: "s#{i}"),
        "choice" => for(i <- 1..1024, do: "p32-#{i}"),
        "map" => Map.new(1..1024, &{"k#{&1}", "v"}),
        "tree" => Enum.reduce(1..62, [], fn _, inner -> [inner] end)
      }

      settings = Map.put(settings, "any", List.duplicate(1, 4096 - values(settings) - 1))
      assert values(settings) == 4096

      # Valid settings pass however slow or busy the machine: the budget decides by
      # reductions, the same on any machine running the same OTP release, so the time is
      # not asserted.
      assert Description.check_settings(description, settings) == :ok

      for over <- [
            %{"list" => for(i <- 1..1025, do: "s#{i}")},
            %{"map" => Map.new(1..1025, &{"k#{&1}", "v"})},
            %{"tree" => Enum.reduce(1..63, [], fn _, inner -> [inner] end)},
            Map.update!(settings, "any", &[1 | &1])
          ] do
        assert limited?(Description.check_settings(description, over))
      end
    end

    test "a refusal by the schema is no refusal by the limits", %{description: description} do
      refused = Description.check_settings(description, %{"list" => [1]})
      assert refused == {:error, {:integration_settings_invalid, %{valid: false}}}
      refute limited?(refused)

      assert {:error, {:description_invalid, [{:schema, _}]}} =
               refused = parse(tracker_description(%{"version" => 2}))

      refute limited?(refused)
    end
  end

  describe "the budget of the settings check" do
    # The settings schema comes from the description, and a few of its references can make
    # the check's work grow exponentially, which no limit on the settings bounds. The check
    # runs in another process within 5000000 reductions and 16 MiB of heap, which count
    # the work and not the time, so which one each check runs out of is the same on any
    # machine running the same OTP release; one over that budget is refused as invalid
    # settings, `budget: :exceeded`, and the warning it logs says which. Without the
    # budget, measured: 1.2 s to 1.7 s at 20 levels of allOf and for 1000 patterns against
    # 1024 strings, 5 s to 5.7 s and 1.19 GB at 20 levels of allOf whose leaf refuses the
    # value, 5.6 s at 20 levels of anyOf, 33 s at 24 levels of allOf and over 30 s in
    # draft-07; 24 s to 28 s for 1000 backtracking patterns against a string of 60001
    # bytes, 15 s against 128 settings, 9.5 s against a list of 100 strings, and 13.3 s for
    # 1000 email formats against a string of 60 KB. With it, each ran out within 350 ms.
    # The reason is asserted and the time is not: a check its time stopped, 10 s, would log
    # `reason=time`.

    defp with_settings_schema(schema) do
      assert {:ok, description} = parse(tracker_description(%{"settings" => schema}))
      description
    end

    # A schema whose every level refers twice to the next, in `keyword`: 2^levels checks of
    # one value, which the last level takes as `last` says. The definitions are in
    # `defs`, `$defs`, or `definitions` under draft-07.
    defp doubling(levels, keyword \\ "allOf", last \\ "string", defs \\ "$defs") do
      chain =
        Map.new(1..levels, fn i ->
          next = %{"$ref" => "#/#{defs}/d#{i + 1}"}
          {"d#{i}", %{keyword => [next, next]}}
        end)

      schema = %{
        "type" => "object",
        "properties" => %{"a" => %{"$ref" => "#/#{defs}/d1"}},
        defs => Map.put(chain, "d#{levels + 1}", %{"type" => last})
      }

      if defs == "definitions",
        do:
          with_settings_schema(
            Map.put(schema, "$schema", "http://json-schema.org/draft-07/schema#")
          ),
        else: with_settings_schema(schema)
    end

    # The refusal, and the budget it ran out of, `reason`: "reductions" or "heap". The
    # caller does little of the work: the check runs in another process, stopped at the
    # budget.
    defp over_budget(description, settings, reason) do
      {{caller, result}, log} =
        with_log(fn ->
          reductions(fn -> Description.check_settings(description, settings) end)
        end)

      assert result ==
               {:error, {:integration_settings_invalid, %{valid: false, budget: :exceeded}}}

      assert log =~ "settings check was stopped name=acme-tracker"
      assert log =~ ~r/reason=(#{reason})$/m
      assert caller < 1_000_000, "#{caller} reductions in the caller"
    end

    # 1000 backtracking patterns, each spending the pattern budget of JSV on a value.
    defp backtracking, do: %{"anyOf" => for(_ <- 1..1000, do: %{"pattern" => "^(a+)+$"})}

    test "a schema that doubles its work at each of 20 or 24 levels runs out of reductions" do
      over_budget(doubling(20), %{"a" => "s"}, "reductions")
      over_budget(doubling(24), %{"a" => "s"}, "reductions")
    end

    test "so does one in draft-07, its definitions in definitions" do
      over_budget(doubling(24, "allOf", "string", "definitions"), %{"a" => "s"}, "reductions")
      over_budget(doubling(24, "allOf", "string", "definitions"), %{"a" => 1}, "heap")
    end

    test "a doubling schema whose leaf refuses the value runs out of heap, the errors kept" do
      over_budget(doubling(20), %{"a" => 1}, "heap")
      over_budget(doubling(20, "anyOf", "integer"), %{"a" => "s"}, "heap")
      over_budget(doubling(20, "oneOf"), %{"a" => 1}, "heap")
    end

    test "an anyOf of 16 or 18 levels, each referring twice to the next, runs out of heap" do
      over_budget(doubling(16, "anyOf", "integer"), %{"a" => "s"}, "heap")
      over_budget(doubling(18, "anyOf", "integer"), %{"a" => "s"}, "heap")
    end

    test "a schema of 1000 patterns for each of 1024 strings runs out of heap" do
      description =
        with_settings_schema(%{
          "type" => "object",
          "properties" => %{
            "x" => %{
              "type" => "array",
              "items" => %{
                "anyOf" => for(i <- 1..1000, do: %{"type" => "string", "pattern" => "^z#{i}$"})
              }
            }
          }
        })

      over_budget(description, %{"x" => List.duplicate("a", 1024)}, "heap")
    end

    test "1000 backtracking patterns run out of reductions on a long setting, 128, a list" do
      one =
        with_settings_schema(%{
          "type" => "object",
          "properties" => %{"s1" => %{"$ref" => "#/$defs/p"}},
          "$defs" => %{"p" => backtracking()}
        })

      over_budget(one, %{"s1" => String.duplicate("a", 60_000) <> "!"}, "reductions")

      many =
        with_settings_schema(%{
          "type" => "object",
          "properties" => Map.new(1..128, &{"s#{&1}", %{"$ref" => "#/$defs/p"}}),
          "$defs" => %{"p" => backtracking()}
        })

      over_budget(
        many,
        Map.new(1..128, &{"s#{&1}", String.duplicate("a", 60) <> "!"}),
        "reductions"
      )

      list =
        with_settings_schema(%{
          "type" => "object",
          "properties" => %{"l" => %{"type" => "array", "items" => backtracking()}}
        })

      over_budget(
        list,
        %{"l" => List.duplicate(String.duplicate("a", 24) <> "!", 100)},
        "reductions"
      )
    end

    # Without the budget, each of the next three checks passed 2000000000 reductions
    # unfinished.

    test "a $ref chain that doubles at each of 40 levels runs out of reductions" do
      over_budget(doubling(40), %{"a" => "s"}, "reductions")
    end

    test "a recursive anyOf of items against settings 64 deep runs out of heap" do
      description =
        with_settings_schema(%{
          "type" => "object",
          "properties" => %{"t" => %{"$ref" => "#/$defs/t"}},
          "$defs" => %{
            "t" => %{
              "type" => "array",
              "anyOf" => [
                %{"items" => %{"$ref" => "#/$defs/t"}},
                %{"items" => %{"$ref" => "#/$defs/t"}}
              ]
            }
          }
        })

      # The settings and 63 lists nested in them are 64 deep. The innermost holds 1, which
      # `t` refuses, so each level tries both branches.
      settings = %{"t" => Enum.reduce(1..62, [1], fn _, inner -> [inner] end)}
      over_budget(description, settings, "heap")
    end

    test "1000 backtracking patterns in items.oneOf against 1024 strings run out of reductions" do
      description =
        with_settings_schema(%{
          "type" => "object",
          "properties" => %{
            "x" => %{
              "type" => "array",
              "items" => %{"oneOf" => for(_ <- 1..1000, do: %{"pattern" => "^(a+)+$"})}
            }
          }
        })

      settings = %{"x" => List.duplicate(String.duplicate("a", 59) <> "!", 1024)}
      assert byte_size(Apiary.Kinds.CanonicalJSON.encode!(settings)) in 60_000..65_536
      over_budget(description, settings, "reductions")
    end

    test "1000 email formats against a string of 60 KB run out of heap" do
      description =
        with_settings_schema(%{
          "type" => "object",
          "properties" => %{"e" => %{"allOf" => for(_ <- 1..1000, do: %{"format" => "email"})}}
        })

      over_budget(description, %{"e" => String.duplicate("a", 60_000) <> "@"}, "heap")
    end

    test "a schema that doubles its work at each of 10 levels passes, as do 1000 settings" do
      assert Description.check_settings(doubling(10), %{"a" => "s"}) == :ok

      description =
        with_settings_schema(%{
          "type" => "object",
          "properties" =>
            Map.new(1..1000, &{"p#{&1}", %{"type" => "string", "pattern" => "^[a-z0-9]{1,40}$"}})
        })

      settings = Map.new(1..1000, &{"p#{&1}", "value#{&1}"})
      assert Description.check_settings(description, settings) == :ok
    end

    test "valid settings pass against a description of many long strings, parts of its bytes" do
      # `count` settings, each described in a string of `length` bytes.
      described = fn count, length ->
        properties =
          Map.new(1..count, fn i ->
            text = String.slice("d#{i}-" <> String.duplicate("x", length), 0, length)
            {"p#{i}", %{"type" => "string", "description" => text}}
          end)

        bytes =
          tracker_description(%{"settings" => %{"type" => "object", "properties" => properties}})
          |> encode()

        assert {:ok, description} = Description.parse(bytes)
        text = description.document["settings"]["properties"]["p1"]["description"]
        assert :binary.referenced_byte_size(text) == byte_size(bytes)
        {description, byte_size(bytes)}
      end

      {four_hundred, _bytes} = described.(400, 100)
      assert Description.check_settings(four_hundred, %{"p1" => "x"}) == :ok

      # Near the 262144 bytes a release's description may have.
      {thousand, bytes} = described.(1000, 215)
      assert bytes in 250_000..262_144
      assert Description.check_settings(thousand, %{"p1" => "x"}) == :ok
      assert Description.check_settings(thousand, Map.new(1..1000, &{"p#{&1}", "x"})) == :ok
    end

    test "every fixture with settings takes the settings it describes" do
      assert {:ok, fixture} =
               @fixtures |> Path.join("github.json") |> File.read!() |> Description.parse()

      assert Description.check_settings(fixture, %{
               "app_id" => 123_456,
               "installation_id" => 7,
               "permissions" => %{"contents" => "read"},
               "api_url" => "http://localhost:8080"
             }) == :ok

      assert {:ok, tracker} = parse(tracker_description())
      assert Description.check_settings(tracker, %{"url" => "https://tracker.example.com"}) == :ok
    end
  end

  describe "the memory of the settings schema's patterns" do
    # A compiled pattern is memory outside the heap, which the budget does not count: each
    # `(?:a){7900}b<i>` compiles to about 64 KB. Measured on main before the estimate,
    # the build of 1950 of them took the node 126 MiB more memory.
    defp heavy(i), do: %{"pattern" => "(?:a){7900}b#{i}"}

    test "a schema of 1950 patterns of about 64 KB each is stopped before its build" do
      description =
        with_settings_schema(%{
          "type" => "object",
          "properties" => %{
            "x" => %{
              "allOf" =>
                for(c <- Enum.chunk_every(1..1950, 1000), do: %{"allOf" => Enum.map(c, &heavy/1)})
            }
          }
        })

      over_budget(description, %{"x" => "b"}, "patterns")
    end

    # JSV builds the target of each distinct reference: 26 pointers, each into the one
    # before, build the 30 patterns 26 times.
    test "so is a schema whose 30 such patterns 26 nested pointers build again" do
      description =
        with_settings_schema(%{
          "type" => "object",
          "properties" =>
            Map.new(
              0..25,
              &{"r#{&1}", %{"$ref" => "#/$defs/p" <> String.duplicate("/allOf/0", &1)}}
            ),
          "$defs" => %{
            "p" =>
              Enum.reduce(1..25, %{"allOf" => Enum.map(1..30, &heavy/1)}, fn _, inner ->
                %{"allOf" => [inner]}
              end)
          }
        })

      over_budget(description, Map.new(0..25, &{"r#{&1}", "b"}), "patterns")
    end

    # Each value checked against `"format": "regex"` is compiled once
    # (`Apiary.Kinds.RegexFormat`). Measured on main before the estimate, 1950 values of
    # `(?:a){7900}b<i>`, 35958 bytes of settings, passed and took the node 120 MiB more
    # memory.
    defp regex_lists do
      with_settings_schema(%{
        "type" => "object",
        "properties" => %{
          "l1" => %{"type" => "array", "items" => %{"type" => "string", "format" => "regex"}},
          "l2" => %{"type" => "array", "items" => %{"type" => "string", "format" => "regex"}}
        }
      })
    end

    test "settings of 1950 regular expressions of about 64 KB each are stopped before they compile" do
      {l1, l2} = Enum.split(for(i <- 1..1950, do: "(?:a){7900}b#{i}"), 1024)
      over_budget(regex_lists(), %{"l1" => l1, "l2" => l2}, "patterns")
    end

    test "settings of 2048 ordinary regular expressions are checked" do
      settings = %{
        "l1" => for(i <- 1..1024, do: "^v#{i}-[a-z0-9]{1,40}$"),
        "l2" => for(i <- 1..1024, do: "(?i)^w#{i}(-[0-9]+)*$")
      }

      assert Description.check_settings(regex_lists(), settings) == :ok
    end

    test "100 such patterns are built and checked" do
      description =
        with_settings_schema(%{
          "type" => "object",
          "properties" => %{"x" => %{"allOf" => Enum.map(1..100, &heavy/1)}}
        })

      assert Description.check_settings(description, %{"x" => "b"}) ==
               {:error, {:integration_settings_invalid, %{valid: false}}}
    end
  end

  describe "the refusal of settings the schema refuses" do
    # A pattern of 16001 bytes, which "b" does not match.
    defp long_pattern(i), do: "^" <> String.duplicate("a", 16_000) <> "#{i}"

    # A list of `count` strings, each checked against `patterns` long patterns in
    # items.allOf: an error for each pattern and string, whose normalised message copies
    # the pattern.
    defp long_patterns(patterns, count) do
      description =
        with_settings_schema(%{
          "type" => "object",
          "properties" => %{
            "x" => %{
              "type" => "array",
              "items" => %{"allOf" => for(i <- 1..patterns, do: %{"pattern" => long_pattern(i)})}
            }
          }
        })

      {description, %{"x" => List.duplicate("b", count)}}
    end

    # The binary bytes a process refers to, each binary once, its heap collected first.
    defp binary_bytes do
      :erlang.garbage_collect()
      {:binary, binaries} = Process.info(self(), :binary)
      binaries |> Enum.uniq_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    end

    # The result of the check, and the binary bytes the caller, a separate Task, refers to
    # once it returns, the result still held.
    defp held(description, settings) do
      Task.async(fn ->
        before = binary_bytes()
        result = Description.check_settings(description, settings)
        {result, binary_bytes() - before}
      end)
      |> Task.await(60_000)
    end

    test "is %{valid: false} alone, and hands the caller no large binaries" do
      # Measured when the refusal carried JSV's normalised errors: 32845824 and 30793728
      # bytes in the caller.
      for {patterns, count} <- [{2, 1024}, {15, 128}] do
        {description, settings} = long_patterns(patterns, count)
        {result, bytes} = held(description, settings)

        assert result == {:error, {:integration_settings_invalid, %{valid: false}}}
        assert bytes < 1_000_000, "#{bytes} binary bytes in the caller"
      end
    end

    test "JSV's normalised errors for them are stopped by the heap budget, binaries counted" do
      # The budget counts the binaries its process refers to: a check whose errors are
      # normalised, their messages made in its process, runs out of heap.
      for {patterns, count} <- [{2, 1024}, {15, 128}] do
        {description, settings} = long_patterns(patterns, count)
        schema = description.document["settings"]

        check = fn ->
          {:ok, root} = Schema.build(schema)
          {:error, error} = JSV.validate(settings, root, cast: false)
          JSV.normalize_error(error)
        end

        assert Budget.run(check, reductions: 5_000_000, heap_words: 2_097_152, ms: 10_000) ==
                 {:error, :heap}
      end
    end
  end

  describe "a settings schema's casts" do
    # A module on the code path, compiled and then unloaded: building a schema that names
    # it in a cast, or refers to it with `jsv:module:`, loads it.
    defp unloaded_module(dir) do
      module = :"Elixir.Apiary.CastProbe#{System.unique_integer([:positive])}"

      source = """
      defmodule #{inspect(module)} do
        def cast(value), do: {:ok, value}
        def json_schema, do: %{"type" => "string"}
      end
      """

      [{^module, beam}] = Code.compile_string(source)
      File.write!(Path.join(dir, "#{module}.beam"), beam)
      :code.purge(module)
      :code.delete(module)
      :code.purge(module)
      true = :code.add_patha(String.to_charlist(dir))
      on_exit(fn -> :code.del_path(String.to_charlist(dir)) end)
      refute :code.is_loaded(module)
      module
    end

    defp tracker_with(settings) do
      assert {:ok, description} =
               tracker_description()
               |> update_in(["settings"], &Map.merge(&1, settings))
               |> parse()

      description
    end

    @tag :tmp_dir
    test "are left out at any depth, and the module a cast names is never loaded",
         %{tmp_dir: dir} do
      short = %{"type" => "string", "maxLength" => 5}

      for settings <- [
            &%{"properties" => %{"url" => Map.put(short, "jsv-cast", [&1, "cast"])}},
            &%{"properties" => %{"url" => Map.put(short, "x-jsv-cast", [[&1, "cast"]])}},
            &%{
              "$defs" => %{"short" => Map.put(short, "jsv-cast", [&1, "cast"])},
              "properties" => %{"url" => %{"$ref" => "#/$defs/short"}}
            },
            # A `$ref` into a value builds the value as a schema.
            &%{
              "$defs" => %{"short" => %{"const" => Map.put(short, "jsv-cast", [&1, "cast"])}},
              "properties" => %{"url" => %{"$ref" => "#/$defs/short/const"}}
            },
            &%{
              "$defs" => %{"short" => %{"default" => Map.put(short, "x-jsv-cast", &1)}},
              "properties" => %{"url" => %{"$ref" => "#/$defs/short/default"}}
            }
          ] do
        module = unloaded_module(dir)
        description = tracker_with(settings.(Atom.to_string(module)))

        assert Description.check_settings(description, %{"url" => "abc"}) == :ok

        assert {:error, {:integration_settings_invalid, _}} =
                 Description.check_settings(description, %{"url" => "abcdefgh"})

        refute :code.is_loaded(module)

        # Built with its casts, the same schema loads the module, which has no `__jsv__`.
        assert {:error, _} = Schema.build(description.document["settings"])
        assert {:file, _} = :code.is_loaded(module)
      end
    end

    test "leave out a setting's schema, or a key in a const, named like a cast" do
      description =
        tracker_with(%{
          "properties" => %{
            "jsv-cast" => %{"type" => "integer"},
            "mode" => %{"const" => %{"x-jsv-cast" => "kept"}}
          }
        })

      # Its schema left out, the setting is checked like one the schema does not name.
      assert Description.check_settings(description, %{"jsv-cast" => "three"}) == :ok
      assert Description.check_settings(description, %{"mode" => %{}}) == :ok
    end
  end

  describe "a settings schema's jsv: references" do
    @describetag :tmp_dir

    test "are answered with a schema no value meets, and the module named is never loaded",
         %{tmp_dir: dir} do
      for settings <- [
            &%{"properties" => %{"url" => %{"$ref" => "jsv:module:" <> &1}}},
            &%{"properties" => %{"url" => %{"$ref" => "JSV:module:" <> &1}}},
            &%{"properties" => %{"url" => %{"$dynamicRef" => "jsv:module:" <> &1}}},
            &%{
              "$defs" => %{"remote" => %{"$ref" => "jsv:module:" <> &1}},
              "properties" => %{"url" => %{"$ref" => "#/$defs/remote"}}
            },
            &%{"$schema" => "jsv:module:" <> &1, "properties" => %{"url" => %{}}}
          ] do
        module = unloaded_module(dir)
        description = tracker_with(settings.(Atom.to_string(module)))

        assert {:error, {:integration_settings_invalid, _}} =
                 Description.check_settings(description, %{"url" => "abc"})

        refute :code.is_loaded(module)

        # Built with JSV's resolvers alone, the same schema loads the module.
        Schema.build(description.document["settings"])
        assert {:file, _} = :code.is_loaded(module)
      end
    end

    test "leave a subschema whose $id is a jsv: URI to its $ref", %{tmp_dir: dir} do
      module = unloaded_module(dir)
      id = "jsv:module:" <> Atom.to_string(module)

      description =
        tracker_with(%{
          "$defs" => %{"local" => %{"$id" => id, "type" => "integer"}},
          "properties" => %{"url" => %{"$ref" => id}}
        })

      assert Description.check_settings(description, %{"url" => 3}) == :ok

      assert {:error, {:integration_settings_invalid, _}} =
               Description.check_settings(description, %{"url" => "abc"})

      refute :code.is_loaded(module)
    end

    test "leave a schema with a meta-schema JSV embeds, and a local $ref, as it was" do
      short = %{"type" => "string", "maxLength" => 5}

      for settings <- [
            %{
              "$schema" => "https://json-schema.org/draft/2020-12/schema",
              "$defs" => %{"short" => short},
              "properties" => %{"url" => %{"$ref" => "#/$defs/short"}}
            },
            %{
              "$schema" => "http://json-schema.org/draft-07/schema#",
              "definitions" => %{"short" => short},
              "properties" => %{"url" => %{"$ref" => "#/definitions/short"}}
            }
          ] do
        description = tracker_with(settings)

        assert Description.check_settings(description, %{"url" => "abc"}) == :ok

        assert {:error, {:integration_settings_invalid, _}} =
                 Description.check_settings(description, %{"url" => "abcdefgh"})
      end
    end
  end

  describe "egress_hosts/2" do
    defp with_address(egress_hosts, default \\ nil) do
      address =
        %{"title" => "Address", "type" => "string"}
        |> then(&if(default, do: Map.put(&1, "default", default), else: &1))

      {:ok, description} =
        tracker_description(%{
          "settings" => %{
            "type" => "object",
            "properties" => %{
              "address" => address,
              "api_key" => %{"title" => "API key", "type" => "string", "writeOnly" => true},
              "api_key_file" => %{"title" => "API key file", "type" => "string"}
            }
          },
          "egress_hosts" => egress_hosts
        })
        |> parse()

      description
    end

    test "is the host entries, and the host of a setting's address" do
      description = with_address(["api.example.com", %{"setting" => "address"}])

      assert Description.egress_hosts(description, %{
               "address" => "https://models.example.com:8443/v1"
             }) == {["api.example.com", "models.example.com"], []}

      assert Description.egress_hosts(description, %{"address" => "https://api.example.com"}) ==
               {["api.example.com"], []}
    end

    test "leaves out an address that the endpoint rule refuses, and names its setting" do
      description = with_address(["api.example.com", %{"setting" => "address"}])

      for address <- ["http://models.example.com", "https://localhost", "https://127.0.0.1"] do
        assert Description.egress_hosts(description, %{"address" => address}) ==
                 {["api.example.com"], ["address"]},
               address
      end

      assert Description.egress_hosts(description, %{}) == {["api.example.com"], []}
    end

    test "takes a setting's host only when it is exact" do
      description = with_address([%{"setting" => "address"}])

      for address <- [
            "https://*.example.com",
            "https://*.example.com/v1",
            "https://api.example.com\n",
            "https://api.example.com/v1\n",
            "https://010.0.0.12",
            "https://10.0.0.012",
            "https://10.1",
            "https://0x0a.0.0.12",
            "https://127.0.0.1"
          ] do
        assert Description.egress_hosts(description, %{"address" => address}) ==
                 {[], ["address"]},
               inspect(address)
      end

      # An address `a.b.c.d` is exact: it matches that address alone.
      assert Description.egress_hosts(description, %{"address" => "https://10.0.0.12/v1"}) ==
               {["10.0.0.12"], []}
    end

    test "reads the setting's default where the connection has no value" do
      description =
        with_address([%{"setting" => "address"}], "https://gateway.example.com/v1")

      assert Description.egress_hosts(description, %{}) == {["gateway.example.com"], []}

      assert Description.egress_hosts(description, %{"address" => "https://edge.example.com"}) ==
               {["edge.example.com"], []}

      description = with_address([%{"setting" => "address"}], "https://*.example.com")
      assert Description.egress_hosts(description, %{}) == {[], ["address"]}
    end

    test "is empty for a description without the member" do
      {:ok, description} = parse(tracker_description())
      assert Description.egress_hosts(description, %{}) == {[], []}
    end
  end
end
