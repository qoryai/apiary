defmodule ApiaryWeb.Storybook.Policy.RuleForm do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  alias ApiaryWeb.PolicyLive.Reading

  def function, do: &ApiaryWeb.PolicyComponents.rule_form/1
  def container, do: {:div, class: "w-full p-6"}

  # The New rule and Edit rule pages' form, as `ApiaryWeb.PolicyLive.Common` fills it: the
  # fields, and the reading of them (`Reading.host_rule/2`) against the rules on the page.
  def variations do
    [
      form(:new_rule, "New rule", %{},
        description: "Empty, Allow picked: the help under each field, and the read-back waiting."
      ),
      form(:reads_back, "New rule", %{"host" => "api.partner.example.com", "paths" => "/v1/*"},
        description: "The rule read back in plain words as it is typed."
      ),
      form(:a_deny, "New rule", %{"action" => "deny", "host" => "telemetry.example.com"},
        description: "A deny takes no paths, and says what it takes out."
      ),
      form(:errors, "New rule", %{"host" => "https://API.example.com:443/v1", "paths" => "v2"},
        description:
          "Each error under its field, the host's with its repair as a link; Add rule " <>
            "stays on and moves to the first field at fault."
      ),
      form(:replaces, "New rule", %{"action" => "deny", "host" => "registry.example.com"},
        own: [rule("registry.example.com", "allow")],
        description:
          "The opposite rule is said in the read-back, and the button says it replaces it."
      ),
      form(:pasted, "New rule", %{"host" => "a.example.com"},
        queued: 2,
        description: "A pasted list: the first in Host, the rest counted beside its label."
      ),
      form(
        :edit_rule,
        "Edit the rule for api.example.com",
        %{
          "host" => "api.example.com",
          "paths" => "/v1/* /v2/*"
        },
        own: [rule("api.example.com", "allow", ["/v1/*"])],
        editing: "api.example.com",
        description: "Edit rule: the host shown and kept, the paths in their field."
      ),
      form(:target_refused, "New rule", %{"host" => "bin.paste.example.com"},
        scope: :target,
        entries: [
          %Apiary.Policy.Entry{
            kind: :host,
            action: :deny,
            host: "*.paste.example.com",
            source: :workspace,
            locked: true
          }
        ],
        description:
          "A repository's form under a locked rule: the refusal in the read-back's place."
      )
    ]
  end

  defp form(id, title, fields, opts) do
    scope = Keyword.get(opts, :scope, :workspace)
    editing = opts[:editing]

    params =
      Map.merge(%{"action" => "allow", "host" => "", "paths" => "", "every" => "false"}, fields)

    context = %{
      scope: scope,
      own: Keyword.get(opts, :own, []),
      entries: Keyword.get(opts, :entries, []),
      owner: true,
      locked_by: %{},
      editing: editing != nil
    }

    %Variation{
      id: id,
      description: opts[:description],
      attributes: %{
        id: "rule-#{id}",
        title: title,
        form: Phoenix.Component.to_form(params, as: :rule),
        scope: scope,
        reading: Reading.host_rule(params, context),
        queued: Keyword.get(opts, :queued, 0),
        editing: editing,
        cancel: "#",
        cancel_by: "patch"
      },
      slots: [
        "<:description>Let this workspace's runs reach a host, or stop them reaching it.</:description>"
      ]
    }
  end

  defp rule(host, action, paths \\ nil),
    do: %{kind: "host", action: action, host: host, paths: paths, locked: false}
end
