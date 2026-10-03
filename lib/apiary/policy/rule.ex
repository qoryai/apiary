defmodule Apiary.Policy.Rule do
  @moduledoc """
  One rule of the security policy: of the workspace's baseline when `target_id` is nil, of
  a target otherwise.

  A `host` rule allows a host (the contract's grammar: a lower-case name or a `*.` suffix)
  on every path (`paths` nil) or on the paths listed (an empty list is no path at all), or
  denies it. `host` is the one kind of rule there is.

  A deny is written to the document's `egress.deny`, which a runner decides first and in
  either mode, and takes the allow entries it covers out of what is rendered. Only a rule
  of the workspace can be `locked`, which holds it against every target.
  """
  use Ecto.Schema
  use Gettext, backend: ApiaryWeb.Gettext

  import Ecto.Changeset

  alias Apiary.Policy.Grammar

  @kinds ~w(host)
  @actions ~w(allow deny)

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "policy_rules" do
    field :kind, :string, default: "host"
    field :action, :string
    field :host, :string
    field :paths, {:array, :string}
    field :locked, :boolean, default: false

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :target, Apiary.Runs.Target
    belongs_to :created_by, Apiary.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def kinds, do: @kinds
  def actions, do: @actions

  @doc "The host: what the rule is about."
  def subject(%__MODULE__{host: host}), do: host

  @doc false
  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [:kind, :action, :host, :paths, :locked])
    |> validate_required([:kind, :action])
    |> validate_inclusion(:kind, @kinds,
      message: dgettext_noop("errors", "A rule allows or denies a host.")
    )
    |> validate_inclusion(:action, @actions)
    |> validate_subject()
    # The kind's sentence first: a rule of another kind is no host rule with a host missing.
    |> kind_first()
    |> unique_constraint(:host,
      name: :policy_rules_subject_index,
      message: dgettext_noop("errors", "already has a rule here")
    )
  end

  defp validate_subject(changeset) do
    changeset
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
  end

  defp kind_first(%Ecto.Changeset{errors: errors} = changeset) do
    case List.keytake(errors, :kind, 0) do
      {kind, rest} -> %{changeset | errors: [kind | rest]}
      nil -> changeset
    end
  end

  # A deny removes the whole host: it has no paths.
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
end
