defmodule ApiaryWeb.Contract.RegistrationControllerTest do
  use ApiaryWeb.ConnCase, async: true

  import Apiary.ContractFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Ecto.Query

  alias Apiary.Policy
  alias Apiary.Policy.{Render, RunConfiguration, Schema}
  alias Apiary.Repo
  alias Apiary.Runs.{Run, Target}
  alias ApiaryWeb.Contract.{Configuration, RawBody}

  @runs "/v1/runs"
  @no_policy ~s({"version":1})
  @unauthorized %{"error" => "unauthorized"}

  setup do
    %{scope: scope} = sign_up_fixture()
    %{access_key: key, secret: secret} = contract_key_fixture(scope)
    %{scope: scope, key: key, secret: secret}
  end

  defp target_fixture(scope, system, path) do
    Repo.insert!(%Target{
      organisation_id: scope.organisation.id,
      workspace_id: scope.workspace.id,
      system: system,
      path: path,
      first_seen_at: DateTime.utc_now()
    })
  end

  # A registration of a new run with `labels`, as the gateway sends it.
  defp register(ctx, labels \\ %{}, opts \\ []) do
    body = registration(Ecto.UUID.generate(), %{"labels" => labels})
    signed_register(build_conn(), ctx.key.key_id, ctx.secret, body, opts)
  end

  defp reload(ctx, run_id, opts \\ []),
    do: signed_get(build_conn(), ctx.key.key_id, ctx.secret, @runs <> "/" <> run_id, opts)

  defp run(run_id), do: Repo.one(from r in Run, where: r.run_id == ^run_id)

  defp allow(conn), do: Jason.decode!(conn.resp_body)["security_policy"]["egress"]["allow"]

  @site %{"forge" => "github.example", "repository" => "acme/site"}

  describe "a workspace nobody has given a policy" do
    test "registers a run with the document of no policy, under its digest, and renders nothing",
         ctx do
      refute Policy.managed?(ctx.scope)

      for labels <- [%{}, @site] do
        conn = register(ctx, labels)
        assert conn.status == 200
        assert conn.resp_body == @no_policy
        assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
        assert signed_answer?(conn)

        digest = Render.digest(@no_policy)
        assert get_resp_header(conn, "x-qory-run-configuration") == [digest]
        assert get_resp_header(conn, "etag") == [~s("#{digest}")]

        assert get_resp_header(conn, "x-qory-configuration") == [
                 Configuration.digest(ctx.key.node)
               ]
      end

      assert Repo.aggregate(RunConfiguration, :count) == 0
    end

    test "answers a reload 404, signed: a policy removed never loosens a run", ctx do
      run_id = Ecto.UUID.generate()
      body = registration(run_id)
      assert signed_register(build_conn(), ctx.key.key_id, ctx.secret, body).status == 200

      conn = reload(ctx, run_id)
      assert json_response(conn, 404) == %{"error" => "not_found"}
      assert signed_answer?(conn)
      assert get_resp_header(conn, "x-qory-run-configuration") == []
      assert get_resp_header(conn, "etag") == []
    end
  end

  @tag needs: :security
  test "from the first change on it is served, in the contract's shape, under its digest", ctx do
    # The first change: a deny of a host nothing allows, in the document's deny list.
    {:ok, _} = Policy.deny(ctx.scope, nil, %{host: "ads.example"})
    assert Policy.managed?(ctx.scope)

    conn = register(ctx, @site)

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

    assert Jason.decode!(conn.resp_body) == %{
             "version" => 1,
             "security_policy" => %{
               "version" => 1,
               "egress" => %{"mode" => "observe", "allow" => [], "deny" => ["ads.example"]}
             }
           }

    assert :ok = Schema.validate(conn.resp_body)
    [digest] = get_resp_header(conn, "x-qory-run-configuration")
    assert digest == Render.digest(conn.resp_body)
    assert get_resp_header(conn, "etag") == [~s("#{digest}")]
    assert get_resp_header(conn, "x-qory-configuration") == [Configuration.digest(ctx.key.node)]
    assert signed_answer?(conn)
    assert get_resp_header(conn, "cache-control") == ["no-store, no-transform"]
    assert [%RunConfiguration{version: 1, target_id: nil}] = Repo.all(RunConfiguration)
  end

  @tag needs: :security
  test "a reload is answered for the run's own key alone, with the same headers", ctx do
    {:ok, _} = Policy.allow(ctx.scope, nil, %{host: "api.example"})
    run_id = Ecto.UUID.generate()
    body = registration(run_id)
    registered = signed_register(build_conn(), ctx.key.key_id, ctx.secret, body)
    assert registered.status == 200

    conn = reload(ctx, run_id)
    assert conn.status == 200
    assert conn.resp_body == registered.resp_body
    assert signed_answer?(conn)

    for header <- ~w(x-qory-run-configuration etag x-qory-configuration content-type) do
      assert get_resp_header(conn, header) == get_resp_header(registered, header), header
    end

    # A change of policy is what a reload brings.
    {:ok, _} = Policy.allow(ctx.scope, nil, %{host: "cdn.example"})
    assert allow(reload(ctx, run_id)) == ["api.example", "cdn.example"]

    # Another key of the workspace, a run its batches created under this key, a run the
    # workspace does not hold, a run id that is not one: 404, signed.
    %{access_key: other, secret: other_secret} = contract_key_fixture(ctx.scope)
    {unregistered, events} = first_events()
    assert build_conn() |> signed_post(ctx.key.key_id, ctx.secret, events) |> response(202)
    assert run(unregistered).registered_at == nil

    for conn <- [
          reload(%{key: other, secret: other_secret}, run_id),
          reload(ctx, unregistered),
          reload(ctx, Ecto.UUID.generate()),
          reload(ctx, String.upcase(run_id)),
          reload(ctx, "not-a-run")
        ] do
      assert json_response(conn, 404) == %{"error" => "not_found"}
      assert signed_answer?(conn)
    end
  end

  test "a key over its rate is 429 with Retry-After, from the run endpoint's own bucket", ctx do
    assert register(ctx).status == 200

    # The key's bucket, emptied and dated an hour ahead of the monotonic clock, so nothing
    # refills it however slowly the suite runs. The bucket is this test's key's alone, and
    # nothing here depends on how fast requests are made.
    bucket = Apiary.Runs.RateLimit
    later = System.monotonic_time(:millisecond) + :timer.hours(1)
    :ets.insert(bucket, {{:registration, ctx.key.id}, 0, later, later})

    for conn <- [register(ctx), reload(ctx, Ecto.UUID.generate())] do
      assert json_response(conn, 429) == %{"error" => "rate_limited"}
      assert signed_answer?(conn)
      assert [seconds] = get_resp_header(conn, "retry-after")
      assert String.to_integer(seconds) >= 1
      assert get_resp_header(conn, "x-qory-run-configuration") == []
    end

    # One token back serves one request, which spends it. Spending dates the bucket at the
    # present, from where it refills, so the bucket is read rather than a second request
    # timed. The events endpoint's bucket is untouched.
    :ets.insert(bucket, {{:registration, ctx.key.id}, 1000, later, later})
    assert register(ctx).status == 200
    assert [{_, 0, _, _}] = :ets.lookup(bucket, {:registration, ctx.key.id})
    assert :ets.lookup(bucket, ctx.key.id) == []
  end

  test "the events endpoint's bucket, spent, leaves a run registered", ctx do
    bucket = Apiary.Runs.RateLimit
    later = System.monotonic_time(:millisecond) + :timer.hours(1)
    :ets.insert(bucket, {ctx.key.id, 0, later, later})
    {_subject, batch} = first_events()

    conn = signed_post(build_conn(), ctx.key.key_id, ctx.secret, batch)
    assert json_response(conn, 429) == %{"error" => "rate_limited"}

    conn = register(ctx)
    assert conn.status == 200
    assert get_resp_header(conn, "retry-after") == []
    assert [{_, 0, ^later, _}] = :ets.lookup(bucket, ctx.key.id)
  end

  @tag needs: :security
  test "the bytes served are the bytes stored, under the stored digest", ctx do
    {:ok, _} = Policy.set_mode(ctx.scope, "enforce")
    {:ok, _} = Policy.allow(ctx.scope, nil, %{host: "api.example"})
    {:ok, stored} = Policy.current_configuration(ctx.scope, nil)

    conn = register(ctx)
    assert conn.resp_body == stored.document
    assert get_resp_header(conn, "x-qory-run-configuration") == [stored.digest]
  end

  @tag needs: :security
  test "a target with rules of its own gets its own; any other gets the baseline", ctx do
    shop = target_fixture(ctx.scope, "github.example", "acme/site")
    _plain = target_fixture(ctx.scope, "github.example", "acme/docs")
    {:ok, _} = Policy.allow(ctx.scope, nil, %{host: "api.example"})
    {:ok, _} = Policy.allow(ctx.scope, shop, %{host: "mcp.example"})

    assert allow(register(ctx, @site)) == ["api.example", "mcp.example"]

    line_feed = <<10>>
    line_separator = <<0xE2, 0x80, 0xA8>>
    next_line = <<0xC2, 0x85>>

    for labels <- [
          %{},
          %{"forge" => "github.example"},
          %{"repository" => "acme/site"},
          %{"forge" => "github.example", "repository" => "acme/docs"},
          %{"forge" => "github.example", "repository" => "acme/unknown"},
          %{"forge" => "other.example", "repository" => "acme/site"},
          %{"forge" => "github.example", "repository" => "acme/site" <> line_feed},
          %{"forge" => "github.example", "repository" => "acme/site" <> line_separator},
          %{"forge" => "github.example" <> next_line, "repository" => "acme/site"}
        ] do
      conn = register(ctx, labels)
      assert conn.status == 200, inspect(labels)
      assert allow(conn) == ["api.example"], inspect(labels)
    end
  end

  @tag needs: :security
  test "a target with a mode of its own is served it; an unknown one gets the workspace's", ctx do
    site = target_fixture(ctx.scope, "github.example", "acme/site")
    {:ok, _} = Policy.set_mode(ctx.scope, site, "enforce")
    mode = fn conn -> Jason.decode!(conn.resp_body)["security_policy"]["egress"]["mode"] end
    unknown = %{@site | "repository" => "acme/unknown"}

    assert mode.(register(ctx, @site)) == "enforce"
    assert mode.(register(ctx, unknown)) == "observe"
    assert mode.(register(ctx)) == "observe"

    {:ok, _} = Policy.set_mode(ctx.scope, "enforce")
    {:ok, _} = Policy.set_mode(ctx.scope, site, "observe")
    assert mode.(register(ctx, @site)) == "observe"
    assert mode.(register(ctx, unknown)) == "enforce"
  end

  @tag needs: :security
  test "every label is the run's, and the domain says which name the target", ctx do
    shop = target_fixture(ctx.scope, "git.example.com", "acme/shop")
    {:ok, _} = Policy.allow(ctx.scope, nil, %{host: "api.example"})
    {:ok, _} = Policy.allow(ctx.scope, shop, %{host: "mcp.example"})

    # The software domain's two among other labels: the target's own.
    labels = %{
      "forge" => "git.example.com",
      "issue" => "77",
      "repository" => "acme/shop",
      "task" => "fix"
    }

    assert allow(register(ctx, labels)) == ["api.example", "mcp.example"]

    # Labels that do not name a target, however many: the baseline.
    for labels <- [
          %{"issue" => "77", "task" => "fix"},
          %{"issue" => "77", "repository" => "acme/shop", "task" => "fix"},
          %{"forge" => "git.example.com", "issue" => "77", "task" => "fix"},
          %{"system" => "git.example.com", "path" => "acme/shop", "task" => "fix"}
        ] do
      conn = register(ctx, labels)
      assert conn.status == 200, inspect(labels)
      assert allow(conn) == ["api.example"], inspect(labels)
    end
  end

  test "never a 304: a matching If-None-Match is answered 200 with the document", ctx do
    first = register(ctx)
    [etag] = get_resp_header(first, "etag")

    conn = register(ctx, %{}, headers: [{"if-none-match", etag}])
    assert conn.status == 200
    assert conn.resp_body == first.resp_body
  end

  @tag needs: :security
  test "another workspace's key gets its own workspace's configuration", ctx do
    shop = target_fixture(ctx.scope, "github.example", "acme/site")
    {:ok, _} = Policy.allow(ctx.scope, shop, %{host: "mcp.example"})

    %{scope: other} = sign_up_fixture()
    %{access_key: key, secret: secret} = contract_key_fixture(other)
    theirs = %{key: key, secret: secret}

    # Managed is the workspace's own, too: this workspace's policy does not make the
    # other's served.
    assert register(theirs, @site).resp_body == @no_policy

    {:ok, _} = Policy.deny(other, nil, %{host: "ads.example"})
    conn = register(theirs, @site)
    assert conn.status == 200
    assert allow(conn) == []
  end

  describe "the run endpoint's own answers" do
    test "the same bytes again under the same key are given the same answer", ctx do
      body = Jason.encode!(registration())
      first = signed_register(build_conn(), ctx.key.key_id, ctx.secret, body)
      again = signed_register(build_conn(), ctx.key.key_id, ctx.secret, body)

      assert first.status == 200
      assert again.status == 200
      assert again.resp_body == first.resp_body

      assert get_resp_header(again, "x-qory-run-configuration") ==
               get_resp_header(first, "x-qory-run-configuration")

      assert signed_answer?(again)
      assert Repo.aggregate(Run, :count) == 1
    end

    test "a run id already held otherwise is 409 run_id_used, signed", ctx do
      run_id = Ecto.UUID.generate()
      body = Jason.encode!(registration(run_id))
      assert signed_register(build_conn(), ctx.key.key_id, ctx.secret, body).status == 200

      %{access_key: other, secret: other_secret} = contract_key_fixture(ctx.scope)
      other_bytes = registration(run_id, %{"labels" => %{"task" => "other"}})

      for conn <- [
            # Other bytes under the same key; the same bytes under another key.
            signed_register(build_conn(), ctx.key.key_id, ctx.secret, other_bytes),
            signed_register(build_conn(), other.key_id, other_secret, body)
          ] do
        assert json_response(conn, 409) == %{"error" => "run_id_used"}
        assert signed_answer?(conn)
        assert get_resp_header(conn, "x-qory-run-configuration") == []
      end
    end

    test "a run whose events retention has pruned is 410, signed, with no body", ctx do
      run_id = Ecto.UUID.generate()
      body = Jason.encode!(registration(run_id))
      assert signed_register(build_conn(), ctx.key.key_id, ctx.secret, body).status == 200

      Repo.update_all(from(r in Run, where: r.run_id == ^run_id),
        set: [events_pruned_at: DateTime.utc_now()]
      )

      other_bytes = registration(run_id, %{"labels" => %{"task" => "other"}})
      conn = signed_register(build_conn(), ctx.key.key_id, ctx.secret, other_bytes)
      assert response(conn, 410) == ""
      assert signed_answer?(conn)

      # The same bytes are a repeat, which comes first.
      assert signed_register(build_conn(), ctx.key.key_id, ctx.secret, body).status == 200
    end

    test "an instance beyond its node's limit is 409 instance_limit, signed, nothing stored",
         ctx do
      node = node_fixture(ctx.scope)
      %{access_key: key, secret: secret} = contract_key_fixture(ctx.scope, node: node)
      ours = %{key: key, secret: secret}
      assert register(ours, %{}, instance_id: "i_one").status == 200

      refused = Ecto.UUID.generate()
      body = registration(refused)
      conn = signed_register(build_conn(), key.key_id, secret, body, instance_id: "i_two")
      assert json_response(conn, 409) == %{"error" => "instance_limit"}
      assert signed_answer?(conn)
      assert run(refused) == nil
    end
  end

  describe "the refusals before the run endpoint's own" do
    test "a body over 64 KiB is 413 before the signature is looked at", ctx do
      body = String.duplicate(" ", RawBody.max_bytes(:registration) + 1)
      conn = signed_register(build_conn(), ctx.key.key_id, "not the secret", body)
      assert json_response(conn, 413) == %{"error" => "payload_too_large"}
      assert unsigned_answer?(conn)
    end

    test "a body of exactly 64 KiB is read and verified", ctx do
      body = String.duplicate(" ", RawBody.max_bytes(:registration))
      conn = signed_register(build_conn(), ctx.key.key_id, ctx.secret, body)
      assert json_response(conn, 400) == %{"error" => "invalid_request", "names" => ["body"]}
      assert signed_answer?(conn)
    end

    test "any content type but application/json is 415, unsigned", ctx do
      body = registration()

      for content_type <- [
            "application/cloudevents-batch+json",
            "text/plain",
            "application/jsonx",
            "application/json-seq"
          ] do
        conn =
          signed_register(build_conn(), ctx.key.key_id, ctx.secret, body,
            content_type: content_type
          )

        assert json_response(conn, 415) == %{"error" => "unsupported_media_type"},
               inspect(content_type)

        assert unsigned_answer?(conn)
      end

      conn =
        signed_register(build_conn(), ctx.key.key_id, ctx.secret, body,
          content_type: "Application/JSON; charset=utf-8"
        )

      assert conn.status == 200
      assert run(body["run_id"])
    end

    test "a registration on the events endpoint's type, or a batch on the run endpoint's, is 415",
         ctx do
      conn =
        signed_post(build_conn(), ctx.key.key_id, ctx.secret, registration(),
          content_type: "application/json"
        )

      assert json_response(conn, 415) == %{"error" => "unsupported_media_type"}

      {_subject, batch} = first_events()

      conn =
        signed_register(build_conn(), ctx.key.key_id, ctx.secret, batch,
          content_type: content_type()
        )

      assert json_response(conn, 415) == %{"error" => "unsupported_media_type"}
    end

    test "a body the contract refuses is 400 invalid_request, signed, naming the member", ctx do
      run_id = Ecto.UUID.generate()

      for {attrs, name} <- [
            {%{"version" => 2}, "version"},
            {%{"run_id" => "not-a-run"}, "run_id"},
            {%{"interval_seconds" => 301}, "interval_seconds"},
            {%{"interval_seconds" => nil}, "interval_seconds"},
            {%{"labels" => %{"repository" => String.duplicate("é", 129)}}, "labels"},
            {%{"labels" => %{"Upper" => "x"}}, "labels"},
            {%{"labels" => %{"repository" => "a" <> <<0>>}}, "labels"},
            {%{"about" => %{"title" => 7}}, "about.title"},
            {%{"time" => "2026-10-10T12:00:00.5Z"}, "time"},
            {%{"time" => "2026-10-10T12:00:00+00:00"}, "time"},
            {%{"extra" => true}, "body"}
          ] do
        conn =
          signed_register(build_conn(), ctx.key.key_id, ctx.secret, registration(run_id, attrs))

        assert json_response(conn, 400) == %{"error" => "invalid_request", "names" => [name]},
               inspect(attrs)

        assert signed_answer?(conn)
      end

      for body <- ["", "not json", "[]", ~s("run")] do
        conn = signed_register(build_conn(), ctx.key.key_id, ctx.secret, body)
        assert json_response(conn, 400) == %{"error" => "invalid_request", "names" => ["body"]}
      end

      assert run(run_id) == nil
    end

    test "a time more than 300 seconds from the server's clock is 401, unsigned, after the body",
         ctx do
      now = System.os_time(:second)
      at = fn offset -> (now + offset) |> DateTime.from_unix!() |> DateTime.to_iso8601() end
      run_id = Ecto.UUID.generate()

      # Each offset keeps 10 seconds from the window's edge, which the server's clock,
      # read a moment later, moves.
      for offset <- [-310, 310] do
        conn =
          signed_register(
            build_conn(),
            ctx.key.key_id,
            ctx.secret,
            registration(run_id, %{"time" => at.(offset)})
          )

        assert json_response(conn, 401) == @unauthorized
        assert unsigned_answer?(conn)
      end

      # A body the contract refuses is refused first, signed.
      stale_and_invalid = registration(run_id, %{"time" => at.(-3600), "version" => 2})
      conn = signed_register(build_conn(), ctx.key.key_id, ctx.secret, stale_and_invalid)
      assert json_response(conn, 400) == %{"error" => "invalid_request", "names" => ["version"]}

      assert run(run_id) == nil

      for offset <- [-290, 290] do
        body = registration(Ecto.UUID.generate(), %{"time" => at.(offset)})
        assert signed_register(build_conn(), ctx.key.key_id, ctx.secret, body).status == 200
      end
    end

    test "a request that does not verify is 401 and stores nothing", ctx do
      body = Jason.encode!(registration())
      signed = sign_request(ctx.secret, ctx.key.key_id, instance_id(), "POST", @runs, body)

      for conn <- [
            signed_register(build_conn(), ctx.key.key_id, ctx.secret, body,
              signature: String.duplicate("A", 86)
            ),
            # Signed for the events endpoint, or the body changed after signing.
            signed_register(build_conn(), ctx.key.key_id, ctx.secret, body,
              signature:
                sign_request(
                  ctx.secret,
                  ctx.key.key_id,
                  instance_id(),
                  "POST",
                  "/v1/events",
                  body
                )
            ),
            signed_register(build_conn(), ctx.key.key_id, ctx.secret, body <> " ",
              signature: signed
            ),
            reload(ctx, Ecto.UUID.generate(), timestamp: System.os_time(:second) - 301),
            post(put_req_header(build_conn(), "content-type", "application/json"), @runs, body)
          ] do
        assert json_response(conn, 401) == @unauthorized
        assert unsigned_answer?(conn)
      end

      assert Repo.aggregate(Run, :count) == 0
    end

    test "a revoked key is refused", ctx do
      {:ok, _} = Apiary.AccessKeys.revoke_access_key(ctx.scope, ctx.key)
      assert json_response(register(ctx), 401) == @unauthorized
    end

    test "a contract version other than 1, absent or sent twice, is 400 and stores nothing",
         ctx do
      for opts <- [
            [contract_version: nil],
            [headers: [{"x-qory-contract-version", "1"}]],
            [contract_version: "2"],
            [contract_version: "0"],
            [contract_version: "one"],
            [contract_version: "1.0"],
            [contract_version: ""]
          ] do
        conn = register(ctx, %{}, opts)

        assert json_response(conn, 400) == %{
                 "error" => "unsupported_contract_version",
                 "supported" => [1]
               }

        assert signed_answer?(conn)
        assert get_resp_header(conn, "x-qory-run-configuration") == []
        assert get_resp_header(conn, "x-qory-configuration") == []
      end

      assert Repo.aggregate(Run, :count) == 0
      assert register(ctx, %{}, contract_version: "1").status == 200

      # A request that does not verify is 401 first, whatever its contract version.
      conn = register(ctx, %{}, contract_version: "2", signature: String.duplicate("A", 86))
      assert json_response(conn, 401) == @unauthorized
    end
  end

  describe "the contract's fixtures" do
    @describetag :contract
    @describetag needs: :security

    test "run-configuration/*.json and what the endpoint serves validate against the same schema",
         ctx do
      dir = contract_dir()
      files = dir |> Path.join("fixtures/run-configuration/*.json") |> Path.wildcard()
      assert files != []

      for file <- files do
        assert :ok = Schema.validate(File.read!(file)), Path.basename(file)
      end

      invalid = dir |> Path.join("fixtures/invalid/run-configuration-*.json") |> Path.wildcard()
      assert invalid != []

      for file <- invalid do
        assert {:error, _} = file |> File.read!() |> Schema.validate(), Path.basename(file)
      end

      # The enforce fixture's policy, said as rules, is served in the fixture's shape: a
      # deny below the allowed suffix stands beside it in the deny list.
      {:ok, _} = Policy.set_mode(ctx.scope, "enforce")

      for host <- ["api.example", "github.com", "*.github.com"],
          do: {:ok, _} = Policy.allow(ctx.scope, nil, %{host: host})

      {:ok, _} = Policy.deny(ctx.scope, nil, %{host: "gist.github.com"})

      fixture =
        dir
        |> Path.join("fixtures/run-configuration/enforce.json")
        |> File.read!()
        |> Jason.decode!()

      served = Jason.decode!(register(ctx).resp_body)

      assert Map.keys(served) == Map.keys(fixture)
      assert served["security_policy"]["egress"]["mode"] == "enforce"

      assert Enum.sort(served["security_policy"]["egress"]["allow"]) ==
               Enum.sort(fixture["security_policy"]["egress"]["allow"])

      assert Enum.sort(served["security_policy"]["egress"]["deny"]) ==
               Enum.sort(fixture["security_policy"]["egress"]["deny"] || [])
    end

    test "run-configuration/observe-deny.json: observe with a deny list, said as rules, is served as the fixture",
         ctx do
      fixture =
        contract_dir()
        |> Path.join("fixtures/run-configuration/observe-deny.json")
        |> File.read!()
        |> Jason.decode!()

      egress = fixture["security_policy"]["egress"]
      assert egress["mode"] == "observe"

      for host <- egress["allow"], do: {:ok, _} = Policy.allow(ctx.scope, nil, %{host: host})
      for host <- egress["deny"], do: {:ok, _} = Policy.deny(ctx.scope, nil, %{host: host})

      conn = register(ctx)
      assert :ok = Schema.validate(conn.resp_body)
      served = Jason.decode!(conn.resp_body)

      # The same document but for the order of the lists, which the server fixes: names
      # before suffixes, so the deny below the allowed suffix is said and holds under observe.
      assert served["version"] == fixture["version"]
      assert served["security_policy"]["version"] == fixture["security_policy"]["version"]
      assert served["security_policy"]["egress"]["mode"] == "observe"
      assert Enum.sort(served["security_policy"]["egress"]["allow"]) == Enum.sort(egress["allow"])
      assert Enum.sort(served["security_policy"]["egress"]["deny"]) == Enum.sort(egress["deny"])
      assert Map.keys(served["security_policy"]["egress"]) |> Enum.sort() == ~w(allow deny mode)
    end

    test "the vendored schemas are the contract's" do
      dir = contract_dir()

      for file <- Schema.files() do
        assert File.read!(Schema.path(file)) == File.read!(Path.join(dir, file)),
               "priv/contract/#{file} differs from the contract's: copy it from #{dir}"
      end
    end
  end
end

defmodule ApiaryWeb.Contract.RegistrationRateLimitTest do
  # The limits come from the application environment, which every test shares.
  use ApiaryWeb.ConnCase, async: false

  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures

  alias ApiaryWeb.Contract.RegistrationController

  setup do
    events = Application.get_env(:apiary, Apiary.Runs.RateLimit)
    registration = Application.get_env(:apiary, RegistrationController)
    Application.put_env(:apiary, Apiary.Runs.RateLimit, rate: 0, burst: 2)
    Application.put_env(:apiary, RegistrationController, rate: 0, burst: 2)

    on_exit(fn ->
      Application.put_env(:apiary, Apiary.Runs.RateLimit, events)
      Application.put_env(:apiary, RegistrationController, registration)
    end)

    %{scope: scope} = sign_up_fixture()
    %{access_key: key, secret: secret} = contract_key_fixture(scope)
    %{key: key, secret: secret}
  end

  test "a flush that spends the events endpoint's bucket leaves a new run registered",
       %{key: key, secret: secret} do
    {_subject, batch} = first_events()

    for _ <- 1..2 do
      assert build_conn() |> signed_post(key.key_id, secret, batch) |> response(202)
    end

    assert build_conn() |> signed_post(key.key_id, secret, batch) |> response(429)

    conn = signed_register(build_conn(), key.key_id, secret, registration())
    assert conn.status == 200
    assert get_resp_header(conn, "retry-after") == []
  end

  test "the run endpoint's bucket limits itself, and leaves the events endpoint's whole",
       %{key: key, secret: secret} do
    for _ <- 1..2 do
      assert build_conn() |> signed_register(key.key_id, secret, registration()) |> response(200)
    end

    conn = signed_register(build_conn(), key.key_id, secret, registration())
    assert json_response(conn, 429) == %{"error" => "rate_limited"}
    assert get_resp_header(conn, "retry-after") == ["1"]
    assert signed_answer?(conn)

    {_subject, batch} = first_events()
    assert build_conn() |> signed_post(key.key_id, secret, batch) |> response(202)
  end
end

defmodule ApiaryWeb.Contract.RegistrationUnavailableTest do
  # Breaks a table for the length of a test, inside the test's own transaction; not async,
  # so no other test waits on the table meanwhile.
  use ApiaryWeb.ConnCase, async: false

  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Repo

  test "a run that cannot be stored is 503, never 500, and the log names the module alone" do
    %{scope: scope} = sign_up_fixture()
    %{access_key: key, secret: secret} = contract_key_fixture(scope)

    Repo.query!("ALTER TABLE runs ADD CONSTRAINT refuse_all CHECK (false) NOT VALID")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        conn = signed_register(build_conn(), key.key_id, secret, registration())
        assert json_response(conn, 503) == %{"error" => "unavailable"}
        assert signed_answer?(conn)
        assert get_resp_header(conn, "x-qory-run-configuration") == []
      end)

    assert log =~ "a registration could not be stored: Postgrex.Error"
    refute log =~ "refuse_all"
    assert Repo.aggregate(Apiary.Runs.Run, :count) == 0
  end
end
