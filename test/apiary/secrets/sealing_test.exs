defmodule Apiary.Secrets.SealingTest do
  # The sealed answer to the secrets request against Forager's known answers, vendored
  # under test/fixtures/forager-contract/ (fixtures/sealed and known-answers/keys.json of
  # the contract at the commit in .forager-contract-ref).
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Apiary.Contract.Ed25519
  alias Apiary.Secrets.Sealing
  alias Apiary.SigningKey

  @dir Path.expand("../../fixtures/forager-contract", __DIR__)

  # A path of the contract's fixtures, fixtures/<path>, as the vendored file.
  defp read("fixtures/" <> path), do: @dir |> Path.join(path) |> File.read!()
  defp json(path), do: path |> read() |> Jason.decode!()

  defp vectors, do: json("fixtures/sealed/vectors.json")

  defp key(name) do
    entry = json("fixtures/known-answers/keys.json") |> Map.fetch!(name)

    seed =
      case entry do
        %{"secret" => "qak_" <> seed} -> seed
        %{"seed" => seed} -> seed
      end

    {:ok, seed} = Ed25519.decode(seed, 32)
    {public_key, _private} = :crypto.generate_key(:eddsa, :ed25519, seed)
    %{entry: entry, seed: seed, public_key: public_key}
  end

  defp request, do: json("fixtures/sealed/secrets-request.json")

  # The recipient the fixture is sealed for: the fixture access key, the request's run and
  # digest, and exp from the vectors' clock.
  defp recipient do
    access_key = key("access_key")
    request = request()

    %{
      access_key_id: access_key.entry["access_key_id"],
      public_key: access_key.public_key,
      run_id: request["run_id"],
      run_configuration: request["run_configuration"],
      exp: Sealing.expiry(DateTime.from_unix!(vectors()["now"]))
    }
  end

  defp opts do
    {:ok, ephemeral} = Ed25519.decode(vectors()["ephemeral_private_key"], 32)
    [signing_key: SigningKey.new(key("signing_key").seed), ephemeral_private_key: ephemeral]
  end

  # A JSON document's bytes without the whitespace between tokens, its members in order.
  defp compact(bytes),
    do: bytes |> Jason.decode!(objects: :ordered_objects) |> Jason.encode!()

  defp hex(bytes), do: Base.encode16(bytes, case: :lower)
  defp sha256(bytes), do: hex(:crypto.hash(:sha256, bytes))
  defp lp32(bytes), do: <<byte_size(bytes)::32>> <> bytes

  defp fixture_plaintext, do: json("fixtures/sealed/sealed-plaintext.json")

  # An item of a value's `apply`.
  @item %{
    "hosts" => ["git.example"],
    "scheme" => "basic",
    "username" => "x-access-token",
    "paths" => ["/example-org/app.git/*"]
  }

  # The case of vectors.json for fixtures/sealed/invalid/<name>.json.
  defp invalid(name),
    do: Enum.find(vectors()["invalid"], &(&1["file"] == "fixtures/sealed/invalid/#{name}.json"))

  defp sealed_bytes do
    {:ok, answer} = Sealing.seal_with(fixture_plaintext(), recipient(), opts())
    answer
  end

  describe "the known answer" do
    test "the fixture access key converts to the X25519 key keys.json publishes" do
      access_key = key("access_key")
      {:ok, x25519} = Ed25519.decode(access_key.entry["x25519_public_key"], 32)
      assert Ed25519.x25519_public_key(access_key.public_key) == {:ok, x25519}
    end

    test "info and aad are the vectors'" do
      vectors = vectors()
      recipient = recipient()
      info = Sealing.info(recipient.access_key_id)

      aad =
        Sealing.aad(
          recipient.run_id,
          recipient.access_key_id,
          recipient.run_configuration,
          recipient.exp
        )

      assert hex(info) == vectors["info"]
      assert byte_size(info) == vectors["info_length"]
      assert hex(aad) == vectors["aad"]
      assert byte_size(aad) == vectors["aad_length"]
    end

    test "the plaintext is sealed-plaintext.json, byte for byte" do
      bytes = read("fixtures/sealed/sealed-plaintext.json")

      assert Sealing.plaintext(fixture_plaintext(), recipient().run_configuration) ==
               {:ok, bytes}

      assert byte_size(bytes) == vectors()["plaintext_length"]
    end

    test "seal_with/3 writes secrets-answer.json, compacted, byte for byte" do
      vectors = vectors()
      assert {:ok, answer} = Sealing.seal_with(fixture_plaintext(), recipient(), opts())
      assert answer == compact(read("fixtures/sealed/secrets-answer.json"))

      %{"sealed" => sealed} = Jason.decode!(answer)
      assert sealed["suite"] == Sealing.suite()
      {:ok, enc} = Ed25519.decode(sealed["enc"], 32)
      {:ok, ct} = Base.url_decode64(sealed["ct"], padding: false)
      {:ok, sig} = Ed25519.decode(sealed["sig"], 64)

      assert byte_size(ct) == vectors["ct_length"]
      assert sha256(ct) == vectors["ct_sha256"]

      signed =
        Enum.map_join(
          [
            "qory envelope v1",
            sealed["suite"],
            sealed["access_key_id"],
            sealed["run_id"],
            sealed["run_configuration"],
            Integer.to_string(sealed["exp"]),
            enc,
            ct
          ],
          &lp32/1
        )

      assert byte_size(signed) == vectors["signed_length"]
      assert sha256(signed) == vectors["signed_sha256"]
      assert Ed25519.verify(signed, sig, key("signing_key").public_key)
    end

    test "seal_with/3 takes a fresh ephemeral key unless given one" do
      plaintext = fixture_plaintext()
      recipient = recipient()
      signing_key = SigningKey.new(key("signing_key").seed)

      assert {:ok, one} = Sealing.seal_with(plaintext, recipient, signing_key: signing_key)
      assert {:ok, two} = Sealing.seal_with(plaintext, recipient, signing_key: signing_key)
      assert Jason.decode!(one)["sealed"]["enc"] != Jason.decode!(two)["sealed"]["enc"]
    end
  end

  describe "seal/2, the production entry point" do
    test "takes no key of a caller: it has no third argument" do
      Code.ensure_loaded!(Sealing)
      assert function_exported?(Sealing, :seal, 2)
      refute function_exported?(Sealing, :seal, 3)
    end

    test "seals to the access key with a fresh ephemeral key, signed under the instance's key" do
      recipient = recipient()
      access_key = key("access_key")
      {:ok, x25519_private_key} = Ed25519.decode(access_key.entry["x25519_private_key"], 32)

      expected = %{
        access_key_id: recipient.access_key_id,
        run_id: recipient.run_id,
        run_configuration: recipient.run_configuration,
        signing_public_key: SigningKey.current().public_key,
        x25519_private_key: x25519_private_key
      }

      assert {:ok, one} = Sealing.seal(fixture_plaintext(), recipient)
      assert {:ok, two} = Sealing.seal(fixture_plaintext(), recipient)
      assert Jason.decode!(one)["sealed"]["enc"] != Jason.decode!(two)["sealed"]["enc"]

      assert {:ok, plaintext, _sealed} = Apiary.SealedOpen.open(one, expected)
      assert plaintext == read("fixtures/sealed/sealed-plaintext.json")

      # Not under the contract's fixture signing key.
      assert Apiary.SealedOpen.open(one, %{
               expected
               | signing_public_key: key("signing_key").public_key
             }) == {:error, :sig}
    end

    test "returns :recipient for a recipient that is not a map" do
      for recipient <- [nil, "ak_f1xt0re000000000", [access_key_id: "ak_f1xt0re000000000"]] do
        assert Sealing.seal(fixture_plaintext(), recipient) == {:error, :recipient}
      end
    end

    test "returns :key for each key of small-order.json" do
      %{"small_order" => small, "non_canonical" => non_canonical, "torsion" => torsion} =
        json("fixtures/known-answers/small-order.json")

      encodings = Enum.map(small ++ non_canonical ++ [torsion], & &1["encoding"])
      assert length(encodings) == 15

      for encoding <- encodings do
        {:ok, public_key} = Base.url_decode64(encoding, padding: false)

        assert Sealing.seal(fixture_plaintext(), %{recipient() | public_key: public_key}) ==
                 {:error, :key},
               encoding
      end
    end
  end

  describe "the invalid cases of the sealer's inputs are never produced" do
    # Each case is sealed with an info, an aad or a plaintext other than the request's.
    # The seal builds info and aad from the request's values alone, so it writes other
    # bytes, or refuses the plaintext.

    test "wrong info, wrong aad and another run: the request's values give other bytes" do
      recipient = recipient()
      info = hex(Sealing.info(recipient.access_key_id))

      aad =
        hex(
          Sealing.aad(
            recipient.run_id,
            recipient.access_key_id,
            recipient.run_configuration,
            recipient.exp
          )
        )

      for name <- ~w(wrong-info wrong-aad other-run) do
        vector = invalid(name)
        assert {vector["info"], vector["aad"]} != {info, aad}, name
        refute sealed_bytes() == compact(read(vector["file"])), name
      end
    end

    test "another digest: a plaintext for another digest is refused" do
      vector = invalid("other-digest")
      plaintext = json(vector["plaintext"])
      digest = recipient().run_configuration
      assert plaintext["run_configuration"] != digest

      assert Sealing.seal_with(plaintext, recipient(), opts()) == {:error, :digest}
      assert Sealing.plaintext(plaintext, digest) == {:error, :digest}
      refute sealed_bytes() == compact(read(vector["file"]))
    end

    test "a value not requested is refused" do
      vector = invalid("value-not-requested")
      plaintext = json(vector["plaintext"])

      assert Enum.sort(plaintext["credentials"]) == Enum.sort(request()["credentials"])
      assert Sealing.seal_with(plaintext, recipient(), opts()) == {:error, :values}
    end
  end

  describe "the errors of the seal" do
    test "identifiers outside their forms" do
      for {field, value} <- [
            access_key_id: "ak_F1XT0RE000000000",
            run_id: "01928F4E-7c3a-7d2e-9b1a-3f5e6d7c8b9a",
            run_configuration: "sha256=" <> String.duplicate("a", 63),
            exp: Integer.pow(2, 53),
            exp: -1
          ] do
        assert Sealing.seal_with(fixture_plaintext(), Map.put(recipient(), field, value), opts()) ==
                 {:error, :identifiers},
               inspect(field)
      end
    end

    test "an access key that fails a key check" do
      for public_key <- [<<1, 0::248>>, <<0::256>>, <<1, 2, 3>>] do
        assert Sealing.seal_with(
                 fixture_plaintext(),
                 %{recipient() | public_key: public_key},
                 opts()
               ) ==
                 {:error, :key}
      end
    end

    test "credentials that are not 1 to 8 names, each once" do
      plaintext = fixture_plaintext()

      for credentials <- [
            [],
            ["forge", "forge"],
            ["Forge", "model"],
            Enum.map(1..9, &"c#{&1}")
          ] do
        assert Sealing.seal_with(%{plaintext | "credentials" => credentials}, recipient(), opts()) ==
                 {:error, :credentials},
               inspect(credentials)
      end
    end

    test "values that are not one for each credential" do
      plaintext = fixture_plaintext()
      [forge, model] = plaintext["values"]

      for values <- [[forge], [forge, model, model], [forge, %{model | "credential" => "other"}]] do
        assert Sealing.seal_with(%{plaintext | "values" => values}, recipient(), opts()) ==
                 {:error, :values}
      end
    end

    test "a value that is not 1 to 16384 bytes of UTF-8 without a NUL" do
      plaintext = fixture_plaintext()
      [forge, model] = plaintext["values"]

      for value <- ["", "a\0b", <<0xFF>>, String.duplicate("a", 16_385), 7] do
        values = [forge, %{model | "value" => value}]

        assert Sealing.seal_with(%{plaintext | "values" => values}, recipient(), opts()) ==
                 {:error, :value}
      end

      long = String.duplicate("a", 16_384)
      values = [forge, %{model | "value" => long}]
      assert {:ok, _} = Sealing.seal_with(%{plaintext | "values" => values}, recipient(), opts())
    end

    test "a value whose expires_at or apply is outside the schema's form" do
      plaintext = fixture_plaintext()
      [forge, model] = plaintext["values"]
      item = @item
      forge = Map.merge(forge, %{"expires_at" => "2026-10-24T13:00:00Z", "apply" => [@item]})

      for other <- [
            %{forge | "expires_at" => "2026-10-24 13:00:00"},
            %{forge | "expires_at" => "2026-10-24T13:00:00"},
            %{forge | "expires_at" => "2026-13-24T13:00:00Z"},
            %{forge | "expires_at" => 1_700_000_000},
            %{forge | "apply" => []},
            %{forge | "apply" => List.duplicate(item, 17)},
            %{forge | "apply" => [Map.put(item, "token", "t")]},
            %{forge | "apply" => [Map.delete(item, "username")]},
            %{forge | "apply" => [%{item | "scheme" => "bearer"}]},
            %{forge | "apply" => [Map.put(item, "header", "x-api-key")]},
            %{forge | "apply" => [%{item | "hosts" => ["*.git.example"]}]},
            %{forge | "apply" => [%{item | "hosts" => ["Git.example"]}]},
            %{forge | "apply" => [%{item | "hosts" => []}]},
            %{forge | "apply" => [%{item | "paths" => ["no-slash"]}]},
            %{forge | "apply" => [%{item | "paths" => ["/a*b"]}]},
            %{forge | "apply" => [%{item | "paths" => ["/a", "/a"]}]},
            %{forge | "apply" => [%{item | "username" => "a:b"}]}
          ] do
        values = [other, model]

        assert Sealing.seal_with(%{plaintext | "values" => values}, recipient(), opts()) ==
                 {:error, :value},
               inspect(other)
      end
    end

    test "a value with neither, one or both of expires_at and apply is sealed" do
      plaintext = fixture_plaintext()
      [forge, model] = plaintext["values"]
      forge = Map.drop(forge, ["expires_at", "apply"])

      for forge <- [
            forge,
            Map.put(forge, "expires_at", "2026-10-24T15:00:00.5+02:00"),
            Map.put(forge, "apply", [@item]),
            Map.merge(forge, %{
              "expires_at" => "2026-10-24T13:00:00Z",
              "apply" => [
                %{"hosts" => ["api.git.example", "2001:db8::1"], "scheme" => "bearer"},
                %{"hosts" => ["192.0.2.1"], "scheme" => "header", "header" => "x-token"}
              ]
            })
          ] do
        values = [forge, model]

        assert {:ok, bytes} =
                 Sealing.plaintext(
                   %{plaintext | "values" => values},
                   plaintext["run_configuration"]
                 ),
               inspect(forge)

        assert Jason.decode!(bytes)["values"] == values
        assert Apiary.ForagerSchemas.validate("sealed-plaintext.schema.json", bytes) == :ok
      end
    end

    test "any other plaintext" do
      plaintext = fixture_plaintext()

      for other <- [
            %{plaintext | "version" => 2},
            Map.put(plaintext, "extra", true),
            Map.delete(plaintext, "values"),
            %{plaintext | "values" => [%{"credential" => "forge"}, hd(plaintext["values"])]},
            %{
              plaintext
              | "values" => [
                  Map.put(hd(plaintext["values"]), "token", "t"),
                  List.last(plaintext["values"])
                ]
            },
            "not a map"
          ] do
        assert Sealing.seal_with(other, recipient(), opts()) == {:error, :plaintext}
      end
    end
  end

  describe "the plaintext's JSON" do
    test "escapes as Go's jsontext does" do
      plaintext = fixture_plaintext()
      [forge, model] = plaintext["values"]
      value = "a\"b\\c\b\f\n\r\t\x01\x1f\x7f<>&\u2028é漢😀\uFFFD"
      values = [forge, %{model | "value" => value}]

      assert {:ok, bytes} =
               Sealing.plaintext(
                 %{plaintext | "values" => values},
                 plaintext["run_configuration"]
               )

      assert bytes =~
               ~S({"credential":"model","value":"a\"b\\c\b\f\n\r\t\u0001\u001f) <>
                 "\x7f<>&\u2028é漢😀\uFFFD\"}]}"

      assert Jason.decode!(bytes)["values"] |> List.last() |> Map.fetch!("value") == value
    end

    test "writes expires_at and apply after the value, an item's members in the schema's order" do
      plaintext = fixture_plaintext()
      [forge, model] = plaintext["values"]
      forge = Map.merge(forge, %{"expires_at" => "2026-10-24T13:00:00Z", "apply" => [@item]})

      assert {:ok, bytes} =
               Sealing.plaintext(
                 %{plaintext | "values" => [model, forge]},
                 plaintext["run_configuration"]
               )

      assert bytes =~
               ~S({"credential":"forge","value":"fixture-forge-token-not-a-real-one",) <>
                 ~S("expires_at":"2026-10-24T13:00:00Z","apply":[{"hosts":["git.example"],) <>
                 ~S("scheme":"basic","username":"x-access-token",) <>
                 ~S("paths":["/example-org/app.git/*"]}]})
    end

    test "sorts the credentials, and the values by credential" do
      plaintext = fixture_plaintext()

      shuffled = %{
        plaintext
        | "credentials" => Enum.reverse(plaintext["credentials"]),
          "values" => Enum.reverse(plaintext["values"])
      }

      assert Sealing.plaintext(shuffled, plaintext["run_configuration"]) ==
               {:ok, read("fixtures/sealed/sealed-plaintext.json")}
    end
  end

  describe "no value in a log, an error or an exception" do
    test "nothing of a value, the plaintext or the sealed bytes is logged or returned" do
      plaintext = fixture_plaintext()
      values = for %{"value" => value} <- plaintext["values"], do: value
      bad_value = put_in(plaintext, ["values", Access.at(1), "value"], "fixture\0secret")

      log =
        capture_log([level: :debug], fn ->
          {:ok, answer} = Sealing.seal_with(plaintext, recipient(), opts())
          send(self(), {:answer, answer})

          for result <- [
                Sealing.seal_with(bad_value, recipient(), opts()),
                Sealing.seal_with(plaintext, %{recipient() | public_key: <<0::256>>}, opts()),
                Sealing.seal_with(
                  plaintext,
                  %{recipient() | run_id: "fixture-model-key"},
                  opts()
                ),
                Sealing.seal_with(Map.put(plaintext, "x", 1), recipient(), opts())
              ] do
            assert {:error, refusal} = result
            assert is_atom(refusal)
          end
        end)

      assert_received {:answer, answer}
      %{"sealed" => %{"ct" => ct}} = Jason.decode!(answer)

      for secret <-
            values ++ ["fixture\0secret", ct, read("fixtures/sealed/sealed-plaintext.json")],
          do: refute(log =~ secret)

      for value <- values, do: refute(answer =~ value)
    end

    test "an ephemeral key of the wrong size raises without the key" do
      key = "fixture-ephemeral-key"

      error =
        assert_raise ArgumentError, fn ->
          Sealing.seal_with(fixture_plaintext(), recipient(), ephemeral_private_key: key)
        end

      refute Exception.message(error) =~ key
    end
  end
end
