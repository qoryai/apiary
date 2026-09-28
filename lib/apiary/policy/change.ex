defmodule Apiary.Policy.Change do
  @moduledoc """
  One change of the security policy, of the workspace's baseline (`target_id` nil) or of a
  target's rules, as the history shows it: what was done (`action`), to what (`subject`, a
  host or a credential's name; nil for the mode), the rule set `before` and `after` as
  JSON (`%{"mode" => …, "rules" => […]}`), who (`changed_by_id`, nil for the instance)
  and when. `version_after` is the version of the holder's run configuration in force once
  the change was made; a change that rendered the same bytes names the version that
  stayed. A `rerendered` change is no change of the rules (`before` equals `after`): the
  documents were rendered again by `mix apiary.policy.rerender` after an upgrade that
  changed what a render says.

  A change is an entry of the audit trail (`Apiary.Audit.Entry`), read by `from_entry/1`:
  its `id` is the entry's, which the run configurations it rendered name
  (`audit_entry_id`). `changed_by` and `target` are what `Apiary.Policy` reads beside it,
  nil when it did not or when the person or the target is gone.
  """

  alias Apiary.Audit.Entry

  @actions ~w(rule_added rule_changed rule_removed rule_locked rule_unlocked mode_changed rerendered)

  @type t :: %__MODULE__{}

  defstruct [
    :id,
    :action,
    :subject,
    :before,
    :after,
    :version_after,
    :inserted_at,
    :organisation_id,
    :workspace_id,
    :target_id,
    :changed_by_id,
    changed_by: nil,
    target: nil
  ]

  @doc "Every action a change can name."
  def actions, do: @actions

  @doc """
  The action of `Apiary.Access` a change of this kind took, which its audit entry names: a
  change of mode `security_policy.set_mode`, a lock or an unlock `security_policy.lock`,
  every other change `security_policy.edit`.
  """
  @spec audit_action(String.t()) :: Apiary.Access.action()
  def audit_action("mode_changed"), do: :"security_policy.set_mode"

  def audit_action(action) when action in ~w(rule_locked rule_unlocked),
    do: :"security_policy.lock"

  def audit_action(action) when action in @actions, do: :"security_policy.edit"

  @doc "The change an audit entry of the policy's actions records."
  @spec from_entry(Entry.t()) :: t
  def from_entry(%Entry{} = entry) do
    details = entry.details || %{}

    %__MODULE__{
      id: entry.id,
      action: details["change"],
      subject: details["subject"],
      before: entry.before,
      after: entry.after,
      version_after: details["version"],
      inserted_at: entry.inserted_at,
      organisation_id: entry.organisation_id,
      workspace_id: entry.workspace_id,
      target_id: if(entry.subject_kind == "target", do: entry.subject_id),
      changed_by_id: if(entry.actor_kind == :person, do: entry.actor_id)
    }
  end
end
