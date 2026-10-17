defmodule Apiary.Sources.Item do
  # An item an adapter sends of a collection (`Apiary.Adapters.Collection`): a piece of
  # work at the source, such as an issue. The contract calls it an item; the pages call it
  # a ticket. The table and its rules are `20261017190000_keep_source_items`'s.
  #
  # `external_ref` is the adapter's ref for it, 1 to 200 characters, unique in its
  # collection, which the core compares and stores and never reads meaning into. `key` is
  # the item's name at its source, such as `#1231`, 1 to 64 characters or nil, shown as
  # text and never parsed. `url` is its page at the source, `https://`, 2,048 characters
  # at most; `title` 1 to 1,024 characters; `body` at most 65,536, written in
  # `body_format` (`Apiary.Sources.Body`). `filed_by_name`, 1 to 100 characters, and
  # `filed_by_kind`, `:person` or `:automation`, are stored as sent. `labels` are at most
  # 100, each 1 to 100 characters, each once. `state` is `:open` or `:closed`, with
  # `state_reason`, at most 64 characters, or nil. `type` is the adapter's word for what
  # it is, or nil. The target (`target_system`, `target_path`, both or neither) is where
  # a change for it would go. `truncated` names the fields the adapter cut, each once.
  # `comment_count` is how many comments it has at its source. `source_created_at` and
  # `source_updated_at` are its times at its source; the newer one wins.
  #
  # `closed_by_listing_at` is when a complete listing closed it by leaving it out; only a
  # closed item has it. `disconnected_at` is when the adapter said its collection is out
  # of reach: the item is marked, never deleted. An item stays with its collection when
  # the collection ends.
  #
  # `organisation_id` and `adapter_id` are its collection's, held to it by the composite
  # key. `public_id` is its name outside the database: `tk_`, then sixteen lowercase
  # Crockford base32 characters (`Apiary.PublicId`), made by the column's default,
  # `source_item_public_id()`, or by `new_public_id/0`, the same shape.
  #
  # Every text and label is untrusted: shown as data, never followed. The database holds
  # every bound above, and counts characters as code points, as `changeset/2` does.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Apiary.Adapters.Collection
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.Organisation

  @typedoc "An item of a collection: a ticket."
  @type t :: %__MODULE__{}

  @prefix "tk"
  @max_ref 200
  @max_key 64
  @max_url 2048
  @max_title 1024
  @max_body 65_536
  @max_name 100
  @max_labels 100
  @max_label 100
  @max_state_reason 64
  @max_path 200
  @kinds [:person, :automation]
  @states [:open, :closed]
  @truncatable ~w(title body filed_by.name labels)

  # definitions.schema.json: $defs.body_format, $defs.type and $defs.target's system.
  @body_format ~r/\A[a-z][a-z0-9_-]{0,39}\z/
  @type_pattern ~r/\A[a-z][a-z ]{0,39}\z/
  @system ~r/\A[a-z0-9.-]{1,253}\z/

  @fields [
    :external_ref,
    :key,
    :url,
    :title,
    :body,
    :body_format,
    :filed_by_name,
    :filed_by_kind,
    :labels,
    :state,
    :state_reason,
    :type,
    :target_system,
    :target_path,
    :truncated,
    :comment_count,
    :source_created_at,
    :source_updated_at
  ]

  @required [
    :external_ref,
    :url,
    :title,
    :body_format,
    :filed_by_name,
    :filed_by_kind,
    :state,
    :comment_count,
    :source_created_at,
    :source_updated_at
  ]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Phoenix.Param, key: :public_id}
  schema "source_items" do
    field :public_id, :string, read_after_writes: true
    field :external_ref, :string
    field :key, :string
    field :url, :string
    field :title, :string
    field :body, :string, default: ""
    field :body_format, :string
    field :filed_by_name, :string
    field :filed_by_kind, Ecto.Enum, values: @kinds
    field :labels, {:array, :string}, default: []
    field :state, Ecto.Enum, values: @states
    field :state_reason, :string
    field :type, :string
    field :target_system, :string
    field :target_path, :string
    field :truncated, {:array, :string}, default: []
    field :comment_count, :integer, default: 0
    field :source_created_at, :utc_datetime
    field :source_updated_at, :utc_datetime
    field :closed_by_listing_at, :utc_datetime_usec
    field :disconnected_at, :utc_datetime_usec

    belongs_to :organisation, Organisation
    belongs_to :adapter, Node
    belongs_to :collection, Collection

    has_many :comments, Apiary.Sources.Comment

    timestamps(type: :utc_datetime_usec)
  end

  # The prefix of an item's public id, `tk`.
  @doc false
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  # A fresh public id for an item: `tk_` and sixteen characters.
  @doc false
  @spec new_public_id() :: String.t()
  def new_public_id, do: Apiary.PublicId.generate(@prefix)

  # Whether `id` is an item's public id, in the shape `Apiary.PublicId` makes.
  @doc false
  @spec public_id?(term) :: boolean
  def public_id?(id), do: Apiary.PublicId.valid?(@prefix, id)

  # The fields an adapter may name in `truncated`.
  @doc false
  @spec truncatable() :: [String.t()]
  def truncatable, do: @truncatable

  # changeset/2 is the changeset of an item as an adapter sent it: every field of the
  # contract's item, each within the bounds above, counted in code points as the database
  # counts them. A value the database refuses all the same is an error on its field. The
  # organisation, the adapter and the collection are the caller's to put, as are
  # `closed_by_listing_at` and `disconnected_at`.
  @doc false
  @spec changeset(t, map) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = item, attrs) do
    item
    |> cast(attrs, @fields, empty_values: [nil])
    |> validate_required(@required, trim: false)
    |> validate_length(:external_ref, min: 1, max: @max_ref, count: :codepoints)
    |> validate_length(:key, min: 1, max: @max_key, count: :codepoints)
    |> validate_length(:url, max: @max_url, count: :codepoints)
    |> validate_format(:url, ~r{\Ahttps://[^/?#@\s]+([/?#]\S*)?\z})
    |> validate_length(:title, min: 1, max: @max_title, count: :codepoints)
    |> validate_length(:body, max: @max_body, count: :codepoints)
    |> validate_format(:body_format, @body_format)
    |> validate_length(:filed_by_name, min: 1, max: @max_name, count: :codepoints)
    |> validate_texts(:labels, @max_labels, @max_label)
    |> validate_length(:state_reason, max: @max_state_reason, count: :codepoints)
    |> validate_format(:type, @type_pattern)
    |> validate_target()
    |> validate_subset(:truncated, @truncatable)
    |> validate_texts(:truncated, length(@truncatable), 13)
    |> validate_number(:comment_count, greater_than_or_equal_to: 0)
    |> check_constraint(:public_id, name: :source_items_public_id_check)
    |> check_constraint(:external_ref, name: :source_items_external_ref_check)
    |> check_constraint(:key, name: :source_items_key_check)
    |> check_constraint(:url, name: :source_items_url_check)
    |> check_constraint(:title, name: :source_items_title_check)
    |> check_constraint(:body, name: :source_items_body_check)
    |> check_constraint(:body_format, name: :source_items_body_format_check)
    |> check_constraint(:filed_by_name, name: :source_items_filed_by_check)
    |> check_constraint(:labels, name: :source_items_labels_check)
    |> check_constraint(:state, name: :source_items_state_check)
    |> check_constraint(:state_reason, name: :source_items_state_reason_check)
    |> check_constraint(:type, name: :source_items_type_check)
    |> check_constraint(:target_system, name: :source_items_target_check)
    |> check_constraint(:truncated, name: :source_items_truncated_check)
    |> check_constraint(:comment_count, name: :source_items_comment_count_check)
    |> check_constraint(:closed_by_listing_at, name: :source_items_closed_by_listing_check)
    |> unique_constraint(:external_ref, name: :source_items_collection_id_external_ref_index)
    |> unique_constraint(:public_id, name: :source_items_public_id_index)
    |> foreign_key_constraint(:collection_id, name: :source_items_collection_id_fkey)
  end

  # Both or neither, the system to the contract's pattern and the path 1 to 200
  # characters.
  defp validate_target(changeset) do
    case {get_field(changeset, :target_system), get_field(changeset, :target_path)} do
      {nil, nil} ->
        changeset

      {nil, _path} ->
        add_error(changeset, :target_system, "can't be blank")

      {_system, nil} ->
        add_error(changeset, :target_path, "can't be blank")

      {_system, _path} ->
        changeset
        |> validate_format(:target_system, @system)
        |> validate_length(:target_path, min: 1, max: @max_path, count: :codepoints)
    end
  end

  # At most `most` texts, each 1 to `longest` code points, each once.
  @doc false
  @spec validate_texts(Ecto.Changeset.t(), atom, pos_integer, pos_integer) ::
          Ecto.Changeset.t()
  def validate_texts(changeset, field, most, longest) do
    validate_change(changeset, field, fn ^field, texts ->
      cond do
        length(texts) > most ->
          [{field, {"should have at most %{count} item(s)", count: most, validation: :length}}]

        Enum.any?(texts, &(not text?(&1, longest))) or
            length(Enum.uniq(texts)) != length(texts) ->
          [{field, {"is invalid", validation: :texts}}]

        true ->
          []
      end
    end)
  end

  defp text?(text, longest) when is_binary(text),
    do: String.valid?(text) and length(String.codepoints(text)) in 1..longest

  defp text?(_text, _longest), do: false
end
