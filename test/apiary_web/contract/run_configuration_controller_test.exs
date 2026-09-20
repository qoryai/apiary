defmodule ApiaryWeb.Contract.RunConfigurationControllerTest do
  use ApiaryWeb.ConnCase, async: true

  import Apiary.AccessKeysFixtures
  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Policy
  alias Apiary.Policy.{Render, RunConfiguration, Schema}
  alias Apiary.Repo
  alias Apiary.Runs.Repository
  alias ApiaryWeb.Contract.Configuration

  @path "/v1/run-configuration"

  setup do
    %{scope: scope} = sign_up_fixture()
    %{access_key: key, secret: secret} = access_key_fixture(scope)
    %{scope: scope, key: key, secret: secret}
  end

  defp repository_fixture(scope, forge, path) do
    Repo.insert!(%Repository{
      organisation_id: scope.organisation.id,
      hive_id: scope.hive.id,
      forge: forge,
      path: path,
      first_seen_at: DateTime.utc_now()
    })
  end

  defp fetch(ctx, query, opts \\ []) do
    target = if query == "", do: @path, else: @path <> "?" <> query
    signed_get(build_conn(), ctx.key.key_id, ctx.secret, target, opts)
  end

  defp allow(conn), do: Jason.decode!(conn.resp_body)["security_policy"]["egress"]["allow"]

  test "a hive nobody has given a policy serves none: 404, and nothing is rendered", ctx do
    refute Policy.managed?(ctx.scope)

    for query <- ["", "forge=github.example&repository=acme%2Fsite"] do
      conn = fetch(ctx, query)
      assert json_response(conn, 404) == %{"error" => "not_found"}
      assert get_resp_header(conn, "x-qory-run-configuration") == []
      assert get_resp_header(conn, "etag") == []
    end

    assert Repo.aggregate(RunConfiguration, :count) == 0
  end

  test "from the first change on it is served, in the contract's shape, under its digest", ctx do
    # The first change may render nothing new: a deny of a host nothing allows.
    {:ok, _} = Policy.deny(ctx.scope, nil, %{host: "ads.example"})
    assert Policy.managed?(ctx.scope)

    conn = fetch(ctx, "forge=github.example&repository=acme%2Fsite")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

    assert Jason.decode!(conn.resp_body) == %{
             "version" => 1,
             "security_policy" => %{
               "version" => 1,
               "egress" => %{"mode" => "observe", "allow" => []}
             }
           }

    assert :ok = Schema.validate(conn.resp_body)
    [digest] = get_resp_header(conn, "x-qory-run-configuration")
    assert digest == Render.digest(conn.resp_body)
    assert get_resp_header(conn, "etag") == [~s("#{digest}")]
    assert get_resp_header(conn, "x-qory-configuration") == [Configuration.digest(true)]
    assert [%RunConfiguration{version: 1, repository_id: nil}] = Repo.all(RunConfiguration)
  end

  test "a key over its rate is 429 with Retry-After, from the events endpoint's bucket", ctx do
    {:ok, _} = Policy.allow(ctx.scope, nil, %{host: "api.example"})

    statuses =
      for _ <- 1..130 do
        conn = fetch(ctx, "")
        if conn.status == 429, do: assert([_seconds] = get_resp_header(conn, "retry-after"))
        conn.status
      end

    assert 200 in statuses
    assert 429 in statuses
    assert Enum.uniq(statuses) -- [200, 429] == []
  end

  test "the bytes served are the bytes stored, under the stored digest", ctx do
    {:ok, _} = Policy.set_mode(ctx.scope, "enforce")
    {:ok, _} = Policy.allow(ctx.scope, nil, %{host: "api.example"})
    {:ok, stored} = Policy.current_configuration(ctx.scope, nil)

    conn = fetch(ctx, "")
    assert conn.resp_body == stored.document
    assert get_resp_header(conn, "x-qory-run-configuration") == [stored.digest]
  end

  test "a repository with rules of its own gets its own; any other gets the baseline", ctx do
    shop = repository_fixture(ctx.scope, "github.example", "acme/site")
    _plain = repository_fixture(ctx.scope, "github.example", "acme/docs")
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
          "forge=github.example&repository=acme%2Fsite%00"
        ] do
      conn = fetch(ctx, query)
      assert conn.status == 200, query
      assert allow(conn) == ["api.example"], query
    end
  end

  test "a repository with a mode of its own is served it; an unknown one gets the hive's", ctx do
    site = repository_fixture(ctx.scope, "github.example", "acme/site")
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

  test "never a 304: a matching If-None-Match is answered 200 with the document", ctx do
    {:ok, _} = Policy.allow(ctx.scope, nil, %{host: "api.example"})
    first = fetch(ctx, "")
    [etag] = get_resp_header(first, "etag")

    conn = fetch(ctx, "", headers: [{"if-none-match", etag}])
    assert conn.status == 200
    assert conn.resp_body == first.resp_body
  end

  test "another hive's key gets its own hive's configuration", ctx do
    shop = repository_fixture(ctx.scope, "github.example", "acme/site")
    {:ok, _} = Policy.allow(ctx.scope, shop, %{host: "mcp.example"})

    %{scope: other} = sign_up_fixture()
    %{access_key: key, secret: secret} = access_key_fixture(other)
    query = "forge=github.example&repository=acme%2Fsite"

    # Managed is the hive's own, too: this hive's policy does not make the other's served.
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
          fetch(ctx, "", signature: "sha256=" <> String.duplicate("0", 64)),
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

      assert {:error, _} =
               dir
               |> Path.join("fixtures/invalid/run-configuration-no-policy.json")
               |> File.read!()
               |> Schema.validate()

      # The enforce fixture's policy, said as rules, is served in the fixture's shape.
      {:ok, _} = Policy.set_mode(ctx.scope, "enforce")

      for host <- ["api.example", "github.com", "*.github.com"],
          do: {:ok, _} = Policy.allow(ctx.scope, nil, %{host: host})

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
