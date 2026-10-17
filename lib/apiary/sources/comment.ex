defmodule Apiary.Sources.Comment do
  # A comment on an item (`Apiary.Sources.Item`), as the adapter sent it. The table and
  # its rules are `20261017190000_keep_source_items`'s.
  #
  # `external_ref` is the adapter's ref for it, 1 to 200 characters, unique on its item.
  # `url` is its page at the source, `https://`, 2,048 characters at most. `author_name`,
  # 1 to 100 characters, and `author_kind`, `:person` or `:automation`, are stored as
  # sent. `body` is at most 65,536 characters, written in `body_format`. `truncated` names
  # the fields the adapter cut, `body` or `author.name`, each once. `source_created_at`
  # and `source_updated_at` are its times at its source, which tell an earlier write of it
  # from a later one. `deleted_at` is for a comment deleted at its source, or left out of
  # a complete set of the item's comments: the column marks it, so that its row can stay.
  # `deleted_by_complete_at` is for one that such a set left out and marked: the set's
  # `complete.since`, from `20261017191500_keep_when_a_complete_set_left_a_comment_out`;
  # only a comment marked deleted has it.
  #
  # A comment is of its item's organisation, held to it by the composite key, and goes
  # with its item. Every text is untrusted: shown as data, never followed.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias Apiary.Sources.Item

  @typedoc "A comment on an item."
  @type t :: %__MODULE__{}

  @max_ref 200
  @max_url 2048
  @max_name 100
  @max_body 65_536
  @kinds [:person, :automation]
  @truncatable ~w(body author.name)

  # definitions.schema.json, $defs.body_format.
  @body_format ~r/\A[a-z][a-z0-9_-]{0,39}\z/

  @fields [
    :external_ref,
    :url,
    :author_name,
    :author_kind,
    :body,
    :body_format,
    :truncated,
    :source_created_at,
    :source_updated_at
  ]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "source_item_comments" do
    field :external_ref, :string
    field :url, :string
    field :author_name, :string
    field :author_kind, Ecto.Enum, values: @kinds
    field :body, :string, default: ""
    field :body_format, :string
    field :truncated, {:array, :string}, default: []
    field :source_created_at, :utc_datetime
    field :source_updated_at, :utc_datetime
    field :deleted_at, :utc_datetime_usec
    field :deleted_by_complete_at, :utc_datetime

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :item, Item

    timestamps(type: :utc_datetime_usec)
  end

  # The fields an adapter may name in `truncated`.
  @doc false
  @spec truncatable() :: [String.t()]
  def truncatable, do: @truncatable

  # changeset/2 is the changeset of a comment as an adapter sent it, each field within
  # the bounds above, counted in code points as the database counts them. A value the
  # database refuses all the same is an error on its field. The organisation, the item,
  # `deleted_at` and `deleted_by_complete_at` are the caller's to put.
  @doc false
  @spec changeset(t, map) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = comment, attrs) do
    comment
    |> cast(attrs, @fields, empty_values: [nil])
    |> validate_required(@fields -- [:body, :truncated], trim: false)
    |> validate_length(:external_ref, min: 1, max: @max_ref, count: :codepoints)
    |> validate_length(:url, max: @max_url, count: :codepoints)
    |> validate_format(:url, ~r{\Ahttps://[^/?#@\s]+([/?#]\S*)?\z})
    |> validate_length(:author_name, min: 1, max: @max_name, count: :codepoints)
    |> validate_length(:body, max: @max_body, count: :codepoints)
    |> validate_format(:body_format, @body_format)
    |> validate_subset(:truncated, @truncatable)
    |> Item.validate_texts(:truncated, length(@truncatable), 11)
    |> check_constraint(:external_ref, name: :source_item_comments_external_ref_check)
    |> check_constraint(:url, name: :source_item_comments_url_check)
    |> check_constraint(:author_name, name: :source_item_comments_author_check)
    |> check_constraint(:body, name: :source_item_comments_body_check)
    |> check_constraint(:body_format, name: :source_item_comments_body_format_check)
    |> check_constraint(:truncated, name: :source_item_comments_truncated_check)
    |> check_constraint(:deleted_by_complete_at,
      name: :source_item_comments_deleted_by_complete_check
    )
    |> unique_constraint(:external_ref,
      name: :source_item_comments_item_id_external_ref_index
    )
    |> foreign_key_constraint(:item_id, name: :source_item_comments_item_id_fkey)
  end
end
