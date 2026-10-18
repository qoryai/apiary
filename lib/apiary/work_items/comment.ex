defmodule Apiary.WorkItems.Comment do
  # A comment: what a member wrote on a work item's Thread, in plain text, for the members
  # of its workspace (`Apiary.WorkItems.Moves`). Nothing of it is posted on the ticket, and
  # no run is given it.
  #
  # `public_id` is its name outside the database: `cm_`, then sixteen lowercase Crockford
  # base32 characters (`Apiary.PublicId`), what a page's DOM ids and events name it by.
  # `body` is the text: its line breaks line feeds, trimmed, 1 to 4,000 characters counted
  # as code points, holding no character a text of several lines may not
  # (`Apiary.Names.validate_characters/3`): no control or format character but tab, line
  # feed and the join controls, and no line or paragraph separator. `author_id` is the
  # member who wrote it, nil once their account's row is gone, and `inserted_at` when.
  #
  # A deleted comment keeps its row, so the Thread keeps a line in its place: `deleted_at`,
  # and `deleted_by_id`, who deleted it, nil once their account's row is gone. Its body is
  # gone. A comment is of its work item's workspace, held to it by the composite key, and
  # follows it, as its events do. The database holds the length, a body exactly while the
  # comment is not deleted, and who deleted it only once it is; the trimming, the line
  # feeds and the characters the application checks.
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @typedoc "A comment on a work item's Thread."
  @type t :: %__MODULE__{}

  @prefix "cm"
  @max_body 4000

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "work_item_comments" do
    field :public_id, :string
    field :body, :string
    field :inserted_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec

    belongs_to :organisation, Apiary.Organisations.Organisation
    belongs_to :workspace, Apiary.Organisations.Workspace
    belongs_to :work_item, Apiary.WorkItems.WorkItem
    belongs_to :author, Apiary.Accounts.User
    belongs_to :deleted_by, Apiary.Accounts.User
  end

  # prefix/0 is the prefix of a comment's public id, `cm`.
  @doc false
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  # max_body/0 is the most characters, code points, a comment's body has.
  @doc false
  @spec max_body() :: pos_integer
  def max_body, do: @max_body

  # changeset/2 is the changeset of a new comment's body, with a fresh public id. A body of
  # more than four bytes for each character it may have is too long before it is read any
  # further. Then its line breaks become line feeds and it is trimmed; it holds no
  # character `Apiary.Names.validate_characters/3` refuses in a text of several lines;
  # empty, it is required; and it is at most `@max_body` code points. A value the
  # database refuses all the same is an error on its field. The work item, its workspace
  # and organisation, the author and the time are the caller's to put.
  @doc false
  @spec changeset(t, map) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = comment, attrs) do
    comment
    |> cast(attrs, [:body], empty_values: [nil])
    |> body()
    |> put_change(:public_id, Apiary.PublicId.generate(@prefix))
    |> check_constraint(:body, name: :work_item_comments_body_check)
    |> check_constraint(:public_id, name: :work_item_comments_public_id_check)
    |> unique_constraint(:public_id, name: :work_item_comments_public_id_index)
    |> foreign_key_constraint(:work_item_id, name: :work_item_comments_work_item_id_fkey)
  end

  defp body(changeset) do
    case fetch_change(changeset, :body) do
      {:ok, body} when is_binary(body) and byte_size(body) > 4 * @max_body ->
        add_error(changeset, :body, "should be at most %{count} character(s)",
          count: @max_body,
          validation: :length,
          kind: :max,
          type: :string
        )

      {:ok, body} when is_binary(body) ->
        changeset
        |> put_change(:body, if(String.valid?(body), do: normal(body), else: body))
        |> Apiary.Names.validate_characters(:body, lines: true)
        |> validate_required([:body])
        |> validate_length(:body, min: 1, max: @max_body, count: :codepoints)

      _none ->
        validate_required(changeset, [:body])
    end
  end

  # A text as a form gives it back: its line breaks line feeds, trimmed.
  defp normal(text), do: text |> String.replace(["\r\n", "\r"], "\n") |> String.trim()

  # error/1 is what is wrong with the body of a comment `changeset/2` refused, as the page
  # says it: `:blank`, `{:too_long, @max_body}` or `:characters`; nil for anything else.
  @doc false
  @spec error(Ecto.Changeset.t()) :: :blank | {:too_long, pos_integer} | :characters | nil
  def error(%Ecto.Changeset{errors: errors}) do
    case Keyword.get(errors, :body) do
      {_message, opts} ->
        cond do
          opts[:constraint] -> nil
          opts[:validation] == :required -> :blank
          opts[:validation] == :length and opts[:kind] == :min -> :blank
          opts[:validation] == :length and opts[:kind] == :max -> {:too_long, @max_body}
          opts[:validation] == :cast -> nil
          # `Apiary.Names.validate_characters/3`'s, which names no validation.
          true -> :characters
        end

      nil ->
        nil
    end
  end
end
