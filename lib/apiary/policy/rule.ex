defmodule Apiary.Policy.Rule do
  @moduledoc """
  One rule of the security policy: of the hive's baseline when `repository_id` is nil, of
  a repository otherwise.

  A `host` rule allows a host (the contract's grammar: a lower-case name or a `*.` suffix)
  on every path (`paths` nil) or on the paths listed (an empty list is no path at all), or
  denies it. A `credential` rule lets the run use a credential of the machine's by `name`,
  with an `argument` when its adapter takes one, or denies it. A rule names a credential
  and never holds one.

  A deny is the apiary's own notion: the contract's document can only allow, so a deny
  takes entries out of what is rendered. Only a rule of the hive can be `locked`, which
  holds it against every repository.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Apiary.Policy.Grammar

  @kinds ~w(host credential)
  @actions ~w(allow deny)

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "policy_rules" do
    field :kind, :string, default: "host"
    field :action, :string
    field :host, :string
    field :paths, {:array, :string}
    field :name, :string
    field :argument, :string
    field :locked, :boolean, default: false

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :hive, Apiary.Organisations.Hive
    belongs_to :repository, Apiary.Runs.Repository
    belongs_to :created_by, Apiary.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def kinds, do: @kinds
  def actions, do: @actions

  @doc "The host or the credential's name: what the rule is about."
  def subject(%__MODULE__{kind: "credential", name: name}), do: name
  def subject(%__MODULE__{host: host}), do: host

  @doc false
  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [:kind, :action, :host, :paths, :name, :argument, :locked])
    |> validate_required([:kind, :action])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:action, @actions)
    |> validate_subject()
    |> unique_constraint(:host,
      name: :policy_rules_subject_index,
      message: "already has a rule here"
    )
  end

  defp validate_subject(changeset) do
    case get_field(changeset, :kind) do
      "credential" ->
        changeset
        |> put_change(:host, nil)
        |> put_change(:paths, nil)
        |> validate_required([:name], message: "Name the credential.")
        |> validate_change(:name, fn :name, name ->
          if Grammar.credential_name?(name),
            do: [],
            else: [
              name:
                "A credential's name is lower-case letters, digits, dots, dashes and underscores, at most 64, and starts with a letter or a digit."
            ]
        end)
        |> drop_on_deny(:argument)
        |> validate_change(:argument, fn :argument, argument ->
          if Grammar.argument?(argument),
            do: [],
            else: [
              argument: "An argument is 1 to #{Grammar.argument_max()} characters on one line."
            ]
        end)

      _host ->
        changeset
        |> put_change(:name, nil)
        |> put_change(:argument, nil)
        |> validate_required([:host], message: "Name the host.")
        |> validate_change(:host, fn :host, host ->
          if Grammar.host?(host),
            do: [],
            else: [
              host:
                "A host is a lower-case name such as api.example, or *.example for every host below example. No port, no path, no scheme."
            ]
        end)
        |> drop_on_deny(:paths)
        |> validate_change(:paths, &validate_paths/2)
    end
  end

  # A deny removes the whole host or credential: it has no paths and no argument.
  defp drop_on_deny(changeset, field) do
    if get_field(changeset, :action) == "deny",
      do: put_change(changeset, field, nil),
      else: changeset
  end

  defp validate_paths(:paths, paths) do
    cond do
      length(paths) > Grammar.paths_max() ->
        [paths: "A host takes at most #{Grammar.paths_max()} paths."]

      bad = Enum.find(paths, &(not Grammar.path?(&1))) ->
        [
          paths:
            "#{inspect(String.slice(bad, 0, 80))} is not a path: it starts with /, holds no ?, # or space, and may end in one * to match everything below it."
        ]

      true ->
        []
    end
  end
end
