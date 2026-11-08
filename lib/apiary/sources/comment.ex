defmodule Apiary.Sources.Comment do
  # A comment on an item (`Apiary.Sources.Item`), as the adapter sent it. The table and
  # its rules are `20261017143000_keep_source_items`'s.
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
  # `complete.since`, from `20261017151000_keep_when_a_complete_set_left_a_comment_out`;
  # only a comment marked deleted has it.
  #
  # A member's comment is one a member wrote on the ticket in Qory Apiary
  # (`member_changeset/3`), from `20261106130000_keep_a_member_s_comment_on_a_ticket`.
  # `author_id` is the member, nil once their account's row is gone; `author_name` is
  # the name members see for them (`member_name/1`), `author_kind` `:person`.
  # `comment_id` is its id, `sc_` and sixteen lowercase Crockford base32 characters
  # (`Apiary.PublicId`), unique. `post_state` is how far its post at the source is:
  # `:posting`, `:posted`, `:not_posted`, or `:kept` for a source that takes no comments
  # (`first_state/1`). `post_failure` is why a post failed, `:item_gone`,
  # `:not_permitted`, `:too_long`, `:unreachable` or `:deleted_at_source`, only with
  # `:not_posted`. It has an `external_ref` and a `url` only once it is posted. A comment
  # the adapter sent has none of these four, and always a ref and a URL. A complete set
  # of the item's comments never marks a member's comment deleted
  # (`Apiary.Sources.Ingest`).
  #
  # A comment is of its item's organisation, held to it by the composite key, and goes
  # with its item. Every text is untrusted: shown as data, never followed.
  #
  # The module reference leaves out this module of the `factory` feature.
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
  @prefix "sc"
  @post_states [:posting, :posted, :not_posted, :kept]
  @post_failures [:item_gone, :not_permitted, :too_long, :unreachable, :deleted_at_source]
  # The characters a prose line refuses (`description.schema.json`, `$defs.line`): the
  # control characters, the bidirectional controls, the line and paragraph separators and
  # the format characters that are usually not shown.
  @not_in_line ~r/[\x{0}-\x{1F}\x{7F}-\x{9F}\x{AD}\x{61C}\x{180E}\x{200B}\x{200E}\x{200F}\x{2028}\x{2029}\x{202A}-\x{202E}\x{2060}-\x{2064}\x{2066}-\x{2069}\x{FEFF}\x{FFF9}-\x{FFFB}]/u
  # A character other than a space: `author_name` has at least one.
  @not_only_spaces ~r/[^\x{20}\x{A0}\x{1680}\x{2000}-\x{200A}\x{202F}\x{205F}\x{3000}]/u
  # The name of a member's comment when the rule takes nothing of its account's short name.
  @member "Member"
  # The most characters a member's comment has: the contract's body limit, 65,536, less
  # room for the line the adapter adds before it at the source.
  @max_member_body 65_000

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
    field :comment_id, :string
    field :post_state, Ecto.Enum, values: @post_states
    field :post_failure, Ecto.Enum, values: @post_failures

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :item, Item
    belongs_to :author, Apiary.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  # The fields an adapter may name in `truncated`.
  @doc false
  @spec truncatable() :: [String.t()]
  def truncatable, do: @truncatable

  # prefix/0 is the prefix of a member's comment's id, `sc`.
  @doc false
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  # max_member_body/0 is the most characters, code points, a member's comment has.
  @doc false
  @spec max_member_body() :: pos_integer
  def max_member_body, do: @max_member_body

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

  # member_name/1 is the name a member's comment has for its author, from the email
  # address of their account: its local part, the name members see for them
  # (`Apiary.Accounts.User.short_name/1`), made to follow the contract's rule for the
  # name of a comment entry (`changes.schema.json`, `author_name`, a prose line of
  # `description.schema.json`): without the characters a prose line refuses
  # (`@not_in_line`), cut to 100 characters, code points, and with at least one that is
  # not a space (`@not_only_spaces`). `Member` when nothing is left that the rule takes.
  @doc false
  @spec member_name(String.t() | nil) :: String.t()
  def member_name(email) do
    name =
      if is_binary(email) and String.valid?(email),
        do:
          email
          |> Apiary.Accounts.User.short_name()
          |> String.replace(@not_in_line, "")
          |> String.codepoints()
          |> Enum.take(@max_name)
          |> Enum.join(),
        else: ""

    if String.match?(name, @not_only_spaces), do: name, else: @member
  end

  # member_name?/1 is true when `name` is a name the contract's rule takes for a comment
  # entry, as `member_name/1` makes one: valid UTF-8, 1 to 100 characters, code points,
  # none a prose line refuses, at least one not a space.
  @doc false
  @spec member_name?(term) :: boolean
  def member_name?(name) do
    is_binary(name) and String.valid?(name) and byte_size(name) <= 4 * @max_name and
      length(String.to_charlist(name)) in 1..@max_name and
      not String.match?(name, @not_in_line) and
      String.match?(name, @not_only_spaces)
  end

  # comment_id?/1 is true when `id` is a member's comment's id: `sc_` and sixteen
  # lowercase Crockford base32 characters.
  @doc false
  @spec comment_id?(term) :: boolean
  def comment_id?(id), do: Apiary.PublicId.valid?(@prefix, id)

  # first_state/1 is the state a member's comment starts in, by the `comments` flag of
  # its source's description: `:posting` for `true`, the source takes comments; `:kept`
  # for `false` and for none, and the comment stays in Qory Apiary.
  @doc false
  @spec first_state(boolean | nil) :: :posting | :kept
  def first_state(true), do: :posting
  def first_state(comments) when comments in [false, nil], do: :kept

  # member_changeset/3 is the changeset of a member's comment on a ticket: `body`, its
  # text, at most `max_member_body/0` code points; `author_name`, 1 to 100 characters;
  # `post_state`, `:posting` or `:kept`. It is written in Markdown, has a fresh
  # `comment_id`, `author_kind` `:person`, no ref and no URL, and its times at its source
  # are `now`, so it sorts among the item's comments by when it was written. A value the
  # database refuses all the same is an error on its field. The organisation, the item
  # and the author are the caller's to put.
  @doc false
  @spec member_changeset(t, map, DateTime.t()) :: Ecto.Changeset.t()
  def member_changeset(%__MODULE__{} = comment, attrs, %DateTime{} = now) do
    now = DateTime.truncate(now, :second)

    comment
    |> cast(attrs, [:body, :author_name, :post_state], empty_values: [nil], force_changes: true)
    |> validate_required([:body, :author_name, :post_state], trim: false)
    |> validate_length(:body, min: 1, max: @max_member_body, count: :codepoints)
    |> validate_length(:author_name, min: 1, max: @max_name, count: :codepoints)
    |> validate_inclusion(:post_state, [:posting, :kept])
    |> change(
      comment_id: Apiary.PublicId.generate(@prefix),
      author_kind: :person,
      body_format: "markdown",
      source_created_at: now,
      source_updated_at: now
    )
    |> check_constraint(:author_name, name: :source_item_comments_author_check)
    |> check_constraint(:body, name: :source_item_comments_body_check)
    |> check_constraint(:comment_id, name: :source_item_comments_comment_id_check)
    |> check_constraint(:post_state, name: :source_item_comments_post_state_check)
    |> check_constraint(:post_failure, name: :source_item_comments_post_failure_check)
    |> check_constraint(:url, name: :source_item_comments_ref_url_check)
    |> unique_constraint(:comment_id, name: :source_item_comments_comment_id_index)
    |> foreign_key_constraint(:item_id, name: :source_item_comments_item_id_fkey)
    |> foreign_key_constraint(:author_id, name: :source_item_comments_author_id_fkey)
  end
end
