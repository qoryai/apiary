defmodule ApiaryWeb.Contract.RunVariablesServedTest do
  # The run variables Qory set for a run (`registration_variables`), given at its attach
  # and at every reload after the stored run configuration's last member, in a document
  # composed for the run, under the digest of the bytes sent: a run that reports that
  # digest is not behind, the digest maps back to the stored configuration, and a
  # policy's change still moves it.
  use ApiaryWeb.ConnCase, async: false

  # Without the `registry` feature, whose members `ApiaryWeb.RegistryTokenTest` covers:
  # the features are the whole node's, so the module is not async.
  setup {Apiary.DataCase, :without_registry}

  import Apiary.ContractFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures, only: [run_fixture: 1]
  import Ecto.Query

  alias Apiary.{Policy, Repo}
  alias Apiary.Policy.{Render, RunConfiguration, Serving}
  alias Apiary.Runs.{Projector, Run, RunVariables}

  @variables %{
    "QORY_RUN_SYSTEM" => "git.example.com",
    "QORY_RUN_REPOSITORIES" => "acme/shop,acme/docs"
  }

  @members ~s("variables":{"QORY_RUN_REPOSITORIES":{"value":"acme/shop,acme/docs"},) <>
             ~s("QORY_RUN_SYSTEM":{"value":"git.example.com"}})

  setup do
    %{scope: scope} = sign_up_fixture()
    gateway = gateway_fixture(scope)

    %{access_key: gateway_key, secret: gateway_secret} =
      contract_key_fixture(scope, node: gateway)

    %{access_key: key, secret: secret} = contract_key_fixture(scope)
    %{scope: scope, gateway_key: {gateway_key, gateway_secret}, key: {key, secret}}
  end

  defp register({key, secret}, body),
    do: signed_register(build_conn(), key.key_id, secret, Jason.encode!(body))

  defp attach({key, secret}, run_id, run_key),
    do:
      signed_attach(build_conn(), key.key_id, secret, run_id, Jason.encode!(attach_body(run_key)))

  defp reload({key, secret}, run_id),
    do: signed_get(build_conn(), key.key_id, secret, "/v1/runs/" <> run_id)

  defp deliver({key, secret}, events, opts),
    do: signed_post(build_conn(), key.key_id, secret, events, opts)

  defp run(run_id), do: Repo.one!(from r in Run, where: r.node_run_id == ^run_id)

  # A run registered through the gateway, with the run variables Qory set for it, as the
  # handover writes them: its id and run key.
  defp registered(ctx, variables \\ @variables) do
    run_id = Ecto.UUID.generate()
    conn = register(ctx.key, gateway_registration(run_id))
    assert %{"run_key" => run_key} = json_response(conn, 200)

    Repo.update_all(from(r in Run, where: r.node_run_id == ^run_id),
      set: [registration_variables: variables]
    )

    {run_id, run_key}
  end

  # The configuration stored for the run's target, as the run's place reads it.
  defp stored(ctx, run_id) do
    {key, _secret} = ctx.key

    {:ok, %RunConfiguration{} = configuration} =
      Serving.fetch(key, run(run_id).registration_labels)

    configuration
  end

  defp keys(body),
    do: Enum.map(Jason.decode!(body, objects: :ordered_objects).values, &elem(&1, 0))

  # The document's bytes, without its closing brace.
  defp unclosed(document), do: binary_part(document, 0, byte_size(document) - 1)

  # The document a run with `@variables` is given, and its digest.
  defp with_members(document), do: unclosed(document) <> "," <> @members <> "}"
  defp digest_with_members(document), do: Render.digest(with_members(document))

  test "for_target/1's variables are served as stored and validate against the contract" do
    {:ok, variables} =
      RunVariables.for_target(%{system: "git.example.com", path: "acme/shop"}, ["acme/docs"])

    assert variables == @variables
    assert Jason.encode!(%{"variables" => RunVariables.document(variables)}) == "{#{@members}}"
  end

  describe "a managed workspace" do
    @describetag needs: :security

    setup ctx do
      {:ok, _rule} = Policy.allow(ctx.scope, nil, %{host: "api.example"})
      :ok
    end

    test "the attach returns the stored document, then the variables, labels and about, under the digest of the document with the variables",
         ctx do
      {run_id, run_key} = registered(ctx)
      conn = attach(ctx.gateway_key, run_id, run_key)
      assert conn.status == 200
      assert signed_answer?(conn)

      stored = stored(ctx, run_id)

      assert conn.resp_body ==
               unclosed(stored.document) <>
                 "," <>
                 @members <>
                 ~s(,"labels":{"forge":"git.example.com","repository":"acme/shop"}) <>
                 ~s(,"about":{"title":"Fix the failing build"}})

      assert keys(conn.resp_body) == ~w(version security_policy variables labels about)
      assert :ok = Apiary.Policy.Schema.validate(conn.resp_body)

      digest = digest_with_members(stored.document)
      refute digest == stored.digest
      assert get_resp_header(conn, "x-qory-run-configuration") == [digest]
      assert get_resp_header(conn, "etag") == [~s("#{digest}")]
      assert run(run_id).attach_answer_digest == digest
      assert run(run_id).registration_variables == @variables
      assert Policy.policy_digest(ctx.scope, digest) == stored.digest

      # A repeat is given the same bytes.
      again = attach(ctx.gateway_key, run_id, run_key)
      assert again.status == 200
      assert again.resp_body == conn.resp_body
      assert get_resp_header(again, "x-qory-run-configuration") == [digest]
    end

    test "a reload returns the stored document and the variables, under the digest of those bytes",
         ctx do
      {run_id, run_key} = registered(ctx)
      assert attach(ctx.gateway_key, run_id, run_key).status == 200

      conn = reload(ctx.gateway_key, run_id)
      assert conn.status == 200
      assert signed_answer?(conn)

      stored = stored(ctx, run_id)
      assert conn.resp_body == with_members(stored.document)
      assert keys(conn.resp_body) == ~w(version security_policy variables)
      assert :ok = Apiary.Policy.Schema.validate(conn.resp_body)
      digest = Render.digest(conn.resp_body)
      assert get_resp_header(conn, "x-qory-run-configuration") == [digest]
      assert get_resp_header(conn, "etag") == [~s("#{digest}")]
    end

    test "a policy's change moves the digest, and the variables stay", ctx do
      {run_id, run_key} = registered(ctx)
      attached = attach(ctx.gateway_key, run_id, run_key)
      [before] = get_resp_header(attached, "x-qory-run-configuration")

      {:ok, _rule} = Policy.allow(ctx.scope, nil, %{host: "registry.example"})

      conn = reload(ctx.gateway_key, run_id)
      assert conn.status == 200
      assert [now] = get_resp_header(conn, "x-qory-run-configuration")
      assert now != before
      assert now == digest_with_members(stored(ctx, run_id).document)

      assert Jason.decode!(conn.resp_body)["variables"] ==
               Jason.decode!("{#{@members}}")["variables"]
    end

    test "a run that reports the digest it was given is not behind", ctx do
      {run_id, run_key} = registered(ctx)
      attached = attach(ctx.gateway_key, run_id, run_key)
      [digest] = get_resp_header(attached, "x-qory-run-configuration")

      {_subject, [started]} = first_events(run_id)
      conn = deliver(ctx.gateway_key, [started], run_configuration: digest)
      assert response(conn, 202) == ""

      {:ok, run} = Projector.project(run(run_id))
      assert run.reported_run_configuration_digest == digest
      assert run.target_id != nil

      # The digests the page shows are the configuration's, which the run's maps back to.
      stored = stored(ctx, run_id).digest

      assert %{in_force: ^stored, reported: ^stored, drift: false} =
               Policy.digests(ctx.scope, run)

      assert Policy.answered_digest(ctx.scope, run) == digest

      # What the overview compares a run against: the newest version for its target.
      versions = Policy.newest_versions(ctx.scope, [nil, run.target_id])
      assert (versions[run.target_id] || versions[nil]).digest == stored
    end
  end

  test "a workspace that serves none: the document of no policy and the variables, under their digest",
       ctx do
    {run_id, run_key} = registered(ctx)
    conn = attach(ctx.gateway_key, run_id, run_key)
    assert conn.status == 200

    document = Render.no_policy_document()

    assert conn.resp_body ==
             unclosed(document) <>
               "," <>
               @members <>
               ~s(,"labels":{"forge":"git.example.com","repository":"acme/shop"}) <>
               ~s(,"about":{"title":"Fix the failing build"}})

    assert :ok = Apiary.Policy.Schema.validate(conn.resp_body)

    assert get_resp_header(conn, "x-qory-run-configuration") == [
             digest_with_members(document)
           ]

    # The reload returns the same document again: it was composed from no policy.
    reloaded = reload(ctx.gateway_key, run_id)
    assert reloaded.status == 200
    assert reloaded.resp_body == with_members(document)

    assert get_resp_header(reloaded, "x-qory-run-configuration") == [
             digest_with_members(document)
           ]
  end

  test "a run without variables is given none", ctx do
    {run_id, run_key} = registered(ctx, nil)
    conn = attach(ctx.gateway_key, run_id, run_key)
    assert conn.status == 200
    refute Map.has_key?(json_response(conn, 200), "variables")
  end

  test "a rebuild keeps the variables", ctx do
    {run_id, run_key} = registered(ctx)
    assert attach(ctx.gateway_key, run_id, run_key).status == 200

    {_subject, [started]} = first_events(run_id)
    assert response(deliver(ctx.gateway_key, [started], []), 202) == ""

    {:ok, _run} = Projector.project(run(run_id))
    {:ok, _run} = Projector.rebuild(run(run_id))
    assert run(run_id).registration_variables == @variables
  end

  test "only a registered run has variables", ctx do
    run = run_fixture(ctx.scope)

    assert_raise Postgrex.Error, ~r/runs_registration_variables_check/, fn ->
      Repo.update_all(from(r in Run, where: r.id == ^run.id),
        set: [registration_variables: @variables]
      )
    end
  end
end
