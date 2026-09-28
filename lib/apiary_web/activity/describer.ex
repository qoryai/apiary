defmodule ApiaryWeb.Activity.Describer do
  @moduledoc """
  The words of the Activity page (`ApiaryWeb.ActivityLive`) for an entry of the audit
  trail (`Apiary.Audit`): what an action is called in the filter, the sentence that says
  what was done, what it was done to, and the change in a few words.

  A describer answers for the actions it knows and says nil for the others. The page asks
  the edition's describer first (`c:ApiaryWeb.Edition.activity_describer/0`), then the
  core's, `ApiaryWeb.Activity.Describer.Core`, and takes the first answer that is not nil
  (`describers/0`): an edition says its own actions, and may say one of the core's where
  the entry holds what only the edition writes, such as a reason of its own. Where none
  answers, the page says the action's code name, "Made a change" and "n/a".

  The names an entry needs are looked up when the page reads (`Apiary.Audit.names/2`),
  never stored in the trail, and a describer takes them from there: a name that is gone
  is said without it.
  """

  use Gettext, backend: ApiaryWeb.Gettext
  import ApiaryWeb.RichText, only: [rich_gettext: 2]

  alias Apiary.Accounts.Scope
  alias Apiary.Audit
  alias Apiary.Audit.Entry
  alias Apiary.Organisations.Workspace

  @typedoc """
  What an entry was done to: its words, whether they are a code name set in mono (a key id,
  a run's id, a target), and the page it links to, or nil.
  """
  @type subject :: %{text: String.t(), mono: boolean, href: String.t() | nil}

  @doc """
  The words of `action` in the Action filter, a noun phrase: "Member invited". Nil for an
  action the describer does not know.
  """
  @callback label(action :: atom) :: String.t() | nil

  @doc """
  Whether the Action filter offers `action` to the reader of `scope`. An entry of an
  action it does not offer still shows; the filter does not name it.
  """
  @callback offered?(Scope.t(), action :: atom) :: boolean

  @doc """
  What was done, one whole sentence without its full stop, from the entry and the names
  the page read: "Invited a member". Nil for an entry the describer does not say.
  """
  @callback sentence(action :: atom, Entry.t(), Audit.names()) :: String.t() | nil

  @doc """
  What `entry` was done to, as it is called now, in the scope of the page, with the
  workspace it is in where that one is in use, whose pages a subject may link to. Nil for
  an entry the describer does not say.
  """
  @callback subject(Entry.t(), action :: atom, Audit.names(), Scope.t(), %Workspace{} | nil) ::
              subject | nil

  @doc """
  The change in a few words, from the entry's before, after and details: rich text
  (`ApiaryWeb.RichText`) or a list of it, a line each. Nil for none, and for an action the
  describer does not know.
  """
  @callback change(action :: atom, before :: map, after_ :: map, details :: map) :: term

  @doc """
  describers/0 is the describers the Activity page asks, in the order it asks them: the
  edition's, when it has one, then the core's.
  """
  @spec describers() :: [module]
  def describers,
    do: Enum.reject([ApiaryWeb.Edition.activity_describer(), __MODULE__.Core], &is_nil/1)

  @doc "text/1 is a subject of plain words that links nowhere."
  @spec text(String.t()) :: subject
  def text(text), do: %{text: text, mono: false, href: nil}

  @doc """
  from_to/2 says a change from one value to another, "Admin → Owner", or nil when either
  is not a string.
  """
  @spec from_to(term, term) :: term
  def from_to(from, to) when is_binary(from) and is_binary(to),
    do: rich_gettext("%{from} → %{to}", from: from, to: to)

  def from_to(_from, _to), do: nil
end
