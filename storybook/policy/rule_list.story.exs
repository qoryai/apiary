defmodule ApiaryWeb.Storybook.Policy.RuleList do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  alias ApiaryWeb.PolicyLive.{Common, RuleList}
  alias ApiaryWeb.Storybook.Sample

  def function, do: &ApiaryWeb.PolicyComponents.rule_list/1
  def layout, do: :one_column
  def container, do: {:div, class: "grid w-full grid-cols-[minmax(0,1fr)] gap-3 p-3"}
  def imports, do: [{ApiaryWeb.CoreComponents, inline_confirm: 1, button: 1}]

  # The section's header, as the workspace's policy page draws it: its link and its line.
  @section_slots [
    ~s|<:link><a href="#" class="link link-hover text-sm">See what the runs reached</a></:link>|,
    ~s|<:description>The hosts this workspace's runs may reach, and those they may not.</:description>|
  ]

  # The list as the workspace's policy page builds it: `RuleList.list/3` of the rows, the
  # query and their use, the Filter menu's sections, and its URLs (`Common.list_path/2`).
  def variations do
    rows = Sample.rules()
    activity = Sample.activity()

    [
      %Variation{
        id: :every_rule,
        description:
          "The Network access section: its header with Add rule, the one primary button; " <>
            "every view, the search, Filter and Sort, and the rules' use. A row's Edit " <>
            "leads to its Edit rule page.",
        attributes: list(rows, %RuleList{}, activity, section(rows, can_lock: true)),
        slots: @section_slots
      },
      %Variation{
        id: :reader,
        description: "A reader who may not change the policy: no Add rule and no row menus.",
        attributes:
          list(rows, %RuleList{}, activity,
            title: "Network access",
            heading_id: "reader-h",
            count: length(rows)
          ),
        slots: @section_slots
      },
      %Variation{
        id: :filtered,
        description: "A filter in force, as a token under the bar, and how many rules match.",
        attributes: list(rows, %RuleList{tokens: [{:by, "dana"}]}, activity, section(rows, [])),
        slots: @section_slots
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
          list(
            [],
            %RuleList{},
            %{},
            section([], empty: "No host rules yet. Add the first with Add rule.")
          ),
        slots: @section_slots
      },
      %Variation{
        id: :not_moved,
        description:
          "Kept for a caller that has not moved to the rule pages: Add rule in the " <>
            "search's bar, opening the composer under the filters.",
        attributes: list(rows, %RuleList{}, activity, can_add: true, can_lock: true)
      }
    ]
  end

  # The section's header and the rule pages' links, as the workspace's page passes them.
  defp section(rows, opts) do
    [
      title: "Network access",
      count: length(rows),
      add_path: "/acme/shop/policy/rules/new",
      edit_path: &"/acme/shop/policy/rules/#{&1}/edit"
    ] ++ opts
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
