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

  describe "the size of a description, and of its settings" do
    # The limits refuse each input below before JSV reads it. Which inputs the limits
    # refuse is asserted, not the time: a refusal by the limits carries them,
    # `%{limits: _}`, and one by the schema does not.

    setup do
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

    # The reductions `fun` does, counted in a separate Task, and its result.
    defp reductions(fun) do
      Task.async(fn ->
        {:reductions, before} = Process.info(self(), :reductions)
        result = fun.()
        {:reductions, done} = Process.info(self(), :reductions)
        {done - before, result}
      end)
      |> Task.await(60_000)
    end

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
    # properties, the document 64 lists and objects deep, a `description` of 16 KiB, 4096
    # values in all. The document, `settings` and the outermost `not` are 3 deep; 61 more
    # objects nest in it.
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

    test "every fixture is within the limits" do
      files = Path.wildcard(Path.join(@fixtures, "*.json"))
      invalid = Path.wildcard(Path.join(@fixtures, "invalid/*.json"))
      assert files != [] and invalid != []

      for file <- files ++ invalid do
        refute limited?(file |> File.read!() |> Description.parse()), Path.basename(file)
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
      assert {:error, {:integration_settings_invalid, _}} =
               refused = Description.check_settings(description, %{"list" => [1]})

      refute limited?(refused)

      assert {:error, {:description_invalid, [{:schema, _}]}} =
               refused = parse(tracker_description(%{"version" => 2}))

      refute limited?(refused)
    end
  end
end
