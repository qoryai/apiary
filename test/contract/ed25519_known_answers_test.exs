defmodule Apiary.Contract.Ed25519KnownAnswersTest do
  @moduledoc """
  The contract's Ed25519 known answers, from Forager's contract directory at the commit
  in `.forager-contract-ref`: the fixture keys (`known-answers/keys.json`), the keys every
  instance refuses (`known-answers/small-order.json`), the request, enrolment and answer
  strings with their signatures (`known-answers/signatures.json`), the discovery body they
  sign (`known-answers/discovery.json`), and the request string of every signed request
  (`signed/*.json`). The strings are built by `Apiary.Contract.SignedMessage` and checked
  by `Apiary.Contract.Ed25519`; nothing here goes through a plug.
  """
  use ExUnit.Case, async: true

  import Apiary.ContractFixtures

  alias Apiary.Contract.Ed25519
  alias Apiary.Contract.SignedMessage

  @moduletag :contract

  defp sign(message, %{seed: seed}),
    do: :crypto.sign(:eddsa, :none, message, [seed, :ed25519]) |> Ed25519.encode()

  defp verify?(message, encoded_signature, %{public_key: public_key}) do
    {:ok, signature} = Ed25519.decode(encoded_signature, 64)
    Ed25519.verify(message, signature, public_key)
  end

  # A `body` member names a file of the contract directory, from `fixtures/`; "" is none.
  defp body(""), do: ""
  defp body("fixtures/" <> path), do: contract_file!(path)

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # Every signed fixture is signed under the fixture access key, an unknown id's too, its
  # note says.
  defp signer(_key_id), do: fixture_key!("access_key")

  # A header the fixture sends twice is a list; both values are the same.
  defp header(headers, name) do
    case headers[name] do
      [value | rest] ->
        assert Enum.all?(rest, &(&1 == value))
        value

      value ->
        value
    end
  end

  defp message(%{"method" => method, "target" => target, "headers" => headers} = fixture) do
    last =
      case method do
        "GET" -> header(headers, "X-Qory-Timestamp")
        "POST" -> fixture["body"]
      end

    SignedMessage.request(
      header(headers, "X-Qory-Access-Key-Id"),
      header(headers, "X-Qory-Instance-Id"),
      method,
      target,
      last
    )
  end

  describe "known-answers/keys.json" do
    test "lists the fixture access key and the server's two keys, and no longer the second access key" do
      assert known_answers!("keys") |> Map.keys() |> Enum.sort() ==
               ~w(access_key next_signing_key signing_key)
    end

    test "each key's seed gives its public key and its fingerprint" do
      for name <- ~w(access_key signing_key next_signing_key) do
        key = fixture_key!(name)
        assert Ed25519.fingerprint(key.public_key) == key.fingerprint, name
      end
    end

    test "the seeds are the contract's byte ranges, and the access key's ids their shapes" do
      for {name, range} <- [
            {"access_key", 1..32},
            {"signing_key", 65..96},
            {"next_signing_key", 161..192}
          ] do
        assert fixture_key!(name).seed == :binary.list_to_bin(Enum.to_list(range)), name
      end

      access_key = fixture_key!("access_key")
      assert access_key.access_key_id == published_key_id()

      assert access_key.instance_id ==
               "i_" <> Ed25519.encode(:binary.list_to_bin(Enum.to_list(129..144)))
    end

    test "the access key and the server's two keys are refused as fixtures, and the second access key the README names" do
      for name <- ~w(access_key signing_key next_signing_key) do
        assert Ed25519.check_public_key(fixture_key!(name).public_key) == {:error, :fixture},
               name
      end

      assert Ed25519.check_public_key(second_fixture_access_key().public_key) ==
               {:error, :fixture}

      assert File.read!(Path.join(contract_dir(), "README.md")) =~
               Ed25519.encode(second_fixture_access_key().public_key)
    end
  end

  describe "known-answers/small-order.json" do
    test "every point of small order is refused, the identity for its y of 1" do
      %{"small_order" => points} = known_answers!("small-order")
      assert length(points) == 8

      for %{"encoding" => encoded, "order" => order} <- points do
        assert {:ok, key} = Ed25519.decode(encoded, 32)
        expected = if order == 1, do: :y_is_one, else: :small_order
        assert Ed25519.check_public_key(key) == {:error, expected}, encoded
      end
    end

    test "every non-canonical encoding is refused as such" do
      %{"non_canonical" => points} = known_answers!("small-order")
      assert length(points) == 6

      for %{"encoding" => encoded} <- points do
        assert {:ok, key} = Ed25519.decode(encoded, 32)
        assert Ed25519.check_public_key(key) == {:error, :non_canonical}, encoded
      end
    end

    test "the torsion key is refused for its order" do
      %{"torsion" => %{"encoding" => encoded}} = known_answers!("small-order")
      assert Ed25519.decode_public_key(encoded) == {:error, :not_prime_order}
    end
  end

  describe "known-answers/signatures.json, the request strings" do
    test "each is built line by line, and its signature is the access key's" do
      %{"requests" => requests} = known_answers!("signatures")
      access_key = fixture_key!("access_key")
      assert length(requests) == 2

      for %{"lines" => lines, "length" => length, "signature" => signature} <- requests do
        ["qory-request-ed25519-v1", key_id, instance_id, method, target, last] = lines
        message = SignedMessage.request(key_id, instance_id, method, target, last)

        assert message == Enum.join(lines, "\n")
        assert byte_size(message) == length
        assert sign(message, access_key) == signature
        assert verify?(message, signature, access_key)
        refute verify?(message <> "\n", signature, access_key)
      end
    end
  end

  describe "known-answers/signatures.json, the enrolment proofs" do
    test "each is the body's proof of the five lines SignedMessage builds, under the body's key" do
      %{"enrolment" => enrolments} = known_answers!("signatures")
      access_key = fixture_key!("access_key")
      assert length(enrolments) == 2

      for %{"lines" => lines, "length" => length, "body" => path} <- enrolments do
        body = path |> body() |> Jason.decode!()

        assert lines == [
                 "qory-enrol-ed25519-v1",
                 body["code"],
                 body["public_key"],
                 body["name"],
                 Integer.to_string(body["timestamp"])
               ]

        message =
          SignedMessage.enrolment(
            body["code"],
            body["public_key"],
            body["name"],
            body["timestamp"]
          )

        assert message == Enum.join(lines, "\n")
        assert byte_size(message) == length
        assert body["public_key"] == Ed25519.encode(access_key.public_key)
        assert sign(message, access_key) == body["proof"]
        assert verify?(message, body["proof"], access_key)
      end
    end
  end

  describe "known-answers/signatures.json, the answer strings" do
    test "each is built from its status, its request and its body, signed by the server's key" do
      %{"requests" => requests, "enrolment" => enrolments, "answers" => answers} =
        known_answers!("signatures")

      signing_key = fixture_key!("signing_key")

      bound =
        Enum.map(requests, & &1["signature"]) ++
          Enum.map(enrolments, &(&1["body"] |> body() |> Jason.decode!() |> Map.fetch!("proof")))

      assert length(answers) == 8

      for %{"lines" => lines, "length" => length, "signature" => signature} = answer <- answers do
        [domain, status, request_signature, hash, configuration, run] = lines
        body = body(answer["body"])

        assert byte_size(body) == answer["body_length"]
        assert hash == Base.encode16(:crypto.hash(:sha256, body), case: :lower)
        assert request_signature in bound

        # An answer to an enrolment, bound to its proof, is under the enrolment answers'
        # own domain line; every other answer under the request answers'.
        message =
          case answer["body"] do
            "fixtures/enrolment/" <> _ ->
              assert domain == "qory-enrol-answer-ed25519-v1"
              assert {configuration, run} == {"", ""}
              SignedMessage.enrolment_answer(String.to_integer(status), request_signature, body)

            _other ->
              assert domain == "qory-answer-ed25519-v1"

              SignedMessage.answer(
                String.to_integer(status),
                request_signature,
                body,
                blank_to_nil(configuration),
                blank_to_nil(run)
              )
          end

        assert message == Enum.join(lines, "\n")
        assert byte_size(message) == length
        assert sign(message, signing_key) == signature
        assert verify?(message, signature, signing_key)
        refute verify?(message, signature, fixture_key!("next_signing_key"))
      end
    end

    test "the discovery answer carries the body's digest as X-Qory-Configuration" do
      %{"answers" => [discovery | _]} = known_answers!("signatures")
      assert discovery["body"] == "fixtures/known-answers/discovery.json"

      ["qory-answer-ed25519-v1", "200", _request, hash, configuration, ""] = discovery["lines"]
      assert configuration == "sha256=" <> hash
    end

    test "every enrolment answer lists the server's key first, and the next during a rotation" do
      signing_key = Ed25519.encode(fixture_key!("signing_key").public_key)
      next_signing_key = Ed25519.encode(fixture_key!("next_signing_key").public_key)

      for name <- ~w(answer refusal-key-invalid refusal-key-limit refusal-rate-limited) do
        assert contract_json!("enrolment/#{name}.json")["apiary_public_key"] ==
                 [%{"alg" => "ed25519", "public_key" => signing_key}],
               name
      end

      for name <- ~w(refusal-key-invalid-rotation refusal-key-limit-rotation) do
        assert contract_json!("enrolment/#{name}.json")["apiary_public_key"] ==
                 [
                   %{"alg" => "ed25519", "public_key" => signing_key},
                   %{"alg" => "ed25519", "public_key" => next_signing_key}
                 ],
               name
      end
    end
  end

  describe "known-answers/discovery.json" do
    test "names the fixture node and lists the server's key" do
      discovery = known_answers!("discovery")

      assert discovery["node_id"] =~ ~r/\And_[a-z0-9]{16}\z/

      assert discovery["apiary_public_key"] == [
               %{
                 "alg" => "ed25519",
                 "public_key" => Ed25519.encode(fixture_key!("signing_key").public_key)
               }
             ]
    end
  end

  describe "signed/*.json, the request strings" do
    test "the fixtures are there, and the ones expected" do
      names = Enum.map(signed_fixtures(), &elem(&1, 0))

      for name <- ~w(batch-valid.json batch-tampered.json batch-unknown-key.json
                     get-configuration-valid.json get-configuration-bad-signature.json
                     get-configuration-stale.json get-configuration-no-instance-id.json
                     get-configuration-header-twice.json get-run-configuration-valid.json),
          do: assert(name in names)
    end

    test "every signature verifies over the request string, but a tampered body's and a trailing line feed's" do
      for {name, %{"headers" => headers} = fixture} <- signed_fixtures() do
        message = message(fixture)
        key = signer(header(headers, "X-Qory-Access-Key-Id"))
        signature = header(headers, "X-Qory-Signature-Ed25519")

        case name do
          "batch-tampered.json" ->
            refute verify?(message, signature, key), name

          "get-configuration-bad-signature.json" ->
            refute verify?(message, signature, key), name
            assert verify?(message <> "\n", signature, key), name

          _verifies ->
            assert verify?(message, signature, key), name
            assert sign(message, key) == signature, name
        end
      end
    end

    test "the discovery fetch's signature is the published known answer" do
      fixtures = Map.new(signed_fixtures())
      %{"requests" => [discovery | _]} = known_answers!("signatures")

      for name <- ~w(get-configuration-valid.json get-configuration-header-twice.json) do
        assert header(fixtures[name]["headers"], "X-Qory-Signature-Ed25519") ==
                 discovery["signature"],
               name

        assert message(fixtures[name]) == Enum.join(discovery["lines"], "\n"), name
      end
    end

    test "a missing instance id is an empty third line" do
      %{"get-configuration-no-instance-id.json" => fixture} = Map.new(signed_fixtures())
      refute Map.has_key?(fixture["headers"], "X-Qory-Instance-Id")
      assert [_tag, _key_id, "" | _rest] = fixture |> message() |> String.split("\n")
    end
  end
end
