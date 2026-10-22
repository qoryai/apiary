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
      `key_invalid`);
    * the run code's request and answer (`run_enrolment` of
      `known-answers/through-gateway.json`): the request reads and its proof is the known
      answer's, the answer is the body `Apiary.Contract.Enrolment.run_answer_body/1`
      builds, byte for byte, and its signature is the known answer's; the invalid run
      answers are refused; and the request, redeemed against a run whose code it is, is
      refused by the key checks, as the fixture request is;
    * the relay's signature of that request (`run_enrolment.relay`): the request string of
      a POST under the fixture gateway key, the body byte for byte as its last line, and
      the signature under that key, each the known answer's; and that request, with the
      known answer's headers, passes `ApiaryWeb.Contract.SignedRequest.relayed/1` under
      the fixture gateway key held on a gateway, and fails with one byte of its body
      changed.

  The instance never signs under the fixture signing key, so an answer's signature is
  replayed here, through `Apiary.SigningKey.sign/2`, not through the endpoint;
  `test/apiary_web/contract/enrolment_controller_test.exs` takes the endpoint end to end
  under the instance's own key.
  """
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Apiary.ContractFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{AccessKeys, ContractSchema, Repo, SigningKey}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode}
  alias Apiary.Contract.{Ed25519, Enrolment, SignedMessage}
  alias ApiaryWeb.Contract.SignedRequest

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

  defp built("answer-gateway.json") do
    Enrolment.answer_body(%{
      access_key_id: "ak_f1xt0re00000000g",
      node_id: "ng_f1xt0re000000000",
      node_kind: :gateway,
      stored_secrets: false,
      apiary_public_key: server_keys(:one)
    })
  end

  defp built("answer-adapter.json") do
    Enrolment.answer_body(%{
      access_key_id: "ak_f1xt0re000000000",
      node_id: "na_f1xt0re000000000",
      node_kind: :adapter,
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

  @requests ~w(request.json request-two-fingerprints.json request-gateway.json)
  # The answers the known answers sign, and an adapter's, which none signs.
  @signed_answers ~w(answer.json refusal-key-invalid.json refusal-key-limit.json
                     refusal-rate-limited.json refusal-key-invalid-rotation.json
                     refusal-key-limit-rotation.json answer-gateway.json)
  @answers @signed_answers ++ ~w(answer-adapter.json)

  # The request each answer answers, whose proof is its line 3.
  defp request_of("answer-gateway.json"), do: "request-gateway.json"

  defp request_of(name),
    do: if(name =~ "rotation", do: "request-two-fingerprints.json", else: "request.json")

  # The fixture key a request's proof is under: a gateway's code is redeemed under the
  # fixture gateway key, a node's under the fixture access key.
  defp enrolling_key("request-gateway.json"), do: fixture_key!("gateway_key")
  defp enrolling_key(_name), do: fixture_key!("access_key")

  defp schema, do: ContractSchema.schema!(contract_dir(), "enrolment.schema.json")

  # The code a request fixture carries, before its first `.`: its prefix and 26 characters.
  defp fixture_head(name),
    do: contract_json!("enrolment/" <> name)["code"] |> String.split(".") |> hd()

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

      for {name, fingerprints, kind} <- [
            {"request.json", [signing], :node},
            {"request-two-fingerprints.json", [signing, next], :node},
            {"request-gateway.json", [signing], :gateway}
          ] do
        assert {:ok, request} = Enrolment.decode(contract_file!("enrolment/" <> name)), name
        assert request.fingerprints == fingerprints, name
        assert request.code_head == fixture_head(name), name
        assert EnrolmentCode.of_kind?(request.code_head, kind), name
        assert ContractSchema.validate(schema(), contract_json!("enrolment/" <> name)) == :ok
      end
    end

    test "each proof is the known answer's lines, and verifies under its fixture key alone" do
      %{"enrolment" => enrolments} = known_answers!("signatures")

      assert Enum.sort(Enum.map(enrolments, & &1["body"])) ==
               Enum.sort(Enum.map(@requests, &("fixtures/enrolment/" <> &1)))

      for %{"body" => "fixtures/enrolment/" <> name, "lines" => lines, "length" => length} <-
            enrolments do
        {:ok, request} = Enrolment.decode(contract_file!("enrolment/" <> name))
        access_key = enrolling_key(name)

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
      for name <-
            ~w(enrolment-answer-no-node-id.json enrolment-refusal-no-key.json
               enrolment-answer-gateway-kind-of-a-node.json
               enrolment-answer-adapter-kind-of-a-pool.json) do
        json = contract_json!("invalid/" <> name)
        assert {:error, _} = ContractSchema.validate(schema(), json), name

        refute contract_file!("invalid/" <> name) in Enum.map(
                 @answers,
                 &built/1
               ),
               name
      end
    end

    test "each signature, under the fixture signing key and the enrolment answers' domain line with the request's proof as line 3, is the known answer's" do
      %{"answers" => answers} = known_answers!("signatures")
      key = signing_key("signing_key")

      enrolment_answers =
        for %{"body" => "fixtures/enrolment/" <> name} = answer <- answers, do: {name, answer}

      assert Enum.sort(Enum.map(enrolment_answers, &elem(&1, 0))) == Enum.sort(@signed_answers)

      for {name, %{"lines" => lines, "signature" => signature, "length" => length}} <-
            enrolment_answers do
        ["qory-enrol-answer-ed25519-v1", status, proof, _hash, "", ""] = lines
        assert proof == contract_json!("enrolment/" <> request_of(name))["proof"], name

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
        |> Ecto.Changeset.change(code_sha256: EnrolmentCode.hash(fixture_head("request.json")))
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
      code = fixture_head("request.json") <> "." <> fixture_key!("signing_key").fingerprint
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

  describe "the run code's known answers, known-answers/through-gateway.json run_enrolment" do
    setup do
      %{"run_enrolment" => known, "run_key" => %{"run_key" => run_key}} =
        known_answers!("through-gateway")

      {:ok, request} =
        Enrolment.decode(contract_file!("known-answers/enrolment-run-request.json"))

      %{known: known, run_key: run_key, request: request}
    end

    test "the request reads as a run code's under the fixture signing key, validates, and its proof is the known answer's",
         %{known: known, request: request} do
      assert known["request"] == "fixtures/known-answers/enrolment-run-request.json"
      assert EnrolmentCode.run_code?(request.code_head)
      assert request.fingerprints == [fixture_key!("signing_key").fingerprint]

      assert ContractSchema.validate(
               schema(),
               contract_json!("known-answers/enrolment-run-request.json")
             ) == :ok

      message =
        SignedMessage.enrolment(request.code, request.public_key, request.name, request.timestamp)

      assert message == Enum.join(known["proof_lines"], "\n")
      assert byte_size(message) == known["proof_length"]
      assert request.proof == known["proof"]
      assert Enrolment.proof_verifies?(request, fixture_key!("access_key").public_key)
    end

    test "the answer is the body run_answer_body/1 makes, byte for byte, and validates",
         %{known: known, run_key: run_key} do
      assert known["answer"] == "fixtures/known-answers/enrolment-run-answer.json"
      body = contract_file!("known-answers/enrolment-run-answer.json")
      assert byte_size(body) == known["body_length"]

      built =
        Enrolment.run_answer_body(%{
          run_id: "0192f0c1-7d4e-7a2b-8c3d-4e5f6a7b8c9d",
          run_key: run_key,
          apiary_public_key: server_keys(:one),
          documents: Jason.encode!(Jason.decode!(body)["documents"])
        })

      assert built == body
      assert ContractSchema.validate(schema(), Jason.decode!(built)) == :ok

      # Its run key is the fixture's, signed under the fixture signing key, for its run.
      assert {:ok, %{run_id: run_id}, _payload} =
               Apiary.Runs.RunKey.verify(run_key, [signing_key("signing_key")])

      assert run_id == Jason.decode!(body)["run_id"]
    end

    test "an answer with the run's documents validates, the documents written as they are",
         %{run_key: run_key} do
      documents = ~s({"step":"explore","domain":"software","inputs":{"version":1}})

      built =
        Enrolment.run_answer_body(%{
          run_id: "0192f0c1-7d4e-7a2b-8c3d-4e5f6a7b8c9d",
          run_key: run_key,
          documents: documents,
          apiary_public_key: server_keys(:one)
        })

      assert String.ends_with?(built, ~s(}],"documents":) <> documents <> "}")
      assert ContractSchema.validate(schema(), Jason.decode!(built)) == :ok
    end

    test "the answer's signature, under the fixture signing key with the request's proof as line 3, is the known answer's",
         %{known: known, request: request} do
      body = contract_file!("known-answers/enrolment-run-answer.json")
      ["qory-enrol-answer-ed25519-v1", "201", proof, _hash, "", ""] = known["lines"]
      assert proof == request.proof

      message = SignedMessage.enrolment_answer(201, proof, body)
      assert message == Enum.join(known["lines"], "\n")
      assert byte_size(message) == known["length"]

      assert signing_key("signing_key") |> SigningKey.sign(message) |> Ed25519.encode() ==
               known["signature"]
    end

    test "the relay's signature: a POST under the gateway's access key, the body byte for byte as the last line, and the known answer's",
         %{known: known} do
      body = contract_file!("known-answers/enrolment-run-request.json")
      gateway = fixture_key!("gateway_key")
      instance_id = fixture_key!("access_key").instance_id
      path = "/.well-known/qory-enrolment"

      message = SignedMessage.request(gateway.access_key_id, instance_id, "POST", path, body)

      lines = [
        "qory-request-ed25519-v1",
        gateway.access_key_id,
        instance_id,
        "POST",
        path,
        body
      ]

      assert message == Enum.join(lines, "\n")
      assert String.ends_with?(message, "\n" <> body)

      signature =
        sign_request(gateway.seed, gateway.access_key_id, instance_id, "POST", path, body)

      {:ok, raw} = Ed25519.decode(signature, 64)
      assert Ed25519.verify(message, raw, gateway.public_key)

      relay = known["relay"]
      assert relay["access_key_id"] == gateway.access_key_id
      assert relay["body"] == "fixtures/known-answers/enrolment-run-request.json"
      assert relay["lines"] == lines
      assert relay["length"] == byte_size(message)
      assert relay["signature"] == signature
    end

    # The relay's request as the endpoint reads it: a POST to the enrolment path with the
    # known answer's headers, its body kept byte for byte (`ApiaryWeb.Contract.RawBody`).
    defp relayed_conn(relay, body) do
      Plug.Test.conn(:post, "/.well-known/qory-enrolment", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-qory-contract-version", "1")
      |> Plug.Conn.put_req_header("x-qory-access-key-id", relay["access_key_id"])
      |> Plug.Conn.put_req_header("x-qory-instance-id", Enum.at(relay["lines"], 2))
      |> Plug.Conn.put_req_header("x-qory-signature-ed25519", relay["signature"])
      |> ApiaryWeb.Contract.RawBody.call(ApiaryWeb.Contract.RawBody.init([]))
    end

    test "the relay's request passes relayed/1 under the fixture gateway key on a gateway, and fails with one body byte changed",
         %{known: known} do
      %{scope: scope} = sign_up_fixture()
      gateway = gateway_fixture(scope)
      key = fixture_access_key!(scope, gateway, "gateway_key")
      relay = known["relay"]
      assert Enum.at(relay["lines"], 2) == "i_gYKDhIWGh4iJiouMjY6PkA"

      body = contract_file!("known-answers/enrolment-run-request.json")
      conn = relayed_conn(relay, body)
      assert conn.assigns.raw_body == body

      assert {:ok, %AccessKey{id: id, node_id: node_id}} = SignedRequest.relayed(conn)
      assert {id, node_id} == {key.id, gateway.id}

      # The name `run-01` sent as `run-02`: one byte of the body changed.
      changed = String.replace(body, ~s("run-01"), ~s("run-02"))
      assert byte_size(changed) == byte_size(body) and changed != body
      assert SignedRequest.relayed(relayed_conn(relay, changed)) == :unauthorized
    end

    test "the invalid run answers are refused by the schema, and are no body the builder makes",
         %{run_key: run_key} do
      built =
        Enrolment.run_answer_body(%{
          run_id: "0192f0c1-7d4e-7a2b-8c3d-4e5f6a7b8c9d",
          run_key: run_key,
          apiary_public_key: server_keys(:one)
        })

      for name <-
            ~w(enrolment-run-answer-access-key-id.json enrolment-run-answer-no-run-key.json
               enrolment-run-answer-run-id-upper-case.json) do
        assert {:error, _} = ContractSchema.validate(schema(), contract_json!("invalid/" <> name))
        refute contract_file!("invalid/" <> name) == built, name
      end
    end

    @tag needs: :factory
    test "redeemed against a run whose code it is, is refused by the key checks, before anything is signed",
         %{request: request} do
      %{scope: scope} = sign_up_fixture()
      place = Apiary.DispatchedRunsFixtures.handover_place_fixture(scope)
      work_item = Apiary.WorkItemsFixtures.work_item_fixture(scope)
      {:ok, _queued} = Repo.transact(fn -> Apiary.Dispatches.queue(work_item, 1) end)
      %{registered: run} = Apiary.DispatchedRunsFixtures.dispatched!(place.key)

      {1, _rows} =
        Repo.update_all(
          from(r in Apiary.Runs.Run, where: r.id == ^run.id),
          set: [
            run_code_sha256: EnrolmentCode.hash(request.code_head),
            run_code_expires_at: at(request.timestamp + 60)
          ]
        )

      assert Apiary.Runs.RunCode.redeem(request,
               relayed_by: run.gateway_id,
               now: at(request.timestamp),
               fingerprint: fixture_key!("signing_key").fingerprint
             ) == {:error, :key_unproven}

      assert Repo.get!(Apiary.Runs.Run, run.id).run_key_payload == nil
    end
  end

  defp at(seconds), do: DateTime.from_unix!(seconds)
end
