defmodule ApiaryWeb.Contract.PrebuildPolicyTest do
  # A prebuild of a workspace that serves no run configuration: its attach and its
  # reloads give it the workspace's default policy, the mode `observe`, no rules and the
  # hosts the integrations reaching the workspace require, composed with the registry's
  # path rules and credential; never the document of no policy, which would leave the
  # machine's local policy in force. Every other run of the workspace is given the
  # document of no policy as before. Not async: the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Apiary.ConnectionsFixtures
  import Apiary.ContractFixtures
  import Apiary.DescriptionFixtures
  import Apiary.DispatchedRunsFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Connections, Dispatches, Policy, Registry, Repo}
  alias Apiary.Policy.{ComposedConfiguration, Render}
  alias Apiary.Registry.{Credential, RunAccess}
  alias Apiary.Runs.{Attach, Registration, Run}

  @moduletag needs: [:factory, :security, :secrets, :registry]

  # The integration's hosts: `api.tracker.example`, or `@tag hosts:`.
  setup ctx do
    %{scope: scope} = sign_up_fixture()
    connection!(scope, "acme-tracker", ctx[:hosts] || ["api.tracker.example"])
    refute Policy.managed?(scope)
    Map.put(handover_place_fixture(scope), :scope, scope)
  end

  # An integration connection of the organisation, reaching every workspace, whose
  # release requires `hosts`. A write to it renders no document for a workspace that
  # serves none (`Apiary.Policy.rerender_in/3`).
  defp connection!(scope, name, hosts) do
    description =
      tracker_description(%{
        "name" => name,
        "settings" => %{
          "type" => "object",
          "properties" => %{"address" => %{"title" => "Address", "type" => "string"}}
        },
        "egress_hosts" => hosts
      })

    release = ready_release!(scope, description, "codeberg.org/acme/#{name}")
    {:ok, connection} = Connections.create_integration(scope, release.id, %{})
    connection
  end

  # The run of the queue the pool's next claim takes, its machine started, its run code
  # redeemed and its attach answered: the registered run and the attach's answer.
  defp attached!(ctx) do
    %{registered: registered, run_code: code} = dispatched!(ctx.key)
    {:ok, attach} = Attach.parse(attach_body(redeemed_run_key!(code)))
    {key, _seed} = ctx.gateway_key

    {:ok, answer} =
      Attach.attach(key, registered.node_run_id, attach, %{
        forager_version: "0.7.0",
        instance_id: instance_id()
      })

    {Repo.get!(Run, registered.id), answer}
  end

  defp prebuild!(ctx) do
    collection = Apiary.NodesFixtures.collection_fixture(ctx.scope)
    [_queued] = queue_builds!(collection)
    attached!(ctx)
  end

  defp reload!(ctx, run) do
    {key, _seed} = ctx.gateway_key
    {:ok, settings} = Registration.fetch(key, run.node_run_id, instance_id())
    settings
  end

  describe "a prebuild of a workspace that serves no run configuration" do
    test "is given the default policy in observe, with the required hosts, the registry's path rules and credential, and no model credential",
         ctx do
      {run, answer} = prebuild!(ctx)
      document = Jason.decode!(answer.settings)
      egress = document["security_policy"]["egress"]

      assert egress["mode"] == "observe"
      # The integration's host, which the default render keeps in allow_first alone.
      assert "api.tracker.example" in egress["allow_first"]
      refute "api.tracker.example" in egress["allow"]
      assert Registry.host() in egress["allow"]
      assert egress["paths"][Registry.host()] == RunAccess.member(run).paths
      assert egress["paths"][RunAccess.instance_host()] == [RunAccess.token_path()]
      assert egress["deny"] in [nil, []]

      assert [%{"name" => name}] = document["credentials"]
      assert name == Credential.name()
      refute Map.has_key?(document, "model_credential")
      refute Map.has_key?(document, "image")

      # Kept as composed from no run configuration, under the digest of its bytes, and
      # the workspace still serves none.
      assert [%ComposedConfiguration{run_configuration_id: nil, image: nil} = row] =
               Repo.all(
                 from c in ComposedConfiguration,
                   where: c.workspace_id == ^ctx.scope.workspace.id and c.digest == ^answer.digest
               )

      assert answer.digest == Render.digest(row.document)
      assert Policy.valid_document(row.document) == :ok

      refute Policy.managed?(ctx.scope)
    end

    test "is given the same document and digest on its reloads", ctx do
      {run, answer} = prebuild!(ctx)

      reloaded = reload!(ctx, run)
      assert reloaded.digest == answer.digest
      assert Render.digest(reloaded.settings) == answer.digest
      assert Jason.decode!(reloaded.settings)["security_policy"]["egress"]["mode"] == "observe"
      assert reload!(ctx, run).digest == answer.digest
    end

    # 64 hosts: the default policy's allow_first takes them, and the registry's two hosts
    # make 66, more than the contract takes.
    @tag hosts: for(n <- 1..64, do: "h#{n}.tracker.example")
    test "whose document cannot be composed is refused its attach, never sent without a security_policy",
         ctx do
      {:ok, document} = Policy.default_document(ctx.scope.workspace.id)
      assert length(Jason.decode!(document)["security_policy"]["egress"]["allow_first"]) == 64

      collection = Apiary.NodesFixtures.collection_fixture(ctx.scope)
      [_queued] = queue_builds!(collection)
      %{registered: registered, run_code: code} = dispatched!(ctx.key)
      {:ok, attach} = Attach.parse(attach_body(redeemed_run_key!(code)))
      {key, _seed} = ctx.gateway_key

      {result, log} =
        ExUnit.CaptureLog.with_log(fn ->
          Attach.attach(key, registered.node_run_id, attach, %{
            forager_version: "0.7.0",
            instance_id: instance_id()
          })
        end)

      assert result == {:error, :unavailable}
      assert log =~ "its allow_first would have 66 hosts"
      assert %Run{attached_at: nil, attach_answer_digest: nil} = Repo.get!(Run, registered.id)
    end

    test "names no version: its digest is not read as the document of no policy", ctx do
      {_run, answer} = prebuild!(ctx)

      assert ComposedConfiguration.policy_digests(ctx.scope.workspace.id, [answer.digest]) ==
               %{}

      assert Policy.policy_digest(ctx.scope, answer.digest) == answer.digest
    end
  end

  test "an explore run of the workspace is given the document of no policy, with its members",
       ctx do
    work_item = work_item_fixture(ctx.scope)
    {:ok, _queued} = Repo.transact(fn -> Dispatches.queue(work_item, 1) end)
    {_run, answer} = attached!(ctx)
    document = Jason.decode!(answer.settings)

    assert document["version"] == 1
    refute Map.has_key?(document, "security_policy")

    no_policy = Render.digest(Render.no_policy_document())

    assert ComposedConfiguration.policy_digests(ctx.scope.workspace.id, [answer.digest]) ==
             %{answer.digest => no_policy}
  end
end
