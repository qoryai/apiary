defmodule ApiaryWeb.Storybook.Policy.RuleMark do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &ApiaryWeb.PolicyComponents.rule_mark/1
  def layout, do: :one_column
  def container, do: {:div, class: "flex w-full flex-wrap items-center gap-3 p-3"}

  # A row of the table of rules (`ApiaryWeb.PolicyComponents.rule_line/1`), where the
  # marks take their tiles; `q-pr-off` is a rule not in force.
  @row """
  <div class="q-tbl q-pr-wrap w-full rounded-box border border-line bg-base-100 shadow-xs">
    <table class="table q-pr">
      <tbody>
        <tr class="q-pr-row ROW">
          <td class="q-pr-mk"><.psb-variation/></td>
          <td class="q-pr-host"><span class="q-host q-pr-h">api.example.com</span></td>
          <td class="q-pr-paths"><span class="q-every">every path</span></td>
        </tr>
      </tbody>
    </table>
  </div>
  """

  def variations do
    [
      %VariationGroup{
        id: :on_their_own,
        description: "Allow, deny, and a host nothing has decided yet, as a connection says it.",
        variations: [
          %Variation{id: :allow, attributes: %{action: "allow"}},
          %Variation{id: :deny, attributes: %{action: "deny"}},
          %Variation{id: :pending, attributes: %{action: "pending"}}
        ]
      },
      %VariationGroup{
        id: :in_the_rule_table,
        description: "In the table of rules: allow on the soft green tile, deny on the soft red.",
        template: String.replace(@row, " ROW", ""),
        variations: [
          %Variation{id: :allow_in_force, attributes: %{action: "allow"}},
          %Variation{id: :deny_in_force, attributes: %{action: "deny"}}
        ]
      },
      %VariationGroup{
        id: :not_in_force,
        description: "A rule not in force: a bare grey glyph, its host struck.",
        template: String.replace(@row, "ROW", "q-pr-off"),
        variations: [
          %Variation{id: :allow_not_in_force, attributes: %{action: "allow"}},
          %Variation{id: :deny_not_in_force, attributes: %{action: "deny"}}
        ]
      }
    ]
  end
end
