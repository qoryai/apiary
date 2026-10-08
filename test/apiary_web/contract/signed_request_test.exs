defmodule ApiaryWeb.Contract.SignedRequestTest do
  @moduledoc """
  The contract's order of refusals on discovery, the run configuration and the events
  endpoint (`ApiaryWeb.Contract.SignedRequest`), which answers are signed and which are
  not, the instance id, a key enrolled with a code, and what a verified request leaves.
  """
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query
  import ExUnit.CaptureLog
  import Apiary.AccessKeysFixtures
  import Apiary.ContractFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Nodes.Instance
  alias Apiary.Repo
  alias Apiary.Runs.Run

  @discovery "/.well-known/qory-configuration"
  @run_configuration "/v1/run-configuration"
  @unauthorized %{"error" => "unauthorized"}

  setup do
    %{scope: scope} = sign_up_fixture()
    node = node_fixture(scope)
    %{access_key: key, secret: secret} = contract_key_fixture(scope, node: node)
    %{scope: scope, node: node, key: key, secret: secret}
  end

  defp error(conn), do: Jason.decode!(conn.resp_body)["error"]

  # A request to each endpoint, `opts` passed to the signing helper.
  defp each_endpoint(key_id, secret, opts) do
    {_subject, batch} = first_events()

    [
      signed_get(build_conn(), key_id, secret, @discovery, opts),
      signed_post(build_conn(), key_id, secret, batch, opts)
    ] ++
      if Apiary.Features.on?(:security),
        do: [signed_get(build_conn(), key_id, secret, @run_configuration, opts)],
        else: []
  end

  describe "the instance id" do
    test "absent is a signed 400 bad_request on every endpoint, and nothing is stored", ctx do
      for conn <- each_endpoint(ctx.key.key_id, ctx.secret, instance_id: nil) do
        assert json_response(conn, 400) == %{"error" => "bad_request"}
        assert signed_answer?(conn)
      end

      assert Repo.aggregate(Run, :count) == 0
      assert Repo.aggregate(Instance, :count) == 0
    end

    test "outside its pattern is a signed 400 bad_request", ctx do
      for instance_id <- [
            "",
            "-leading",
            ".leading",
            "has space",
            "slash/inside",
            "é",
            String.duplicate("a", 65)
          ] do
        conn =
          signed_get(build_conn(), ctx.key.key_id, ctx.secret, @discovery,
            instance_id: instance_id
          )

        assert json_response(conn, 400) == %{"error" => "bad_request"}, inspect(instance_id)
        assert signed_answer?(conn)
      end

      for instance_id <- [
            "a",
            "i_gYKDhIWGh4iJiouMjY6PkA",
            "build-01.local",
            String.duplicate("a", 64)
          ] do
        conn =
          signed_get(build_conn(), ctx.key.key_id, ctx.secret, @discovery,
            instance_id: instance_id
          )

        assert json_response(conn, 200), instance_id
      end
    end

    test "is signed: another instance's claim under the same signature is 401", ctx do
      timestamp = to_string(System.os_time(:second))

      signature =
        sign_request(ctx.secret, ctx.key.key_id, "i_one", "GET", @discovery, timestamp)

      conn =
        signed_get(build_conn(), ctx.key.key_id, ctx.secret, @discovery,
          instance_id: "i_two",
          timestamp: timestamp,
          signature: signature
        )

      assert json_response(conn, 401) == @unauthorized
    end
  end

  describe "a key enrolled with a code" do
    setup ctx do
      node = node_fixture(ctx.scope)
      %{access_key: enrolled, pair: pair} = enrolled_key_fixture(ctx.scope, node)
      %{enrolled: enrolled, enrolled_secret: pair.secret, enrolled_node: node}
    end

    test "is active at once: discovery and the events endpoint answer it, signed", ctx do
      conn = signed_get(build_conn(), ctx.enrolled.key_id, ctx.enrolled_secret, @discovery)
      assert conn.status == 200
      assert signed_answer?(conn)

      {_subject, batch} = first_events()
      conn = signed_post(build_conn(), ctx.enrolled.key_id, ctx.enrolled_secret, batch)
      assert conn.status == 202
      assert signed_answer?(conn)

      assert [%Instance{node_id: node_id, access_key_id: key_id}] = Repo.all(Instance)
      assert node_id == ctx.enrolled_node.id
      assert key_id == ctx.enrolled.id
    end

    test "after the instance id comes the contract version", ctx do
      conn =
        signed_get(build_conn(), ctx.enrolled.key_id, ctx.enrolled_secret, @discovery,
          contract_version: "2"
        )

      assert error(conn) == "unsupported_contract_version"
      assert signed_answer?(conn)
    end
  end

  describe "the order of refusals" do
    test "415, then a header sent twice, then 401", ctx do
      {_subject, batch} = first_events()
      twice = [headers: [{"x-qory-access-key-id", ctx.key.key_id}]]

      conn =
        signed_post(
          build_conn(),
          ctx.key.key_id,
          "another key",
          batch,
          [content_type: "text/plain"] ++ twice
        )

      assert conn.status == 415

      conn = signed_post(build_conn(), ctx.key.key_id, "another key", batch, twice)
      assert json_response(conn, 400) == %{"error" => "bad_request"}
      assert unsigned_answer?(conn)

      assert json_response(signed_post(build_conn(), ctx.key.key_id, "another key", batch), 401) ==
               @unauthorized
    end

    test "a header sent twice on a GET is an unsigned 400, before the signature", ctx do
      for header <- [
            {"x-qory-access-key-id", ctx.key.key_id},
            {"x-qory-instance-id", instance_id()},
            {"x-qory-signature-ed25519", String.duplicate("A", 86)},
            {"x-qory-timestamp", "1"}
          ] do
        conn =
          signed_get(build_conn(), ctx.key.key_id, "another key", @discovery, headers: [header])

        assert json_response(conn, 400) == %{"error" => "bad_request"}, elem(header, 0)
        assert unsigned_answer?(conn)
      end
    end

    test "the rate limit comes after verification and before the instance id", ctx do
      bucket = Apiary.Runs.RateLimit
      later = System.monotonic_time(:millisecond) + :timer.hours(1)
      :ets.insert(bucket, {ctx.key.id, 0, later})
      {_subject, batch} = first_events()

      conn = signed_post(build_conn(), ctx.key.key_id, "another key", batch)
      assert conn.status == 401

      conn = signed_post(build_conn(), ctx.key.key_id, ctx.secret, batch, instance_id: nil)
      assert json_response(conn, 429) == %{"error" => "rate_limited"}
      assert signed_answer?(conn)

      # Discovery is not limited.
      assert signed_get(build_conn(), ctx.key.key_id, ctx.secret, @discovery).status == 200
    end

    test "the contract version comes before the body and the timestamp", ctx do
      conn =
        signed_post(build_conn(), ctx.key.key_id, ctx.secret, "not a batch",
          contract_version: "2"
        )

      assert error(conn) == "unsupported_contract_version"
      assert signed_answer?(conn)

      conn =
        signed_get(build_conn(), ctx.key.key_id, ctx.secret, @discovery,
          contract_version: "2",
          timestamp: System.os_time(:second) - 1000
        )

      assert error(conn) == "unsupported_contract_version"
    end

    test "a stale timestamp is last, and its 401 goes out unsigned", ctx do
      conn =
        signed_get(build_conn(), ctx.key.key_id, ctx.secret, @discovery,
          timestamp: System.os_time(:second) - 1000
        )

      assert json_response(conn, 401) == @unauthorized
      assert unsigned_answer?(conn)
      assert Repo.get!(AccessKey, ctx.key.id).last_used_at == nil
    end

    test "a GET captured an hour ago is refused, and records the instance as seen nowhere",
         ctx do
      seen_at = DateTime.add(DateTime.utc_now(), -2, :hour) |> DateTime.truncate(:microsecond)

      known =
        instance_fixture(ctx.node,
          instance_id: "i_known",
          name: "spot-runners",
          seen_at: seen_at
        )

      for instance_id <- ["i_known", "i_new"],
          timestamp <- [System.os_time(:second) - 3600, System.os_time(:second) + 3600] do
        conn =
          signed_get(build_conn(), ctx.key.key_id, ctx.secret, @discovery,
            instance_id: instance_id,
            timestamp: timestamp
          )

        assert json_response(conn, 401) == @unauthorized
        assert unsigned_answer?(conn)
      end

      assert [instance] = Repo.all(Instance)
      assert instance.id == known.id
      assert instance.last_seen_at == known.last_seen_at
      assert instance.name == "spot-runners"
      assert Repo.get!(AccessKey, ctx.key.id).last_used_at == nil

      # The same request, fresh, is what records it.
      assert signed_get(build_conn(), ctx.key.key_id, ctx.secret, @discovery,
               instance_id: "i_known"
             ).status == 200

      assert %Instance{name: "build-01", last_seen_at: last_seen_at} =
               Repo.get!(Instance, known.id)

      assert DateTime.after?(last_seen_at, known.last_seen_at)
    end

    test "a stale GET under an enrolled key is 401, and records nothing", ctx do
      %{access_key: enrolled, pair: pair} = enrolled_key_fixture(ctx.scope, ctx.node)

      conn =
        signed_get(build_conn(), enrolled.key_id, pair.secret, @discovery,
          timestamp: System.os_time(:second) - 3600
        )

      assert json_response(conn, 401) == @unauthorized
      assert unsigned_answer?(conn)
      assert Repo.aggregate(Instance, :count) == 0
    end
  end

  describe "the key's row" do
    test "changed outside the application is 401, with a line in the log", ctx do
      %{access_key: key, pair: pair} = enrolled_key_fixture(ctx.scope, node_fixture(ctx.scope))

      Repo.update_all(from(k in AccessKey, where: k.id == ^key.id), set: [rate: 1000])

      {conn, log} =
        with_log(fn -> signed_get(build_conn(), key.key_id, pair.secret, @discovery) end)

      assert json_response(conn, 401) == @unauthorized
      assert log =~ "does not match its integrity code"
    end
  end

  describe "the log" do
    @tag capture_log: true
    test "holds no signature and no key, of a verified request or a refused one", ctx do
      timestamp = to_string(System.os_time(:second))

      signature =
        sign_request(ctx.secret, ctx.key.key_id, instance_id(), "GET", @discovery, timestamp)

      level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: level) end)

      log =
        capture_log([level: :debug], fn ->
          conn =
            signed_get(build_conn(), ctx.key.key_id, ctx.secret, @discovery,
              timestamp: timestamp,
              signature: signature
            )

          assert conn.status == 200
          [answer] = get_resp_header(conn, "x-qory-signature-ed25519")
          send(self(), {:answer, answer})

          assert signed_get(build_conn(), ctx.key.key_id, "another key", @discovery).status ==
                   401
        end)

      Logger.configure(level: level)
      assert_received {:answer, answer}

      assert log =~ "GET #{@discovery}"
      refute log =~ signature
      refute log =~ answer
      refute log =~ Apiary.Contract.Ed25519.encode(ctx.secret)
      refute log =~ Apiary.Contract.Ed25519.encode(ctx.key.public_key)
    end
  end

  describe "a signed answer" do
    @tag :contract
    test "is the contract's known answer under the fixture signing key" do
      %{"answers" => [discovery, not_found | _]} = known_answers!("signatures")
      key = Apiary.SigningKey.new(fixture_key!("signing_key").seed)
      body = contract_file!("known-answers/discovery.json")
      [_, "200", bound, _hash, configuration, ""] = discovery["lines"]

      assert ApiaryWeb.Contract.SignedAnswer.headers(200, bound, body, configuration, nil, key) ==
               {"no-store, no-transform", discovery["signature"]}

      [_, "404", bound, _hash, "", ""] = not_found["lines"]

      assert ApiaryWeb.Contract.SignedAnswer.headers(404, bound, "", nil, nil, key) ==
               {"no-store, no-transform", not_found["signature"]}
    end
  end
end
