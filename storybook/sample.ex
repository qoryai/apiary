defmodule ApiaryWeb.Storybook.Sample do
  @moduledoc """
  The data the component storybook's stories draw (`ApiaryWeb.Storybook`): neutral and
  synthetic, an organisation `acme` with a workspace `shop`, hosts under `example.com`
  and `git.example.com`, people by short name. Built in the shapes the pages build, so a
  story renders the real component the page renders.
  """
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Organisation, Workspace}

  @doc "The scope of a page of the workspace acme/shop, for the components that build links."
  @spec scope() :: Scope.t()
  def scope do
    %Scope{
      organisation: %Organisation{name: "Acme", slug: "acme"},
      workspace: %Workspace{name: "shop", slug: "shop"}
    }
  end

  @doc """
  Host rules of the workspace's policy, as `ApiaryWeb.PolicyLive.Common.workspace_rules/3`
  builds them for `ApiaryWeb.PolicyComponents.rule_line/1`: allowed with paths and
  without, denied, locked, and one not in force.
  """
  @spec rules() :: [map()]
  def rules do
    [
      rule("r1", "deny", "*.tracking.example.com", nil,
        locked: true,
        by: "dana",
        at: ~U[2026-07-02 09:12:00Z]
      ),
      rule("r2", "allow", "git.example.com", ["/acme/shop/**", "/acme/shared-ui/**"],
        locked: true,
        by: "dana",
        at: ~U[2026-08-19 14:40:00Z]
      ),
      rule("r3", "deny", "paste.example.com", nil, by: "lee", at: ~U[2026-09-03 11:05:00Z]),
      rule("r4", "allow", "registry.example.com", nil, by: "lee", at: ~U[2026-09-10 08:30:00Z]),
      rule("r5", "allow", "api.example.com", ["/v2/orders", "/v2/stock/*"],
        by: "dana",
        at: ~U[2026-09-21 16:02:00Z]
      ),
      rule("r6", "allow", "cdn.tracking.example.com", nil,
        in_force: false,
        off: "Not in force: shop's locked *.tracking.example.com holds",
        by: "sam",
        at: ~U[2026-09-28 10:18:00Z]
      )
    ]
  end

  @doc "The use of `rules/0` in the last 14 days, as `Apiary.Policy.rule_activity/3` counts it."
  @spec activity() :: %{String.t() => %{allowed: non_neg_integer(), denied: non_neg_integer()}}
  def activity do
    %{
      "r1" => %{allowed: 0, denied: 37},
      "r2" => %{allowed: 1_284, denied: 0},
      "r3" => %{allowed: 0, denied: 2},
      "r4" => %{allowed: 412, denied: 0},
      "r5" => %{allowed: 96, denied: 3}
    }
  end

  defp rule(id, action, host, paths, opts) do
    %{
      id: id,
      action: action,
      host: host,
      paths: paths,
      locked: Keyword.get(opts, :locked, false),
      source: %{key: "shop", label: "shop", rank: 2},
      own: true,
      in_force: Keyword.get(opts, :in_force, true),
      off: Keyword.get(opts, :off),
      by: Keyword.get(opts, :by),
      at: Keyword.get(opts, :at),
      locked_tip: "Locked: only an owner changes it, and a target cannot override it.",
      can_change: true,
      act: :remove,
      view: nil
    }
  end

  @doc """
  Runs of the workspace, as the runs list holds them (`ApiaryWeb.RunComponents.runs_table/1`):
  running, succeeded, failed with denials, and pending. Their times are this minute's.
  """
  @spec runs() :: [map()]
  def runs do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    [
      run(1, "running", "Add stock levels to the order page", now, -240,
        elapsed_seconds: 236,
        last_heartbeat_at: DateTime.add(now, -4)
      ),
      run(2, "succeeded", "Fix the rounding of order totals", now, -3_600,
        duration_ms: 1_122_000
      ),
      run(3, "failed", "Upgrade the payment client", now, -9_000,
        duration_ms: 431_000,
        denied_count: 3
      ),
      run(4, "pending", nil, now, -20, [])
    ]
  end

  defp run(n, state, task, now, offset, opts) do
    at = DateTime.add(now, offset)

    Map.merge(
      %{
        id: n,
        run_id: "8f3c2a#{n}e0-5b1d-4c7e-9a10-2f6d0c4b7e1#{n}",
        state: state,
        task: task,
        target_system: "git.example.com",
        target_path: if(rem(n, 2) == 0, do: "acme/shared-ui", else: "acme/shop"),
        runtime: "claude",
        runtime_version: "2.4.1",
        host: "build-0#{n}",
        started_at: at,
        inserted_at: at,
        closed_at: nil,
        duration_ms: nil,
        elapsed_seconds: nil,
        last_heartbeat_at: nil,
        heartbeat_interval_seconds: 30,
        denied_count: 0
      },
      Map.new(opts)
    )
  end
end
