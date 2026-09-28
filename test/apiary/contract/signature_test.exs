defmodule Apiary.Contract.SignatureTest do
  use ExUnit.Case, async: true

  alias Apiary.Contract.Signature

  # Reference values: HMAC-SHA256 with the key "test-secret" over
  # "GET\n/.well-known/qory-configuration?x=1\n1700000000", as any HMAC tool computes it.
  @secret "test-secret"
  @canonical "GET\n/.well-known/qory-configuration?x=1\n1700000000"
  @signature "sha256=e8cc6260e2740e9282f2b45fa8bc590e3afe0e59eb53882b19cdb0f87a613c02"

  test "canonical_string/3 upcases the method and joins with newlines" do
    assert Signature.canonical_string("get", "/.well-known/qory-configuration?x=1", 1_700_000_000) ==
             @canonical

    assert Signature.canonical_string("GET", "/p", "42") == "GET\n/p\n42"
  end

  test "sign/2 matches the known answer" do
    assert Signature.sign(@secret, @canonical) == @signature
  end

  test "verify/3 accepts a match under any secret and rejects everything else" do
    assert Signature.verify([@secret], @canonical, @signature)
    assert Signature.verify(["other", @secret], @canonical, @signature)
    assert Signature.verify([@secret, "other"], @canonical, @signature)
    refute Signature.verify(["other"], @canonical, @signature)
    refute Signature.verify([], @canonical, @signature)
    refute Signature.verify([@secret], @canonical <> "x", @signature)
    refute Signature.verify([@secret], @canonical, String.replace_suffix(@signature, "02", "03"))
    refute Signature.verify([@secret], @canonical, String.upcase(@signature))
    refute Signature.verify([@secret], @canonical, "")
    refute Signature.verify([@secret], @canonical, nil)
  end
end
