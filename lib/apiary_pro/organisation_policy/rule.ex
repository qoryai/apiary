defmodule ApiaryPro.OrganisationPolicy.Rule do
  @moduledoc """
  One host rule of the organisation's policy (`organisation_policy_rules`): a host, in the
  contract's grammar (a lower-case name or a `*.` suffix), allowed on every path (`paths`
  nil) or on the paths listed, or denied, which has no paths. One rule per host and
  organisation.

  The core resolves it as an `Apiary.Policy.Rule` of the level above the workspace
  (`to_core_rule/1`): the same shape, unpersisted, never a row of `policy_rules`.
  """
  use Ecto.Schema
  use Gettext, backend: ApiaryProWeb.Gettext

  import Ecto.Changeset

  alias Apiary.Policy.Grammar

  @actions ~w(allow deny)

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "organisation_policy_rules" do
    field :action, :string
    field :host, :string
    field :paths, {:array, :string}

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :created_by, Apiary.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The actions a rule takes: allow or deny."
  def actions, do: @actions

  @doc """
  changeset/2 checks a rule as the core's `Apiary.Policy.Rule` checks a host
  rule, with the same sentences: the host's grammar, the paths' and their number, a deny
  without paths, and one rule per host.
  """
  @spec changeset(t, map) :: Ecto.Changeset.t()
  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [:action, :host, :paths])
    |> validate_required([:action])
    |> validate_inclusion(:action, @actions)
    |> validate_required([:host], message: dgettext_noop("errors", "Name the host."))
    |> validate_change(:host, fn :host, host ->
      if Grammar.host?(host),
        do: [],
        else: [
          host:
            dgettext_noop(
              "errors",
              "A host is a lower-case name such as api.example, or *.example for every host below example. No port, no path, no scheme."
            )
        ]
    end)
    |> drop_paths_on_deny()
    |> validate_change(:paths, &validate_paths/2)
    |> unique_constraint(:host,
      name: :organisation_policy_rules_host_index,
      message: dgettext_noop("errors", "already has a rule here")
    )
  end

  defp drop_paths_on_deny(changeset) do
    if get_field(changeset, :action) == "deny",
      do: put_change(changeset, :paths, nil),
      else: changeset
  end

  defp validate_paths(:paths, paths) do
    cond do
      length(paths) > Grammar.paths_max() ->
        [
          paths:
            {dgettext_noop("errors", "A host takes at most %{max} paths."),
             max: Grammar.paths_max()}
        ]

      bad = Enum.find(paths, &(not Grammar.path?(&1))) ->
        [
          paths:
            {dgettext_noop(
               "errors",
               "%{path} is not a path: it starts with /, holds no ?, # or space, and may end in one * to match everything below it."
             ), path: inspect(String.slice(bad, 0, 80))}
        ]

      true ->
        []
    end
  end

  @doc """
  to_core_rule/1 is the rule as the core resolves it: an `Apiary.Policy.Rule` of kind
  `host`, unlocked, of no workspace and no target, with the organisation's id, its author
  and its times, and the rule's id, which the pages and the use counts name it by.
  """
  @spec to_core_rule(t) :: Apiary.Policy.Rule.t()
  def to_core_rule(%__MODULE__{} = rule) do
    %Apiary.Policy.Rule{
      id: rule.id,
      kind: "host",
      action: rule.action,
      host: rule.host,
      paths: rule.paths,
      locked: false,
      organisation_id: rule.organisation_id,
      workspace_id: nil,
      target_id: nil,
      created_by_id: rule.created_by_id,
      inserted_at: rule.inserted_at,
      updated_at: rule.updated_at
    }
  end
end
