defmodule Apiary.Adapters.WireTest do
  # The bodies an adapter posts, read as the integration contract has them: strictly, a
  # member twice refused at any depth, times in UTC to the second, URLs a person may be
  # sent to, and the declaration of `POST /v1/adapter`, against the contract's fixtures.
  use ExUnit.Case, async: true

  alias Apiary.Adapters.Wire
  alias Apiary.IntegrationsContract

  @declaration %{
    "version" => 1,
    "time" => "2026-10-15T12:00:00Z",
    "connect_url" => "https://tracker-adapter.acme.example/connect",
    "sync" => %{"default_interval" => 900, "minimum_interval" => 300, "sends_changes" => false}
  }

  describe "decode/1" do
    test "reads a JSON object, objects inside it as maps" do
      assert Wire.decode(~s({"a":{"b":[{"c":1}]}})) == {:ok, %{"a" => %{"b" => [%{"c" => 1}]}}}
    end

    test "refuses a member twice, at the top and at any depth" do
      assert Wire.decode(~s({"a":1,"a":1})) == :error
      assert Wire.decode(~s({"a":{"b":1,"b":2}})) == :error
      assert Wire.decode(~s({"a":[{"b":1,"b":2}]})) == :error
    end

    test "refuses anything that is not a JSON object" do
      for raw <- ["", "[]", "1", "null", ~s("a"), "{", ~s({"a":1} x)] do
        assert Wire.decode(raw) == :error, raw
      end

      assert Wire.decode(nil) == :error
    end
  end

  describe "time/1" do
    test "reads RFC 3339 in UTC with whole seconds" do
      assert Wire.time("2026-10-15T12:00:00Z") == {:ok, ~U[2026-10-15 12:00:00Z]}
    end

    test "refuses a fraction, an offset, a lower-case z, a date alone, or no string" do
      for value <- [
            "2026-10-15T12:00:00.5Z",
            "2026-10-15T12:00:00+00:00",
            "2026-10-15T14:00:00+02:00",
            "2026-10-15T12:00:00z",
            "2026-10-15",
            "2026-13-15T12:00:00Z",
            " 2026-10-15T12:00:00Z",
            1_792_065_600,
            nil
          ] do
        assert Wire.time(value) == :error, inspect(value)
      end
    end
  end

  describe "url?/1" do
    test "takes an https URL with a host, a path, a query and a fragment" do
      for url <- [
            "https://tracker-adapter.acme.example/connect",
            "https://tracker-adapter.acme.example",
            "https://tracker-adapter.acme.example:8443/connect?team=acme#start",
            "https://203.0.113.10/connect"
          ] do
        assert Wire.url?(url), url
      end
    end

    test "refuses another scheme, user information, no host, white space, controls and non-ASCII" do
      for url <- [
            "http://tracker-adapter.acme.example/connect",
            "HTTPS://tracker-adapter.acme.example/connect",
            "https://user@tracker-adapter.acme.example/connect",
            "https://user:secret@tracker-adapter.acme.example/connect",
            "https:///connect",
            "https://",
            "https://?a=1",
            "https://tracker-adapter.acme.example/con nect",
            "https://tracker-adapter.acme.example/connect\n",
            "https://tracker-adapter.acme.example/connect\t",
            "https://tracker-adapter.acme.example/\u0000",
            "https://tracker-adapter.acme.example/\u00E9",
            "https://tracker-adapter.acme.example/\u202E",
            "https://tracker-adapter.acme.example/" <> String.duplicate("a", 2048),
            nil,
            1
          ] do
        refute Wire.url?(url), inspect(url)
      end
    end

    test "takes 2,048 characters and no more" do
      base = "https://tracker-adapter.acme.example/"
      url = base <> String.duplicate("a", 2048 - byte_size(base))
      assert Wire.url?(url)
      refute Wire.url?(url <> "a")
    end
  end

  describe "declaration/1" do
    test "reads the declaration" do
      assert Wire.declaration(@declaration) ==
               {:ok,
                %{
                  time: ~U[2026-10-15 12:00:00Z],
                  connect_url: "https://tracker-adapter.acme.example/connect",
                  default_interval: 900,
                  minimum_interval: 300,
                  sends_changes: false
                }}
    end

    test "takes a minimum equal to the default, and the bounds of a minute and a day" do
      for {default, minimum} <- [{900, 900}, {86_400, 60}, {60, 60}, {86_400, 86_400}] do
        body = put_in(@declaration, ["sync", "default_interval"], default)
        body = put_in(body, ["sync", "minimum_interval"], minimum)
        assert {:ok, _} = Wire.declaration(body), inspect({default, minimum})
      end
    end

    test "refuses what the contract refuses" do
      refused = [
        Map.put(@declaration, "version", 2),
        Map.put(@declaration, "version", "1"),
        Map.put(@declaration, "extra", true),
        Map.delete(@declaration, "time"),
        Map.delete(@declaration, "connect_url"),
        Map.delete(@declaration, "sync"),
        Map.put(@declaration, "time", "2026-10-15T12:00:00.000Z"),
        Map.put(@declaration, "connect_url", "http://tracker-adapter.acme.example/connect"),
        Map.put(@declaration, "connect_url", "https://a@tracker-adapter.acme.example/"),
        Map.put(@declaration, "sync", nil),
        put_in(@declaration, ["sync", "extra"], 1),
        update_in(@declaration, ["sync"], &Map.delete(&1, "sends_changes")),
        put_in(@declaration, ["sync", "sends_changes"], "false"),
        put_in(@declaration, ["sync", "default_interval"], 59),
        put_in(@declaration, ["sync", "default_interval"], 86_401),
        put_in(@declaration, ["sync", "default_interval"], 900.5),
        put_in(@declaration, ["sync", "minimum_interval"], 59),
        put_in(@declaration, ["sync", "minimum_interval"], 901),
        put_in(@declaration, ["sync", "minimum_interval"], "300")
      ]

      for body <- refused do
        assert Wire.declaration(body) == :error, inspect(body)
      end

      assert Wire.declaration([]) == :error
    end
  end

  describe "the contract's fixtures" do
    @describetag :integrations_contract

    test "the declarations of fixtures/adapter/adapter are read, and the schema takes them" do
      schema = IntegrationsContract.schema!("adapter.schema.json")

      for name <- ["acme-tracker", "code-host"] do
        raw = IntegrationsContract.file!("fixtures/adapter/adapter/#{name}.json")
        assert {:ok, body} = Wire.decode(raw)
        assert IntegrationsContract.validate(schema, body) == :ok
        assert {:ok, declaration} = Wire.declaration(body)
        assert declaration.connect_url == body["connect_url"]
        assert declaration.sends_changes == body["sync"]["sends_changes"]
      end
    end

    test "the declaration the contract refuses is refused here too" do
      raw =
        IntegrationsContract.file!(
          "fixtures/adapter/invalid/adapter-sync-without-sends-changes.json"
        )

      assert {:ok, body} = Wire.decode(raw)
      assert {:error, _} = IntegrationsContract.validate(schema(), body)
      assert Wire.declaration(body) == :error
    end

    test "what the schema refuses beyond its fixtures is refused here too" do
      schema = schema()

      for body <- [
            Map.put(@declaration, "version", 2),
            Map.put(@declaration, "extra", true),
            Map.put(@declaration, "time", "2026-10-15T12:00:00+00:00"),
            Map.put(@declaration, "connect_url", "http://tracker-adapter.acme.example/"),
            put_in(@declaration, ["sync", "default_interval"], 59),
            put_in(@declaration, ["sync", "minimum_interval"], 86_401)
          ] do
        assert {:error, _} = IntegrationsContract.validate(schema, body), inspect(body)
        assert Wire.declaration(body) == :error, inspect(body)
      end
    end

    defp schema, do: IntegrationsContract.schema!("adapter.schema.json")
  end
end
