defmodule Apiary.WorkItems.WorkItem do
  # A work item of a workspace: something its members took in to work on, numbered from 1
  # in the workspace (`number`, `Apiary.WorkItems.Number`), never twice.
  #
  # What it was taken in from is kept as it was at that moment: `connection_id`, the
  # organisation's connection to an adapter the ticket came through
  # (`Apiary.Adapters.Connection`), and `adapter_id`, that connection's adapter, which
  # says what system it is of; `item_id`, the ticket (`Apiary.Sources.Item`), or nil once
  # the ticket's row is gone; `external_ref`, the ticket's ref at its source, an external
  # id, 1 to 200 characters; `url`, its address, `https://`, 2,048 characters at most;
  # `title`, 1 to 1,024 characters; `collection_title`, the title of the repository or
  # project that holds it, 1 to 1,024 characters; and where a change for it goes,
  # `target_system`, a host name to the contract's pattern, and `target_path`, 1 to 200
  # characters. A later change at the source does not change it. A ticket has one work
  # item in an organisation, live or not, by its adapter and its ref, so that a take in
  # again has one work item to find; `take_in` counts the take ins of the work item, from
  # 1. No end of its ticket, the ticket's collection, its connection or its adapter
  # deletes a work item.
  # `owner_id` is the person who owns it, and `first_instruction` what a person said
  # first, 0 to 4,000 characters.
  #
  # `state` is where it stands (`Apiary.WorkItems.State`): `:exploring`, `:declined`,
  # `:closed` or `:undone`. A declined one has the time it was declined, `declined_at`,
  # and the person who declined it, `declined_by_id`, where a person did; a closed one has
  # the time it closed, `closed_at`, and the person who closed it, `closed_by_id`, where a
  # person did; no other has them.
  #
  # `public_id` is its name outside the database: `wi_`, then sixteen lowercase Crockford
  # base32 characters, made once with it (`Apiary.PublicId`). The database holds every
  # bound above, and counts characters as code points, as `take_in_changeset/2` does.
  #
  # Every module of the work items is left out of the documentation at `/docs`
  # (`@moduledoc false`): the feature they belong to is one the documentation does not
  # differ by (`Apiary.Features`, `docs: false`).
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Apiary.Sources.Item
  alias Apiary.WorkItems.State

  @typedoc "A work item of a workspace."
  @type t :: %__MODULE__{}

  @prefix "wi"
  @max_external_ref 200
  @max_target_path 200
  @max_url 2048
  @max_title 1024
  @max_instruction 4000

  # definitions.schema.json: $defs.url as a ticket's is held, and $defs.target's system.
  @url ~r{\Ahttps://[^/?#@\s]+([/?#]\S*)?\z}
  @system ~r/\A[a-z0-9.-]{1,253}\z/

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Phoenix.Param, key: :public_id}
  schema "work_items" do
    field :public_id, :string
    field :number, :integer
    field :external_ref, :string
    field :url, :string
    field :title, :string
    field :collection_title, :string
    field :target_system, :string
    field :target_path, :string
    field :take_in, :integer
    field :first_instruction, :string, default: ""
    field :state, Ecto.Enum, values: State.states()
    field :taken_in_at, :utc_datetime_usec
    field :declined_at, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :connection, Apiary.Adapters.Connection
    belongs_to :adapter, Apiary.Nodes.Node
    belongs_to :item, Item
    belongs_to :owner, Apiary.Accounts.User
    belongs_to :taken_in_by, Apiary.Accounts.User
    belongs_to :declined_by, Apiary.Accounts.User
    belongs_to :closed_by, Apiary.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  # prefix/0 is the prefix of a work item's public id, `wi`.
  @doc false
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  # max_instruction/0 is the most characters, code points, a first instruction has.
  @doc false
  @spec max_instruction() :: pos_integer
  def max_instruction, do: @max_instruction

  # take_in_changeset/2 is the changeset of a new work item's snapshot, the connection
  # and the adapter its ticket came through and the ticket among it, its target, its owner
  # and its first instruction, each within the bounds above, counted in code points as
  # the database counts them, with a fresh public id, at its first take in. A value the
  # database refuses all the same is an error on its field, and a second work item of
  # the same ticket in the organisation an error on `external_ref`. The workspace, the
  # number, the state and who took it in, and when, are the caller's to put.
  @doc false
  @spec take_in_changeset(t, map) :: Ecto.Changeset.t()
  def take_in_changeset(%__MODULE__{} = work_item, attrs) do
    work_item
    |> cast(
      attrs,
      [
        :connection_id,
        :adapter_id,
        :item_id,
        :external_ref,
        :url,
        :title,
        :collection_title,
        :target_system,
        :target_path,
        :owner_id,
        :first_instruction
      ],
      empty_values: [nil]
    )
    |> validate_required([
      :connection_id,
      :adapter_id,
      :item_id,
      :external_ref,
      :url,
      :title,
      :collection_title,
      :target_system,
      :target_path,
      :owner_id
    ])
    |> validate_length(:external_ref, min: 1, max: @max_external_ref, count: :codepoints)
    |> validate_length(:url, max: @max_url, count: :codepoints)
    |> validate_format(:url, @url)
    |> validate_length(:title, min: 1, max: @max_title, count: :codepoints)
    |> validate_length(:collection_title, min: 1, max: @max_title, count: :codepoints)
    |> validate_format(:target_system, @system)
    |> validate_length(:target_path, min: 1, max: @max_target_path, count: :codepoints)
    |> validate_length(:first_instruction, max: @max_instruction, count: :codepoints)
    |> put_change(:public_id, Apiary.PublicId.generate(@prefix))
    |> put_change(:take_in, 1)
    |> check_constraint(:external_ref, name: :work_items_external_ref_check)
    |> check_constraint(:url, name: :work_items_url_check)
    |> check_constraint(:title, name: :work_items_title_check)
    |> check_constraint(:collection_title, name: :work_items_collection_title_check)
    |> check_constraint(:target_system, name: :work_items_target_check)
    |> check_constraint(:first_instruction, name: :work_items_first_instruction_check)
    |> unique_constraint(:number, name: :work_items_workspace_id_number_index)
    |> unique_constraint(:external_ref,
      name: :work_items_organisation_id_adapter_id_external_ref_index
    )
    |> foreign_key_constraint(:owner_id, name: :work_items_owner_id_fkey)
    |> foreign_key_constraint(:connection_id, name: :work_items_connection_id_fkey)
    |> foreign_key_constraint(:item_id, name: :work_items_item_id_fkey)
  end
end
