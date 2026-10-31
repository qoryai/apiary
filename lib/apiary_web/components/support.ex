defmodule ApiaryWeb.Support do
  @moduledoc """
  "Contact support", in every place people in an organisation read it: a link to the
  support address (`Apiary.SupportAddress`) where one is set, `mailto:` for an email
  address, and plain text where none is. The core's pages and an edition's use it, so the
  words and where they lead are the same everywhere.

  Three forms, by where the words go:

  - `contact/1`, a function component, where the words stand alone in a template:

        <ApiaryWeb.Support.contact />
        <ApiaryWeb.Support.contact mid_sentence />

  - `rich/1`, rich text (`ApiaryWeb.RichText`), where the words are part of a translated
    sentence. The sentence is one msgid with a `%{contact_support}` binding, so a
    translation moves the words wherever its language needs them:

        <.rich text={
          rich_gettext("%{contact_support} with run %{run}.",
            contact_support: ApiaryWeb.Support.rich(),
            run: {:m, run.public_id}
          )
        } />

        rich_gettext("If it fails again, %{contact_support}.",
          contact_support: ApiaryWeb.Support.rich(mid_sentence: true)
        )

  - `text/1`, plain text, for an email's text part and other places without HTML:
    "Contact support at support@example.com.", or "Contact support." where no address is
    set.

  The words are "Contact support" at the start of a sentence and "contact support" inside
  one (`mid_sentence`). Each form reads the address when it is called
  (`Apiary.SupportAddress.get/0`), from the node's copy, unless `address` gives one; give
  `address: nil` for the plain words.
  """
  use Phoenix.Component
  use Gettext, backend: ApiaryWeb.Gettext

  alias Apiary.SupportAddress

  @doc """
  contact/1 renders the words "Contact support", or "contact support" with
  `mid_sentence`, as a link to the support address, or as plain text where none is set.
  The inner block, where given, takes the place of the words, as the link's text too.

      <ApiaryWeb.Support.contact id="run-failed-support" />
  """
  attr :id, :string, default: nil

  attr :mid_sentence, :boolean,
    default: false,
    doc: ~s(true for "contact support", inside a sentence; false for "Contact support")

  attr :address, :any,
    default: :stored,
    doc: "the address to link to, or nil for none; `:stored` reads `Apiary.SupportAddress.get/0`"

  attr :class, :string, default: "q-link", doc: "the link's class; plain text has none"
  slot :inner_block, doc: "words in place of Contact support"

  def contact(assigns) do
    assigns
    |> assign(
      href: SupportAddress.href(address(assigns.address)),
      words: words(assigns.mid_sentence)
    )
    |> link_or_text()
  end

  defp link_or_text(%{href: nil} = assigns) do
    ~H"""
    <span id={@id}>{if @inner_block != [], do: render_slot(@inner_block), else: @words}</span>
    """
  end

  defp link_or_text(assigns) do
    ~H"""
    <a id={@id} href={@href} class={@class} rel="noopener noreferrer">{if @inner_block != [],
      do: render_slot(@inner_block),
      else: @words}</a>
    """
  end

  @doc """
  rich/1 is the words as rich text (`ApiaryWeb.RichText`), for the `%{contact_support}`
  binding of a translated sentence: `{:href, href, words}` where an address is set, the
  words alone where none is.

  Options: `mid_sentence: true` for "contact support"; `address:` an address, or nil for
  none, in place of `Apiary.SupportAddress.get/0`.

      iex> ApiaryWeb.Support.rich(address: "support@example.com")
      {:href, "mailto:support@example.com", "Contact support"}

      iex> ApiaryWeb.Support.rich(address: nil, mid_sentence: true)
      "contact support"
  """
  @spec rich(keyword) :: {:href, String.t(), String.t()} | String.t()
  def rich(opts \\ []) when is_list(opts) do
    words = words(Keyword.get(opts, :mid_sentence, false))

    case SupportAddress.href(address(Keyword.get(opts, :address, :stored))) do
      nil -> words
      href -> {:href, href, words}
    end
  end

  @doc """
  text/1 is a sentence in plain text, for an email's text part and other places without
  HTML: "Contact support at %{address}." where an address is set, "Contact support." where
  none is. Takes `address:` as `rich/1` does.

      iex> ApiaryWeb.Support.text(address: "https://help.example.com")
      "Contact support at https://help.example.com."

      iex> ApiaryWeb.Support.text(address: nil)
      "Contact support."
  """
  @spec text(keyword) :: String.t()
  def text(opts \\ []) when is_list(opts) do
    case address(Keyword.get(opts, :address, :stored)) do
      nil -> gettext("Contact support.")
      address -> gettext("Contact support at %{address}.", address: address)
    end
  end

  @doc """
  stored_line/2 is one line of text that Qory Apiary stored in English, such as the fix
  line of an escalation's stopped run (`Apiary.Stages.StopCause`), as rich text: a line
  that starts with "Contact support" has those words as `rich/1` makes them, a link where
  an address is set, and the rest of the line as it is stored; any other line is
  unchanged. The stored text stays as it is; the link is made when the line is shown.
  Takes `address:` as `rich/1` does. Split a text of several lines at `"\n"` first.

      iex> ApiaryWeb.Support.stored_line("Contact support with run r-42.", address: "support@example.com")
      [{:href, "mailto:support@example.com", "Contact support"}, " with run r-42."]

      iex> ApiaryWeb.Support.stored_line("Contact support with run r-42.", address: nil)
      ["Contact support", " with run r-42."]

      iex> ApiaryWeb.Support.stored_line("The run ended with an error.", address: nil)
      "The run ended with an error."
  """
  @spec stored_line(String.t(), keyword) :: String.t() | list
  def stored_line(line, opts \\ []) when is_binary(line) and is_list(opts) do
    case line do
      "Contact support" <> rest -> [rich(Keyword.take(opts, [:address])), rest]
      other -> other
    end
  end

  defp address(:stored), do: SupportAddress.get()
  defp address(address) when is_binary(address) or is_nil(address), do: address

  defp words(false), do: gettext("Contact support")
  defp words(true), do: gettext("contact support")
end
