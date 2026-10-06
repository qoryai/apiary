defmodule ApiaryWeb.Storybook.Policy.RuleList do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  alias ApiaryWeb.PolicyLive.{Common, RuleList}
  alias ApiaryWeb.Storybook.Sample

  def function, do: &ApiaryWeb.PolicyComponents.rule_list/1
  def layout, do: :one_column
  def container, do: {:div, class: "grid w-full grid-cols-[minmax(0,1fr)] gap-3 p-3"}
  def imports, do: [{ApiaryWeb.CoreComponents, inline_confirm: 1, button: 1}]

  # The list as the workspace's policy page builds it: `RuleList.list/3` of the rows, the
  # query and their use, the Filter menu's sections, and its URLs (`Common.list_path/2`).
  def variations do
    rows = Sample.rules()
    activity = Sample.activity()

    [
      %Variation{
        id: :every_rule,
        description: "Every view, the search, Filter, Sort and Add rule, and the rules' use.",
        attributes: list(rows, %RuleList{}, activity, can_add: true, can_lock: true)
      },
      %Variation{
        id: :filtered,
        description: "A filter in force, as a token under the bar, and how many rules match.",
        attributes: list(rows, %RuleList{tokens: [{:by, "dana"}]}, activity, can_add: true)
      },
      %Variation{
        id: :denied_view,
        attributes: list(rows, %RuleList{view: :deny}, activity, [])
      },
      %Variation{
        id: :use_not_counted,
        description: "The use could not be counted: the column is not shown, never faked.",
        attributes: list(rows, %RuleList{}, :unavailable, [])
      },
      %Variation{
        id: :confirming,
        description:
          "A rule's row asking to confirm its removal; where the table scrolls sideways, " <>
            "the question and its buttons stay in its box's view.",
        attributes: list(rows, %RuleList{}, activity, can_lock: true, confirming: "r3"),
        slots: [
          """
          <:confirm>
            <.inline_confirm id="remove-confirm" question="Remove the deny rule paste.example.com?" cancel="#">
              This takes effect within a heartbeat.
              <:action>
                <.button variant="danger" size="xs">Yes, remove</.button>
              </:action>
            </.inline_confirm>
          </:confirm>
          """
        ]
      },
      %Variation{
        id: :loading,
        attributes: list(rows, %RuleList{sort: :used}, :loading, [])
      },
      %Variation{
        id: :no_rule_yet,
        attributes:
          list([], %RuleList{}, %{}, empty: "No rule yet: every host is observed.", can_add: true)
      }
    ]
  end

  defp list(rows, query, activity, opts) do
    Map.merge(
      %{
        label: "Network access rules of the workspace",
        listing: RuleList.list(rows, query, activity),
        query: query,
        path: &Common.list_path("/acme/shop/policy", &1),
        sections: RuleList.sections(rows, activity),
        default_sort: "Locked first",
        activity: activity
      },
      Map.new(opts)
    )
  end
end
