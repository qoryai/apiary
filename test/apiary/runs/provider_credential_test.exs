defmodule Apiary.Runs.ProviderCredentialTest do
  # A run the handover set a model provider for receives its model key's credential in its
  # run configuration, and the provider's hosts in its allow list and its allow_first list
  # (`Apiary.Runs.ProviderCredential`, `Apiary.Policy.ComposedConfiguration`); every digest
  # sent for it is the SHA-256 of the bytes sent.
  use Apiary.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog, only: [with_log: 1]
  import Apiary.ConnectionsFixtures, only: [no_runtime_hosts!: 0, ready_release!: 3]
  import Apiary.DescriptionFixtures, only: [tracker_description: 1]
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.SealedRunsFixtures

  alias Apiary.{Connections, Policy, Repo}
  alias Apiary.Connections.Connection
  alias Apiary.Policy.{ComposedConfiguration, Render, Rule}
  alias Apiary.Runs.{ModelKey, ProviderCredential, Registration, Run}

  @moduletag needs: :factory
  # Without the `registry` feature, whose members `ApiaryWeb.RegistryTokenTest`
  # covers: the features are the whole node's, so the module is not async.
  setup {Apiary.DataCase, :without_registry}

  defp sha256(bytes), do: Render.digest(bytes)

  # An integration of the scope's organisation for every workspace, whose `egress_hosts`
  # are `hosts`.
  defp integration!(scope, name, hosts) do
    release =
      ready_release!(
        scope,
        tracker_description(%{"name" => name, "egress_hosts" => hosts}),
        "codeberg.org/acme/#{name}"
      )

    {:ok, connection} = Connections.create_integration(scope, release.id, %{})
    connection
  end

  defp reload(ctx) do
    {key, _seed} = ctx.secrets_key

    Registration.fetch(
      key,
      ctx.run.node_run_id,
      Apiary.ContractFixtures.instance_id()
    )
  end

  # The run configuration of the attach, without the labels and about appended after it.
  defp document(%{attached: %{settings: bytes}}) do
    bytes
    |> Jason.decode!(objects: :ordered_objects)
    |> Map.get(:values)
    |> Enum.reject(fn {name, _value} -> name in ["labels", "about"] end)
    |> Jason.OrderedObject.new()
    |> Jason.encode!(escape: :json)
  end

  describe "a run of a workspace that serves a policy" do
    setup do
      %{scope: scope} = sign_up_fixture()
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "git.example"})
      scope |> sealed_run_fixture() |> Map.put(:scope, scope)
    end

    test "is given the credential, its name and the provider's host, under the digest of the bytes",
         ctx do
      document = document(ctx)
      assert ctx.attached.digest == sha256(document)

      decoded = Jason.decode!(document, objects: :ordered_objects)
      names = Enum.map(decoded.values, &elem(&1, 0))

      assert names ==
               ~w(version security_policy variables credentials default_model_provider_credential_name)

      name = "#{ctx.provider.public_id}-1"
      assert name =~ ~r/\A[a-z0-9][a-z0-9_.-]{0,63}\z/

      assert Jason.decode!(document)["credentials"] == [
               %{
                 "name" => name,
                 "group" => ctx.provider.public_id,
                 "format" => "anthropic-messages",
                 "endpoint" => "https://api.anthropic.com",
                 "auth" => %{"scheme" => "header", "header" => "x-api-key"},
                 "pause_for_s" => 60
               }
             ]

      assert Jason.decode!(document)["default_model_provider_credential_name"] == name

      assert Jason.decode!(document)["security_policy"]["egress"]["allow"] ==
               ["git.example", "api.anthropic.com"]

      assert Jason.decode!(document)["security_policy"]["egress"]["allow_first"] ==
               ["api.anthropic.com"]

      assert Apiary.Policy.Schema.validate(document) == :ok
      assert Apiary.ForagerSchemas.validate("run-configuration.schema.json", document) == :ok

      # No key, no secret id, no value id.
      refute document =~ model_key()
      refute document =~ Repo.get!(Apiary.Secrets.Secret, ctx.provider.secret_id).public_id
      refute document =~ ~s("main")

      # The reload returns the same bytes, under the same digest, which the run keeps.
      assert {:ok, %{settings: ^document, digest: digest}} = reload(ctx)
      assert digest == ctx.attached.digest
      assert ctx.run.attach_answer_digest == digest

      # What the policy pages compare a run's report with.
      {:ok, configuration} = Policy.current_configuration(ctx.scope, nil)
      assert ComposedConfiguration.run_digest(configuration, ctx.run) == digest

      assert ComposedConfiguration.policy_digest(ctx.scope.workspace.id, digest) ==
               configuration.digest
    end

    test "whose harness walk hid its harness is given harness_hidden, last, and none else",
         ctx do
      refute Map.has_key?(Jason.decode!(document(ctx)), "harness_hidden")

      {1, _rows} =
        Repo.update_all(
          from(h in Apiary.Harnesses.RunHarness,
            where: h.dispatch_run_id == ^ctx.run.dispatch_run_id
          ),
          set: [harness_hidden: true]
        )

      assert {:ok, %{settings: settings, digest: digest}} = reload(ctx)
      document = document(%{attached: %{settings: settings}})
      assert digest == sha256(document)
      assert digest != ctx.attached.digest

      decoded = Jason.decode!(document, objects: :ordered_objects)
      assert List.last(decoded.values) == {"harness_hidden", true}
      assert Apiary.ForagerSchemas.validate("run-configuration.schema.json", document) == :ok
    end

    test "the default model provider credential of every run of the provider is <provider id>-<place>",
         ctx do
      run = Repo.preload(ctx.run, :model_keys)
      {:ok, credential} = ProviderCredential.for_run(run)
      {:ok, again} = ProviderCredential.for_run(%{run | id: Ecto.UUID.generate()})
      assert credential.name == again.name
      assert credential.name == "#{ctx.provider.public_id}-1"
      assert [%{name: name, secret_value_id: id}] = credential.keys
      assert name == credential.name
      assert [%ModelKey{secret_value_id: ^id}] = run.model_keys
    end

    test "a provider row that fails its integrity code leaves no run configuration", ctx do
      {1, _rows} =
        Repo.update_all(from(c in Connection, where: c.id == ^ctx.provider.id),
          set: [name: "Changed past the save"]
        )

      {answer, log} = with_log(fn -> reload(ctx) end)
      assert answer == {:error, :unavailable}
      assert log =~ "#{ctx.provider.public_id} fails its integrity code"
      refute log =~ model_key()
    end

    test "a run whose provider is gone has no run configuration", ctx do
      # A deleted provider's row leaves the run and its key rows with no provider.
      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id),
          set: [provider_connection_id: nil]
        )

      {1, _rows} =
        Repo.update_all(from(k in ModelKey, where: k.run_id == ^ctx.run.id),
          set: [connection_id: nil]
        )

      {answer, _log} = with_log(fn -> reload(ctx) end)
      assert answer == {:error, :unavailable}
    end
  end

  describe "a run with several keys" do
    test "is given each key of the run, a key in cooldown last, none chosen, which the schema takes" do
      %{scope: scope} = sign_up_fixture()
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "git.example"})
      until = Apiary.ModelKeysFixtures.in_seconds(3600)

      ctx =
        sealed_run_fixture(scope,
          keys: [
            %{value_id: "main", value: model_key()},
            %{value_id: "spare", value: "sk-ant-spare-0123456789"}
          ],
          before_claim: &Apiary.ModelKeysFixtures.key_state!(&1, "spare", until: until)
        )

      document = document(ctx)
      p = ctx.provider.public_id
      at = DateTime.to_iso8601(until)

      assert [start, cooling] = Jason.decode!(document)["credentials"]
      assert start["name"] == "#{p}-1"
      refute Map.has_key?(start, "cooldown_until")
      refute Map.has_key?(start, "chosen")

      assert Map.take(cooling, ~w(name resets_at cooldown_until chosen pause_for_s)) == %{
               "name" => "#{p}-2",
               "resets_at" => at,
               "cooldown_until" => at,
               "pause_for_s" => 60
             }

      assert Jason.decode!(document)["default_model_provider_credential_name"] == "#{p}-1"
      assert Apiary.Policy.Schema.validate(document) == :ok
      assert Apiary.ForagerSchemas.validate("run-configuration.schema.json", document) == :ok
      refute document =~ model_key()
      refute document =~ "sk-ant-spare"
    end
  end

  describe "the provider's hosts and the deny list" do
    setup do
      %{scope: scope} = sign_up_fixture()
      {:ok, _rule} = Policy.allow(scope, nil, %{host: "git.example"})
      %{scope: scope}
    end

    test "an exact deny of a provider's host stays in the deny, and allow_first lists the host",
         %{scope: scope} do
      # A runtime's host refuses this deny: here the host is the provider's alone.
      no_runtime_hosts!()
      {:ok, _rule} = Policy.deny(scope, nil, %{host: "api.anthropic.com"})
      {:ok, _rule} = Policy.deny(scope, nil, %{host: "tracker.example"})
      ctx = sealed_run_fixture(scope)

      egress = Jason.decode!(document(ctx))["security_policy"]["egress"]
      assert egress["allow"] == ["git.example", "api.anthropic.com"]
      assert egress["allow_first"] == ["api.anthropic.com"]
      assert egress["deny"] == ["api.anthropic.com", "tracker.example"]
      assert Apiary.Policy.Schema.validate(document(ctx)) == :ok
    end

    test "a saved deny of a host both a runtime and the provider need leaves the deny",
         %{scope: scope} do
      # Inserted past the writes, which refuse it: the rule was saved before the host
      # became a runtime's. The vendored catalogue applies, with no stub.
      Repo.insert!(%Rule{
        organisation_id: scope.organisation.id,
        workspace_id: scope.workspace.id,
        kind: "host",
        action: "deny",
        host: "api.anthropic.com",
        locked: false
      })

      {:ok, _rule} = Policy.deny(scope, nil, %{host: "tracker.example"})
      ctx = sealed_run_fixture(scope)

      egress = Jason.decode!(document(ctx))["security_policy"]["egress"]
      assert egress["allow"] == ["git.example", "api.anthropic.com"]
      assert egress["allow_first"] == ["api.anthropic.com"]
      assert egress["deny"] == ["tracker.example"]
      assert Apiary.Policy.Schema.validate(document(ctx)) == :ok
    end

    test "a `*.` deny that covers a provider's host stays in the deny", %{scope: scope} do
      {:ok, _rule} = Policy.deny(scope, nil, %{host: "*.anthropic.com"})
      ctx = sealed_run_fixture(scope)

      egress = Jason.decode!(document(ctx))["security_policy"]["egress"]
      assert egress["allow"] == ["git.example", "api.anthropic.com"]
      assert egress["allow_first"] == ["api.anthropic.com"]
      assert egress["deny"] == ["*.anthropic.com"]
    end

    test "the provider's hosts join the workspace's allow_first, sorted, each once",
         %{scope: scope} do
      integration!(scope, "acme-tracker", ["zeta.example.com", "api.anthropic.com"])
      ctx = sealed_run_fixture(scope)
      document = document(ctx)

      egress = Jason.decode!(document, objects: :ordered_objects)["security_policy"]["egress"]
      assert Enum.map(egress.values, &elem(&1, 0)) == ~w(mode allow allow_first)

      egress = Jason.decode!(document)["security_policy"]["egress"]
      assert egress["allow"] == ["git.example", "api.anthropic.com"]
      assert egress["allow_first"] == ["api.anthropic.com", "zeta.example.com"]
      assert Apiary.Policy.Schema.validate(document) == :ok
      assert Apiary.ForagerSchemas.validate("run-configuration.schema.json", document) == :ok
      assert {:ok, %{settings: ^document}} = reload(ctx)
    end

    test "more than 64 entries leave the run without a run configuration", %{scope: scope} do
      # The provider's host is the entry that overflows: here it is no runtime's.
      no_runtime_hosts!()
      ctx = sealed_run_fixture(scope)
      integration!(scope, "acme-tracker", for(n <- 1..64, do: "host#{n}.example.com"))

      {answer, log} = with_log(fn -> reload(ctx) end)
      assert answer == {:error, :unavailable}
      assert log =~ "its allow_first would have 65 hosts, more than the 64 the contract takes"

      {:ok, configuration} = Policy.current_configuration(scope, nil)
      assert ComposedConfiguration.run_digest(configuration, ctx.run) == nil
    end
  end

  describe "a run of a workspace that serves no policy" do
    test "is given the credential and its variables in the document of no policy, with no hosts" do
      %{scope: scope} = sign_up_fixture()
      no_policy_version!(scope.workspace)
      ctx = sealed_run_fixture(scope)
      document = document(ctx)

      assert ctx.attached.digest == sha256(document)

      assert document
             |> Jason.decode!(objects: :ordered_objects)
             |> Map.get(:values)
             |> Enum.map(&elem(&1, 0)) ==
               ~w(version variables credentials default_model_provider_credential_name)

      assert Apiary.Policy.Schema.validate(document) == :ok
      assert {:ok, %{settings: ^document, digest: digest}} = reload(Map.put(ctx, :scope, scope))
      assert digest == ctx.attached.digest
    end
  end

  describe "a setting's host" do
    test "is the host of the address the run's API takes its endpoint from" do
      %{scope: scope} = sign_up_fixture()

      {:ok, litellm} =
        Connections.create_provider(scope, %{
          provider: "litellm",
          settings: %{"address" => "https://litellm.example.com"},
          keys: [%{value_id: "main", value: "sk-team"}]
        })

      key = %ModelKey{
        position: 1,
        name: "model-1",
        start: true,
        secret_value_id: Ecto.UUID.generate(),
        connection_id: litellm.id,
        secret_id: litellm.secret_id,
        chain: "organisation",
        api: %{
          "format" => "anthropic-messages",
          "endpoint" => "https://litellm.example.com",
          "auth" => %{"scheme" => "bearer"}
        },
        pause_for_s: 60
      }

      run = %{provider_connection_id: litellm.id, model_keys: [key]}

      assert {:ok, %{hosts: ["litellm.example.com"], keys: [%{entry: entry}]}} =
               ProviderCredential.for_run(run)

      assert Jason.encode!(entry) ==
               ~s({"name":"model-1","group":"#{litellm.public_id}",) <>
                 ~s("format":"anthropic-messages",) <>
                 ~s("endpoint":"https://litellm.example.com","auth":{"scheme":"bearer"},) <>
                 ~s("pause_for_s":60})
    end
  end

  describe "which gateway a model key may be sealed for" do
    # `sealable_to?/3` by the gateway's level: the instance's gateway and a gateway of the
    # run's organisation get a key of the organisation's chain; nothing else does.
    setup do
      %{scope: scope} = sign_up_fixture()
      %{scope: stranger} = sign_up_fixture()

      %{
        scope: scope,
        instance_gateway: instance_gateway_fixture(),
        organisation_gateway: organisation_gateway_fixture(scope),
        workspace_gateway: gateway_fixture(scope),
        stranger_gateway: organisation_gateway_fixture(stranger)
      }
    end

    test "the instance's gateway gets a key of the organisation's chain of any organisation",
         ctx do
      %{scope: other} = sign_up_fixture()

      for scope <- [ctx.scope, other] do
        assert ProviderCredential.sealable_to?(
                 "organisation",
                 ctx.instance_gateway,
                 run_in(scope)
               )
      end
    end

    test "a gateway of the run's organisation gets a key of the organisation's chain", ctx do
      for gateway <- [ctx.organisation_gateway, ctx.workspace_gateway] do
        assert ProviderCredential.sealable_to?("organisation", gateway, run_in(ctx.scope))
      end
    end

    test "a gateway of another organisation gets no key", ctx do
      refute ProviderCredential.sealable_to?(
               "organisation",
               ctx.stranger_gateway,
               run_in(ctx.scope)
             )
    end

    test "no gateway gets a key of a chain other than the organisation's", ctx do
      for gateway <- [
            ctx.instance_gateway,
            ctx.organisation_gateway,
            ctx.workspace_gateway,
            ctx.stranger_gateway
          ] do
        refute ProviderCredential.sealable_to?("operator", gateway, run_in(ctx.scope))
      end
    end

    test "a gateway made in a workspace gets a key of a run of that workspace alone", ctx do
      other = workspace_fixture(ctx.scope.organisation, "Other")
      assert is_binary(ctx.workspace_gateway.workspace_id)

      assert ProviderCredential.sealable_to?(
               "organisation",
               ctx.workspace_gateway,
               run_in(ctx.scope)
             )

      refute ProviderCredential.sealable_to?("organisation", ctx.workspace_gateway, %{
               organisation_id: ctx.scope.organisation.id,
               workspace_id: other.id
             })
    end

    test "a node that is not a gateway gets no key", ctx do
      pool = instance_pool_fixture()

      for chain <- ["organisation", "operator"] do
        refute ProviderCredential.sealable_to?(chain, pool, run_in(ctx.scope))
      end
    end

    test "no gateway gets a key for a run without a workspace id", ctx do
      without = %{organisation_id: ctx.scope.organisation.id}

      for gateway <- [ctx.instance_gateway, ctx.organisation_gateway, ctx.workspace_gateway] do
        refute ProviderCredential.sealable_to?("organisation", gateway, without)
      end
    end

    # The place of a run in the scope's workspace.
    defp run_in(scope),
      do: %{organisation_id: scope.organisation.id, workspace_id: scope.workspace.id}
  end
end
