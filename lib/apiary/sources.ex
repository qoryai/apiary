defmodule Apiary.Sources do
  # The tickets of a workspace's Backlog as their adapters send them: the items of a
  # collection (`Apiary.Sources.Item`, `tk_…`) and their comments (`Apiary.Sources.Comment`),
  # kept as a mirror of the source. The contract calls them items; the pages call them
  # tickets.
  #
  #   * `post_items/2` takes the body of `POST /v1/source-items`, as
  #     `Apiary.Sources.Wire.items/1` decoded it, from the adapter's key of `key_scope`;
  #   * `post_comments/2` takes the body of `POST /v1/source-items/comments`, as
  #     `Apiary.Sources.Wire.comments/1` decoded it;
  #   * `comment_failed/2` takes the body of `POST /v1/work-items/changes/failed`, as
  #     `Apiary.Sources.Wire.failed/1` decoded it: the adapter stopped trying to post a
  #     member's comment (`Apiary.Sources.Posts`);
  #   * `post_again/2` posts a member's comment again after such a report;
  #   * `purge_listings/1` deletes the bookkeeping of items listings a day after their
  #     first part (`Apiary.Adapters.SeenRequestsPurge` runs it).
  #
  # Each post answers `{:ok, :accepted}`, or a refusal in the contract's order, which
  # changes nothing: `{:error, :forbidden}`, `{:error, :ended}` (`connection_ended`),
  # `{:error, :suspended}` (`connection_suspended`), `{:error, :not_linked}`
  # (`collection_not_linked`); and `{:error, :invalid}` for a body the tables would not
  # hold, or a listing's part that disagrees with the parts before it. How each is
  # decided, what is kept and the locks taken are `Apiary.Sources.Ingest`'s.
  #
  # **Broadcasts.** Once a post's change commits, each workspace whose Backlog it changed
  # is sent, on its topic (`Apiary.Sources.Topic.topic/1`, `"backlog:"` and the
  # workspace's id), `{:tickets_changed, ids}`: the public ids (`tk_…`) of the tickets of
  # its collections that the post wrote, ended or closed, or whose comments it changed,
  # each once. Ids only: a reader loads what it may see. A collection linked to no
  # workspace is told nothing; a post that changed nothing sends nothing.
  # `comment_failed/2` and `post_again/2` send the same message, with the ticket of the
  # comment they changed (`Apiary.Sources.Posts`).
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  alias Apiary.Accounts.Scope
  alias Apiary.Sources.{Comment, Ingest, Posts, Topic, Wire}

  @doc false
  # post_items/2 keeps the items of one collection, as the module says.
  @spec post_items(Scope.t() | nil, Wire.items()) ::
          {:ok, :accepted} | {:error, Ingest.refusal()}
  def post_items(key_scope, %{collection_ref: _, items: _, listing: _} = items),
    do: key_scope |> Ingest.items(items) |> broadcast()

  @doc false
  # post_comments/2 keeps the comments of one item, as the module says.
  @spec post_comments(Scope.t() | nil, Wire.comments()) ::
          {:ok, :accepted} | {:error, Ingest.refusal()}
  def post_comments(key_scope, %{item_ref: _, comments: _, complete: _} = comments),
    do: key_scope |> Ingest.comments(comments) |> broadcast()

  @doc false
  # comment_failed/2 keeps an adapter's report that it stopped trying to post a member's
  # comment: `{:ok, :accepted}`, or `{:error, :forbidden}` for a key that may not post
  # comments (`source_item.post`).
  @spec comment_failed(Scope.t() | nil, Wire.failed()) ::
          {:ok, :accepted} | {:error, :forbidden}
  defdelegate comment_failed(key_scope, report), to: Posts, as: :failed

  @doc false
  # post_again/2 posts again the member's comment `comment_id`, marked not posted, for a
  # person with `work_item.take_in` in the scope's workspace: `{:ok, comment}`, or
  # `{:error, :not_found | :forbidden | :not_failed}`.
  @spec post_again(Scope.t(), String.t()) ::
          {:ok, Comment.t()} | {:error, :not_found | :forbidden | :not_failed}
  defdelegate post_again(scope, comment_id), to: Posts

  @doc false
  # purge_listings/1 deletes the bookkeeping of items listings whose first part arrived
  # more than a day before `now`. The number deleted. Run twice, the second run deletes
  # nothing more.
  @spec purge_listings(DateTime.t()) :: non_neg_integer
  defdelegate purge_listings(now), to: Ingest

  # The change has committed: each workspace it changed is told the ids. A message that
  # cannot be sent is dropped, and the post still answers as it went.
  defp broadcast({:ok, changed}) when is_map(changed) do
    for {workspace_id, ids} <- changed, ids != [] do
      _sent =
        Phoenix.PubSub.broadcast(
          Apiary.PubSub,
          Topic.topic(workspace_id),
          {:tickets_changed, Enum.uniq(ids)}
        )
    end

    {:ok, :accepted}
  end

  defp broadcast({:error, _reason} = refused), do: refused
end
