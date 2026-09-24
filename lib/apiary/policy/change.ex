defmodule Apiary.Policy.Change do
  @moduledoc """
  One change of the security policy, of the hive's baseline (`repository_id` nil) or of a
  repository's rules: what was done (`action`), to what (`subject`, a host or a
  credential's name; nil for the mode), the rule set `before` and `after` as JSON
  (`%{"mode" => …, "rules" => […]}`), who and when. `version_after` is the version of the
  holder's run configuration in force once the change was made; a change that rendered
  the same bytes names the version that stayed. A `rerendered` change is no change of the
  rules (`before` equals `after`): the documents were rendered again by
  `mix apiary.policy.rerender` after an upgrade that changed what a render says.
  """
  use Ecto.Schema

  @actions ~w(rule_added rule_changed rule_removed rule_locked rule_unlocked mode_changed rerendered)

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "policy_changes" do
    field :action, :string
    field :subject, :string
    field :before, :map
    field :after, :map
    field :version_after, :integer
    field :inserted_at, :utc_datetime_usec

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :hive, Apiary.Organisations.Hive
    belongs_to :repository, Apiary.Runs.Repository
    belongs_to :changed_by, Apiary.Accounts.User
  end

  @doc "Every action a change can name."
  def actions, do: @actions
end
