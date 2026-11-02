defmodule ApiaryWeb.Contract.SignedAnswerTest do
  # What `ApiaryWeb.Contract.SignedAnswer.put/3` signs: an answer's body, or, for a file of
  # the run API, the stored SHA-256 in `conn.private[:qory_body_sha256]`.
  use ExUnit.Case, async: true

  alias Apiary.Contract.SignedMessage
  alias Apiary.SigningKey
  alias ApiaryWeb.Contract.SignedAnswer

  @request_signature "c2ln"

  defp answer(body),
    do: %{Plug.Test.conn(:get, "/") | status: 200, resp_body: body}

  defp signature(conn), do: Plug.Conn.get_resp_header(conn, "x-qory-signature-ed25519")

  test "an answer without a digest is signed over its body, as headers/6 signs it" do
    key = SigningKey.current()
    {_cache, expected} = SignedAnswer.headers(200, @request_signature, "abc", nil, nil, key)

    assert signature(SignedAnswer.put(answer("abc"), @request_signature, key)) == [expected]
  end

  test "an answer with the digest of its body is signed as the body itself" do
    key = SigningKey.current()
    digest = Base.encode16(:crypto.hash(:sha256, "abc"), case: :lower)
    {_cache, expected} = SignedAnswer.headers(200, @request_signature, "abc", nil, nil, key)

    conn = answer(nil) |> Plug.Conn.put_private(:qory_body_sha256, digest)
    assert signature(SignedAnswer.put(conn, @request_signature, key)) == [expected]
  end

  test "a digest that is not lowercase hex is not used" do
    key = SigningKey.current()
    {_cache, empty} = SignedAnswer.headers(200, @request_signature, "", nil, nil, key)
    digest = String.upcase(Base.encode16(:crypto.hash(:sha256, "abc")))

    conn = answer(nil) |> Plug.Conn.put_private(:qory_body_sha256, digest)
    assert signature(SignedAnswer.put(conn, @request_signature, key)) == [empty]
  end

  test "answer_digest/5 is answer/5's string for the body of that digest" do
    digest = Base.encode16(:crypto.hash(:sha256, "abc"), case: :lower)

    assert SignedMessage.answer_digest(201, "c2ln", digest, "cfg", nil) ==
             SignedMessage.answer(201, "c2ln", "abc", "cfg", nil)

    assert_raise ArgumentError, fn ->
      SignedMessage.answer_digest(201, "c2ln", String.duplicate("g", 64), nil, nil)
    end
  end
end
