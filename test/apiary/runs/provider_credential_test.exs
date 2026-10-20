defmodule Apiary.Runs.ProviderCredentialTest do
  # A run the handover set a model provider for receives its model key's credential in its
  # run configuration, and the provider's hosts in its allow list and its allow_first list
  # (`Apiary.Runs.ProviderCredential`, `Apiary.Policy.ComposedConfiguration`); every digest
  # sent for it is the SHA-256 of the bytes sent.
  use Apiary.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog, only: [with_log: 1]
  import Apiary.ConnectionsFixtures, only: [ready_release!: 3]
  import Apiary.DescriptionFixtures, only: [tracker_description: 1]
  import Apiary.OrganisationsFixtures
  import Apiary.SealedRunsFixtures

  alias Apiary.{Connections, Policy, Repo}
  alias Apiary.Connections.Connection
  alias Apiary.Policy.{ComposedConfiguration, Render}
  alias Apiary.Runs.{ProviderCredential, Registration, Run}

  @moduletag needs: :factory

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
      assert names == ~w(version security_policy variables credentials model_credential)

      name = ctx.provider.public_id
      assert name =~ ~r/\A[a-z0-9][a-z0-9_.-]{0,63}\z/

      assert Jason.decode!(document)["credentials"] == [
               %{
                 "name" => name,
                 "format" => "anthropic-messages",
                 "endpoint" => "https://api.anthropic.com",
                 "auth" => %{"scheme" => "header", "header" => "x-api-key"}
               }
             ]

      assert Jason.decode!(document)["model_credential"] == name

      assert Jason.decode!(document)["security_policy"]["egress"]["allow"] ==
               ["git.example", "api.anthropic.com"]

      assert Jason.decode!(document)["security_policy"]["egress"]["allow_first"] ==
               ["api.anthropic.com"]

      assert Apiary.Policy.Schema.validate(document) == :ok
      assert Apiary.ForagerSchemas.validate("run-configuration.schema.json", document) == :ok

      # No key, no secret id, no value id.
      refute document =~ model_key()
      refute document =~ Repo.get!(Apiary.Secrets.Secret, ctx.run.provider_secret_id).public_id
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

    test "every run of the provider is given the same name", ctx do
      %{run: run} = ctx
      {:ok, credential} = ProviderCredential.for_run(run)
      {:ok, again} = ProviderCredential.for_run(%{run | id: Ecto.UUID.generate()})
      assert credential.name == again.name
      assert credential.name == ctx.provider.public_id
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
      {1, _rows} =
        Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id),
          set: [provider_connection_id: nil]
        )

      {answer, _log} = with_log(fn -> reload(ctx) end)
      assert answer == {:error, :unavailable}
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
      {:ok, _rule} = Policy.deny(scope, nil, %{host: "api.anthropic.com"})
      {:ok, _rule} = Policy.deny(scope, nil, %{host: "tracker.example"})
      ctx = sealed_run_fixture(scope)

      egress = Jason.decode!(document(ctx))["security_policy"]["egress"]
      assert egress["allow"] == ["git.example", "api.anthropic.com"]
      assert egress["allow_first"] == ["api.anthropic.com"]
      assert egress["deny"] == ["api.anthropic.com", "tracker.example"]
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
      ctx = sealed_run_fixture(scope)
      document = document(ctx)

      assert ctx.attached.digest == sha256(document)

      assert document
             |> Jason.decode!(objects: :ordered_objects)
             |> Map.get(:values)
             |> Enum.map(&elem(&1, 0)) == ~w(version variables credentials model_credential)

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

      run = %{
        provider_connection_id: litellm.id,
        provider_api: %{
          "format" => "anthropic-messages",
          "endpoint" => "https://litellm.example.com",
          "auth" => %{"scheme" => "bearer"}
        }
      }

      assert {:ok, %{hosts: ["litellm.example.com"], entry: entry}} =
               ProviderCredential.for_run(run)

      assert Jason.encode!(entry) ==
               ~s({"name":"#{litellm.public_id}","format":"anthropic-messages",) <>
                 ~s("endpoint":"https://litellm.example.com","auth":{"scheme":"bearer"}})
    end
  end
end
