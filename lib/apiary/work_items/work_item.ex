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
  # `title`, 1 to 1,024 characters; `collection_title`, the title of the collection that
  # holds it, 1 to 1,024 characters; and where a change for it goes, its target, both or
  # neither: `target_system`, a host name to the contract's pattern, and `target_path`, 1
  # to 200 characters. Whether it needs a target is its workspace's domain's rule
  # (`Apiary.Lingo.Domain.target_required?/1`). A later change at the source does not change it until a take in again,
  # which takes the ticket's current record, its connection, its title, its address and
  # its collection's title as they are then (`take_in_again_changeset/2`). A ticket has
  # one work item in an organisation, live or not, by its adapter and its ref, so that a
  # take in again has one work item to find; `take_in` counts the take ins of the work
  # item, from 1. No end of its ticket, the ticket's collection, its connection or its
  # adapter deletes a work item.
  # `owner_id` is the person who owns it, and `first_instruction` what a person said
  # first at its latest take in, 0 to 4,000 characters, none of them one a run's input
  # refuses.
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
  use Gettext, backend: ApiaryWeb.Gettext
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
  # explore v1 result.schema.json `$defs/text`, to which a run's input holds the first
  # instruction: the control characters it refuses (tab, line feed and carriage return
  # are allowed), then the other characters it refuses, which do not show.
  @control ~r/[\x{0}-\x{8}\x{B}\x{C}\x{E}-\x{1F}\x{7F}-\x{9F}]/u
  @invisible ~r/[\x{AD}\x{61C}\x{180E}\x{200B}\x{200E}\x{200F}\x{2028}\x{2029}\x{202A}-\x{202E}\x{2060}-\x{2064}\x{2066}-\x{2069}\x{FEFF}\x{FFF9}-\x{FFFB}]/u

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
  # and the adapter its ticket came through and the ticket among it, its target, both its
  # system and its path or neither (`validate_target/1`), its owner and its first
  # instruction, each within the bounds above, counted in code points as
  # the database counts them, with a fresh public id, at its first take in. The first
  # instruction holds no character a run's input refuses (`validate_instruction/1`). A
  # value the database refuses all the same is an error on its field, and a second work
  # item of the same ticket in the organisation an error on `external_ref`. The
  # workspace, the number, the state and who took it in, and when, are the caller's to
  # put.
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
      :owner_id
    ])
    |> validate_length(:external_ref, min: 1, max: @max_external_ref, count: :codepoints)
    |> validate_length(:url, max: @max_url, count: :codepoints)
    |> validate_format(:url, @url)
    |> validate_length(:title, min: 1, max: @max_title, count: :codepoints)
    |> validate_length(:collection_title, min: 1, max: @max_title, count: :codepoints)
    |> validate_target()
    |> validate_instruction()
    |> put_change(:public_id, Apiary.PublicId.generate(@prefix))
    |> put_change(:take_in, 1)
    |> check_constraint(:external_ref, name: :work_items_external_ref_check)
    |> check_constraint(:url, name: :work_items_url_check)
    |> check_constraint(:title, name: :work_items_title_check)
    |> check_constraint(:collection_title, name: :work_items_collection_title_check)
    |> check_constraint(:target_system, name: :work_items_target_check)
    |> check_constraint(:target_system, name: :work_items_target_shape_check)
    |> check_constraint(:target_path, name: :work_items_target_pair_check)
    |> check_constraint(:first_instruction, name: :work_items_first_instruction_check)
    |> unique_constraint(:number, name: :work_items_workspace_id_number_index)
    |> unique_constraint(:external_ref,
      name: :work_items_organisation_id_adapter_id_external_ref_index
    )
    |> foreign_key_constraint(:owner_id, name: :work_items_owner_id_fkey)
    |> foreign_key_constraint(:connection_id, name: :work_items_connection_id_fkey)
    |> foreign_key_constraint(:item_id, name: :work_items_item_id_fkey)
  end

  # take_in_again_changeset/2 is the changeset of a take in again of an ended work item:
  # the ticket's current record and the connection it came through, the ticket's title
  # and address and its collection's title as that record and its collection hold them
  # now, and the target, the owner and the first instruction of this take in, each within
  # the bounds `take_in_changeset/2` holds, with the take in counted one more. Its adapter
  # and its ref stay: they are the key the work item was found by. The state, who took it
  # in and when, the ended fields and a move to another workspace are the caller's to put.
  @doc false
  @spec take_in_again_changeset(t, map) :: Ecto.Changeset.t()
  def take_in_again_changeset(%__MODULE__{take_in: take_in} = work_item, attrs)
      when is_integer(take_in) do
    work_item
    |> cast(
      attrs,
      [
        :connection_id,
        :item_id,
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
      :item_id,
      :url,
      :title,
      :collection_title,
      :owner_id
    ])
    |> validate_length(:url, max: @max_url, count: :codepoints)
    |> validate_format(:url, @url)
    |> validate_length(:title, min: 1, max: @max_title, count: :codepoints)
    |> validate_length(:collection_title, min: 1, max: @max_title, count: :codepoints)
    |> validate_target()
    |> validate_instruction()
    |> put_change(:take_in, take_in + 1)
    |> check_constraint(:url, name: :work_items_url_check)
    |> check_constraint(:title, name: :work_items_title_check)
    |> check_constraint(:collection_title, name: :work_items_collection_title_check)
    |> check_constraint(:target_system, name: :work_items_target_check)
    |> check_constraint(:target_system, name: :work_items_target_shape_check)
    |> check_constraint(:target_path, name: :work_items_target_pair_check)
    |> check_constraint(:first_instruction, name: :work_items_first_instruction_check)
    |> unique_constraint(:number, name: :work_items_workspace_id_number_index)
    |> foreign_key_constraint(:owner_id, name: :work_items_owner_id_fkey)
    |> foreign_key_constraint(:connection_id, name: :work_items_connection_id_fkey)
    |> foreign_key_constraint(:item_id, name: :work_items_item_id_fkey)
  end

  # The target: both its system and its path, or neither, for a work item without one;
  # the system a host name's characters, and the path 1 to `@max_target_path` code
  # points. Whether a work item needs one, and what else its path must be, are its
  # workspace's domain's rules, which Take in checks (`Apiary.Lingo.Domain`).
  defp validate_target(changeset) do
    case {get_field(changeset, :target_system), get_field(changeset, :target_path)} do
      {nil, nil} ->
        changeset

      {nil, _path} ->
        add_error(changeset, :target_system, "can't be blank", validation: :required)

      {_system, nil} ->
        add_error(changeset, :target_path, "can't be blank", validation: :required)

      {_system, _path} ->
        changeset
        |> validate_format(:target_system, @system)
        |> validate_length(:target_path, min: 1, max: @max_target_path, count: :codepoints)
    end
  end

  # The first instruction: at most `@max_instruction` code points, and none of the
  # characters a run's input refuses in a text, so that a work item taken in can always
  # be given to its run as it was written.
  defp validate_instruction(changeset) do
    changeset
    |> validate_length(:first_instruction, max: @max_instruction, count: :codepoints)
    |> refuse_in_instruction(
      @control,
      dgettext_noop("errors", "must not contain control characters")
    )
    |> refuse_in_instruction(
      @invisible,
      dgettext_noop("errors", "must not contain invisible characters")
    )
  end

  defp refuse_in_instruction(changeset, pattern, message) do
    validate_change(changeset, :first_instruction, fn :first_instruction, text ->
      if String.valid?(text) and not Regex.match?(pattern, text),
        do: [],
        else: [first_instruction: message]
    end)
  end
end
