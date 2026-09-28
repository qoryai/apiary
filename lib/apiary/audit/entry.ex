defmodule Apiary.Audit.Entry do
  @moduledoc """
  One entry of the audit trail: who (`actor_kind` and `actor_id`), which action of
  `Apiary.Access` (`action`), on what (`subject_kind` and `subject_id`), when
  (`inserted_at`, the transaction's time in UTC, set by the database), from where
  (`remote_ip` and `user_agent`, or `worker`), and the fields the change changed as they
  were and as they are (`before` and `after`), with what else it says (`details`).

  The actor is an id and never a name: a person's user id, an access key's row id, or none
  for the instance. `before`, `after` and `details` hold no secret and no person's name
  or email address; a page looks a person up by id when it shows them.

  Written by `Apiary.Audit.record/6` and nothing else; never updated. The primary key is
  a version 7 UUID, so the entries of one transaction, which share its time, keep the
  order they were written in.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @actor_kinds [:person, :access_key, :instance]

  @primary_key {:id, Ecto.UUID, autogenerate: [version: 7, precision: :monotonic]}
  @foreign_key_type :binary_id
  schema "audit_entries" do
    field :actor_kind, Ecto.Enum, values: @actor_kinds
    field :actor_id, Ecto.UUID
    field :action, :string
    field :subject_kind, :string
    field :subject_id, Ecto.UUID
    field :before, :map
    field :after, :map
    field :details, :map
    field :remote_ip, :string
    field :user_agent, :string
    field :worker, :string
    # The database's `timezone('UTC', now())`: the time of the transaction the change was
    # made in, never the application's clock.
    field :inserted_at, :utc_datetime_usec, read_after_writes: true, writable: :never

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
  end

  @doc "Every kind of actor: a person, an access key, the instance."
  @spec actor_kinds() :: [atom]
  def actor_kinds, do: @actor_kinds
end
