defmodule Apiary.Policy.Entry do
  @moduledoc """
  One rule as it stands in an effective policy.

    * `rule`: the `Apiary.Policy.Rule` itself; `kind`, `action`, `host`, `paths`, `name`,
      `argument` and `locked` repeat it for a page's convenience;
    * `source`: `:workspace` or `:target`, where the rule was written;
    * `in_force`: whether the rule decides anything in this policy;
    * `overridden_by`: the entry that beat it when it is not in force (a locked rule of
      the workspace, the target's own rule, a `*.` deny that covers it, a `*.` allow above
      it), without its own `overridden_by` and `overrides`;
    * `overrides`: the entries this one beat, likewise.
  """

  @type t :: %__MODULE__{}

  defstruct [
    :rule,
    :kind,
    :action,
    :host,
    :paths,
    :name,
    :argument,
    :source,
    locked: false,
    in_force: true,
    overridden_by: nil,
    overrides: []
  ]
end
