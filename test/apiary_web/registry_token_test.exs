defmodule ApiaryWeb.RegistryTokenTest do
  # The registry token route (`GET /registry/token`) and what a run gains for it: the
  # registry credential and the path rules in its run configuration, the credential's
  # value in the secrets request, and each token and refusal. Not async: the features and
  # the registry's settings are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog, only: [with_log: 1]
  import Apiary.ContractFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.SealedRunsFixtures

  alias Apiary.{InstanceConfig, Policy, Registry, Repo, SealedOpen, SigningKey}
  alias Apiary.Adapters.Collection
  alias Apiary.Contract.Ed25519
  alias Apiary.Environments.Record
  alias Apiary.Registry.{Credential, Names, RunAccess}
  alias Apiary.Runs.{Attach, RateLimit, Run, Target}
  alias ApiaryWeb.Contract.SignedRequest

  @moduletag needs: :registry

  @service "registry.test.example"
  @base ["/v2/", "/v2/shared/*", "/v2/upstream/*"]

  setup do
    %{scope: scope} = sign_up_fixture()
    {:ok, _rule} = Policy.allow(scope, nil, %{host: "git.example"})
    %{scope: scope}
  end

  # A run of the workspace's queue with a model key, attached by its gateway, whose
  # target has a row, as a collection's assignment makes it.
  defp reader(%{scope: scope}) do
    :ok = target_row(scope, "forge.example.com", "acme/shop")
    ctx = sealed_run_fixture(scope)
    Map.merge(ctx, %{target: target_name(scope, "forge.example.com", "acme/shop")})
  end

  # A prebuild of a fresh collection, claimed through a gateway whose key is not allowed
  # stored secrets, and attached by it: a build with no model key.
  defp build(%{scope: scope}) do
    place = handover_place_fixture(scope)
    collection = Apiary.NodesFixtures.collection_fixture(scope)
    :ok = target_row(scope, collection.target_system, collection.target_path)

    [_queued] = queue_builds!(collection)

    %{registered: registered, run_code: code} = dispatched!(place.key)
    {:ok, attach} = Attach.parse(attach_body(redeemed_run_key!(code)))
    {key, _seed} = place.gateway_key

    {:ok, attached} =
      Attach.attach(key, registered.node_run_id, attach, %{
        forager_version: "0.7.0",
        instance_id: instance_id()
      })

    Map.merge(place, %{
      run: Repo.get!(Run, registered.id),
      attached: attached,
      secrets_key: place.gateway_key,
      collection: collection,
      target: target_name(scope, collection.target_system, collection.target_path)
    })
  end

  # A registry credential for `run`, as a seal stores it.
  defp issue(run) do
    secret = Credential.new_secret()
    :ok = Credential.store(run, secret)
    secret
  end

  defp target_row(scope, system, path),
    do:
      Target.insert_new(scope.organisation.id, scope.workspace.id, [
        %{system: system, path: path}
      ])

  defp target_name(scope, system, path) do
    public_id =
      Repo.one!(
        from t in Target,
          where: t.workspace_id == ^scope.workspace.id and t.system == ^system,
          where: t.path == ^path,
          select: t.public_id
      )

    Names.target_name(InstanceConfig.registry_instance(), scope.organisation.id, public_id)
  end

  defp document(ctx), do: Jason.decode!(ctx.attached.settings)

  defp registry_paths(ctx),
    do: document(ctx)["security_policy"]["egress"]["paths"][@service]

  defp environment(ctx) do
    [name] =
      for "/v2/" <> rest <- registry_paths(ctx),
          String.contains?(rest, "/environments/"),
          String.ends_with?(rest, "/blobs/*"),
          do: String.replace_suffix(rest, "/blobs/*", "")

    name
  end

  defp token(user, secret, query, method \\ :get) do
    conn =
      if user,
        do:
          put_req_header(
            build_conn(),
            "authorization",
            Plug.BasicAuth.encode_basic_auth(user, secret)
          ),
        else: build_conn()

    dispatch(conn, @endpoint, method, "/registry/token?" <> URI.encode_query(query), nil)
  end

  defp token_for(%{run: run, secret: secret}, query), do: token(run.public_id, secret, query)

  defp scopes(names_actions),
    do: [{"service", @service} | for(scope <- names_actions, do: {"scope", scope})]

  defp access(conn) do
    assert conn.status == 200, conn.resp_body
    claims(Jason.decode!(conn.resp_body)["token"])["access"]
  end

  defp claims(token) do
    [_header, claims, _signature] = String.split(token, ".")
    Jason.decode!(Base.url_decode64!(claims, padding: false))
  end

  defp error(conn) do
    assert %{"errors" => [%{"code" => code, "message" => message}]} =
             Jason.decode!(conn.resp_body)

    {conn.status, code, message}
  end

  defp seal(ctx, credentials) do
    {key, seed} = ctx.secrets_key
    body = secrets_request(ctx.run, ctx.attached.digest, credentials, SignedRequest.now())

    signed_post(build_conn(), key.key_id, seed, body,
      target: "/v1/secrets",
      content_type: "application/json",
      delivery: nil
    )
  end

  defp open(ctx, conn) do
    {key, seed} = ctx.secrets_key

    assert {:ok, plaintext, _sealed} =
             SealedOpen.open(conn.resp_body, %{
               access_key_id: key.key_id,
               run_id: ctx.run.node_run_id,
               run_configuration: ctx.attached.digest,
               signing_public_key: SigningKey.current().public_key,
               x25519_private_key: SealedOpen.x25519_private_key(seed)
             })

    Jason.decode!(plaintext)
  end

  defp registry_value(plaintext) do
    [value] = for %{"credential" => "registry", "value" => v} <- plaintext["values"], do: v
    value
  end

  describe "a run of the queue" do
    setup ctx do
      ctx = reader(ctx)
      Map.put(ctx, :secret, issue(ctx.run))
    end

    test "gains the registry credential, the hosts and the path rules", ctx do
      document = document(ctx)
      assert Apiary.ForagerSchemas.validate("run-configuration.schema.json", document) == :ok
      host = RunAccess.instance_host()

      assert [%{"name" => model}, registry] = document["credentials"]
      assert model == ctx.provider.public_id

      assert registry == %{
               "name" => "registry",
               "apply" => [
                 %{
                   "hosts" => [host],
                   "scheme" => "basic",
                   "username" => ctx.run.public_id,
                   "paths" => ["/registry/token"]
                 }
               ]
             }

      refute Map.has_key?(document, "harness_hidden")

      egress = document["security_policy"]["egress"]
      assert host in egress["allow"] and @service in egress["allow"]
      assert host in egress["allow_first"] and @service in egress["allow_first"]

      t = ctx.target

      assert registry_paths(ctx) ==
               @base ++
                 ["/v2/#{t}/manifests/sha256:*", "/v2/#{t}/blobs/*", "/v2/#{t}/referrers/*"]
    end

    test "is sealed the registry credential after its model key, and a new seal replaces it",
         ctx do
      credentials = [ctx.provider.public_id, "registry"]
      conn = seal(ctx, credentials)
      assert conn.status == 200, conn.resp_body
      plaintext = open(ctx, conn)
      assert plaintext["credentials"] == Enum.sort(credentials)
      assert Enum.map(plaintext["values"], & &1["credential"]) == Enum.sort(credentials)
      first = registry_value(plaintext)
      assert {:ok, %Run{id: id}} = Credential.verify(ctx.run.public_id, first)
      assert id == ctx.run.id

      second = registry_value(open(ctx, seal(ctx, credentials)))
      assert first != second
      assert Credential.verify(ctx.run.public_id, first) == :error
      assert {:ok, _run} = Credential.verify(ctx.run.public_id, second)

      assert token(ctx.run.public_id, second, scopes(["repository:#{ctx.target}:pull"])).status ==
               200

      assert {401, "UNAUTHORIZED", _message} =
               error(token(ctx.run.public_id, first, scopes(["repository:#{ctx.target}:pull"])))
    end

    test "is sealed the model key alone for a request that names it alone, its secret kept",
         ctx do
      conn = seal(ctx, [ctx.provider.public_id])
      assert conn.status == 200, conn.resp_body
      plaintext = open(ctx, conn)
      assert plaintext["credentials"] == [ctx.provider.public_id]
      assert [%{"credential" => model}] = plaintext["values"]
      assert model == ctx.provider.public_id
      # The credential stored before stays the one that matches.
      assert {:ok, _run} = Credential.verify(ctx.run.public_id, ctx.secret)
    end

    test "is sealed a new registry secret alone for a request that names it alone", ctx do
      seals = fn ->
        Repo.aggregate(
          from(e in Apiary.Audit.Entry, where: e.action == "secret.seal"),
          :count
        )
      end

      before = seals.()
      conn = seal(ctx, ["registry"])
      assert conn.status == 200, conn.resp_body
      plaintext = open(ctx, conn)
      assert plaintext["credentials"] == ["registry"]
      assert [%{"credential" => "registry"}] = plaintext["values"]
      refute Jason.encode!(plaintext) =~ model_key()

      assert {:ok, _run} = Credential.verify(ctx.run.public_id, registry_value(plaintext))
      assert Credential.verify(ctx.run.public_id, ctx.secret) == :error
      # No model key sealed, so no seal recorded.
      assert seals.() == before
    end

    test "is refused a request out of the run configuration's order", ctx do
      conn = seal(ctx, ["registry", ctx.provider.public_id])
      assert conn.status == 409
      assert Jason.decode!(conn.resp_body)["error"] == "credentials_differ"
      assert {:ok, _run} = Credential.verify(ctx.run.public_id, ctx.secret)
    end

    test "is sealed nothing for a key of its gateway not allowed stored secrets", ctx do
      # A key of the gateway made in a browser after the handover, without the flag. With
      # the feature on, the key passes the flag's check and the run's run key does not
      # list it: `404`, as for any key of the gateway the run key does not list.
      %{access_key: plain, secret: seed} =
        Apiary.ContractFixtures.contract_key_fixture(ctx.scope, node: ctx.gateway)

      conn = seal(%{ctx | secrets_key: {plain, seed}}, [ctx.provider.public_id, "registry"])
      assert {conn.status, Jason.decode!(conn.resp_body)["error"]} == {404, "not_found"}
      assert Credential.verify(ctx.run.public_id, ctx.secret) |> elem(0) == :ok
    end

    test "is sealed the registry credential alone for a listed key not allowed stored secrets",
         ctx do
      # The claim ends a run with a model key whose gateway has such a key, so the test
      # writes the run's run key to list one.
      %{access_key: plain, secret: seed} =
        Apiary.ContractFixtures.contract_key_fixture(ctx.scope, node: ctx.gateway)

      refute plain.allow_secrets
      payload = Jason.decode!(ctx.run.run_key_payload)
      keys = [%{"alg" => "ed25519", "public_key" => Ed25519.encode(plain.public_key)}]
      listed = Jason.encode!(%{payload | "gateway_public_key" => keys})

      {1, _} =
        Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id),
          set: [run_key_payload: listed]
        )

      ctx = %{ctx | secrets_key: {plain, seed}}

      conn = seal(ctx, [ctx.provider.public_id, "registry"])
      assert {conn.status, Jason.decode!(conn.resp_body)["error"]} == {409, "secrets_not_allowed"}

      conn = seal(ctx, ["registry"])
      assert conn.status == 200, conn.resp_body
      plaintext = open(ctx, conn)
      assert [%{"credential" => "registry"}] = plaintext["values"]
      refute Jason.encode!(plaintext) =~ model_key()
      assert {:ok, _run} = Credential.verify(ctx.run.public_id, registry_value(plaintext))
    end

    test "has its target's image name, to pull, and a run without a gateway has nothing",
         ctx do
      assert RunAccess.rights(ctx.run) == %{ctx.target => ["pull"]}
      direct = %{ctx.run | run_key_payload: nil, run_code_sha256: nil}
      refute RunAccess.applies?(direct)
      assert RunAccess.rights(direct) == %{}
      assert RunAccess.member(direct) == nil
    end

    test "gets a signed token for its target's image, pull alone", ctx do
      {conn, log} =
        with_log(fn ->
          token_for(ctx, scopes(["repository:#{ctx.target}:pull,push"]))
        end)

      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      body = Jason.decode!(conn.resp_body)
      assert body["expires_in"] == 900
      {:ok, issued_at, 0} = DateTime.from_iso8601(body["issued_at"])

      [header, payload, signature] = String.split(body["token"], ".")
      settings = Registry.settings()

      assert Jason.decode!(Base.url_decode64!(header, padding: false)) == %{
               "alg" => "ES256",
               "typ" => "JWT",
               "kid" => settings.kid
             }

      claims = claims(body["token"])
      assert claims["iss"] == ApiaryWeb.Endpoint.url()
      assert claims["aud"] == @service
      assert claims["sub"] == ctx.run.public_id
      assert claims["exp"] == DateTime.to_unix(issued_at) + 900
      assert claims["jti"] =~ ~r/\A[0-9a-f]{32}\z/

      assert claims["access"] == [
               %{"type" => "repository", "name" => ctx.target, "actions" => ["pull"]}
             ]

      {:ECPrivateKey, _version, _private, params, point, _attributes} = settings.key
      <<r::unsigned-big-256, s::unsigned-big-256>> = Base.url_decode64!(signature, padding: false)
      der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})

      assert :public_key.verify(
               header <> "." <> payload,
               :sha256,
               der,
               {{:ECPoint, point}, params}
             )

      refute log =~ ctx.secret
      refute log =~ body["token"]
    end

    test "gets pull alone under shared/ and upstream/, and never push", ctx do
      assert access(
               token_for(
                 ctx,
                 scopes([
                   "repository:shared/base:pull,push",
                   "repository:upstream/docker.io/library/alpine:pull,push"
                 ])
               )
             ) == [
               %{"type" => "repository", "name" => "shared/base", "actions" => ["pull"]},
               %{
                 "type" => "repository",
                 "name" => "upstream/docker.io/library/alpine",
                 "actions" => ["pull"]
               }
             ]
    end

    test "is refused with 401 when the request grants nothing, or has no scope", ctx do
      other = Names.target_name(InstanceConfig.registry_instance(), Ecto.UUID.generate(), "tg_x")

      message =
        "Ask only for images inside the run. The request contains no image that the run " <>
          "#{ctx.run.public_id} may pull or push."

      for query <- [
            scopes([]),
            scopes(["repository:#{other}:pull"]),
            scopes(["repository:shared/base:push", "repository::pull", "registry:catalog:*"]),
            scopes(["repository:#{ctx.target}:delete"])
          ] do
        conn = token_for(ctx, query)
        assert error(conn) == {401, "UNAUTHORIZED", message}
        assert get_resp_header(conn, "www-authenticate") == [~s(Basic realm="Qory Apiary")]
      end
    end
  end

  describe "the instance's host" do
    test "gets the token route as its one path rule where the document did not allow it",
         ctx do
      ctx = reader(ctx)
      host = RunAccess.instance_host()
      assert document(ctx)["security_policy"]["egress"]["paths"][host] == ["/registry/token"]
    end

    test "keeps the document's path rules for it, with the token route after them", ctx do
      {:ok, _rule} =
        Policy.allow(ctx.scope, nil, %{host: RunAccess.instance_host(), paths: ["/api/*"]})

      ctx = reader(ctx)
      host = RunAccess.instance_host()

      assert document(ctx)["security_policy"]["egress"]["paths"][host] ==
               ["/api/*", "/registry/token"]
    end

    test "gets no path rule where the document allowed it on every path", ctx do
      {:ok, _rule} = Policy.allow(ctx.scope, nil, %{host: RunAccess.instance_host()})
      ctx = reader(ctx)
      paths = document(ctx)["security_policy"]["egress"]["paths"]
      refute Map.has_key?(paths, RunAccess.instance_host())
      assert Map.has_key?(paths, @service)
    end

    test "gets the token route as its one path rule where the document denies it", ctx do
      {:ok, _rule} = Policy.deny(ctx.scope, nil, %{host: RunAccess.instance_host()})
      ctx = reader(ctx)
      host = RunAccess.instance_host()
      assert document(ctx)["security_policy"]["egress"]["paths"][host] == ["/registry/token"]
    end
  end

  describe "a build" do
    setup ctx do
      ctx = build(ctx)
      Map.put(ctx, :secret, issue(ctx.run))
    end

    test "gains the push path rules for its target and environment image", ctx do
      assert Apiary.ForagerSchemas.validate("run-configuration.schema.json", document(ctx)) ==
               :ok

      assert [%{"name" => "registry"}] = document(ctx)["credentials"]
      t = ctx.target
      e = environment(ctx)
      assert e =~ ~r|\A[0-9a-f]{16}/[0-9a-f]{16}/environments/[0-9a-f]{16}\z|
      id = ctx.run.node_run_id

      assert registry_paths(ctx) ==
               @base ++
                 [
                   "/v2/#{t}/manifests/#{id}",
                   "/v2/#{t}/manifests/sha256:*",
                   "/v2/#{t}/blobs/*",
                   "/v2/#{t}/referrers/*",
                   "/v2/#{e}/manifests/#{id}",
                   "/v2/#{e}/manifests/sha256:*",
                   "/v2/#{e}/blobs/*",
                   "/v2/#{e}/referrers/*"
                 ]
    end

    test "is sealed the registry credential alone, under a key not allowed stored secrets",
         ctx do
      {key, _seed} = ctx.secrets_key
      refute key.allow_secrets
      conn = seal(ctx, ["registry"])
      assert conn.status == 200, conn.resp_body
      plaintext = open(ctx, conn)
      assert plaintext["credentials"] == ["registry"]
      assert {:ok, _run} = Credential.verify(ctx.run.public_id, registry_value(plaintext))
    end

    test "may push its environment image while it does not exist, then pull it alone", ctx do
      e = environment(ctx)
      query = scopes(["repository:#{ctx.target}:pull,push", "repository:#{e}:pull,push"])
      paths = registry_paths(ctx)

      assert access(token_for(ctx, query)) == [
               %{"type" => "repository", "name" => ctx.target, "actions" => ["pull", "push"]},
               %{"type" => "repository", "name" => e, "actions" => ["pull", "push"]}
             ]

      {1, _rows} =
        Repo.update_all(from(r in Record, where: r.organisation_id == ^ctx.scope.organisation.id),
          set: [
            image: "#{@service}/#{e}@sha256:" <> String.duplicate("0", 64),
            size: 1,
            commit: String.duplicate("a", 40),
            built_at: DateTime.utc_now(),
            reported_ref: "env-1",
            built_ref: "env-1"
          ]
        )

      assert access(token_for(ctx, query)) == [
               %{"type" => "repository", "name" => ctx.target, "actions" => ["pull", "push"]},
               %{"type" => "repository", "name" => e, "actions" => ["pull"]}
             ]

      # The path rules, and so the run configuration's digest, stay as they were.
      assert RunAccess.member(Repo.get!(Run, ctx.run.id)).paths == paths

      for rule <- ["manifests/sha256:*", "blobs/*", "referrers/*"],
          do: assert("/v2/#{e}/#{rule}" in paths)
    end

    test "pushes to its target and its environment image while its collection keeps the target",
         ctx do
      e = environment(ctx)
      query = scopes(["repository:#{ctx.target}:pull,push", "repository:#{e}:pull,push"])

      assert RunAccess.rights(ctx.run) == %{
               ctx.target => ["pull", "push"],
               e => ["pull", "push"]
             }

      assert access(token_for(ctx, query)) == [
               %{"type" => "repository", "name" => ctx.target, "actions" => ["pull", "push"]},
               %{"type" => "repository", "name" => e, "actions" => ["pull", "push"]}
             ]
    end

    test "pushes nowhere once a listing changes its collection's target after the claim",
         ctx do
      e = environment(ctx)
      :ok = target_row(ctx.scope, "code.example.com", "acme/other")
      other = target_name(ctx.scope, "code.example.com", "acme/other")

      {1, _rows} =
        Repo.update_all(from(c in Collection, where: c.id == ^ctx.collection.id),
          set: [target_system: "code.example.com", target_path: "acme/other"]
        )

      run = Repo.get!(Run, ctx.run.id)
      assert RunAccess.rights(run) == %{ctx.target => ["pull"]}

      query =
        scopes([
          "repository:#{ctx.target}:pull,push",
          "repository:#{other}:pull,push",
          "repository:#{e}:pull,push"
        ])

      assert access(token_for(ctx, query)) == [
               %{"type" => "repository", "name" => ctx.target, "actions" => ["pull"]}
             ]

      assert RunAccess.member(run).paths ==
               @base ++
                 [
                   "/v2/#{ctx.target}/manifests/sha256:*",
                   "/v2/#{ctx.target}/blobs/*",
                   "/v2/#{ctx.target}/referrers/*"
                 ]
    end

    test "pushes nowhere without a dispatched target, whatever its labels are", ctx do
      e = environment(ctx)
      query = scopes(["repository:#{ctx.target}:pull,push", "repository:#{e}:pull,push"])

      # The collection has no target any more; the labels are still those of its old target.
      {1, _rows} =
        Repo.update_all(from(c in Collection, where: c.id == ^ctx.collection.id),
          set: [target_system: nil, target_path: nil]
        )

      run = Repo.get!(Run, ctx.run.id)
      assert RunAccess.rights(run) == %{ctx.target => ["pull"]}

      assert access(token_for(ctx, query)) == [
               %{"type" => "repository", "name" => ctx.target, "actions" => ["pull"]}
             ]

      assert RunAccess.member(run).paths ==
               @base ++
                 [
                   "/v2/#{ctx.target}/manifests/sha256:*",
                   "/v2/#{ctx.target}/blobs/*",
                   "/v2/#{ctx.target}/referrers/*"
                 ]

      # A run of no queue with the target's labels, as a registration stores them.
      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id), set: [dispatch_run_id: nil])

      assert RunAccess.rights(Repo.get!(Run, ctx.run.id)) == %{ctx.target => ["pull"]}

      assert access(token_for(ctx, query)) == [
               %{"type" => "repository", "name" => ctx.target, "actions" => ["pull"]}
             ]
    end

    test "never pushes under shared/ or upstream/", ctx do
      assert access(
               token_for(
                 ctx,
                 scopes([
                   "repository:shared/base:push,pull",
                   "repository:upstream/quay.io/example/tool:push,pull"
                 ])
               )
             ) == [
               %{"type" => "repository", "name" => "shared/base", "actions" => ["pull"]},
               %{
                 "type" => "repository",
                 "name" => "upstream/quay.io/example/tool",
                 "actions" => ["pull"]
               }
             ]

      assert {401, "UNAUTHORIZED", _message} =
               error(token_for(ctx, scopes(["repository:shared/base:push"])))
    end
  end

  describe "the refusals" do
    setup ctx do
      ctx = reader(ctx)
      Map.put(ctx, :secret, issue(ctx.run))
    end

    test "405 for any method other than GET", ctx do
      for method <- [:post, :put, :delete, :patch] do
        conn = token(ctx.run.public_id, ctx.secret, scopes([]), method)

        assert error(conn) ==
                 {405, "UNSUPPORTED",
                  "Send the token request as a GET request. Only a GET request gets a " <>
                    "registry token here."}

        assert get_resp_header(conn, "allow") == ["GET"]
      end
    end

    test "401 without a registry credential", ctx do
      message =
        "Send the token request through the run's gateway, which adds the run's registry " <>
          "credential. The request has no registry credential."

      for conn <- [
            token(nil, nil, scopes(["repository:#{ctx.target}:pull"])),
            token(ctx.run.public_id, "", scopes(["repository:#{ctx.target}:pull"])),
            build_conn()
            |> put_req_header("authorization", "Bearer x")
            |> get("/registry/token?service=#{@service}")
          ] do
        assert error(conn) == {401, "UNAUTHORIZED", message}
        assert get_resp_header(conn, "www-authenticate") == [~s(Basic realm="Qory Apiary")]
      end
    end

    test "401 for a credential that matches no run", ctx do
      message =
        "Send the token request through the gateway of a running run. The registry " <>
          "credential in the request matches no run of this instance."

      for {user, secret} <- [
            {ctx.run.public_id, ctx.secret <> "x"},
            {"run_unknown", ctx.secret},
            {String.duplicate("r", 65), ctx.secret}
          ] do
        assert error(token(user, secret, scopes(["repository:#{ctx.target}:pull"]))) ==
                 {401, "UNAUTHORIZED", message}
      end
    end

    test "401 for a run that ended, whatever the secret", ctx do
      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id), set: [state: "completed"])

      assert error(token_for(ctx, scopes(["repository:#{ctx.target}:pull"]))) ==
               {401, "UNAUTHORIZED",
                "Start a new run to pull or push images. The run #{ctx.run.public_id} has " <>
                  "ended, and its registry credential ended with it."}
    end

    test "400 for no service, or another one", ctx do
      fix = "Set the registry's token service to #{@service}, the host in QORY_REGISTRY."

      assert error(token_for(ctx, [{"scope", "repository:#{ctx.target}:pull"}])) ==
               {400, "UNSUPPORTED", fix <> " The request has no service parameter."}

      assert error(token_for(ctx, [{"service", "other.example\nx"}])) ==
               {400, "UNSUPPORTED", fix <> " The request's service parameter is other.examplex."}
    end

    test "400 for more than 16 scope parameters, and none for scopes in one parameter", ctx do
      query = scopes(List.duplicate("repository:#{ctx.target}:pull", 17))

      assert error(token_for(ctx, query)) ==
               {400, "UNSUPPORTED",
                "Send at most 16 scope parameters in one token request. The request has 17."}

      joined = Enum.join(List.duplicate("repository:#{ctx.target}:pull", 17), " ")
      assert {401, "UNAUTHORIZED", _message} = error(token_for(ctx, scopes([joined])))
    end

    test "429 after 120 tokens to the run in its window of 60 seconds", ctx do
      query = scopes(["repository:#{ctx.target}:pull"])
      key = {:registry_token, ctx.run.id}

      # A refusal after the credential matched gives its reservation back.
      for _ <- 1..130, do: assert(token_for(ctx, scopes([])).status == 401)
      assert token_for(ctx, query).status == 200

      for _ <- 1..119, do: assert({:ok, _started} = RateLimit.reserve(key, 120, 60_000))

      message =
        "Wait 1 minute, then try again. Qory Apiary issued 120 registry tokens to the " <>
          "run #{ctx.run.public_id} in the last 60 seconds, the limit."

      conn = token_for(ctx, query)
      assert error(conn) == {429, "TOOMANYREQUESTS", message}
      assert [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) in 1..60

      # Checked before the run's rights and its state are read.
      assert error(token_for(ctx, scopes([]))) == {429, "TOOMANYREQUESTS", message}

      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id), set: [state: "completed"])

      assert error(token_for(ctx, query)) == {429, "TOOMANYREQUESTS", message}
    end

    test "401 with nothing granted for a run that does not go through a gateway", ctx do
      # A run its events created, with a registry credential stored as a seal stores one.
      run =
        ctx.scope
        |> Apiary.RunEventsFixtures.run_fixture(%{state: "running"})
        |> then(&Repo.get!(Run, &1.id))

      refute RunAccess.applies?(run)
      secret = issue(run)

      assert error(token(run.public_id, secret, scopes(["repository:shared/base:pull"]))) ==
               {401, "UNAUTHORIZED",
                "Ask only for images inside the run. The request contains no image that the " <>
                  "run #{run.public_id} may pull or push."}
    end

    test "503 when the token cannot be issued, with a line in the log", ctx do
      settings = Registry.settings()
      setting = Application.get_env(:apiary, :registry_setting)

      on_exit(fn ->
        Application.put_env(:apiary, Registry.Settings, settings)
        Application.put_env(:apiary, :registry_setting, setting)
      end)

      Application.delete_env(:apiary, Registry.Settings)
      Application.put_env(:apiary, :registry_setting, nil)

      {conn, log} = with_log(fn -> token_for(ctx, scopes(["repository:#{ctx.target}:pull"])) end)

      assert error(conn) ==
               {503, "UNAVAILABLE",
                "Try the pull or push again in 1 minute. Qory Apiary could not issue a " <>
                  "registry token; the cause is in the instance's log."}

      assert log =~
               "Qory Apiary could not build the response to a registry token request: ArgumentError"

      refute log =~ ctx.secret
    end
  end

  test "the instance's registry name is nil, and nothing kept, on a schema without it" do
    assert Application.fetch_env(:apiary, :registry_instance) == :error

    # Each in a transaction rolled back, the column dropped inside it alone.
    for {read, expected} <- [
          {&InstanceConfig.record_registry_instance/0, nil},
          {&Apiary.Registry.InstanceName.start_link/0, :ignore}
        ] do
      assert {:error, ^expected} =
               Repo.transaction(fn ->
                 Repo.query!("ALTER TABLE instance_settings DROP COLUMN registry_instance")
                 Repo.rollback(read.())
               end)
    end

    assert Application.fetch_env(:apiary, :registry_instance) == :error
  end

  test "the instance's registry name is made once and stored" do
    name = InstanceConfig.registry_instance()
    assert Names.instance?(name)
    assert InstanceConfig.record_registry_instance() == name

    assert Repo.one!(from s in "instance_settings", select: s.registry_instance) == name
  end

  describe "a run of the queue with a work entry" do
    @apply [
      %{"hosts" => ["git.example.com"], "scheme" => "bearer", "paths" => ["/{target.path}/*"]}
    ]
    @entry_apply [
      %{"hosts" => ["git.example.com"], "scheme" => "bearer", "paths" => ["/acme/shop/*"]}
    ]

    setup %{scope: scope} do
      :ok = target_row(scope, "forge.example.com", "acme/shop")
      sealed_run_fixture(scope, work: @apply)
    end

    test "keeps its registry secret at a renewal of work-1 alone", ctx do
      credential = &Apiary.WorkCredentialStub.credential(&1, @entry_apply)
      Apiary.WorkCredentialStub.issue(ctx.adapter_seed, credential.("fixture-work-token-start"))
      credentials = [ctx.provider.public_id, "registry", "work-1"]
      conn = seal(ctx, credentials)
      assert conn.status == 200, conn.resp_body
      assert Enum.map(open(ctx, conn)["values"], & &1["credential"]) == Enum.sort(credentials)
      hash = Repo.get!(Run, ctx.run.id).registry_credential_sha256
      assert is_binary(hash)

      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id), set: [state: "running"])

      Apiary.WorkCredentialStub.issue(ctx.adapter_seed, credential.("fixture-work-token-renewed"))
      conn = seal(ctx, ["work-1"])
      assert conn.status == 200, conn.resp_body

      assert [%{"credential" => "work-1", "value" => "fixture-work-token-renewed"}] =
               open(ctx, conn)["values"]

      assert Repo.get!(Run, ctx.run.id).registry_credential_sha256 == hash
    end
  end
end
