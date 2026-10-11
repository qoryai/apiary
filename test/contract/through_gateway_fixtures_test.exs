defmodule Apiary.Contract.ThroughGatewayFixturesTest do
  @moduledoc """
  A run through a gateway against Forager's contract at the commit in
  `.forager-contract-ref`: the known answers of `known-answers/through-gateway.json` (the
  run key, made again by `Apiary.Runs.RunKey` under the fixture signing key, and each
  request's and answer's lines and signature), the contract's fixtures and invalid files of
  the run key, the registration, the attach and their answers, and the answers this server
  gives (a registration through a gateway, an attach, an outcome and a batch after the
  run's end), each against its schema.
  """
  use ApiaryWeb.ConnCase, async: true

  import Apiary.ContractFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Contract.{Ed25519, SignedMessage}
  alias Apiary.ContractSchema
  alias Apiary.Runs.{Attach, Outcome, Registration, RunKey}
  alias Apiary.SigningKey

  @moduletag :contract

  defp schema(file), do: ContractSchema.schema!(contract_dir(), file)

  defp valid?(file, document), do: ContractSchema.validate(schema(file), document) == :ok

  defp signing_key, do: SigningKey.new(fixture_key!("signing_key").seed)

  defp sign(message, seed),
    do: :crypto.sign(:eddsa, :none, message, [seed, :ed25519]) |> Ed25519.encode()

  defp invalid(prefix) do
    files =
      contract_dir()
      |> Path.join("fixtures/invalid/#{prefix}*.json")
      |> Path.wildcard()

    assert files != [], prefix
    files
  end

  describe "known-answers/through-gateway.json" do
    test "the run key of its payload is made again here, byte for byte" do
      %{"run_key" => known} = known_answers!("through-gateway")
      payload = contract_file!("known-answers/run-key-payload.json")
      assert byte_size(payload) == known["payload_length"]
      assert SignedMessage.run_key(payload) == Enum.join(known["lines"], "\n")

      key = signing_key()
      assert {:ok, grant, ^payload} = RunKey.verify(known["run_key"], [key])
      assert {:ok, run_key, ^payload} = RunKey.issue(grant, key)
      assert run_key == known["run_key"]
      assert RunKey.encode(payload, key) == known["run_key"]
      assert byte_size(SignedMessage.run_key(payload)) == known["length"]

      assert grant.instance_id == "i_gYKDhIWGh4iJiouMjY6PkA"
      assert valid?("run-key.schema.json", Jason.decode!(payload))

      # Under the instance's own key, which is not the fixture's, it is no run key.
      assert RunKey.verify(known["run_key"]) == :error
    end

    test "each request's lines are this server's request string, and their signature verifies" do
      for request <- known_answers!("through-gateway")["requests"] do
        body = contract_file!(String.trim_leading(request["body"], "fixtures/"))
        [_tag, key_id, instance_id, method, target, last] = request["lines"]
        assert last == body

        message = SignedMessage.request(key_id, instance_id, method, target, body)
        assert message == Enum.join(request["lines"], "\n")

        name = if key_id == "ak_f1xt0re00000000g", do: "gateway_key", else: "access_key"
        key = fixture_key!(name)
        assert key.access_key_id == request["access_key_id"]
        assert sign(message, key.seed) == request["signature"]
      end
    end

    test "each answer's lines are this server's answer string, signed under the fixture key" do
      %{"requests" => requests, "answers" => answers} = known_answers!("through-gateway")

      for {request, answer} <- Enum.zip(requests, answers) do
        body = contract_file!(String.trim_leading(answer["body"], "fixtures/"))
        assert byte_size(body) == answer["body_length"]

        [_tag, status, request_signature, _hash, configuration, run_configuration] =
          answer["lines"]

        assert request_signature == request["signature"]

        message =
          SignedMessage.answer(
            String.to_integer(status),
            request_signature,
            body,
            if(configuration == "", do: nil, else: configuration),
            if(run_configuration == "", do: nil, else: run_configuration)
          )

        assert message == Enum.join(answer["lines"], "\n")
        assert sign(message, fixture_key!("signing_key").seed) == answer["signature"]
      end
    end

    test "its bodies pass their schemas, and this server reads the requests" do
      file = &contract_file!("known-answers/" <> &1)

      registration = Jason.decode!(file.("registration-gateway.json"))
      assert valid?("run-registration.schema.json", registration)

      assert {:ok, %Registration{shape: :gateway, attach_seconds: 600}} =
               Registration.parse(registration)

      answer = Jason.decode!(file.("registration-gateway-answer.json"))
      assert valid?("run-registration-answer.schema.json", answer)

      assert file.("registration-gateway-answer.json") ==
               Jason.encode!(
                 Jason.OrderedObject.new(
                   version: 1,
                   run_id: answer["run_id"],
                   run_key: answer["run_key"]
                 )
               )

      attach = Jason.decode!(file.("attach.json"))
      assert valid?("run-attach.schema.json", attach)
      assert {:ok, %Attach{interval_seconds: 30}} = Attach.parse(attach)
      assert valid?("run-attach-answer.schema.json", Jason.decode!(file.("attach-answer.json")))

      outcome = Jason.decode!(file.("outcome.json"))
      assert valid?("run-outcome.schema.json", outcome)
      assert {:ok, %Outcome{}} = Outcome.parse(outcome)
      assert valid?("run-outcome-answer.schema.json", Jason.decode!(file.("outcome-answer.json")))
    end
  end

  describe "the fixtures" do
    test "each fixture passes its schema, and each invalid answer fails it" do
      for {dir, schema} <- [
            {"run-attach-answer", "run-attach-answer.schema.json"},
            {"run-outcome", "run-outcome.schema.json"},
            {"batch-answer", "batch-answer.schema.json"},
            {"run-registration", "run-registration.schema.json"}
          ],
          file <- contract_dir() |> Path.join("fixtures/#{dir}/*.json") |> Path.wildcard() do
        assert valid?(schema, Jason.decode!(File.read!(file))), Path.basename(file)
      end

      for {prefix, schema} <- [
            {"run-attach-answer-", "run-attach-answer.schema.json"},
            {"run-registration-answer-", "run-registration-answer.schema.json"},
            {"run-outcome-answer-", "run-outcome-answer.schema.json"},
            {"batch-answer-", "batch-answer.schema.json"}
          ],
          file <- invalid(prefix) do
        refute valid?(schema, Jason.decode!(File.read!(file))), Path.basename(file)
      end
    end

    test "invalid/run-key-*.json, each signed under the fixture signing key, are no run key" do
      key = signing_key()

      for file <- invalid("run-key-") do
        payload = File.read!(file)
        refute valid?("run-key.schema.json", Jason.decode!(payload)), Path.basename(file)

        run_key =
          "qrk_" <>
            Ed25519.encode(payload) <>
            "." <> Ed25519.encode(SigningKey.sign(key, SignedMessage.run_key(payload)))

        assert RunKey.verify(run_key, [key]) == :error, Path.basename(file)
      end
    end

    test "invalid/run-attach-*.json are refused by the attach's reading, as its schema refuses them" do
      for file <- invalid("run-attach-"), not String.contains?(file, "-answer-") do
        body = Jason.decode!(File.read!(file))
        refute valid?("run-attach.schema.json", body), Path.basename(file)
        assert {:error, :invalid_request, _name} = Attach.parse(body), Path.basename(file)
      end
    end

    test "invalid/run-outcome-*.json are refused by the outcome's reading, as its schema refuses them" do
      for file <- invalid("run-outcome-"), not String.contains?(file, "-answer-") do
        body = Jason.decode!(File.read!(file))
        refute valid?("run-outcome.schema.json", body), Path.basename(file)
        assert {:error, :invalid_request, _name} = Outcome.parse(body), Path.basename(file)
      end
    end
  end

  describe "this server's answers" do
    setup do
      %{scope: scope} = sign_up_fixture()
      gateway = gateway_fixture(scope)

      %{access_key: gateway_key, secret: gateway_secret} =
        contract_key_fixture(scope, node: gateway)

      %{access_key: key, secret: secret} = contract_key_fixture(scope)
      %{gateway_key: {gateway_key, gateway_secret}, key: {key, secret}}
    end

    test "to a registration, an attach, an outcome and a batch after the end pass their schemas",
         %{gateway_key: {gateway_key, gateway_secret}, key: {key, secret}} do
      run_id = Ecto.UUID.generate()

      conn =
        signed_register(
          build_conn(),
          key.key_id,
          secret,
          Jason.encode!(gateway_registration(run_id))
        )

      assert %{"run_key" => run_key} = answer = json_response(conn, 200)
      assert valid?("run-registration-answer.schema.json", answer)

      {:ok, _grant, payload} = RunKey.verify(run_key)
      assert valid?("run-key.schema.json", Jason.decode!(payload))

      body = attach_body(run_key)
      assert valid?("run-attach.schema.json", body)

      conn =
        signed_attach(
          build_conn(),
          gateway_key.key_id,
          gateway_secret,
          run_id,
          Jason.encode!(body)
        )

      assert valid?("run-attach-answer.schema.json", json_response(conn, 200))

      time =
        ApiaryWeb.Contract.SignedRequest.now() |> DateTime.from_unix!() |> DateTime.to_iso8601()

      outcome = %{"version" => 1, "state" => "failed", "reason" => "tests_failed", "time" => time}
      assert valid?("run-outcome.schema.json", outcome)

      conn =
        signed_post(build_conn(), key.key_id, secret, Jason.encode!(outcome),
          target: "/v1/runs/#{run_id}/outcome",
          content_type: "application/json",
          delivery: nil
        )

      assert valid?("run-outcome-answer.schema.json", json_response(conn, 200))

      {_subject, events} = first_events(run_id)
      conn = signed_post(build_conn(), gateway_key.key_id, gateway_secret, events)

      assert %{"end" => %{"state" => "failed", "reason" => "tests_failed"}} =
               answer = Jason.decode!(conn.resp_body)

      assert valid?("batch-answer.schema.json", answer)
    end
  end
end
