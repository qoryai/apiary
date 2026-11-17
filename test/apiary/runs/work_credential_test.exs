defmodule Apiary.Runs.WorkCredentialTest do
  # The parts of a run's work credential that need no call (`Apiary.Runs.WorkCredential`):
  # the sealed value a checked answer makes, against Forager's known answer, vendored
  # under test/fixtures/forager-contract/, and which gateways it may be sealed for.
  # The call, its refusals and its Activity entries are
  # `ApiaryWeb.Contract.SecretsControllerTest`'s.
  use ExUnit.Case, async: true

  alias Apiary.Nodes.Node
  alias Apiary.Runs.{RunCredentialIssue, WorkCredential}
  alias Apiary.Secrets.Sealing

  @dir Path.expand("../../fixtures/forager-contract/sealed", __DIR__)

  test "a checked answer makes the value of Forager's known answer, byte for byte" do
    bytes = File.read!(Path.join(@dir, "sealed-plaintext.json"))
    fixture = Jason.decode!(bytes)
    [forge, model] = fixture["values"]

    entry = %{"name" => "forge", "purpose" => "work", "apply" => forge["apply"]}

    answer = %{
      "version" => 1,
      "token" => forge["value"],
      "expires_at" => forge["expires_at"],
      "apply" => forge["apply"]
    }

    {:ok, now, 0} = DateTime.from_iso8601("2026-10-24T12:00:00Z")
    assert {:ok, issued} = RunCredentialIssue.check(entry, answer, now)
    value = WorkCredential.value("forge", issued)
    assert value == forge

    plaintext = %{fixture | "values" => [value, model]}
    assert Sealing.plaintext(plaintext, fixture["run_configuration"]) == {:ok, bytes}
  end

  test "a value with no expiry has no expires_at" do
    entry = %{"apply" => [%{"hosts" => ["git.example"], "scheme" => "bearer"}]}
    answer = %{"version" => 1, "token" => "fixture-token", "apply" => entry["apply"]}
    assert {:ok, issued} = RunCredentialIssue.check(entry, answer, DateTime.utc_now())

    assert WorkCredential.value("work-1", issued) == %{
             "credential" => "work-1",
             "value" => "fixture-token",
             "apply" => entry["apply"]
           }
  end

  test "the value of a write entry's credential has the entry's push_ref on each item" do
    branch = "refs/heads/qory/wi_0123456789abcdef"
    item = %{"hosts" => ["git.example"], "scheme" => "bearer"}
    entry = %{"apply" => [Map.put(item, "push_ref", branch)]}
    answer = %{"version" => 1, "token" => "fixture-token", "apply" => [item]}
    assert {:ok, issued} = RunCredentialIssue.check(entry, answer, DateTime.utc_now())

    assert WorkCredential.value("work-1", issued) == %{
             "credential" => "work-1",
             "value" => "fixture-token",
             "apply" => [Map.put(item, "push_ref", branch)]
           }
  end

  describe "sealable_to?/2" do
    @run_organisation Ecto.UUID.generate()
    @run %{organisation_id: @run_organisation, workspace_id: Ecto.UUID.generate()}

    test "a gateway of the run's organisation, at the run's workspace or the organisation" do
      for workspace_id <- [@run.workspace_id, nil] do
        gateway = %Node{
          kind: :gateway,
          organisation_id: @run_organisation,
          workspace_id: workspace_id
        }

        assert WorkCredential.sealable_to?(gateway, @run)
      end
    end

    test "not a gateway of the run's organisation made in another of its workspaces" do
      gateway = %Node{
        kind: :gateway,
        organisation_id: @run_organisation,
        workspace_id: Ecto.UUID.generate()
      }

      refute WorkCredential.sealable_to?(gateway, @run)
    end

    test "the instance's gateway" do
      gateway = %Node{kind: :gateway, organisation_id: nil, workspace_id: nil}
      assert WorkCredential.sealable_to?(gateway, @run)
    end

    test "not a gateway of another organisation, nor another node" do
      refute WorkCredential.sealable_to?(
               %Node{kind: :gateway, organisation_id: Ecto.UUID.generate()},
               @run
             )

      refute WorkCredential.sealable_to?(
               %Node{kind: :pool, organisation_id: @run_organisation},
               @run
             )
    end

    test "no gateway for a run without a workspace id" do
      without = %{organisation_id: @run_organisation}

      for gateway <- [
            %Node{kind: :gateway, organisation_id: nil, workspace_id: nil},
            %Node{kind: :gateway, organisation_id: @run_organisation, workspace_id: nil}
          ] do
        refute WorkCredential.sealable_to?(gateway, without)
      end
    end
  end
end
