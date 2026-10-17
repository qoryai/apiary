defmodule Apiary.Integrations.DescriptionTest do
  use ExUnit.Case, async: true

  import Apiary.DescriptionFixtures

  alias Apiary.Integrations.Description
  alias Apiary.Kinds.Schema

  @fixtures Path.expand("../../fixtures/integration-contract", __DIR__)

  defp parse(description), do: description |> encode() |> Description.parse()

  describe "the integrations contract's fixtures" do
    test "every accepted fixture is read" do
      for file <- Path.wildcard(Path.join(@fixtures, "*.json")) do
        assert {:ok, %Description{}} = file |> File.read!() |> Description.parse(),
               Path.basename(file)
      end
    end

    test "every refused fixture is refused" do
      files = Path.wildcard(Path.join(@fixtures, "invalid/*.json"))
      assert files != []

      for file <- files do
        assert {:error, {:description_invalid, _}} = file |> File.read!() |> Description.parse(),
               Path.basename(file)
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

  describe "a connection's settings" do
    setup do
      {:ok, description} = parse(github_description())
      %{description: description}
    end

    test "are its plain settings, valid against the description", %{description: description} do
      assert Description.check_settings(description, %{"app_id" => "123456"}) == :ok
      assert Description.check_settings(description, %{}) == :ok

      assert {:error, {:integration_settings_invalid, _}} =
               Description.check_settings(description, %{"app_id" => "not an id"})

      assert {:error, {:integration_settings_invalid, _}} =
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
end
