defmodule Apiary.Contract.SignedMessageTest do
  use ExUnit.Case, async: true

  alias Apiary.Contract.SignedMessage

  doctest SignedMessage

  # The contract's known answers are replayed against the runner's contract directory in
  # test/contract/ed25519_known_answers_test.exs; these hold without it.

  describe "request/5" do
    test "a GET ends at its timestamp, with no line feed after it" do
      assert SignedMessage.request(
               "ak_f1xt0re000000000",
               "i_gYKDhIWGh4iJiouMjY6PkA",
               "GET",
               "/.well-known/qory-configuration",
               "1700000000"
             ) ==
               "qory-request-ed25519-v1\nak_f1xt0re000000000\ni_gYKDhIWGh4iJiouMjY6PkA\nGET\n" <>
                 "/.well-known/qory-configuration\n1700000000"
    end

    test "an absent instance id is an empty line" do
      assert SignedMessage.request("ak_f1xt0re000000000", nil, "GET", "/x", "1") ==
               "qory-request-ed25519-v1\nak_f1xt0re000000000\n\nGET\n/x\n1"
    end

    test "a POST ends with its raw body, line feeds and all, and the target is kept as sent" do
      body = ~s([{"a":1}]\n)

      assert SignedMessage.request("ak_f1xt0re000000000", "i_a", "post", "/v1/events?x=%2F", body) ==
               "qory-request-ed25519-v1\nak_f1xt0re000000000\ni_a\nPOST\n/v1/events?x=%2F\n" <>
                 body
    end
  end

  describe "answer/5" do
    test "carries the body's hash and both digests" do
      body = ~s({"version":1})
      hash = Base.encode16(:crypto.hash(:sha256, body), case: :lower)

      assert SignedMessage.answer(200, "sig", body, "sha256=" <> hash, "sha256=00") ==
               "qory-answer-ed25519-v1\n200\nsig\n#{hash}\nsha256=#{hash}\nsha256=00"

      assert SignedMessage.answer(200, "sig", [~s({"version":), "1}"], nil, nil) ==
               "qory-answer-ed25519-v1\n200\nsig\n#{hash}\n\n"
    end

    test "takes a status of three digits only" do
      assert_raise FunctionClauseError, fn -> SignedMessage.answer(99, "s", "", nil, nil) end
      assert_raise FunctionClauseError, fn -> SignedMessage.answer(600, "s", "", nil, nil) end
    end
  end
end
