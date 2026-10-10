defmodule ApiaryWeb.Contract.RunConfigurationControllerTest do
  use ApiaryWeb.ConnCase, async: true

  # The security policy: left out of a run without the security feature.
  @moduletag needs: :security

  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Policy
  alias Apiary.Policy.{Render, RunConfiguration, Schema}
  alias Apiary.Repo
  alias Apiary.Runs.Target
  alias ApiaryWeb.Contract.Configuration

  @path "/v1/run-configuration"

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

  defp fetch(ctx, query, opts \\ []) do
    url = if query == "", do: @path, else: @path <> "?" <> query
    signed_get(build_conn(), ctx.key.key_id, ctx.secret, url, opts)
  end

  defp allow(conn), do: Jason.decode!(conn.resp_body)["security_policy"]["egress"]["allow"]

  test "a workspace nobody has given a policy serves none: 404, and nothing is rendered", ctx do
    refute Policy.managed?(ctx.scope)

    for query <- ["", "forge=github.example&repository=acme%2Fsite"] do
      conn = fetch(ctx, query)
      assert json_response(conn, 404) == %{"error" => "not_found"}
      assert signed_answer?(conn)
      assert get_resp_header(conn, "x-qory-run-configuration") == []
      assert get_resp_header(conn, "etag") == []
    end

    assert Repo.aggregate(RunConfiguration, :count) == 0
  end

  test "from the first change on it is served, in the contract's shape, under its digest", ctx do
    # The first change: a deny of a host nothing allows, in the document's deny list.
    {:ok, _} = Policy.deny(ctx.scope, nil, %{host: "ads.example"})
    assert Policy.managed?(ctx.scope)

    conn = fetch(ctx, "forge=github.example&repository=acme%2Fsite")

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

    assert get_resp_header(conn, "x-qory-configuration") == [
             Configuration.digest(ctx.key.node, true)
           ]

    assert signed_answer?(conn)
    assert get_resp_header(conn, "cache-control") == ["no-store, no-transform"]
    assert [%RunConfiguration{version: 1, target_id: nil}] = Repo.all(RunConfiguration)
  end

  test "a key over its rate is 429 with Retry-After, from the run configuration's own bucket",
       ctx do
    {:ok, _} = Policy.allow(ctx.scope, nil, %{host: "api.example"})
    assert fetch(ctx, "").status == 200

    # The key's bucket, emptied and dated an hour ahead of the monotonic clock, so nothing
    # refills it however slowly the suite runs. The bucket is this test's key's alone, and
    # nothing here depends on how fast requests are made.
    bucket = Apiary.Runs.RateLimit
    later = System.monotonic_time(:millisecond) + :timer.hours(1)
    :ets.insert(bucket, {{:run_configuration, ctx.key.id}, 0, later, later})

    conn = fetch(ctx, "")
    assert json_response(conn, 429) == %{"error" => "rate_limited"}
    assert signed_answer?(conn)
    assert [seconds] = get_resp_header(conn, "retry-after")
    assert String.to_integer(seconds) >= 1
    assert get_resp_header(conn, "x-qory-run-configuration") == []

    # One token back serves one request, which spends it. Spending dates the bucket at the
    # present, from where it refills, so the bucket is read rather than a second request
    # timed. The events endpoint's bucket is untouched.
    :ets.insert(bucket, {{:run_configuration, ctx.key.id}, 1000, later, later})
    assert fetch(ctx, "").status == 200
    assert [{_, 0, _, _}] = :ets.lookup(bucket, {:run_configuration, ctx.key.id})
    assert :ets.lookup(bucket, ctx.key.id) == []
  end

  test "the events endpoint's bucket, spent, leaves the run configuration served", ctx do
    {:ok, _} = Policy.allow(ctx.scope, nil, %{host: "api.example"})

    bucket = Apiary.Runs.RateLimit
    later = System.monotonic_time(:millisecond) + :timer.hours(1)
    :ets.insert(bucket, {ctx.key.id, 0, later, later})
    {_subject, batch} = first_events()

    conn = signed_post(build_conn(), ctx.key.key_id, ctx.secret, batch)
    assert json_response(conn, 429) == %{"error" => "rate_limited"}

    conn = fetch(ctx, "")
    assert conn.status == 200
    assert get_resp_header(conn, "retry-after") == []
    assert [{_, 0, ^later, _}] = :ets.lookup(bucket, ctx.key.id)
  end

  test "the bytes served are the bytes stored, under the stored digest", ctx do
    {:ok, _} = Policy.set_mode(ctx.scope, "enforce")
    {:ok, _} = Policy.allow(ctx.scope, nil, %{host: "api.example"})
    {:ok, stored} = Policy.current_configuration(ctx.scope, nil)

    conn = fetch(ctx, "")
    assert conn.resp_body == stored.document
    assert get_resp_header(conn, "x-qory-run-configuration") == [stored.digest]
  end

  test "a target with rules of its own gets its own; any other gets the baseline", ctx do
    shop = target_fixture(ctx.scope, "github.example", "acme/site")
    _plain = target_fixture(ctx.scope, "github.example", "acme/docs")
    {:ok, _} = Policy.allow(ctx.scope, nil, %{host: "api.example"})
    {:ok, _} = Policy.allow(ctx.scope, shop, %{host: "mcp.example"})

    assert allow(fetch(ctx, "forge=github.example&repository=acme%2Fsite")) == [
             "api.example",
             "mcp.example"
           ]

    for query <- [
          "",
          "forge=github.example",
          "repository=acme%2Fsite",
          "forge=github.example&repository=acme%2Fdocs",
          "forge=github.example&repository=acme%2Funknown",
          "forge=other.example&repository=acme%2Fsite",
          "forge[]=github.example&repository=acme%2Fsite",
          "forge[a]=github.example&repository[b]=acme%2Fsite",
          "forge=github.example&repository=" <> String.duplicate("a", 600),
          "forge=github.example&repository=acme%2Fsite%0A",
          "forge=github.example&repository=acme%2Fsite%E2%80%A8",
          "forge=github.example%C2%85&repository=acme%2Fsite",
          "forge=github.example&repository=acme%2Fsite%00"
        ] do
      conn = fetch(ctx, query)
      assert conn.status == 200, query
      assert allow(conn) == ["api.example"], query
    end
  end

  test "a target with a mode of its own is served it; an unknown one gets the workspace's", ctx do
    site = target_fixture(ctx.scope, "github.example", "acme/site")
    {:ok, _} = Policy.set_mode(ctx.scope, site, "enforce")
    mode = fn conn -> Jason.decode!(conn.resp_body)["security_policy"]["egress"]["mode"] end

    assert mode.(fetch(ctx, "forge=github.example&repository=acme%2Fsite")) == "enforce"
    assert mode.(fetch(ctx, "forge=github.example&repository=acme%2Funknown")) == "observe"
    assert mode.(fetch(ctx, "")) == "observe"

    {:ok, _} = Policy.set_mode(ctx.scope, "enforce")
    {:ok, _} = Policy.set_mode(ctx.scope, site, "observe")
    assert mode.(fetch(ctx, "forge=github.example&repository=acme%2Fsite")) == "observe"
    assert mode.(fetch(ctx, "forge=github.example&repository=acme%2Funknown")) == "enforce"
  end

  test "every label is a parameter, and the domain says which name the target",
       ctx do
    shop = target_fixture(ctx.scope, "git.example.com", "acme/shop")
    {:ok, _} = Policy.allow(ctx.scope, nil, %{host: "api.example"})
    {:ok, _} = Policy.allow(ctx.scope, shop, %{host: "mcp.example"})

    # The labels in any order, the software domain's two among them: the target's own.
    for query <- [
          "forge=git.example.com&issue=77&repository=acme%2Fshop&task=fix",
          "task=fix&repository=acme%2Fshop&issue=77&forge=git.example.com"
        ] do
      assert allow(fetch(ctx, query)) == ["api.example", "mcp.example"], query
    end

    # Labels that do not name a target, however many: the baseline.
    for query <- [
          "issue=77&task=fix",
          "issue=77&repository=acme%2Fshop&task=fix",
          "forge=git.example.com&issue=77&task=fix",
          "system=git.example.com&path=acme%2Fshop&task=fix"
        ] do
      conn = fetch(ctx, query)
      assert conn.status == 200, query
      assert allow(conn) == ["api.example"], query
    end
  end

  test "never a 304: a matching If-None-Match is answered 200 with the document", ctx do
    {:ok, _} = Policy.allow(ctx.scope, nil, %{host: "api.example"})
    first = fetch(ctx, "")
    [etag] = get_resp_header(first, "etag")

    conn = fetch(ctx, "", headers: [{"if-none-match", etag}])
    assert conn.status == 200
    assert conn.resp_body == first.resp_body
  end

  test "another workspace's key gets its own workspace's configuration", ctx do
    shop = target_fixture(ctx.scope, "github.example", "acme/site")
    {:ok, _} = Policy.allow(ctx.scope, shop, %{host: "mcp.example"})

    %{scope: other} = sign_up_fixture()
    %{access_key: key, secret: secret} = contract_key_fixture(other)
    query = "forge=github.example&repository=acme%2Fsite"

    # Managed is the workspace's own, too: this
    # workspace's policy does not make the other's served.
    assert fetch(%{key: key, secret: secret}, query).status == 404

    {:ok, _} = Policy.deny(other, nil, %{host: "ads.example"})
    conn = fetch(%{key: key, secret: secret}, query)
    assert conn.status == 200
    assert allow(conn) == []
  end

  test "a request that does not verify is 401 and renders nothing", ctx do
    {:ok, _} = Policy.allow(ctx.scope, nil, %{host: "api.example"})
    count = Repo.aggregate(RunConfiguration, :count)

    for conn <- [
          fetch(ctx, "", signature: String.duplicate("A", 86)),
          fetch(ctx, "", timestamp: System.os_time(:second) - 301),
          get(build_conn(), @path)
        ] do
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
      assert get_resp_header(conn, "x-qory-run-configuration") == []
    end

    assert Repo.aggregate(RunConfiguration, :count) == count
  end

  test "a revoked key is refused", ctx do
    {:ok, _} = Apiary.AccessKeys.revoke_access_key(ctx.scope, ctx.key)
    assert json_response(fetch(ctx, ""), 401) == %{"error" => "unauthorized"}
  end

  test "a contract version other than 1, absent or sent twice, is 400 and serves nothing",
       ctx do
    {:ok, _} = Policy.allow(ctx.scope, nil, %{host: "api.example"})
    query = "forge=github.example&repository=acme%2Fsite"

    for opts <- [
          [contract_version: nil],
          [headers: [{"x-qory-contract-version", "1"}]],
          [contract_version: "2"],
          [contract_version: "0"],
          [contract_version: "one"],
          [contract_version: "1.0"],
          [contract_version: ""]
        ] do
      conn = fetch(ctx, query, opts)

      assert json_response(conn, 400) == %{
               "error" => "unsupported_contract_version",
               "supported" => [1]
             }

      assert get_resp_header(conn, "x-qory-run-configuration") == []
      assert get_resp_header(conn, "x-qory-configuration") == []
    end

    assert fetch(ctx, query, contract_version: "1").status == 200

    # A request that does not verify is 401 first, whatever its contract version.
    conn =
      fetch(ctx, query, contract_version: "2", signature: String.duplicate("A", 86))

    assert json_response(conn, 401) == %{"error" => "unauthorized"}
  end

  describe "the contract's fixtures" do
    @describetag :contract

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

      served = Jason.decode!(fetch(ctx, "").resp_body)

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

      conn = fetch(ctx, "")
      assert :ok = Schema.validate(conn.resp_body)
      served = Jason.decode!(conn.resp_body)

      # The same document but for the order of the lists, which the apiary fixes: names
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

defmodule ApiaryWeb.Contract.RunConfigurationRateLimitTest do
  # The limits come from the application environment, which every test shares.
  use ApiaryWeb.ConnCase, async: false

  # The security policy: left out of a run without the security feature.
  @moduletag needs: :security

  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Policy
  alias ApiaryWeb.Contract.RunConfigurationController

  @path "/v1/run-configuration"

  setup do
    events = Application.get_env(:apiary, Apiary.Runs.RateLimit)
    run_configuration = Application.get_env(:apiary, RunConfigurationController)
    Application.put_env(:apiary, Apiary.Runs.RateLimit, rate: 0, burst: 2)
    Application.put_env(:apiary, RunConfigurationController, rate: 0, burst: 2)

    on_exit(fn ->
      Application.put_env(:apiary, Apiary.Runs.RateLimit, events)
      Application.put_env(:apiary, RunConfigurationController, run_configuration)
    end)

    %{scope: scope} = sign_up_fixture()
    %{access_key: key, secret: secret} = contract_key_fixture(scope)
    {:ok, _} = Policy.allow(scope, nil, %{host: "api.example"})
    %{key: key, secret: secret}
  end

  test "a flush that spends the events endpoint's bucket leaves a new run's configuration served",
       %{key: key, secret: secret} do
    {_subject, batch} = first_events()

    for _ <- 1..2 do
      assert build_conn() |> signed_post(key.key_id, secret, batch) |> response(202)
    end

    assert build_conn() |> signed_post(key.key_id, secret, batch) |> response(429)

    conn = signed_get(build_conn(), key.key_id, secret, @path)
    assert conn.status == 200
    assert get_resp_header(conn, "retry-after") == []
  end

  test "the run configuration's bucket limits itself, and leaves the events endpoint's whole",
       %{key: key, secret: secret} do
    for _ <- 1..2 do
      assert build_conn() |> signed_get(key.key_id, secret, @path) |> response(200)
    end

    conn = signed_get(build_conn(), key.key_id, secret, @path)
    assert json_response(conn, 429) == %{"error" => "rate_limited"}
    assert get_resp_header(conn, "retry-after") == ["1"]
    assert signed_answer?(conn)

    {_subject, batch} = first_events()
    assert build_conn() |> signed_post(key.key_id, secret, batch) |> response(202)
  end
end
