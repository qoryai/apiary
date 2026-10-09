defmodule Apiary.Contract.EnrolmentFixturesTest do
  @moduledoc """
  Replays the contract's enrolment fixtures (`fixtures/enrolment/*.json`, the enrolment
  files of `fixtures/invalid/`, and the enrolment proofs and answers of
  `known-answers/signatures.json`), from Forager's contract directory at the commit in
  `.forager-contract-ref`:

    * each request reads (`Apiary.Contract.Enrolment.decode/1`), validates against
      `enrolment.schema.json`, and its proof verifies over the five lines
      `Apiary.Contract.SignedMessage.enrolment/4` builds;
    * each answer and refusal is the body `Apiary.Contract.Enrolment` builds, byte for
      byte, and its signature under the fixture signing key, under the enrolment answers'
      own domain line with the request's proof as line 3, is the known answer's;
    * the fixture request, redeemed at its second against a code of its value under the
      fixture signing key's fingerprint, is refused, as the contract says a server refuses
      the fixture access key: by Apiary's key checks, which hold the published fixture
      keys, so before anything is signed (`:key_unproven`, an unsigned `409`
      `key_invalid`).

  The instance never signs under the fixture signing key, so an answer's signature is
  replayed here, through `Apiary.SigningKey.sign/2`, not through the endpoint;
  `test/apiary_web/contract/enrolment_controller_test.exs` takes the endpoint end to end
  under the instance's own key.
  """
  use Apiary.DataCase, async: true

  import Apiary.ContractFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{AccessKeys, ContractSchema, Repo, SigningKey}
  alias Apiary.AccessKeys.EnrolmentCode
  alias Apiary.Contract.{Ed25519, Enrolment, SignedMessage}

  @moduletag :contract

  @clock 1_700_000_000

  defp signing_key(name), do: SigningKey.new(fixture_key!(name).seed)

  # The server's keys as a fixture lists them: the current one, and during a rotation
  # the next.
  defp server_keys(:one), do: SigningKey.apiary_public_key([signing_key("signing_key")])

  defp server_keys(:rotation),
    do:
      SigningKey.apiary_public_key([signing_key("signing_key"), signing_key("next_signing_key")])

  # What builds each answer of `fixtures/enrolment/`.
  defp built("answer.json") do
    Enrolment.answer_body(%{
      access_key_id: "ak_f1xt0re000000000",
      node_id: "nd_f1xt0re000000000",
      node_kind: :node,
      stored_secrets: false,
      apiary_public_key: server_keys(:one)
    })
  end

  defp built("refusal-key-invalid.json"),
    do: Enrolment.refusal_body(:key_invalid, server_keys(:one))

  defp built("refusal-key-limit.json"), do: Enrolment.refusal_body(:key_limit, server_keys(:one))

  defp built("refusal-rate-limited.json"),
    do: Enrolment.refusal_body(:rate_limited, server_keys(:one))

  defp built("refusal-key-invalid-rotation.json"),
    do: Enrolment.refusal_body(:key_invalid, server_keys(:rotation))

  defp built("refusal-key-limit-rotation.json"),
    do: Enrolment.refusal_body(:key_limit, server_keys(:rotation))

  @requests ~w(request.json request-two-fingerprints.json)
  @answers ~w(answer.json refusal-key-invalid.json refusal-key-limit.json
              refusal-rate-limited.json refusal-key-invalid-rotation.json
              refusal-key-limit-rotation.json)

  defp schema, do: ContractSchema.schema!(contract_dir(), "enrolment.schema.json")

  test "the fixtures are there, and the ones expected" do
    names =
      contract_dir()
      |> Path.join("fixtures/enrolment/*.json")
      |> Path.wildcard()
      |> Enum.map(&Path.basename/1)
      |> Enum.sort()

    assert names == Enum.sort(@requests ++ @answers)
  end

  describe "the requests" do
    test "each reads, validates, and carries the server's fingerprints, current then next" do
      signing = fixture_key!("signing_key").fingerprint
      next = fixture_key!("next_signing_key").fingerprint

      for {name, fingerprints} <- [
            {"request.json", [signing]},
            {"request-two-fingerprints.json", [signing, next]}
          ] do
        assert {:ok, request} = Enrolment.decode(contract_file!("enrolment/" <> name)), name
        assert request.fingerprints == fingerprints, name
        assert request.code_head == "qec_F1XT0RE0000000000000000000", name
        assert ContractSchema.validate(schema(), contract_json!("enrolment/" <> name)) == :ok
      end
    end

    test "each proof is the known answer's lines, and verifies under the fixture access key alone" do
      %{"enrolment" => enrolments} = known_answers!("signatures")
      access_key = fixture_key!("access_key")
      assert length(enrolments) == 2

      for %{"body" => "fixtures/enrolment/" <> name, "lines" => lines, "length" => length} <-
            enrolments do
        {:ok, request} = Enrolment.decode(contract_file!("enrolment/" <> name))

        message =
          SignedMessage.enrolment(
            request.code,
            request.public_key,
            request.name,
            request.timestamp
          )

        assert message == Enum.join(lines, "\n"), name
        assert byte_size(message) == length, name
        assert Ed25519.encode(access_key.public_key) == request.public_key
        assert Enrolment.proof_verifies?(request, access_key.public_key), name

        refute Enrolment.proof_verifies?(request, second_fixture_access_key().public_key)
        refute Enrolment.proof_verifies?(%{request | name: "build-02"}, access_key.public_key)

        refute Enrolment.proof_verifies?(
                 %{request | timestamp: @clock + 1},
                 access_key.public_key
               )
      end
    end

    test "the code carries one fingerprint, the server's, as an instance whose key does not rotate issues it" do
      signing = fixture_key!("signing_key").fingerprint
      next = fixture_key!("next_signing_key").fingerprint

      {:ok, one} = Enrolment.decode(contract_file!("enrolment/request.json"))
      {:ok, two} = Enrolment.decode(contract_file!("enrolment/request-two-fingerprints.json"))

      assert Enrolment.issued_under?(one, signing)
      refute Enrolment.issued_under?(one, next)
      refute Enrolment.issued_under?(two, signing)
      refute Enrolment.issued_under?(two, next)
    end

    test "the proof's second is fresh within 300 seconds of the server's clock, either way" do
      {:ok, request} = Enrolment.decode(contract_file!("enrolment/request.json"))

      for offset <- [-300, 0, 300], do: assert(Enrolment.fresh?(request, at(@clock + offset)))
      for offset <- [-301, 301], do: refute(Enrolment.fresh?(request, at(@clock + offset)))
    end

    test "invalid/enrolment-code-lower-case.json is refused, for its code" do
      assert Enrolment.decode(contract_file!("invalid/enrolment-code-lower-case.json")) ==
               {:error, ["code"]}

      assert {:error, _} =
               ContractSchema.validate(
                 schema(),
                 contract_json!("invalid/enrolment-code-lower-case.json")
               )
    end
  end

  describe "the answers" do
    test "each is the body the builders make, byte for byte, and validates" do
      for name <- @answers do
        assert built(name) == contract_file!("enrolment/" <> name), name
        assert ContractSchema.validate(schema(), Jason.decode!(built(name))) == :ok, name
      end
    end

    test "the invalid answers are refused by the schema, and are no body the builders make" do
      for name <- ~w(enrolment-answer-no-node-id.json enrolment-refusal-no-key.json) do
        json = contract_json!("invalid/" <> name)
        assert {:error, _} = ContractSchema.validate(schema(), json), name
        refute contract_file!("invalid/" <> name) in Enum.map(@answers, &built/1), name
      end
    end

    test "each signature, under the fixture signing key and the enrolment answers' domain line with the request's proof as line 3, is the known answer's" do
      %{"answers" => answers} = known_answers!("signatures")
      key = signing_key("signing_key")

      enrolment_answers =
        for %{"body" => "fixtures/enrolment/" <> name} = answer <- answers, do: {name, answer}

      assert Enum.sort(Enum.map(enrolment_answers, &elem(&1, 0))) == Enum.sort(@answers)

      for {name, %{"lines" => lines, "signature" => signature, "length" => length}} <-
            enrolment_answers do
        ["qory-enrol-answer-ed25519-v1", status, proof, _hash, "", ""] = lines
        request = if name =~ "rotation", do: "request-two-fingerprints.json", else: "request.json"
        assert proof == contract_json!("enrolment/" <> request)["proof"], name

        message = SignedMessage.enrolment_answer(String.to_integer(status), proof, built(name))
        assert message == Enum.join(lines, "\n"), name
        assert byte_size(message) == length, name
        assert key |> SigningKey.sign(message) |> Ed25519.encode() == signature, name

        # Never the signature of the same lines as the answer to a signed request.
        request_answer =
          SignedMessage.answer(String.to_integer(status), proof, built(name), nil, nil)

        refute key |> SigningKey.sign(request_answer) |> Ed25519.encode() == signature, name
      end
    end
  end

  describe "the fixture request, redeemed" do
    setup do
      %{scope: scope} = sign_up_fixture()
      node = node_fixture(scope, %{name: "build-01"})

      # A code whose value is the fixture's, made now, so at the fixture's second it is
      # outstanding.
      {:ok, row, _code} = AccessKeys.create_enrolment_code(scope, node, %{})

      row =
        row
        |> Ecto.Changeset.change(
          code_sha256: EnrolmentCode.hash("qec_F1XT0RE0000000000000000000")
        )
        |> EnrolmentCode.put_integrity()
        |> Repo.update!()

      %{row: row}
    end

    test "under the fixture signing key's fingerprint, is refused by the key checks, before anything is signed: the server refuses the fixture access key",
         %{row: row} do
      {:ok, request} = Enrolment.decode(contract_file!("enrolment/request.json"))

      assert AccessKeys.enrol(request,
               now: at(@clock),
               fingerprint: fixture_key!("signing_key").fingerprint
             ) == {:error, :key_unproven}

      assert Repo.reload!(row).used_at == nil
    end

    test "a second past the window is no code, before the key is looked at" do
      {:ok, request} = Enrolment.decode(contract_file!("enrolment/request.json"))

      assert AccessKeys.enrol(request,
               now: at(@clock + 301),
               fingerprint: fixture_key!("signing_key").fingerprint
             ) == {:error, :unauthorized}
    end

    test "under the instance's own key's fingerprint, or carrying two, is no code" do
      {:ok, one} = Enrolment.decode(contract_file!("enrolment/request.json"))
      {:ok, two} = Enrolment.decode(contract_file!("enrolment/request-two-fingerprints.json"))

      assert AccessKeys.enrol(one, now: at(@clock)) == {:error, :unauthorized}

      assert AccessKeys.enrol(two,
               now: at(@clock),
               fingerprint: fixture_key!("signing_key").fingerprint
             ) ==
               {:error, :unauthorized}
    end

    test "with a proof made by the second fixture access key, is refused by the key checks too" do
      key = second_fixture_access_key()
      code = "qec_F1XT0RE0000000000000000000." <> fixture_key!("signing_key").fingerprint
      encoded = Ed25519.encode(key.public_key)
      message = SignedMessage.enrolment(code, encoded, "build-01", @clock)
      proof = :crypto.sign(:eddsa, :none, message, [key.seed, :ed25519]) |> Ed25519.encode()

      body =
        Jason.encode!(%{
          version: 1,
          code: code,
          name: "build-01",
          public_key: encoded,
          timestamp: @clock,
          proof: proof
        })

      {:ok, request} = Enrolment.decode(body)
      assert Enrolment.proof_verifies?(request, key.public_key)

      assert AccessKeys.enrol(request,
               now: at(@clock),
               fingerprint: fixture_key!("signing_key").fingerprint
             ) == {:error, :key_unproven}
    end
  end

  defp at(seconds), do: DateTime.from_unix!(seconds)
end
