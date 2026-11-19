defmodule Apiary.ModelKeys.AccountClaimTest do
  # The account id in an access token, read by the rules of the gateway of Forager
  # (`AccountClaim` in `gateway/internal/credential/credential.go`, tests in
  # `account_test.go`). Each case of those tests is one test here, with an invented token.
  use ExUnit.Case, async: true

  alias Apiary.ModelKeys.AccountClaim

  @pointer "/https:~1~1auth.model.example~1auth/account_id"
  @payload ~s({"https://auth.model.example/auth":{"account_id":"acct-fake-0001","plan":"team"},"list":["a","b"],"a~b":{"c/d":"x"},"n":5})
  @max 8192

  defp enc(bin), do: Base.url_encode64(bin, padding: false)
  defp token(payload), do: enc(~s({"alg":"none"})) <> "." <> enc(payload) <> ".fake-signature"
  defp read(payload, pointer \\ @pointer), do: AccountClaim.read(token(payload), pointer)

  describe "read/2 reads" do
    test "the account id at the pointer" do
      assert read(@payload) == {:ok, "acct-fake-0001"}
    end

    test "a member with ~0 and ~1 in its name, and a list index" do
      assert read(@payload, "/a~0b/c~1d") == {:ok, "x"}
      assert read(@payload, "/list/1") == {:ok, "b"}
    end

    test "a payload with padding" do
      parts = String.split(token(@payload), ".")
      padded = Enum.at(parts, 0) <> "." <> Base.url_encode64(@payload) <> "." <> Enum.at(parts, 2)

      assert String.ends_with?(Base.url_encode64(@payload), "=")
      assert AccountClaim.read(padded, @pointer) == {:ok, "acct-fake-0001"}
    end

    test "a payload with a line feed or a carriage return inside the base64" do
      encoded = enc(@payload)
      {first, last} = String.split_at(encoded, 10)
      broken = enc(~s({"alg":"none"})) <> "." <> first <> "\r\n" <> last <> ".sig"

      assert AccountClaim.read(broken, @pointer) == {:ok, "acct-fake-0001"}
    end

    test "a payload of exactly 8 KiB, and not one byte more" do
      head = ~s({"id":"acct-fake-0001","pad":")
      exact = head <> String.duplicate("p", @max - byte_size(head) - 2) <> ~s("})

      assert byte_size(exact) == @max
      assert read(exact, "/id") == {:ok, "acct-fake-0001"}
      assert read(exact <> " ", "/id") == :error
    end

    test "what is off the way of the pointer, whatever it holds" do
      for payload <- [
            ~s({"big":1e400,"https://auth.model.example/auth":{"account_id":"acct-fake-0001"}}),
            ~s({"name":"bad-\xFF-name","https://auth.model.example/auth":{"account_id":"acct-fake-0001"}}),
            ~s( { "https://auth.model.example/auth" : { "account_id" : "acct-fake-0001" } } ),
            ~s({"other":{"a":1,"a":2},"https://auth.model.example/auth":{"account_id":"acct-fake-0001"}})
          ] do
        assert read(payload) == {:ok, "acct-fake-0001"}
      end
    end

    test "a list on the way of the pointer" do
      list = ~s({"https://auth.model.example/auth":[{"x":1} , {"account_id":"acct-fake-0001"}]})

      assert read(list, "/https:~1~1auth.model.example~1auth/1/account_id") ==
               {:ok, "acct-fake-0001"}
    end

    test "a tab inside the account id" do
      assert read(~s({"id":"acct\\tfake"}), "/id") == {:ok, "acct\tfake"}
    end
  end

  describe "read/2 refuses" do
    test "a value of two parts, of four, and an empty one" do
      two = enc("{}") <> "." <> enc(@payload)

      assert AccountClaim.read(two, @pointer) == :error
      assert AccountClaim.read(token(@payload) <> ".extra", @pointer) == :error
      assert AccountClaim.read("", @pointer) == :error
    end

    test "a payload over 8 KiB" do
      head = ~s({"id":"acct-fake-0001","pad":")
      over = head <> String.duplicate("p", @max) <> ~s("})

      assert read(over, "/id") == :error
    end

    test "a payload that is not base64url" do
      assert AccountClaim.read("e30.not*base64.sig", @pointer) == :error
    end

    test "a payload that is not one JSON object" do
      assert read("acct-fake-0001") == :error
      assert read(~s(["acct-fake-0001"]), "/0") == :error
      assert read("null") == :error
      assert read(~s({"id":"acct-fake-0001"} {"id":"acct-fake-0002"}), "/id") == :error
    end

    test "a payload with a member name twice at the top" do
      assert read(~s({"id":"acct-fake-0001","id":"acct-fake-0002"}), "/id") == :error
    end

    test "a member name twice on the way to the account id" do
      twice =
        ~s({"https://auth.model.example/auth":{"account_id":"acct-fake-0001","account_id":"acct-fake-0002"}})

      assert read(twice) == :error
    end

    test "a pointer that reaches no string" do
      assert read(@payload, "/https:~1~1auth.model.example~1auth/org_id") == :error
      assert read(@payload, "/n") == :error
      assert read(@payload, "/https:~1~1auth.model.example~1auth") == :error
      assert read(@payload, @pointer <> "/x") == :error
      assert read(@payload, "/list/01") == :error
      assert read(@payload, "/list/2") == :error
    end

    test "a pointer that does not start with a slash, and a pointer or token that is no text" do
      assert read(@payload, "account_id") == :error
      assert AccountClaim.read(token(@payload), nil) == :error
      assert AccountClaim.read(nil, @pointer) == :error
    end

    test "an account id that is empty" do
      assert read(~s({"id":""}), "/id") == :error
    end

    test "an account id with a space at either end" do
      assert read(~s({"id":"acct-fake-0001 "}), "/id") == :error
      assert read(~s({"id":" acct-fake-0001"}), "/id") == :error
      assert read(~s({"id":"acct-fake-0001\\t"}), "/id") == :error
      assert read(~s({"id":"\\tacct-fake-0001"}), "/id") == :error
    end

    test "an account id with a control character" do
      assert read(~s({"id":"acct-fake\\n0001"}), "/id") == :error
      assert read(~s({"id":"acct-fake\\u0000-0001"}), "/id") == :error
      assert read(~s({"id":"acct-fake\\u007F-0001"}), "/id") == :error
      assert read(~s({"id":"acct-fake\\u009F-0001"}), "/id") == :error
    end

    test "an account id that is not UTF-8" do
      assert read(~s({"id":"acct-\xFF"}), "/id") == :error
    end
  end
end
