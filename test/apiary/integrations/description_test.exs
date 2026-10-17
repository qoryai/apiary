defmodule Apiary.Integrations.DescriptionTest do
  use ExUnit.Case, async: true

  import Apiary.DescriptionFixtures
  import ExUnit.CaptureLog

  alias Apiary.Integrations
  alias Apiary.Integrations.{Description, Release}

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
               ~w(acme-chat.json acme-tracker.json example-tracker.json github.json
                  unknown-role.json)

      for name <- names, do: assert({:ok, %Description{}} = parse_fixture(name), name)
    end

    test "every refused fixture is refused, those a reader refuses included" do
      names = fixture_names("invalid/*.json") ++ fixture_names("refused-by-reader/*.json")
      assert length(names) == 26

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
      assert length(names) == 11

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
            {"zero-width-space", :pattern, "#/roles/source/description"}
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

    test "is found within 150 ms in a description of 256 KiB and 30001 objects" do
      for {repeat, expected} <- [{true, :member_repeated}, {false, :limits}] do
        text = many_objects(repeat)
        {microseconds, result} = :timer.tc(fn -> Description.parse(text) end)
        assert div(microseconds, 1000) < 150, "took #{div(microseconds, 1000)} ms"

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
    # in a few. Without them, JSV and the normalising of its errors took about 3 to 5 s on
    # the slowest descriptions below and about 3 s on the slowest settings, and JSV alone
    # over 0.25 s on some of them; the budget leaves room for a slow machine. Which inputs
    # the limits refuse is asserted apart from the time: a refusal by the limits carries
    # them, `%{limits: _}`, and one by the schema does not.
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
    # runs in another process within 100 ms and 16 MiB of heap; one over that budget is
    # refused as invalid settings, `budget: :exceeded`, and the warning it logs says which
    # it ran out of, time or heap. Without the budget, measured: 1.2 s to 1.7 s at 20
    # levels of allOf and for 1000 patterns against 1024 strings, 5 s to 5.7 s and 1.19 GB
    # at 20 levels of allOf whose leaf refuses the value, 5.6 s at 20 levels of anyOf, 33 s
    # at 24 levels of allOf and over 30 s in draft-07; 24 s to 28 s for 1000 backtracking
    # patterns against a string of 60001 bytes, 15 s against 128 settings, 9.5 s against a
    # list of 100 strings, and 13.3 s for 1000 email formats against a string of 60 KB.
    # With it, the heap ran out in under 40 ms where it did, the first check in a fresh VM
    # included, but for the 1000 patterns, which ran out of time once. The time asserted
    # leaves room for a slow machine.
    @refused_within_ms 1000

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

    # The refusal, in time, and the budget it ran out of, `reason`: "time", "heap", or
    # "time|heap" where a cold machine can take longer to fill the heap than the time.
    defp over_budget(description, settings, reason) do
      {{microseconds, result}, log} =
        with_log(fn -> :timer.tc(fn -> Description.check_settings(description, settings) end) end)

      assert result ==
               {:error, {:integration_settings_invalid, %{valid: false, budget: :exceeded}}}

      assert log =~ "settings check was stopped name=acme-tracker"
      assert log =~ ~r/reason=(#{reason})$/m
      assert div(microseconds, 1000) < @refused_within_ms, "took #{div(microseconds, 1000)} ms"
    end

    # 1000 backtracking patterns, each spending the pattern budget of JSV on a value.
    defp backtracking, do: %{"anyOf" => for(_ <- 1..1000, do: %{"pattern" => "^(a+)+$"})}

    test "a schema that doubles its work at each of 20 or 24 levels runs out of time" do
      over_budget(doubling(20), %{"a" => "s"}, "time")
      over_budget(doubling(24), %{"a" => "s"}, "time")
    end

    test "so does one in draft-07, its definitions in definitions" do
      over_budget(doubling(24, "allOf", "string", "definitions"), %{"a" => "s"}, "time")
      over_budget(doubling(24, "allOf", "string", "definitions"), %{"a" => 1}, "time|heap")
    end

    test "a doubling schema whose leaf refuses the value runs out of heap, the errors kept" do
      over_budget(doubling(20), %{"a" => 1}, "heap")
      over_budget(doubling(20, "anyOf", "integer"), %{"a" => "s"}, "heap")
      over_budget(doubling(20, "oneOf"), %{"a" => 1}, "heap")
    end

    test "an anyOf of 16 or 18 levels, each referring twice to the next, is refused" do
      over_budget(doubling(16, "anyOf", "integer"), %{"a" => "s"}, "time|heap")
      over_budget(doubling(18, "anyOf", "integer"), %{"a" => "s"}, "time|heap")
    end

    test "a schema of 1000 patterns for each of 1024 strings is refused" do
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

      over_budget(description, %{"x" => List.duplicate("a", 1024)}, "time|heap")
    end

    test "1000 backtracking patterns run out of time on one long setting, on 128, on a list" do
      one =
        with_settings_schema(%{
          "type" => "object",
          "properties" => %{"s1" => %{"$ref" => "#/$defs/p"}},
          "$defs" => %{"p" => backtracking()}
        })

      over_budget(one, %{"s1" => String.duplicate("a", 60_000) <> "!"}, "time")

      many =
        with_settings_schema(%{
          "type" => "object",
          "properties" => Map.new(1..128, &{"s#{&1}", %{"$ref" => "#/$defs/p"}}),
          "$defs" => %{"p" => backtracking()}
        })

      over_budget(many, Map.new(1..128, &{"s#{&1}", String.duplicate("a", 60) <> "!"}), "time")

      list =
        with_settings_schema(%{
          "type" => "object",
          "properties" => %{"l" => %{"type" => "array", "items" => backtracking()}}
        })

      over_budget(list, %{"l" => List.duplicate(String.duplicate("a", 24) <> "!", 100)}, "time")
    end

    test "1000 email formats against a string of 60 KB are refused" do
      description =
        with_settings_schema(%{
          "type" => "object",
          "properties" => %{"e" => %{"allOf" => for(_ <- 1..1000, do: %{"format" => "email"})}}
        })

      over_budget(description, %{"e" => String.duplicate("a", 60_000) <> "@"}, "time|heap")
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
end
