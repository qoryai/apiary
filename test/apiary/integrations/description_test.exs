defmodule Apiary.Integrations.DescriptionTest do
  use ExUnit.Case, async: true

  import Apiary.DescriptionFixtures

  alias Apiary.Integrations.Description

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

  describe "the size of a description, and of its settings" do
    # A check takes less than this many milliseconds: the limits refuse each input below
    # in a few, where JSV and the normalising of its errors took up to 3.5 s for a
    # description and 2.9 s for settings, and JSV alone over 0.25 s on some of them; the
    # budget leaves room for a slow machine. Which inputs the limits refuse is asserted
    # apart from the time: a refusal by the limits carries them, `%{limits: _}`, and one
    # by the schema does not.
    @budget_ms 150

    setup do
      # The schemas are built once; the first check pays for it.
      assert {:ok, _} = parse(tracker_description())
      assert {:ok, description} = parse(unbounded_settings())
      %{description: description}
    end

    defp timed(fun) do
      {microseconds, result} = :timer.tc(fun)
      assert div(microseconds, 1000) < @budget_ms, "took #{div(microseconds, 1000)} ms"
      result
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

    test "a description over the limits is refused by them, at once" do
      for text <- attacks() do
        assert byte_size(text) in 90_000..262_144
        assert limited?(timed(fn -> Description.parse(text) end))
      end
    end

    test "a valid description at the limits is read, and one value, entry or byte more is refused" do
      document = largest()
      assert values(document) == 4096
      text = encode(document)
      assert byte_size(text) > 30_000
      assert {:ok, %Description{}} = timed(fn -> Description.parse(text) end)

      for over <- [
            update_in(document, ["settings", "examples"], &[["one more"] | &1]),
            Map.put(document, "domains", for(i <- 1..1025, do: "d#{i}")),
            Map.put(document, "description", String.duplicate("d", 16_385)),
            put_in(document, ["settings", "not"], nested("not", 62, %{}))
          ] do
        assert limited?(parse(over))
      end
    end

    test "every fixture is within the limits" do
      files = Path.wildcard(Path.join(@fixtures, "*.json"))
      invalid = Path.wildcard(Path.join(@fixtures, "invalid/*.json"))

      for file <- files ++ invalid do
        refute limited?(file |> File.read!() |> Description.parse()), Path.basename(file)
      end
    end

    test "settings over the limits are refused by them, at once, whatever their schema",
         %{description: description} do
      for settings <- settings_attacks() do
        assert byte_size(Apiary.Kinds.CanonicalJSON.encode!(settings)) in 50_000..65_536
        assert limited?(timed(fn -> Description.check_settings(description, settings) end))
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
      assert timed(fn -> Description.check_settings(description, settings) end) == :ok

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
      assert {:error, {:integration_settings_invalid, %{count: _, errors: [_ | _]}} = refused} =
               Description.check_settings(description, %{"list" => [1]})

      refute limited?(refused)
    end
  end

  describe "the budget of the settings check" do
    # The settings schema comes from the description, and a few of its references can make
    # the check's work grow exponentially, which no limit on the settings bounds. The check
    # runs in another process within 500 ms and 32 MiB of heap; one over that budget is
    # refused as invalid settings, `budget: :exceeded`, in about 500 ms or less. Without
    # the budget the checks below took 1.2 s to 1.7 s at 20 levels of allOf and for the
    # patterns, 5.6 s at 20 levels of anyOf, and over 5 s at 24 levels of allOf. The time
    # asserted leaves room for a slow machine.
    @refused_within_ms 1000

    defp with_settings_schema(schema) do
      assert {:ok, description} = parse(tracker_description(%{"settings" => schema}))
      description
    end

    # A schema whose every level refers twice to the next, in `keyword`: 2^levels checks of
    # one string, which the last level takes as `last` says.
    defp doubling(levels, keyword \\ "allOf", last \\ "string") do
      defs =
        Map.new(1..levels, fn i ->
          next = %{"$ref" => "#/$defs/d#{i + 1}"}
          {"d#{i}", %{keyword => [next, next]}}
        end)

      with_settings_schema(%{
        "type" => "object",
        "properties" => %{"a" => %{"$ref" => "#/$defs/d1"}},
        "$defs" => Map.put(defs, "d#{levels + 1}", %{"type" => last})
      })
    end

    defp over_budget(description, settings) do
      {microseconds, result} =
        :timer.tc(fn -> Description.check_settings(description, settings) end)

      assert result ==
               {:error, {:integration_settings_invalid, %{valid: false, budget: :exceeded}}}

      assert div(microseconds, 1000) < @refused_within_ms, "took #{div(microseconds, 1000)} ms"
    end

    @tag :capture_log
    test "a schema that doubles its work at each of 20 or 24 levels is refused within the budget" do
      over_budget(doubling(20), %{"a" => "s"})
      over_budget(doubling(24), %{"a" => "s"})
    end

    @tag :capture_log
    test "a schema whose anyOf doubles its work at each of 20 levels is refused within the budget" do
      # The string fails every branch, so every branch is checked.
      over_budget(doubling(20, "anyOf", "integer"), %{"a" => "s"})
    end

    @tag :capture_log
    test "a schema of 1000 patterns for each of 1024 strings is refused within the budget" do
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

      over_budget(description, %{"x" => List.duplicate("a", 1024)})
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

    test "every fixture with settings takes the settings it describes" do
      assert {:ok, github} =
               @fixtures |> Path.join("github.json") |> File.read!() |> Description.parse()

      assert Description.check_settings(github, %{
               "app_id" => 123_456,
               "installation_id" => 7,
               "permissions" => %{"contents" => "read"},
               "api_url" => "https://api.github.com"
             }) == :ok

      assert {:ok, tracker} = parse(tracker_description())
      assert Description.check_settings(tracker, %{"url" => "https://tracker.example.com"}) == :ok
    end
  end
end
