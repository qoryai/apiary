defmodule Apiary.SourcesFixtures do
  @moduledoc """
  Test helpers for the bodies an adapter posts with the items of a collection and the
  comments of an item (`Apiary.Sources`): each built as the contract writes it and read by
  `Apiary.Sources.Wire`, as a request's body is.
  """

  import ExUnit.Assertions

  alias Apiary.AccessKeys
  alias Apiary.Accounts.Scope
  alias Apiary.Sources.Wire

  @at ~U[2026-10-15 11:00:00Z]

  @doc "The time the helpers below write an entry at, unless told otherwise."
  def at, do: @at

  @doc """
  An item with the ref `ref`, as the contract writes it. `opts` overrides `updated_at`
  (a `DateTime`, else `at/0`), `state` (`"open"`), `title` and `comment_count` (0).
  """
  def item(ref, opts \\ []) do
    %{
      "ref" => ref,
      "url" => "https://tracker.example.com/items/" <> URI.encode_www_form(ref),
      "title" => Keyword.get(opts, :title, "Title of " <> ref),
      "body" => "The text of " <> ref,
      "body_format" => "markdown",
      "filed_by" => %{"name" => "Avery Example", "kind" => "person"},
      "labels" => ["bug"],
      "state" => Keyword.get(opts, :state, "open"),
      "state_reason" => nil,
      "comment_count" => Keyword.get(opts, :comment_count, 0),
      "created_at" => time(@at),
      "updated_at" => time(Keyword.get(opts, :updated_at, @at))
    }
  end

  @doc """
  The body of `POST /v1/source-items` for the collection `collection_ref` with `items`
  (`item/2`), as `Apiary.Sources.Wire.items/1` reads it: an event, or, with
  `opts[:listing]` (`%{id:, part:, started_at:, complete:}`, each but the id defaulted:
  part 1, `at/0`, complete), a part of a listing.
  """
  def items_body(collection_ref, items, opts \\ []) do
    body = %{
      "version" => 1,
      "time" => time(DateTime.utc_now()),
      "collection_ref" => collection_ref,
      "items" => items
    }

    body =
      case Keyword.get(opts, :listing) do
        nil ->
          body

        listing ->
          Map.put(body, "listing", %{
            "id" => Map.fetch!(listing, :id),
            "part" => Map.get(listing, :part, 1),
            "started_at" => time(Map.get(listing, :started_at, @at)),
            "complete" => Map.get(listing, :complete, true)
          })
      end

    assert {:ok, decoded} = Wire.items(body)
    decoded
  end

  @doc """
  A comment with the ref `ref`, as the contract writes it. `opts` overrides `updated_at`
  (else `at/0`), `body` and `deleted` (left out).
  """
  def comment(ref, opts \\ []) do
    comment = %{
      "ref" => ref,
      "url" => "https://tracker.example.com/comments/" <> URI.encode_www_form(ref),
      "author" => %{"name" => "Robin Example", "kind" => "person"},
      "body" => Keyword.get(opts, :body, "A comment, " <> ref),
      "body_format" => "markdown",
      "created_at" => time(@at),
      "updated_at" => time(Keyword.get(opts, :updated_at, @at))
    }

    if Keyword.get(opts, :deleted), do: Map.put(comment, "deleted", true), else: comment
  end

  @doc """
  The body of `POST /v1/source-items/comments` for the item `item_ref` with `comments`
  (`comment/2`), as `Apiary.Sources.Wire.comments/1` reads it, with `complete` when
  `opts[:since]` gives its time.
  """
  def comments_body(item_ref, comments, opts \\ []) do
    body = %{
      "version" => 1,
      "time" => time(DateTime.utc_now()),
      "item_ref" => item_ref,
      "comments" => comments
    }

    body =
      case Keyword.get(opts, :since) do
        nil -> body
        since -> Map.put(body, "complete", %{"since" => time(since)})
      end

    assert {:ok, decoded} = Wire.comments(body)
    decoded
  end

  @doc "The verified scope of the adapter's key `key`, as a signed request carries it."
  def key_scope(key) do
    {:ok, verified} = AccessKeys.fetch_for_verification(key.key_id)
    Scope.for_access_key(verified)
  end

  defp time(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
