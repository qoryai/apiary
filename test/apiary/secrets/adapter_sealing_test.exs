defmodule Apiary.Secrets.AdapterSealingTest do
  # `Apiary.Secrets.AdapterSealing`: the integration contract's known answer of an adapter's
  # secrets, both ways, and what an envelope of another kind, key or adapter does.
  #
  # The known answer is copied from qoryai/integrations at the commit in
  # `.integration-contract-ref`, `contracts/integration/v1/fixtures/adapter/`: `signed/adapter-secrets.json` (the
  # identifiers, the plaintext and the hex of both infos and the aad),
  # `adapter-secrets/upload.json` (sealed to the fixture server key) and
  # `adapter-secrets-answer/delivery.json` (sealed to the fixture access key), under the keys
  # of `signed/keys.json`, Forager's published fixture keys, which grant nothing.
  use ExUnit.Case, async: true

  alias Apiary.Contract.Ed25519
  alias Apiary.Secrets.{AdapterSealing, Hpke, InstanceSecretValue}
  alias Apiary.SigningKey

  @adapter_id "na_f1xt0re000000000"
  @access_key_id "ak_f1xt0re000000000"
  @server_key "rcFAEfgtHFbZVqpPnXPYhYNhpgYEhSXg0Ixjjcdd2Mc"
  # The fixture server key's seed, the bytes 65 to 96, and the fixture access key's, 1 to 32.
  @server_seed :binary.list_to_bin(Enum.to_list(65..96))
  @access_seed :binary.list_to_bin(Enum.to_list(1..32))
  @plaintext ~s({"version":1,"secrets":[{"name":"event-secret","value":"fixture-event-secret-for-tests-only"},{"name":"signing-key","value":"fixture-signing-key-for-tests-only\\nsecond line"}]})
  @upload_info "716f7279206164617074657220736563726574732075706c6f616420763100002000010002002b72634641456667744846625a567170506e58505968594e6870675945685358673049786a6a636464324d63"
  @delivery_info "716f727920616461707465722073656372657473207631000020000100020013616b5f66317874307265303030303030303030"
  @aad "00136e615f663178743072653030303030303030300013616b5f66317874307265303030303030303030"
  @upload %{
    "suite" => "x25519-sha256-aes256gcm",
    "server_key" => @server_key,
    "enc" => "TGuG6r45zkI30lG-ZjBaxf_fSX8dPyWvs-49ViGQKng",
    "ct" =>
      "J0PTPrGUNNJ--l9LANVTU1qrMUaMzw1FMz4TaV6MdUPi_3svc5nuHGrpAYcbb5kiE40XWRtfOB3iwEXgzYX1GBLmb5opVhs1kP9fR_1LBwhMLIPC8dta8E6fjfQg8ClCqhwFxHRa4aa0uz3Oz0kY7JNgkifaxKMUFHoQKLNOw0OaYKD_0kNfpTn60HG42pCtl9C1BdxJItA0xEj6tf-FPdFAHIGOzCV1bm5kpRQitZ7yTKgPuC6xPUZMQh0tJ7uT"
  }
  @delivery %{
    "enc" => "5TNqaGVrZFIRjnU7VEeBD2mqgQ89FSFlK7ey4hxOOHo",
    "ct" =>
      "KpPDW7XbN0NG5N9BIqJkP6a1UXsOWA3SvsRm9xXiu4tueGB0N0XGDkewrlt-einap4bzb0RtCIGJ4kd_7u4xsn1HsXgxue09HXkj76GrP3mgfckAAobXNI4STp1mG0AtvzQy-qL2Z-fijg5tX2arxCIocCbHGxJvs2TANrhHrdeQjgZ9x9H8mgn6OKJAyjwCjY3J8iVXIseGICtxksxVjZUKtkWt7rOLFQ205hlgdgmgnwW-6ofYL7rIrp8pJMzD"
  }

  defp server_key, do: SigningKey.new(@server_seed)
  defp access_private_key, do: binary_part(:crypto.hash(:sha512, @access_seed), 0, 32)

  defp access_public_key do
    {public, _private} = :crypto.generate_key(:eddsa, :ed25519, @access_seed)
    public
  end

  defp d(value), do: value |> Base.url_decode64!(padding: false)

  defp pairs({:ok, values}),
    do: {:ok, for(%InstanceSecretValue{value_id: id, value: value} <- values, do: {id, value})}

  defp pairs(other), do: other

  defp values(pairs),
    do: for({id, value} <- pairs, do: %InstanceSecretValue{value_id: id, value: value})

  defp open_delivery(body, adapter_id \\ @adapter_id) do
    %{"sealed" => %{"enc" => enc, "ct" => ct}} = Jason.decode!(body)

    Hpke.open(
      access_private_key(),
      d(enc),
      AdapterSealing.delivery_info(@access_key_id),
      AdapterSealing.aad(adapter_id, @access_key_id),
      d(ct)
    )
  end

  describe "the known answer" do
    test "the infos and the aad, byte for byte" do
      assert Base.encode16(AdapterSealing.upload_info(@server_key), case: :lower) == @upload_info

      assert Base.encode16(AdapterSealing.delivery_info(@access_key_id), case: :lower) ==
               @delivery_info

      assert Base.encode16(AdapterSealing.aad(@adapter_id, @access_key_id), case: :lower) == @aad
      assert Ed25519.encode(SigningKey.public_key(server_key())) == @server_key
    end

    test "the upload opens with the fixture server key to its secrets" do
      assert AdapterSealing.open_upload(@upload, @adapter_id, @access_key_id, server_key())
             |> pairs() ==
               {:ok,
                [
                  {"event-secret", "fixture-event-secret-for-tests-only"},
                  {"signing-key", "fixture-signing-key-for-tests-only\nsecond line"}
                ]}
    end

    test "the delivery opens with the fixture access key to the plaintext" do
      assert Hpke.open(
               access_private_key(),
               d(@delivery["enc"]),
               AdapterSealing.delivery_info(@access_key_id),
               AdapterSealing.aad(@adapter_id, @access_key_id),
               d(@delivery["ct"])
             ) == {:ok, @plaintext}
    end

    test "the plaintext a delivery seals is the fixture's, byte for byte" do
      {:ok, values} = AdapterSealing.plaintext(@plaintext)
      assert AdapterSealing.encode_plaintext(Enum.reverse(values)) == @plaintext
    end
  end

  describe "an upload" do
    test "opens with no other adapter id, access key id or server key" do
      for {adapter_id, access_key_id} <- [
            {"na_f1xt0re000000001", @access_key_id},
            {@adapter_id, "ak_f1xt0re000000001"}
          ] do
        assert AdapterSealing.open_upload(@upload, adapter_id, access_key_id, server_key()) ==
                 {:error, :open}
      end

      # Sealed to a key the instance does not hold.
      assert AdapterSealing.open_upload(
               @upload,
               @adapter_id,
               @access_key_id,
               SigningKey.new(:crypto.strong_rand_bytes(32))
             ) == {:error, :server_key}
    end

    test "a delivery does not open as an upload, nor an upload as a delivery" do
      delivery_as_upload = Map.merge(@upload, @delivery)

      assert AdapterSealing.open_upload(
               delivery_as_upload,
               @adapter_id,
               @access_key_id,
               server_key()
             ) == {:error, :open}

      # The upload under the delivery's info, with the server key: it does not open.
      assert Hpke.open(
               SigningKey.x25519_private_key(server_key()),
               d(@upload["enc"]),
               AdapterSealing.delivery_info(@access_key_id),
               AdapterSealing.aad(@adapter_id, @access_key_id),
               d(@upload["ct"])
             ) == :error
    end

    test "an envelope outside its form is refused before it is opened" do
      for sealed <- [
            Map.delete(@upload, "server_key"),
            Map.put(@upload, "values", [%{"name" => "signing-key", "value" => "in clear"}]),
            Map.put(@upload, "suite", "x25519-sha256-chacha20poly1305"),
            Map.put(@upload, "enc", String.slice(@upload["enc"], 0, 42)),
            Map.put(@upload, "enc", @upload["enc"] <> "="),
            Map.put(@upload, "ct", "AAAA"),
            Map.put(@upload, "ct", @upload["ct"] <> "A"),
            Map.put(@upload, "server_key", 1),
            "sealed",
            nil
          ] do
        assert AdapterSealing.open_upload(sealed, @adapter_id, @access_key_id, server_key()) ==
                 {:error, :sealed}
      end
    end
  end

  describe "a plaintext" do
    test "outside the contract's rules is refused" do
      seventeen = for n <- 0..16, do: %{"name" => "secret-#{n}", "value" => "v"}

      for doc <- [
            %{"version" => 1, "secrets" => seventeen},
            %{"version" => 1, "secrets" => [%{"name" => "signing-key", "value" => ""}]},
            %{"version" => 1, "secrets" => [%{"name" => "Signing-Key", "value" => "v"}]},
            %{"version" => 2, "secrets" => []},
            %{"version" => 1, "secrets" => [], "more" => true},
            %{"version" => 1, "secrets" => [%{"name" => "k", "value" => "v", "more" => 1}]},
            %{"version" => 1, "secrets" => [%{"name" => "k", "value" => 1}]},
            %{"version" => 1, "secrets" => [%{"name" => "k", "value" => "a" <> <<0>>}]},
            %{
              "version" => 1,
              "secrets" => [%{"name" => "k", "value" => "a"}, %{"name" => "k", "value" => "b"}]
            },
            %{"version" => 1, "secrets" => %{}}
          ] do
        assert AdapterSealing.plaintext(Jason.encode!(doc)) == {:error, :plaintext}, inspect(doc)
      end

      assert AdapterSealing.plaintext(~s({"version":1,"version":1,"secrets":[]})) ==
               {:error, :plaintext}

      assert AdapterSealing.plaintext(<<0xFF>>) == {:error, :plaintext}
      assert AdapterSealing.plaintext(~s({"version":1,"secrets":[]})) == {:ok, []}
    end
  end

  describe "a delivery" do
    @recipient %{adapter_id: @adapter_id, access_key_id: @access_key_id}

    test "opens with the access key to the values, sorted by name" do
      recipient = Map.put(@recipient, :public_key, access_public_key())
      values = values([{"signing-key", "two"}, {"event-secret", "one"}])

      assert {:ok, body} = AdapterSealing.delivery(values, recipient, 1)

      assert %{
               "version" => 1,
               "revision" => 1,
               "sealed" => %{
                 "suite" => "x25519-sha256-aes256gcm",
                 "access_key_id" => @access_key_id,
                 "enc" => _,
                 "ct" => _
               }
             } = Jason.decode!(body)

      assert body =~ ~s({"version":1,"revision":1,"sealed":{"suite":)

      assert open_delivery(body) ==
               {:ok,
                ~s({"version":1,"secrets":[{"name":"event-secret","value":"one"},{"name":"signing-key","value":"two"}]})}

      assert open_delivery(body, "na_f1xt0re000000001") == :error
    end

    test "with no value lists none, and each answer has a fresh ephemeral key" do
      recipient = Map.put(@recipient, :public_key, access_public_key())
      {:ok, one} = AdapterSealing.delivery([], recipient, 1)
      {:ok, two} = AdapterSealing.delivery([], recipient, 1)

      assert open_delivery(one) == {:ok, ~s({"version":1,"secrets":[]})}
      refute Jason.decode!(one)["sealed"]["enc"] == Jason.decode!(two)["sealed"]["enc"]
    end

    test "a gateway's envelope does not open as an adapter's" do
      recipient = Map.put(@recipient, :public_key, access_public_key())
      {:ok, body} = AdapterSealing.delivery(values([{"k", "v"}]), recipient, 1)
      %{"sealed" => %{"enc" => enc, "ct" => ct}} = Jason.decode!(body)

      assert Hpke.open(
               access_private_key(),
               d(enc),
               Apiary.Secrets.Sealing.info(@access_key_id),
               AdapterSealing.aad(@adapter_id, @access_key_id),
               d(ct)
             ) == :error
    end

    test "refuses values outside their forms and a key off the curve, with an atom alone" do
      recipient = Map.put(@recipient, :public_key, access_public_key())
      assert AdapterSealing.delivery(values([{"K", "v"}]), recipient, 1) == {:error, :plaintext}

      assert AdapterSealing.delivery(
               values([{"k", "v"}]),
               %{recipient | public_key: <<1::256>>},
               1
             ) ==
               {:error, :key}
    end
  end
end
