defmodule Apiary.Policy.SuggestionCountsTest do
  use Apiary.DataCase, async: true

  # The security policy: left out of a run without the security feature.
  @moduletag needs: :security

  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures
  import Apiary.RunListFixtures

  alias Apiary.Policy
  alias Apiary.Runs.Target

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope}
  end

  describe "suggestion_counts/2" do
    test "counts the open declared hosts across the workspace's targets, bounded", %{scope: scope} do
      assert %{hosts: 0, targets: 0} = Policy.suggestion_counts(scope)

      shop = started_run(scope, shop())
      docs = started_run(scope, %{"forge" => "github.example", "repository" => "acme/docs"})

      event_fixture(shop, 10, "run.policy_applied", %{
        "harness_hosts" => ["api.example", "registry.example", "NOT A HOST"]
      })

      event_fixture(shop, 11, "run.policy_applied", %{"harness_hosts" => ["registry.example"]})
      event_fixture(docs, 10, "run.policy_applied", %{"harness_hosts" => ["docs.s.example"]})
      # A run without a target declares nothing anybody could allow for it.
      plain = started_run(scope, %{})
      event_fixture(plain, 10, "run.policy_applied", %{"harness_hosts" => ["plain.example"]})

      assert %{hosts: 3, targets: 2} = Policy.suggestion_counts(scope)

      {:ok, _} = Policy.allow(scope, nil, %{host: "api.example"})
      assert %{hosts: 2, targets: 2} = Policy.suggestion_counts(scope)

      target = Repo.get!(Target, docs.target_id)
      {:ok, _} = Policy.allow(scope, target, %{host: "*.s.example"})
      assert %{hosts: 1, targets: 1} = Policy.suggestion_counts(scope)

      {:ok, _} = Policy.deny(scope, nil, %{host: "registry.example"})
      assert %{hosts: 0, targets: 0} = Policy.suggestion_counts(scope)

      # Nothing older than since, and another workspace counts nothing of this one.
      {:ok, _} =
        Policy.remove_rule(
          scope,
          Enum.find(Policy.list_rules(scope, nil), &(&1.host == "registry.example"))
        )

      assert %{hosts: 1} = Policy.suggestion_counts(scope)
      future = DateTime.add(DateTime.utc_now(), 60, :second)
      assert %{hosts: 0, targets: 0} = Policy.suggestion_counts(scope, future)
      %{scope: other} = sign_up_fixture()
      assert %{hosts: 0, targets: 0} = Policy.suggestion_counts(other)
    end
  end

  describe "what the edition leaves out" do
    test "the core leaves the declared hosts as they are; an edition narrows each read", %{
      scope: scope
    } do
      shop = started_run(scope, shop())
      event_fixture(shop, 10, "run.policy_applied", %{"harness_hosts" => ["api.example"]})
      target = Repo.get!(Target, shop.target_id)

      assert %{hosts: 1, targets: 1} = Policy.suggestion_counts(scope)

      assert [%{host: "api.example", runs: 1, allowed: 0, denied: 0}] =
               Policy.suggestions(scope, target)

      :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.HidesRuns)

      assert %{hosts: 0, targets: 0} = Policy.suggestion_counts(scope)
      assert %{suggested: [], covered: []} = Policy.declared_hosts(scope, target)
    end
  end
end
