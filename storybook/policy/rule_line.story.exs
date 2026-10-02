defmodule ApiaryWeb.Storybook.Policy.RuleLine do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  alias ApiaryWeb.Storybook.Sample

  def function, do: &ApiaryWeb.PolicyComponents.rule_line/1
  def layout, do: :one_column
  def container, do: {:div, class: "w-full p-3"}

  def template do
    """
    <div class="q-tbl q-pr-wrap w-full rounded-box border border-line bg-base-100 shadow-xs">
      <table class="table q-pr">
        <tbody><.psb-variation/></tbody>
      </table>
    </div>
    """
  end

  def variations do
    [rule, locked, denied, paths, off | _] = Sample.rules() |> sort_sample()
    seen = Sample.activity()

    [
      line(:allowed, rule, seen),
      line(:allowed_with_paths, paths, seen),
      line(:denied, denied, seen),
      line(:locked, locked, seen),
      line(:not_in_force, off, seen),
      %Variation{
        id: :from_the_level_above,
        description: "A rule of the level above the workspace: its tile in the Source column.",
        attributes: %{
          rule:
            %{
              rule
              | id: "o1",
                host: "*.ads.example.com",
                action: "deny",
                own: false,
                source: %{key: "acme", label: "Acme", rank: 1, tile: "A"},
                locked_tip: "Acme's rule: it holds in every workspace."
            }
            |> Map.put(:above, true),
          source: true,
          use?: true,
          seen: %{allowed: 0, denied: 12}
        }
      }
    ]
  end

  defp line(id, rule, seen) do
    %Variation{
      id: id,
      attributes: %{
        rule: rule,
        use?: true,
        seen: if(rule.in_force, do: Map.get(seen, rule.id, %{allowed: 0, denied: 0})),
        can_lock: true
      }
    }
  end

  # The sample's rules, in the order the variations name them: allowed, locked, denied,
  # allowed with paths, not in force.
  defp sort_sample(rules) do
    Enum.map(~w(r4 r1 r3 r5 r6), fn id -> Enum.find(rules, &(&1.id == id)) end)
  end
end
