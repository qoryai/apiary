defmodule Apiary.Contract.GatewayUrlTest do
  # A gateway's address as the contracts take it (`Apiary.Contract.GatewayUrl`): the
  # pattern of the vendored provisioner contract's `gateway_url` and of Forager's run key's,
  # character for character,
  # and each case the rule accepts or refuses, through the check a gateway's form, a run
  # key and a claim answer use.
  use ExUnit.Case, async: true

  alias Apiary.Contract.GatewayUrl

  @claim_answer Path.expand(
                  "../../fixtures/contract/provisioner/v1/claim-answer.schema.json",
                  __DIR__
                )

  test "the pattern and the length are the vendored claim answer's gateway_url" do
    rule =
      @claim_answer |> File.read!() |> Jason.decode!() |> get_in(["properties", "gateway_url"])

    assert GatewayUrl.pattern() == rule["pattern"]
    assert GatewayUrl.max_length() == rule["maxLength"]
  end

  @tag :contract
  test "the pattern and the length are Forager's run key gateway_url" do
    rule =
      Apiary.ContractFixtures.contract_dir()
      |> Path.join("run-key.schema.json")
      |> File.read!()
      |> Jason.decode!()
      |> get_in(["properties", "gateway_url"])

    assert GatewayUrl.pattern() == rule["pattern"]
    assert GatewayUrl.max_length() == rule["maxLength"]
  end

  test "a host with an underscore is refused" do
    refute GatewayUrl.valid?("https://edge_01.example")
  end

  test "port 0 is refused" do
    refute GatewayUrl.valid?("https://gateway.example:0")
  end

  test "port 65536 is refused" do
    refute GatewayUrl.valid?("https://gateway.example:65536")
  end

  test "user information is refused" do
    refute GatewayUrl.valid?("https://user@gateway.example")
  end

  test "a percent-encoding is refused" do
    refute GatewayUrl.valid?("https://gate%2Dway.example")
  end

  test "a trailing dot is refused" do
    refute GatewayUrl.valid?("https://gateway.example.")
  end

  test "a path is refused" do
    refute GatewayUrl.valid?("https://gateway.example/v1")
  end

  test "a query is refused" do
    refute GatewayUrl.valid?("https://gateway.example?x=1")
  end

  test "301 characters are refused, 300 accepted" do
    label = String.duplicate("a", 63)
    host = Enum.join([label, label, label, label, String.duplicate("b", 36)], ".")
    longest = "https://" <> host
    assert String.length(longest) == 300
    assert GatewayUrl.valid?(longest)

    refute GatewayUrl.valid?(longest <> "b")
    assert GatewayUrl.shape?(longest <> "b")
  end

  test "an IPv6 address in brackets is accepted" do
    assert GatewayUrl.valid?("https://[2001:db8::1]")
    assert GatewayUrl.valid?("https://[::ffff:10.0.0.5]:8443")
  end

  test "a host with a port is accepted" do
    assert GatewayUrl.valid?("https://gateway.example:8443")
    assert GatewayUrl.valid?("https://gateway.example:65535")
  end

  test "a final newline, another scheme and a value that is no string are refused" do
    refute GatewayUrl.valid?("https://gateway.example\n")
    refute GatewayUrl.valid?("http://gateway.example")
    refute GatewayUrl.valid?(nil)
  end
end
