defmodule Apiary.Runs.RegistrationWithoutSecurityTest do
  # A registration and a reload on an instance without the security feature. The features
  # are the node's, so this module is not async.
  use Apiary.DataCase, async: false

  import Apiary.ContractFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Policy.{Render, RunConfiguration}
  alias Apiary.Runs.{Registration, Run}

  @no_policy ~s({"version":1})

  @tag with_features: [:observability]
  test "a managed workspace's run is given no policy, and created; its reload is not found" do
    %{scope: scope} = sign_up_fixture()
    %{access_key: key} = contract_key_fixture(scope)

    # The workspace's policy was made while the feature was on: its baseline is stored.
    document =
      ~s({"version":1,"security_policy":{"version":1,"egress":{"mode":"enforce","allow":[]}}})

    Repo.insert!(%RunConfiguration{
      organisation_id: scope.organisation.id,
      workspace_id: scope.workspace.id,
      version: 1,
      document: document,
      digest: Render.digest(document),
      rendered_at: DateTime.utc_now()
    })

    run_id = Ecto.UUID.generate()

    bytes =
      Jason.encode!(%{
        "version" => 1,
        "run_id" => run_id,
        "time" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "forager_version" => "0.8.0",
        "contract_version" => 1,
        "interval_seconds" => 30,
        "events" => ["*"]
      })

    {:ok, registration} = Registration.parse(Jason.decode!(bytes))
    meta = %{body: bytes, contract_version: 1, instance_id: "i_one"}

    assert {:ok, %{settings: @no_policy, digest: digest, managed: false, run: %Run{}}} =
             Registration.register(key, registration, meta)

    assert digest == Render.digest(@no_policy)
    assert [%Run{run_id: ^run_id}] = Repo.all(Run)

    assert Registration.fetch(key, run_id) == {:error, :not_found}
  end
end
