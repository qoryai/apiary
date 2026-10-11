defmodule ApiaryWeb.Activity.Actor do
  @moduledoc """
  Who made an entry of the audit trail, as the Activity page's Who column says it
  (`ApiaryWeb.ActivityLive`): a person by the email address their account has now, "you"
  beside the reader's own, "Former member" once the account is deleted; an access key by
  its label and key id, "An access key" once it is gone; the instance as Qory Apiary.

  The edition may say it instead (`c:ApiaryWeb.Edition.activity_actor/2`), from what it
  wrote into the entry's details (`c:Apiary.Edition.audit_details/3`), such as how the
  person reached the organisation; its nil leaves the core's words. The names are those
  the page read (`Apiary.Audit.names/2`), never stored in the trail.
  """
  use ApiaryWeb, :html

  alias Apiary.Accounts.Scope
  alias Apiary.Audit
  alias Apiary.Audit.Entry

  @typedoc """
  The core's words for an actor: its `kind` (`:person`, `:access_key`, `:instance`, or
  `:gone` for an account or a key that is no more), its `text`, `you?` for the reader's
  own entries, and `detail`, an access key's key id.
  """
  @type words :: %{
          required(:kind) => :person | :access_key | :instance | :gone,
          required(:text) => String.t() | nil,
          optional(:you?) => boolean | nil,
          optional(:detail) => String.t()
        }

  @typedoc "An entry's actor, as the column draws it: the core's words, and the edition's."
  @type t :: %{words: words, edition: Phoenix.LiveView.Rendered.t() | nil}

  @doc """
  of/4 is who made `entry`, in the scope of the page, from the names it read: the core's
  words, and what the edition renders instead (`c:ApiaryWeb.Edition.activity_actor/2`),
  asked once here, or nil. `edition` is the module asked, `ApiaryWeb.Edition` unless said,
  for tests.
  """
  @spec of(Entry.t(), Audit.names(), Scope.t(), module) :: t
  def of(%Entry{} = entry, names, scope, edition \\ ApiaryWeb.Edition) do
    words = words(entry, names, scope)

    %{
      words: words,
      edition:
        edition.activity_actor(entry, %{
          __changed__: nil,
          actor: words,
          names: names,
          scope: scope
        })
    }
  end

  @doc """
  words/3 is the core's words for who made `entry` (`t:words/0`), in the scope of the
  page, from the names it read.
  """
  @spec words(Entry.t(), Audit.names(), Scope.t()) :: words
  def words(%Entry{actor_kind: :person, actor_id: id}, names, scope) do
    case names.users[id] do
      nil -> %{kind: :gone, text: gettext("Former member")}
      email -> %{kind: :person, text: email, you?: scope.user && scope.user.id == id}
    end
  end

  def words(%Entry{actor_kind: :access_key, actor_id: id}, names, _scope) do
    case names.access_keys[id] do
      %{label: label, key_id: key_id} -> %{kind: :access_key, text: label, detail: key_id}
      nil -> %{kind: :gone, text: gettext("An access key")}
    end
  end

  def words(%Entry{actor_kind: :instance}, _names, _scope),
    do: %{kind: :instance, text: gettext("Qory Apiary")}

  @doc """
  The Who column's cell: the edition's rendering where it gave one (`of/4`), the core's
  words otherwise.
  """
  attr :id, :string, required: true
  attr :actor, :map, required: true, doc: "the actor, as `of/4` answers"

  def actor(assigns) do
    ~H"""
    <span id={@id} class="inline-flex min-w-0 items-center gap-2">
      <%= if @actor.edition do %>
        {@actor.edition}
      <% else %>
        <.core_words words={@actor.words} />
      <% end %>
    </span>
    """
  end

  attr :words, :map, required: true

  defp core_words(assigns) do
    ~H"""
    <%= case @words.kind do %>
      <% :person -> %>
        <span class="truncate">{@words.text}</span>
        <span :if={@words.you?} class="q-faint">{gettext("you")}</span>
      <% :gone -> %>
        <span class="q-faint truncate">{@words.text}</span>
      <% :access_key -> %>
        <.icon name="hero-key" class="size-3.5 flex-none text-faint" />
        <span :if={@words.text} class="truncate">{@words.text}</span>
        <span class="q-faint q-mono">{@words.detail}</span>
      <% :instance -> %>
        <.icon name="hero-cpu-chip" class="size-3.5 flex-none text-faint" />
        <span>{@words.text}</span>
    <% end %>
    """
  end
end
