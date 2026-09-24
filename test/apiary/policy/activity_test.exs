defmodule Apiary.Policy.ActivityTest do
  # Not async: one test sets the cap in the application environment, which is global.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures
  import Apiary.RunListFixtures

  alias Apiary.Policy
  alias Apiary.Policy.Activity
  alias Apiary.Runs.Target

  @site %{"forge" => "github.example", "repository" => "acme/site"}
  @docs %{"forge" => "github.example", "repository" => "acme/docs"}

  defp allowed(host, extra \\ %{}),
    do: Map.merge(%{"host" => host, "decision" => "allowed"}, extra)

  defp denied(host, extra \\ %{}), do: Map.merge(%{"host" => host, "decision" => "denied"}, extra)
  defp since, do: DateTime.add(DateTime.utc_now(), -7, :day)

  setup do
    %{scope: scope} = sign_up_fixture()

    site =
      started_run(scope, @site,
        egress: [
          allowed("api.example"),
          allowed("api.example"),
          allowed("x.cdn.example"),
          allowed("new.example"),
          allowed("git.example", %{"path" => "/acme/site.git/info/refs"}),
          allowed("git.example", %{"path" => "/acme/site.git/git-receive-pack"}),
          denied("ads.example"),
          denied("ads.example"),
          denied("mcp.example")
        ]
      )

    docs = started_run(scope, @docs, egress: [allowed("new.example"), allowed("mcp.example")])
    _plain = started_run(scope, %{}, egress: [allowed("new.example"), denied("other.example")])

    target = Repo.get!(Target, site.target_id)
    {:ok, api} = Policy.allow(scope, nil, %{host: "api.example"})
    {:ok, cdn} = Policy.allow(scope, nil, %{host: "*.cdn.example"})
    {:ok, ads} = Policy.deny(scope, nil, %{host: "ads.example"})

    {:ok, git} =
      Policy.allow(scope, nil, %{host: "git.example", paths: ["/acme/site.git/info/refs"]})

    {:ok, mcp} = Policy.allow(scope, target, %{host: "mcp.example"})

    %{scope: scope, target: target, docs: Repo.get!(Target, docs.target_id)}
    |> Map.merge(%{api: api, cdn: cdn, ads: ads, git: git, mcp: mcp})
  end

  describe "uncovered/2" do
    test "what was let through and no rule of the run's target covers, most attempts first",
         ctx do
      assert {:ok, [new, push, mcp]} = Policy.uncovered(ctx.scope, since())

      assert %{host: "new.example", path: nil, attempts: 3, runs: 3, last_seen_at: %DateTime{}} =
               new

      assert Enum.map(new.targets, & &1.path) == ["acme/docs", "acme/site"]

      # A host held to paths: the path no entry matches is the destination.
      assert %{host: "git.example", path: "/acme/site.git/git-receive-pack", attempts: 1} = push

      # Allowed in acme/site by its own rule, uncovered in acme/docs.
      assert %{host: "mcp.example", runs: 1, targets: [%{path: "acme/docs"}]} = mcp
    end

    test "nothing older than since, and :unavailable beyond the cap", ctx do
      assert {:ok, []} =
               Policy.uncovered(ctx.scope, DateTime.add(DateTime.utc_now(), 60, :second))

      assert :unavailable = Activity.uncovered(ctx.scope, nil, since(), cap: 3)
      assert :unavailable = Activity.denied_summary(ctx.scope, since(), cap: 3)
      assert :unavailable = Activity.rule_activity(ctx.scope, nil, since(), cap: 3)
      assert {:ok, [_ | _]} = Activity.uncovered(ctx.scope, nil, since(), cap: 100)
    end
  end

  describe "denied_destinations/2" do
    test "the denied destinations today's rules still do not allow, most denied first", ctx do
      # ads.example is denied by a hive rule; mcp.example is allowed in acme/site by its
      # own rule, so its denial is a fact of the past; other.example has no rule.
      assert {:ok, [ads, other]} = Policy.denied_destinations(ctx.scope, since())

      assert %{host: "ads.example", port: 443, path: "", denied: 2, runs: 1, held: false} = ads
      assert ads.locked == nil
      assert Enum.map(ads.targets, & &1.path) == ["acme/site"]
      assert %{host: "other.example", denied: 1, runs: 1, targets: []} = other

      # A locked deny is named, so the page can say that only an owner changes it.
      {:ok, _} = Policy.lock(ctx.scope, ctx.ads)

      assert {:ok, [%{host: "ads.example", locked: "ads.example"} | _]} =
               Policy.denied_destinations(ctx.scope, since())

      # Allowed since: the row leaves.
      {:ok, _} = Policy.allow(ctx.scope, nil, %{host: "other.example"})
      assert {:ok, [%{host: "ads.example"}]} = Policy.denied_destinations(ctx.scope, since())

      assert {:ok, []} =
               Policy.denied_destinations(
                 ctx.scope,
                 DateTime.add(DateTime.utc_now(), 60, :second)
               )

      assert :unavailable = Activity.denied_destinations(ctx.scope, since(), cap: 3)
    end
  end

  describe "uncovered and a target's own mode" do
    test "the hive's form leaves out a target that does not follow the hive", ctx do
      {:ok, _} = Policy.set_mode(ctx.scope, ctx.docs, "observe")

      assert {:ok, [new, push]} = Policy.uncovered(ctx.scope, since())
      # acme/docs reached new.example and mcp.example; enforcing the hive changes neither.
      assert %{host: "new.example", attempts: 2, runs: 2} = new
      assert Enum.map(new.targets, & &1.path) == ["acme/site"]
      assert push.host == "git.example"

      assert {:ok, same} = Policy.uncovered(ctx.scope, nil, since())
      assert same == [new, push]

      {:ok, _} = Policy.set_mode(ctx.scope, ctx.docs, :inherit)
      assert {:ok, [_, _, %{host: "mcp.example"}]} = Policy.uncovered(ctx.scope, since())
    end

    test "a target's form is its own runs under its own rules, whatever its mode", ctx do
      for mode <- ["observe", "enforce", :inherit] do
        {:ok, _} = Policy.set_mode(ctx.scope, ctx.docs, mode)

        assert {:ok, [%{host: "mcp.example", attempts: 1}, %{host: "new.example", attempts: 1}]} =
                 Policy.uncovered(ctx.scope, ctx.docs, since())
      end

      # mcp.example is allowed in acme/site by its own rule.
      assert {:ok,
              [
                %{host: "git.example", path: "/acme/site.git/git-receive-pack"},
                %{host: "new.example"}
              ]} =
               Policy.uncovered(ctx.scope, ctx.target, since())
    end

    test "another hive's target has nothing", ctx do
      %{scope: other} = sign_up_fixture()
      assert {:ok, []} = Policy.uncovered(other, ctx.target, since())
    end
  end

  test "the cap is the configuration's at each call, so a page can be shown a hive over it",
       ctx do
    assert Activity.cap() == 20_000
    previous = Application.get_env(:apiary, Activity)
    Application.put_env(:apiary, Activity, cap: 3)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:apiary, Activity, previous),
        else: Application.delete_env(:apiary, Activity)
    end)

    assert Activity.cap() == 3
    assert :unavailable = Policy.uncovered(ctx.scope, since())
    assert :unavailable = Policy.denied_summary(ctx.scope, since())
    assert :unavailable = Policy.rule_activity(ctx.scope, nil, since())
  end

  test "denied_summary/2: the attempts denied and their destinations", ctx do
    assert {:ok, %{denied: 4, destinations: 3}} = Policy.denied_summary(ctx.scope, since())
  end

  describe "rule_activity/3" do
    test "counts each connection on the rule the runner would report", ctx do
      assert {:ok, counts} = Policy.rule_activity(ctx.scope, nil, since())

      assert counts[ctx.api.id] == %{allowed: 2, denied: 0}
      assert counts[ctx.cdn.id] == %{allowed: 1, denied: 0}
      assert counts[ctx.git.id] == %{allowed: 2, denied: 0}
      assert counts[ctx.ads.id] == %{allowed: 0, denied: 2}
      # The target's rule decided its run's connection; the other target's had none.
      assert counts[ctx.mcp.id] == %{allowed: 0, denied: 1}
      assert map_size(counts) == 5
    end

    test "a target's page reads its own runs, and names the hive's rules that decided", ctx do
      assert {:ok, counts} = Policy.rule_activity(ctx.scope, ctx.docs, since())
      assert counts == %{}

      assert {:ok, counts} = Policy.rule_activity(ctx.scope, ctx.target, since())
      assert counts[ctx.api.id] == %{allowed: 2, denied: 0}
      assert counts[ctx.mcp.id] == %{allowed: 0, denied: 1}
    end

    test "a host a deny covers is counted on the deny, decided before the suffix that allows it",
         ctx do
      {:ok, deny} = Policy.deny(ctx.scope, nil, %{host: "x.cdn.example"})
      assert {:ok, counts} = Policy.rule_activity(ctx.scope, nil, since())
      # The record says the old runner let it through; the rule it is counted on is the deny.
      assert counts[deny.id] == %{allowed: 1, denied: 0}
      refute Map.has_key?(counts, ctx.cdn.id)

      # Denied in either mode already: enforcing would not start denying it.
      assert {:ok, uncovered} = Policy.uncovered(ctx.scope, since())
      refute Enum.any?(uncovered, &(&1.host == "x.cdn.example"))
      assert Enum.any?(uncovered, &(&1.host == "new.example"))
    end

    test "an exact name is reported before the suffix that also matches", ctx do
      {:ok, exact} = Policy.allow(ctx.scope, nil, %{host: "x.cdn.example"})
      assert {:ok, counts} = Policy.rule_activity(ctx.scope, nil, since())
      assert counts[exact.id] == %{allowed: 1, denied: 0}
      refute Map.has_key?(counts, ctx.cdn.id)
    end
  end

  test "tenancy: another hive reads nothing of this one, and its target is not a holder",
       ctx do
    %{scope: other} = sign_up_fixture()

    assert {:ok, []} = Policy.uncovered(other, since())
    assert {:ok, %{denied: 0, destinations: 0}} = Policy.denied_summary(other, since())
    assert {:ok, %{}} = Policy.rule_activity(other, nil, since())
    assert {:ok, counts} = Policy.rule_activity(other, ctx.target, since())
    assert counts == %{}

    # A rule of the same host in the other hive is not counted from this hive's record.
    {:ok, _rule} = Policy.allow(other, nil, %{host: "api.example"})
    assert {:ok, counts} = Policy.rule_activity(other, nil, since())
    assert counts == %{}
  end
end
