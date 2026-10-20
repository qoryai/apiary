defmodule Apiary.Policy.Entry do
  @moduledoc """
  One rule as it stands in an effective policy, or one host an integration requires.

    * `rule`: the `Apiary.Policy.Rule` itself; `kind`, `action`, `host`, `paths` and
      `locked` repeat it for a page's convenience; nil for an `:integration` entry;
    * `source`: where the rule was written: `:workspace`, `:target`, or `:organisation`
      for a rule of the level above the workspace (`Apiary.Policy.Above`), which is never
      `locked`: its glyph is its source's; `:integration` for a host of an integration's
      `egress_hosts` (`Apiary.Integrations.Description.egress_hosts/2`), an allow on every
      path that comes from no rule;
    * `connection`: for an `:integration` entry, the connection whose description lists
      the host, `%{id:, public_id:, name:}`; nil otherwise;
    * `in_force`: whether the rule decides anything in this policy;
    * `overridden_by`: the entry that beat it when it is not in force (a rule of the level
      above, a locked rule of the workspace, a rule of the target, a `*.` deny that
      covers it, a `*.` allow above it, an integration's host), without that entry's
      `overridden_by` and `overrides`;
    * `overrides`: the entries this one beat, likewise; for an `:integration` entry, also
      each `*.` deny that covers its host, which stays in force for every other host it
      covers (`Apiary.Policy.Resolution`, point 7);
    * `reason`: why it is not in force when nothing beat it: `:only_above_allows`, a host
      allow of the workspace or of a target where the level above allows only the hosts on
      its list; `:out_of_grammar`, a rule stored before the grammar refused its host (an
      address in a form other than `a.b.c.d`), which no document holds; nil otherwise.
  """

  @type t :: %__MODULE__{}

  defstruct [
    :rule,
    :kind,
    :action,
    :host,
    :paths,
    :source,
    connection: nil,
    locked: false,
    in_force: true,
    overridden_by: nil,
    overrides: [],
    reason: nil
  ]
end
