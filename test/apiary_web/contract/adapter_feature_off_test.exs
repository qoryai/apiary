defmodule ApiaryWeb.Contract.AdapterFeatureOffTest do
  # An adapter's five signed POST routes where the feature is off, by their paths and by
  # paths with a character escaped, which the router decodes: an unsigned request is
  # answered exactly as a path the router does not know, whatever its body, as its body is
  # parsed as any request's is (`ApiaryWeb.Contract.RawBody`) and its route is found as the
  # router finds it (`ApiaryWeb.Features.Routes`); a request that carries a signature goes
  # on to be verified, and a verified one is answered `404` `not_found`, signed. Where the
  # feature is on, a path with a character escaped is answered as the route it names. Not
  # async: the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Apiary.ContractFixtures, only: [signed_post: 5, signed_answer?: 1, unsigned_answer?: 1]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Repo
  alias ApiaryWeb.Contract.{RawBody, SignedRequest}

  @moduletag needs: :factory

  @targets [
    "/v1/adapter",
    "/v1/source-collections",
    "/v1/source-items",
    "/v1/sources/disconnect",
    "/v1/source-items/comments"
  ]
  # The same routes, a character of each escaped, as the router decodes them, with the
  # route each names.
  @encoded [
    {"/v1/%61dapter", "/v1/adapter"},
    {"/v1/source%2Dcollections", "/v1/source-collections"},
    {"/v1/source%2Ditems", "/v1/source-items"},
    {"/v1/source-%69tems", "/v1/source-items"},
    {"/v1/sources/%64isconnect", "/v1/sources/disconnect"},
    {"/v1/%73ources/disconnect", "/v1/sources/disconnect"},
    {"/v1/source-items/%63omments", "/v1/source-items/comments"},
    {"/v1/source%2Ditems/comments", "/v1/source-items/comments"}
  ]
  # Paths the router does not know, of two segments and of three.
  @unknown_two "/v1/source-unknown"
  @unknown_three "/v1/source-items/unknown"

  # The adapter and its key are made while the feature is on.
  setup do
    sign_up_fixture()
    %{access_key: key, pair: pair} = connectable_adapter_fixture()
    %{key: key, seed: pair.secret}
  end

  defp without_factory(_ctx) do
    previous = Application.get_env(:apiary, :features)
    {:ok, features} = Apiary.Features.parse("observability,security")
    Application.put_env(:apiary, :features, features)
    on_exit(fn -> Application.put_env(:apiary, :features, previous) end)

    refute Apiary.Features.on?(:factory)
    :ok
  end

  defp body do
    %{
      "version" => 1,
      "time" => SignedRequest.now() |> DateTime.from_unix!() |> DateTime.to_iso8601()
    }
  end

  defp signed(ctx, target) do
    signed_post(build_conn(), ctx.key.key_id, ctx.seed, body(),
      target: target,
      content_type: "application/json",
      delivery: nil
    )
  end

  defp unsigned(ctx, path, raw) do
    fn ->
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-qory-access-key-id", ctx.key.key_id)
      |> post(path, raw)
    end
  end

  # The path the router does not know with as many segments as `path`.
  defp unknown(path) do
    case String.split(path, "/", trim: true) do
      [_, _] -> @unknown_two
      [_, _, _] -> @unknown_three
    end
  end

  # The bodies an unsigned request is sent with, and the status a path the router does not
  # know answers each: JSON, none, no JSON, no JSON over the routes' limit, and JSON over
  # it, which the endpoint's parser still takes.
  defp bodies do
    over = String.duplicate("x", RawBody.max_bytes(:adapter) + 1)

    [
      {"JSON", Jason.encode!(body()), 404},
      {"empty", "", 404},
      {"no JSON", "not json", 400},
      {"no JSON over the limit", over, 400},
      {"JSON over the limit", Jason.encode!(Map.put(body(), "padding", over)), 404}
    ]
  end

  describe "where the feature is off" do
    setup :without_factory

    test "an unsigned request answers exactly as a path the router does not know", ctx do
      paths = @targets ++ Enum.map(@encoded, &elem(&1, 0))

      for {name, raw, status} <- bodies() do
        unknown_two = sent(status, unsigned(ctx, @unknown_two, raw))
        assert unknown_two == sent(status, unsigned(ctx, @unknown_three, raw)), name

        # The route's body is not read apart from the others where it is not served, nor
        # is its route found apart from them, whichever character is escaped.
        for path <- paths do
          assert sent(status, unsigned(ctx, path, raw)) ==
                   sent(status, unsigned(ctx, unknown(path), raw)),
                 "#{path}, #{name}"
        end
      end
    end

    test "a verified request is answered 404 not_found, signed, and records nothing", ctx do
      for target <- @targets ++ Enum.map(@encoded, &elem(&1, 0)) do
        conn = signed(ctx, target)
        assert json_response(conn, 404) == %{"error" => "not_found"}, target
        assert signed_answer?(conn), target
      end

      assert Repo.aggregate("adapter_seen_requests", :count) == 0
    end

    test "a request that carries a signature goes on to be verified: 401 when it does not verify, 413 over the limit",
         ctx do
      over = String.duplicate("x", RawBody.max_bytes(:adapter) + 1)

      for target <- @targets do
        request = fn raw ->
          build_conn()
          |> put_req_header("content-type", "application/json")
          |> put_req_header("x-qory-access-key-id", ctx.key.key_id)
          |> put_req_header("x-qory-signature-ed25519", "unverified")
          |> post(target, raw)
        end

        conn = request.(Jason.encode!(body()))
        assert json_response(conn, 401) == %{"error" => "unauthorized"}, target
        assert unsigned_answer?(conn), target

        conn = request.(over)
        assert json_response(conn, 413) == %{"error" => "payload_too_large"}, target
      end
    end
  end

  describe "with the feature" do
    test "a path with a character escaped is answered as the route it names", ctx do
      for {path, route} <- @encoded do
        encoded = signed(ctx, path)
        plain = signed(ctx, route)

        assert {encoded.status, encoded.resp_body} == {plain.status, plain.resp_body}, path
        assert encoded.status != 404, path
        assert signed_answer?(encoded), path
      end
    end
  end

  # The answer the endpoint sends to `request`, of `status`: its status, its headers but
  # the request's id, and its body, each without its nonce (`ApiaryWeb.ContentSecurityPolicy`).
  defp sent(status, request) do
    # A path the router does not know is answered without raising; a body the parsers
    # refuse raises, and is answered as the error is.
    {^status, headers, body} =
      try do
        conn = request.()
        {conn.status, conn.resp_headers, conn.resp_body}
      rescue
        _exception -> assert_error_sent(status, request)
      end

    headers =
      headers
      |> Enum.reject(fn {name, _value} -> name == "x-request-id" end)
      |> Enum.map(fn {name, value} -> {name, without_nonce(value)} end)
      |> Enum.sort()

    {status, headers, without_nonce(body)}
  end

  defp without_nonce(text),
    do: String.replace(text, ~r/nonce(-|=")[A-Za-z0-9+\/=]+/, "nonce\\1…")
end
